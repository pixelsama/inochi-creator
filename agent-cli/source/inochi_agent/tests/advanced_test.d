module inochi_agent.tests.advanced_test;

import std.exception : assertThrown;
import std.file : exists, read, write, remove, mkdir, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.json : JSONValue, parseJSON;
import std.math : abs;
import std.uuid : randomUUID;
import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import inochi_agent.sdkvalidate;
import inochi_agent.cpurender;

// Synthetic pixels only. Every test owns an isolated directory.
private struct Fixture {
    string directory;
    string input;
    string output;
    static Fixture create(ubyte alpha = 255, string blendMode = "norm", bool duplicateNames = false) {
        Fixture f;
        f.directory = buildPath(tempDir(), "inochi-advanced-" ~ randomUUID().toString());
        mkdir(f.directory);
        f.input = buildPath(f.directory, "base.inx");
        f.output = buildPath(f.directory, "rig.inx");
        AgentPsdImportLayer part;
        part.name = "Iris"; part.path = "/Iris";
        part.visible = true; part.width = 4; part.height = 4;
        part.left = 14; part.top = 14; part.blendMode = blendMode;
        part.rgba.length = 64;
        foreach (i; 0 .. 16) part.rgba[i * 4 .. i * 4 + 4] = [200, 80, 40, alpha];
        AgentPsdImportDocument doc;
        doc.width = 32; doc.height = 32;
        doc.sourceLayerRecordCount = 1; doc.layers = [part];
        if (duplicateNames) { doc.layers ~= part; doc.sourceLayerRecordCount = 2; }
        write(f.input, agentBuildInitialInx(doc, "synthetic-agent"));
        return f;
    }
    void cleanup() { if (exists(directory)) rmdirRecurse(directory); }
}

private JSONValue vectorRig() {
    return parseJSON(`{"parameters":[{
      "name":"HeadXY",
      "axes":[{"min":-1,"max":1,"default":0,"keys":[-1,0,1]},
              {"min":0,"max":1,"default":0,"keys":[0,1]}],
      "bindings":[{"path":"/Iris","property":"transform.t.x",
                   "values":[[0,10],[2,12],[4,14]]}]
    }]}`);
}

unittest {
    auto f = Fixture.create(255, "norm", true); scope(exit) f.cleanup();
    auto original = agentReadModelPayload(f.input);
    auto uuid = cast(ulong)original["nodes"]["children"][0]["uuid"].integer;
    agentRenameNode(f.input, f.output, uuid, "EyeRight");
    auto renamed = agentReadModelPayload(f.output);
    assert(renamed["nodes"]["children"][0]["name"].str == "EyeRight");
    assert(renamed["nodes"]["children"][1]["name"].str == "Iris");
    assert(renamed["nodes"]["children"][0]["psdLayerPath"] == original["nodes"]["children"][0]["psdLayerPath"]);
    auto before = read(f.output).dup;
    assertThrown!Exception(agentRenameNode(f.output, f.output, uuid, "Iris"));
    assert(read(f.output) == before);
    assert(agentReadModelTextures(f.input)[0].data == agentReadModelTextures(f.output)[0].data);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = vectorRig();
    spec["parameters"][0]["bindings"][0]["property"] = JSONValue("deform");
    auto values = parseJSON(`[[null,{"offsets":[[0,2],[0,2],[0,2],[0,2]]}],
      [null,{"offsets":[[0,4],[0,4],[0,4],[0,4]]}],
      [null,{"offsets":[[0,6],[0,6],[0,6],[0,6]]}]]`);
    spec["parameters"][0]["bindings"][0]["values"] = values;
    agentApplyRigSpec(f.input, f.output, spec);
    auto refined = parseJSON(`{"verts":[-2,-2,-2,2,2,-2,2,2,0,0],
      "uvs":[0,0,0,1,1,0,1,1,0.5,0.5],"indices":[0,1,4,1,3,4,3,2,4,2,0,4],"origin":[0,0]}`);
    agentRetopologizePartByPsdPath(f.output, f.output, "/Iris", refined);
    assert(agentValidateWithSdk(f.output).partCount == 1);
    auto report = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"middle","parameters":{"HeadXY":[0.5,0.5]},"probes":["/Iris"]}
    ]}`));
    assert(report.poses[0].probes[0].deformationVertexCount == 5);
    assert(abs(report.poses[0].probes[0].deformationMagnitude - 12.5) < 0.0001);
    assert(agentReadModelTextures(f.input)[0].data == agentReadModelTextures(f.output)[0].data);
    auto before = read(f.output).dup;
    refined["uvs"][8] = JSONValue(10.0);
    assertThrown!Exception(agentRetopologizePartByPsdPath(f.output, f.output, "/Iris", refined));
    assert(read(f.output) == before);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    agentApplyRigSpec(f.input, f.output, parseJSON(`{"parameters":[{
      "name":"Gradient","min":0,"max":1,"keys":[0,1],"bindings":[{
        "path":"/Iris","property":"deform","values":[null,
          {"offsets":[[0,0],[0,0],[0,4],[0,4]]}]}]}]}`));
    auto refined = parseJSON(`{"verts":[-2,-2,-2,2,2,-2,2,2,0,0],
      "uvs":[0,0,0,1,1,0,1,1,0.5,0.5],"indices":[0,1,4,1,3,4,3,2,4,2,0,4],"origin":[0,0]}`);
    agentRetopologizePartByPsdPath(f.output, f.output, "/Iris", refined);
    auto report = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"gradient","parameters":{"Gradient":1}}
    ]}`));
    auto offsets = report.poses[0].probes[0].vertexOffsets;
    assert(abs(offsets[0][1].floating) < 0.0001);
    assert(abs(offsets[2][1].floating - 4) < 0.0001);
    assert(abs(offsets[4][1].floating - 2) < 0.0001,
        "Inserted vertex must interpolate spatially varying offsets across a shared edge.");
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    // Disconnected islands share UVs but may have different deformation keys.
    agentApplyRigSpec(f.input, f.output, parseJSON(`{"meshes":[{"path":"/Iris","mesh":{
      "verts":[0,0,0,2,2,0,4,0,4,2,6,0],
      "uvs":[0,0,0,1,1,0,0,0,0,1,1,0],"indices":[0,1,2,3,4,5],"origin":[0,0]}}]}`));
    auto before = read(f.output).dup;
    auto requested = parseJSON(`{"verts":[0,0,0,2,2,0],
      "uvs":[0,0,0,1,1,0],"indices":[0,1,2],"origin":[0,0]}`);
    assertThrown!Exception(agentRetopologizePartByPsdPath(f.output, f.output, "/Iris", requested),
        "Ambiguous UV islands must be rejected even when new vertices lie on boundaries.");
    assert(read(f.output) == before);
}

unittest {
    import imagefmt : read_image;
    auto f = Fixture.create(128); scope(exit) f.cleanup();
    auto report = agentRenderPoses(f.input, parseJSON(`{"canvas":{"width":32,"height":32},"poses":[
      {"name":"neutral","parameters":{}}
    ]}`), buildPath(f.directory, "alpha"));
    auto png = read_image(report.poses[0].outputPath, 4, 8);
    foreach (i; 0 .. png.w * png.h) {
        auto alpha = png.buf8[i * 4 + 3];
        assert(alpha == 0 || alpha == 128, "Shared mesh edges must not double-composite translucent pixels.");
    }
}

unittest {
    auto f = Fixture.create(255, "mul "); scope(exit) f.cleanup();
    assert(agentValidateWithSdk(f.input).partCount == 1);
    assertThrown!Exception(agentRenderPoses(f.input, parseJSON(`{"canvas":{"width":32,"height":32},"poses":[
      {"name":"multiply","parameters":{}}
    ]}`), buildPath(f.directory, "unsupported")));
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = vectorRig();
    auto binding = spec["parameters"][0]["bindings"][0];
    binding["property"] = JSONValue("deform");
    binding["values"] = parseJSON(`[
      [null,{"offsets":[[0,2],[0,2],[0,2],[0,2]]}],
      [null,{"offsets":[[0,4],[0,4],[0,4],[0,4]]}],
      [null,{"offsets":[[0,6],[0,6],[0,6],[0,6]]}]
    ]`);
    spec["parameters"][0]["bindings"] = JSONValue([binding]);
    agentApplyRigSpec(f.input, f.output, spec);
    auto report = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"interior","parameters":{"HeadXY":[0.5,0.5]},"probes":["/Iris"]}
    ]}`));
    assert(abs(report.poses[0].probes[0].deformationMagnitude - 10) < 0.0001);
    foreach (value; ["0", "[0]", "[0,2]", "[0,0,0]"]) {
        auto bad = parseJSON(`{"poses":[{"name":"bad","parameters":{"HeadXY":` ~ value ~ `},"probes":["/Iris"]}]}`);
        assertThrown!Exception(agentSamplePoses(f.output, bad));
    }
    // Re-meshing a bound model cannot leave stale deformation arrays behind.
    auto before = read(f.output).dup;
    assertThrown!Exception(agentApplyRigSpec(f.output, f.output,
        parseJSON(`{"meshes":[{"path":"/Iris","columns":3,"rows":3}]}`)));
    assert(read(f.output) == before);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto summary = agentApplyRigSpec(f.input, f.output, vectorRig());
    assert(summary.parameterCount == 1);
    assert(agentValidateWithSdk(f.output).partCount == 1);
    auto samples = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"corner","parameters":{"HeadXY":[1,1]},"probes":["/Iris"]},
      {"name":"middle","parameters":{"HeadXY":[0.5,0.5]},"probes":["/Iris"]}
    ]}`));
    assert(abs(samples.poses[0].probes[0].translationX - 14) < 0.0001, samples.toJson());
    assert(abs(samples.poses[1].probes[0].translationX - 8) < 0.0001, samples.toJson());
    auto renders = agentRenderPoses(f.output, parseJSON(`{"canvas":{"width":32,"height":32},"poses":[
      {"name":"left","parameters":{"HeadXY":[-1,0]}},
      {"name":"middle","parameters":{"HeadXY":[0.5,0.5]}}
    ]}`), buildPath(f.directory, "renders"));
    assert(renders.poses[0].rgbaSha256 != renders.poses[1].rgbaSha256);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = parseJSON(`{"meshes":[{"path":"/Iris","mesh":{
      "verts":[-2,-2,-2,2,2,-2,2,2],"uvs":[0,0,0,1,1,0,1,1],
      "indices":[0,1,2,2,1,3],"origin":[0,0]}}],
      "parameters":[{"name":"Lid","min":0,"max":1,"keys":[0,1],"bindings":[
        {"path":"/Iris","property":"deform","values":[null,
          {"offsets":[[0,2],[0,0],[0,2],[0,0]]}]}]}]}`);
    agentApplyRigSpec(f.input, f.output, spec);
    auto samples = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"half","parameters":{"Lid":0.5},"probes":["/Iris"]}
    ]}`));
    assert(abs(samples.poses[0].probes[0].deformationMagnitude - 2) < 0.0001);
    assert(agentReadModelTextures(f.input)[0].data == agentReadModelTextures(f.output)[0].data);
    auto before = read(f.output).dup;
    spec["parameters"][0]["bindings"][0]["values"][1] = parseJSON(`{"offsets":[[0,1]]}`);
    assertThrown!Exception(agentApplyRigSpec(f.input, f.output, spec));
    assert(read(f.output) == before);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    foreach (mode; ["Linear", "Nearest", "Cubic"]) {
        auto spec = parseJSON(`{"parameters":[{"name":"X","min":0,"max":1,"keys":[0,1],
          "bindings":[{"path":"/Iris","property":"transform.t.x","values":[0,8]}]}]}`);
        spec["parameters"][0]["bindings"][0].object["interpolation"] = JSONValue(mode);
        agentApplyRigSpec(f.input, f.output, spec);
        auto report = agentSamplePoses(f.output, parseJSON(`{"poses":[
          {"name":"quarter","parameters":{"X":0.25},"probes":["/Iris"]} ]}`));
        auto actual = report.poses[0].probes[0].translationX;
        if (mode == "Nearest") assert(abs(actual) < 0.0001);
        if (mode == "Linear") assert(abs(actual - 2) < 0.0001);
        if (mode == "Cubic") assert(actual > 0 && actual < 2);
    }
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    foreach (bad; [
      `{"paramters":[]}`,
      `{"schema_version":99}`,
      `{"parameters":[{"name":"X","min":0,"max":1,"keys":[0,1],"bindings":[{"path":"/Iris","property":"transform.t.x","values":[0,1e100]}]}]}`,
      `{"parameters":[{"name":"X","min":0,"max":1,"keys":[0,0.00000000000000000000000000000000000000000000000000001,1],"bindings":[{"path":"/Iris","property":"transform.t.x","values":[0,1,2]}]}]}`,
      `{"parameters":[{"name":"X","min":0,"max":1,"keys":[0,1],"bindings":[{"path":"/Iris","property":"opacity","values":[0,2]}]}]}`,
      `{"parameters":[{"name":"X","min":0,"max":1,"keys":[0,1],"bindings":[{"path":"/Iris","property":"opacity","interpolation":"typo","values":[0,1]}]}]}`
    ]) {
        write(f.output, "keep me");
        assertThrown!Exception(agentApplyRigSpec(f.input, f.output, parseJSON(bad)), bad);
        assert(cast(string) read(f.output) == "keep me");
    }
    auto duplicate = vectorRig();
    duplicate["parameters"][0]["bindings"].array ~= duplicate["parameters"][0]["bindings"][0];
    assertThrown!Exception(agentApplyRigSpec(f.input, f.output, duplicate));
    auto malformed = vectorRig();
    malformed["parameters"][0]["bindings"][0]["values"] = parseJSON(`[[0,1],[2,3]]`);
    assertThrown!Exception(agentApplyRigSpec(f.input, f.output, malformed));
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = parseJSON(`{"parameters":[{"name":"Fold","min":0,"max":1,"keys":[0,1],"bindings":[
      {"path":"/Iris","property":"deform","values":[null,{"offsets":[[0,0],[0,0],[-8,0],[-8,0]]}]}]}]}`);
    agentApplyRigSpec(f.input, f.output, spec);
    auto report = agentSamplePoses(f.output, parseJSON(`{"poses":[
      {"name":"neutral","parameters":{}},
      {"name":"flat","parameters":{"Fold":0.5}},
      {"name":"folded","parameters":{"Fold":1}}
    ]}`));
    assert(report.probeCount == 3);
    assert(report.poses[0].probes[0].collapsedTriangleCount == 0);
    assert(report.poses[1].probes[0].collapsedTriangleCount == 2);
    assert(report.poses[2].probes[0].flippedTriangleCount == 2);
    assert(report.poses[2].probes[0].worldVertices.length == 4);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = vectorRig();
    auto physics = parseJSON(`{"name":"HairSpring","parent":"/Iris","parameter":"HeadXY",
      "model_type":"SpringPendulum","map_mode":"XY","length":100,"frequency":1,
      "angle_damping":0.5,"length_damping":0.5,"local_only":false}`);
    spec.object["physics"] = JSONValue([physics]);
    assert(agentApplyRigSpec(f.input, f.output, spec).physicsCount == 1);
    auto before = read(f.output).dup;
    foreach (field; ["length", "frequency", "angle_damping", "length_damping", "local_only"]) {
        auto bad = parseJSON(spec.toString());
        bad["physics"][0][field] = field == "local_only" ? JSONValue("false") : JSONValue(-1);
        assertThrown!Exception(agentApplyRigSpec(f.input, f.output, bad), field);
        assert(read(f.output) == before);
    }
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto spec = parseJSON(`{"parameters":[{"name":"Overflow","min":0,"max":1,"keys":[0,1],"bindings":[
      {"path":"/Iris","property":"deform","values":[null,{"profiles":[{"type":"curveMorph","amount":1e30,"widthScale":1e30}]}]}]}]}`);
    assertThrown!Exception(agentApplyRigSpec(f.input, f.output, spec));
}

// Supersampling must affect raster coverage, never the physical model size.
unittest {
    import imagefmt : read_image;
    auto f = Fixture.create(); scope(exit) f.cleanup();
    agentApplyRigSpec(f.input, f.output, parseJSON(`{"parameters":[{
      "name":"Shift","min":0,"max":1,"keys":[0,1],"bindings":[{
        "path":"/Iris","property":"transform.t.x","values":[0,1]}]}]}`));
    auto spec = parseJSON(`{"canvas":{"width":32,"height":32,"supersample":2},"poses":[
      {"name":"half_pixel","parameters":{"Shift":0.5},"physics":{"frames":3,"dt":0.0166666667}}
    ]}`);
    auto rendered = agentRenderPoses(f.output, spec, buildPath(f.directory, "aa2"));
    auto png = read_image(rendered.poses[0].outputPath, 4, 8); scope(exit) png.free();
    assert(png.w == 32 && png.h == 32, "Supersampling must preserve output dimensions.");
    size_t partial; ulong coverage;
    foreach (i; 0 .. png.w * png.h) {
        auto alpha = png.buf8[i * 4 + 3]; coverage += alpha;
        if (alpha > 0 && alpha < 255) partial++;
    }
    assert(partial == 8, "A half-pixel shifted 4x4 quad needs two half-covered edge columns.");
    assert(abs(cast(double)coverage - 16 * 255) <= 8, "Model scale and covered area must remain unchanged.");
    assert(rendered.poses[0].physicsFrameCount == 3, "Raster samples must not advance physics repeatedly.");
    spec["canvas"].object.remove("supersample");
    auto legacy = agentRenderPoses(f.output, spec, buildPath(f.directory, "legacy"));
    spec["canvas"]["supersample"] = JSONValue(1);
    auto one = agentRenderPoses(f.output, spec, buildPath(f.directory, "aa1"));
    assert(one.poses[0].rgbaSha256 == legacy.poses[0].rgbaSha256);
}

unittest {
    import imagefmt : read_image;
    auto f = Fixture.create(128); scope(exit) f.cleanup();
    agentApplyRigSpec(f.input, f.output, parseJSON(`{"parameters":[{
      "name":"Shift","min":0,"max":1,"keys":[0,1],"bindings":[{
        "path":"/Iris","property":"transform.t.x","values":[0,1]}]}]}`));
    auto rendered = agentRenderPoses(f.output, parseJSON(`{"canvas":{"width":32,"height":32,"supersample":2},"poses":[
      {"name":"alpha_edge","parameters":{"Shift":0.5}}
    ]}`), buildPath(f.directory, "alpha-aa"));
    auto png = read_image(rendered.poses[0].outputPath, 4, 8); scope(exit) png.free();
    size_t partial;
    foreach (i; 0 .. png.w * png.h) {
        auto a = png.buf8[i * 4 + 3];
        assert(a == 0 || a == 64 || a == 128, "Shared mesh edges must not be blended twice.");
        if (a == 64) {
            partial++;
            assert(abs(cast(int)png.buf8[i * 4] - 200) <= 4,
                "Downsample premultiplied values before converting to straight alpha; avoid dark fringes.");
        }
    }
    assert(partial == 8);
}

unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    foreach (value; ["0", "5", "1.5", "true"]) {
        auto bad = parseJSON(`{"canvas":{"width":32,"height":32,"supersample":` ~ value ~ `},"poses":[]}`);
        assertThrown!Exception(agentRenderPoses(f.input, bad, buildPath(f.directory,"invalid")));
    }
    assertThrown!Exception(agentRenderPoses(f.input, parseJSON(
        `{"canvas":{"width":4096,"height":4096,"supersample":2},"poses":[]}`),
        buildPath(f.directory,"too-large")));
}

// A static pose is an explicit parameter evaluation, including driven axes.
// Its result cannot depend on a preceding pose or implicit physics updates.
unittest {
    auto f = Fixture.create(); scope(exit) f.cleanup();
    auto rig = parseJSON(`{"groups":[{"name":"Anchor","paths":["/Iris"]}],"parameters":[
      {"name":"Swing","min":-1,"max":1,"keys":[-1,0,1],"bindings":[
        {"path":"/Anchor/Iris","property":"transform.t.x","values":[-4,0,4]}]},
      {"name":"Move","min":-1,"max":1,"keys":[-1,0,1],"bindings":[
        {"path":"/Anchor","property":"transform.t.x","values":[-8,0,8]}]}
    ]}`);
    auto plain = buildPath(f.directory, "plain.inx");
    agentApplyRigSpec(f.input, plain, rig);
    rig["physics"] = parseJSON(`[{"name":"Spring","parent":"/Anchor","parameter":"Swing",
      "model_type":"Pendulum","map_mode":"AngleLength","length":100,
      "frequency":1.5,"angle_damping":0.7,"length_damping":0.7,"output_scale":[6,0]}]`);
    agentApplyRigSpec(f.input, f.output, rig);
    auto pose = parseJSON(`{"name":"explicit_static","parameters":{"Swing":1}}`);
    auto spec = parseJSON(`{"canvas":{"width":32,"height":32,"supersample":2},"poses":[]}`);
    spec["poses"] = JSONValue([pose]);
    auto expected = agentRenderPoses(plain, spec, buildPath(f.directory, "without-driver"));
    auto actual = agentRenderPoses(f.output, spec, buildPath(f.directory, "with-driver"));
    assert(actual.poses[0].rgbaSha256 == expected.poses[0].rgbaSha256,
        "Static rendering must honor the explicit driven parameter instead of invoking physics.");
    auto simulated = parseJSON(`{"name":"simulated","parameters":{},"physics":{
      "frames":8,"dt":0.0166666667,"trajectory":[{},{},{},{},{"Move":1},{"Move":1},{"Move":1},{"Move":1}]}}`);
    spec["poses"] = JSONValue([pose, simulated, pose]);
    auto mixed = agentRenderPoses(f.output, spec, buildPath(f.directory, "mixed"));
    assert(mixed.poses[0].physicsFrameCount == 0 && mixed.poses[2].physicsFrameCount == 0);
    assert(mixed.poses[1].physicsFrameCount == 8);
    assert(mixed.poses[0].rgbaSha256 == expected.poses[0].rgbaSha256);
    assert(mixed.poses[2].rgbaSha256 == expected.poses[0].rgbaSha256,
        "A previous simulated pose must not contaminate a following static pose.");
    assert(abs(mixed.poses[1].physicsParameterValues[0]) > 0.001,
        "Explicit physics must still respond to the input trajectory.");
    auto named = parseJSON(mixed.toJson())["poses"][1];
    assert("physicsParameters" in named.object,
        "A physics render must identify the driven parameter, not only emit unordered values.");
    auto values = named["physicsParameters"];
    assert("Swing" in values.object && !("Move" in values.object));
    assert(values["Swing"].array.length == 2);
    assert(abs(values["Swing"][0].floating - mixed.poses[1].physicsParameterValues[0]) < 1e-9);
    auto replay = parseJSON(`{"canvas":{"width":32,"height":32,"supersample":2},
      "poses":[{"name":"replay","parameters":{"Move":1,"Swing":0}}]}`);
    replay["poses"][0]["parameters"]["Swing"] = values["Swing"][0];
    auto replayed = agentRenderPoses(f.output, replay, buildPath(f.directory, "named-physics-replay"));
    assert(replayed.poses[0].rgbaSha256 == mixed.poses[1].rgbaSha256,
        "The reported named physics state must reproduce the actual rendered pose.");
}


// OC hair regression: a pixel can contain more than one deformation region.
unittest {
    import inochi2d.core;
    import inochi2d.math;
    auto group = new MeshGroup();
    group.dynamic = true;
    MeshData mesh;
    mesh.vertices = [vec2(0,0), vec2(0.4f,0), vec2(2,0),
                     vec2(0,2), vec2(0.4f,2), vec2(2,2)];
    mesh.uvs = [vec2(0),vec2(0),vec2(0),vec2(0),vec2(0),vec2(0)];
    mesh.indices = [0,1,4, 0,4,3, 1,2,5, 1,5,4];
    group.rebuffer(mesh);
    group.deformation = [vec2(0),vec2(0.8f,0),vec2(0),
                         vec2(0),vec2(0.8f,0),vec2(0)];
    group.update();
    auto matrix = mat4.identity;
    vec2 deformPoint(vec2 point) {
        auto result = group.filterChildren([point], [vec2(0)], &matrix);
        return point + result[0][0];
    }
    assert((deformPoint(vec2(0.75f,0.25f))-vec2(1.375f,0.25f)).length < 0.0001f,
        "MeshGroup must locate the actual point, not the triangle at its pixel corner.");
    assert((deformPoint(vec2(0.25f,2))-vec2(0.75f,2)).length < 0.0001f,
        "The closed maximum boundary belongs to the deformation domain.");
    assert((deformPoint(vec2(2.1f,0.25f))-vec2(2.1f,0.25f)).length < 0.0001f,
        "Points outside the cage must remain unchanged.");
    assert((deformPoint(vec2(0.40001f,0.25f))-deformPoint(vec2(0.39999f,0.25f))).length < 0.0001f,
        "The two regions must meet continuously at their shared edge.");
    group.dynamic = false;
    auto staticResult = group.filterChildren([vec2(0.75f,0.25f)], [vec2(0.25f,0)], &matrix);
    assert((vec2(0.75f,0.25f)+staticResult[0][0]-vec2(1.625f,0.25f)).length < 0.0001f,
        "Static cage mode must retain its additive child-offset semantics.");
}


// Dynamic MeshGroup rendering must match an independently baked affine result.
unittest {
    import std.json : JSONType;
    auto f = Fixture.create(); scope(exit) f.cleanup();
    agentApplyRigSpec(f.input, f.output, parseJSON(`{"parameters":[{
      "name":"Shift","min":0,"max":1,"keys":[0,1],"bindings":[{
      "path":"/Iris","property":"deform","values":[null,
      {"offsets":[[1,0],[1,0],[1,0],[1,0]]}]}]}]}`));
    auto bytes = cast(ubyte[])read(f.output);
    uint oldLength = (cast(uint)bytes[8]<<24) | (cast(uint)bytes[9]<<16) |
                     (cast(uint)bytes[10]<<8) | bytes[11];
    void savePayload(JSONValue payload, string path) {
        auto encoded = payload.toString();
        uint n = cast(uint)encoded.length;
        ubyte[] output = bytes[0..8].dup;
        output ~= [cast(ubyte)(n>>24),cast(ubyte)(n>>16),cast(ubyte)(n>>8),cast(ubyte)n];
        output ~= cast(ubyte[])encoded;
        output ~= bytes[12+oldLength..$];
        write(path, output);
    }
    auto native = agentReadModelPayload(f.output);
    auto group = parseJSON(`{"name":"Cage","uuid":9000,"type":"MeshGroup",
      "enabled":true,"lockToRoot":false,"zsort":0,
      "transform":{"trans":[3,2,0],"rot":[0,0,0],"scale":[1,1]},
      "dynamic_deformation":true,"translate_children":false,
      "mesh":{"verts":[-8,-8,8,-8,8,8,-8,8],"uvs":[0,0,1,0,1,1,0,1],
              "indices":[0,1,2,0,2,3],"origin":[0,0]},"children":[]}`);
    group["children"] = native["nodes"]["children"];
    native["nodes"]["children"] = JSONValue([group]);
    auto warp = parseJSON(`{"name":"Warp","uuid":9001,"is_vec2":false,
      "min":[0,0],"max":[1,1],"defaults":[0,0],"merge_mode":"Additive",
      "axis_points":[[0,1],[0]],"bindings":[{"node":9000,"param_name":"deform",
        "interpolate_mode":"Linear","isSet":[[true],[true]],"values":[
        [[[0,0],[0,0],[0,0],[0,0]]],[[[-8,0],[8,0],[8,0],[-8,0]]]]}]}`);
    native["param"] = JSONValue(native["param"].array ~ [warp]);
    auto cagePath = buildPath(f.directory,"cage.inx");savePayload(native,cagePath);
    auto baked = agentReadModelPayload(f.output);
    auto part = baked["nodes"]["children"][0];
    auto verts = part["mesh"]["verts"].array;
    double number(JSONValue x) { return x.type == JSONType.float_ ? x.floating : cast(double)x.integer; }
    foreach (i; 0..verts.length/2) verts[i*2] = JSONValue(number(verts[i*2])*2);
    part["mesh"]["verts"] = JSONValue(verts);
    auto translation = part["transform"]["trans"].array;
    translation[0] = JSONValue(number(translation[0])*2+3);
    translation[1] = JSONValue(number(translation[1])+2);
    part["transform"]["trans"] = JSONValue(translation);
    baked["nodes"]["children"] = JSONValue([part]);
    auto values = baked["param"][0]["bindings"][0]["values"].array;
    foreach (ref row; values) foreach (ref cell; row.array)
        foreach (ref point; cell.array) point[0] = JSONValue(number(point[0])*2);
    baked["param"][0]["bindings"][0]["values"] = JSONValue(values);
    warp["bindings"] = JSONValue.emptyArray;
    baked["param"] = JSONValue(baked["param"].array ~ [warp]);
    auto bakedPath = buildPath(f.directory,"baked.inx");savePayload(baked,bakedPath);
    auto spec = parseJSON(`{"canvas":{"width":32,"height":32,"supersample":2},"poses":[
      {"name":"start","parameters":{"Warp":1,"Shift":0}},
      {"name":"middle","parameters":{"Warp":1,"Shift":0.5}},
      {"name":"end","parameters":{"Warp":1,"Shift":1}}]}`);
    auto expected = agentRenderPoses(bakedPath,spec,buildPath(f.directory,"baked"));
    auto actual = agentRenderPoses(cagePath,spec,buildPath(f.directory,"cage"));
    foreach (i; 0..3) {
        assert(actual.poses[i].rgbaSha256 == expected.poses[i].rgbaSha256,
            "CPU preview must render the SDK's dynamic matrix and composed deformation.");
        assert(actual.poses[i].nonTransparentPixelCount == 32);
    }
}
