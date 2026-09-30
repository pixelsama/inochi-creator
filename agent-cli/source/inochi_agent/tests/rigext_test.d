module inochi_agent.tests.rigext_test;

import std.algorithm : max;
import std.exception : assertThrown;
import std.file : exists, mkdir, read, rmdirRecurse, tempDir, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.path : buildPath;
import std.uuid : randomUUID;
import imagefmt : read_image;
import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import inochi_agent.cpurender;
import inochi_agent.sdkvalidate;

// Synthetic 32x32 documents. With a 32x32 canvas at scale 1, PSD pixel
// coordinates equal rendered pixel coordinates.
private struct Scene {
    string directory;
    string input;
    string output;
    AgentPsdImportLayer[] layers;

    static Scene create() {
        Scene s;
        s.directory = buildPath(tempDir(), "inochi-rigext-" ~ randomUUID().toString());
        mkdir(s.directory);
        s.input = buildPath(s.directory, "base.inx");
        s.output = buildPath(s.directory, "rig.inx");
        return s;
    }

    // Layers are added in PSD panel order: top first, groups before children.
    void rect(string name, int left, int top, uint width, uint height, ubyte[4] color,
        string blendMode = "norm", size_t depth = 0, string parent = "") {
        AgentPsdImportLayer layer;
        layer.name = name; layer.path = parent ~ "/" ~ name;
        layer.visible = true; layer.depth = depth;
        layer.left = left; layer.top = top; layer.width = width; layer.height = height;
        layer.blendMode = blendMode;
        layer.rgba.length = width * height * 4;
        foreach (i; 0 .. width * height) layer.rgba[i * 4 .. i * 4 + 4] = color;
        layers ~= layer;
    }

    void group(string name, ubyte opacity, string blendMode = "norm") {
        AgentPsdImportLayer layer;
        layer.name = name; layer.path = "/" ~ name;
        layer.visible = true; layer.isGroup = true;
        layer.opacity = opacity; layer.blendMode = blendMode;
        layers ~= layer;
    }

    void build() {
        AgentPsdImportDocument doc;
        doc.width = 32; doc.height = 32;
        // sourceIndex counts from the bottom record, as in a PSD file.
        foreach (i, layer; layers) {
            auto copy = layer;
            copy.sourceIndex = layers.length - 1 - i;
            doc.layers ~= copy;
        }
        doc.sourceLayerRecordCount = layers.length;
        write(input, agentBuildInitialInx(doc, "rigext"));
    }

    ubyte[] render(string model, string poses) {
        auto report = agentRenderPoses(model, parseJSON(`{"canvas":{"width":32,"height":32},"poses":` ~ poses ~ `}`),
            buildPath(directory, randomUUID().toString()));
        auto png = read_image(report.poses[0].outputPath, 4, 8);
        return png.buf8.dup;
    }

    void cleanup() { if (exists(directory)) rmdirRecurse(directory); }
}

private ubyte[4] pixel(const(ubyte)[] rgba, int x, int y) {
    size_t o = (y * 32 + x) * 4;
    return [rgba[o], rgba[o + 1], rgba[o + 2], rgba[o + 3]];
}

private bool near(ubyte[4] actual, ubyte[4] expected, int tolerance = 1) {
    foreach (i; 0 .. 4) if (abs(cast(int)actual[i] - expected[i]) > tolerance) return false;
    return true;
}

// Legacy Multiply: destination * source color where the part draws.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Shade", 8, 8, 8, 8, [128, 128, 128, 255], "mul ");
    s.rect("Base", 8, 8, 8, 8, [200, 100, 50, 255]);
    s.build();
    auto image = s.render(s.input, `[{"name":"n","parameters":{}}]`);
    assert(near(pixel(image, 12, 12), [100, 50, 25, 255]));
}

// Blend modes only touch pixels the part rasterizes: DestinationIn must not
// erase the canvas outside its own mesh.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Cut", 8, 8, 8, 8, [0, 0, 0, 128]);
    s.rect("Base", 0, 0, 32, 32, [255, 0, 0, 255]);
    s.build();
    auto summary = agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"parts":[{"path":"/Cut","blend_mode":"DestinationIn"}]}`));
    assert(summary.partPropertyCount == 1);
    auto image = s.render(s.output, `[{"name":"n","parameters":{}}]`);
    assert(near(pixel(image, 12, 12), [255, 0, 0, 128]));
    assert(pixel(image, 2, 2) == [255, 0, 0, 255]);
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"parts":[{"path":"/Cut","blend_mode":"Glow"}]}`)));
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"parts":[{"path":"/Cut","tint":[1,2,1]}]}`)));
}

// Tint multiplies and screen tint brightens, both driven by parameters.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Skin", 8, 8, 8, 8, [200, 100, 50, 255]);
    s.build();
    agentApplyRigSpec(s.input, s.output, parseJSON(`{"parameters":[{"name":"Blush","min":0,"max":1,"keys":[0,1],
      "bindings":[{"path":"/Skin","property":"tint.g","values":[1,0.5]},
                  {"path":"/Skin","property":"screenTint.b","values":[0,1]}]}]}`));
    auto neutral = s.render(s.output, `[{"name":"n","parameters":{}}]`);
    assert(near(pixel(neutral, 12, 12), [200, 100, 50, 255]));
    auto blush = s.render(s.output, `[{"name":"b","parameters":{"Blush":1}}]`);
    assert(near(pixel(blush, 12, 12), [200, 50, 255, 255]));
    auto probe = agentSamplePoses(s.output, parseJSON(`{"poses":[{"name":"b","parameters":{"Blush":1}}]}`));
    auto json = probe.poses[0].probes[0].toJson();
    assert(abs(json["tint"][1].floating - 0.5) < 1e-6 && abs(json["screenTint"][2].floating - 1) < 1e-6);
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(`{"parameters":[{"name":"Bad","min":0,"max":1,
      "keys":[0,1],"bindings":[{"path":"/Skin","property":"tint.r","values":[1,-0.5]}]}]}`)));
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(`{"parameters":[{"name":"Bad","min":0,"max":1,
      "keys":[0,1],"bindings":[{"path":"/Skin","property":"screenTint.r","values":[0,2]}]}]}`)));
}

// A zSort binding reorders drawing, e.g. an ear passing behind hair.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Front", 8, 8, 8, 8, [0, 0, 255, 255]);
    s.rect("Back", 8, 8, 8, 8, [255, 0, 0, 255]);
    s.build();
    agentApplyRigSpec(s.input, s.output, parseJSON(`{"parameters":[{"name":"Swap","min":0,"max":1,"keys":[0,1],
      "bindings":[{"path":"/Front","property":"zSort","values":[0,10]}]}]}`));
    assert(pixel(s.render(s.output, `[{"name":"n","parameters":{}}]`), 12, 12) == [0, 0, 255, 255]);
    assert(pixel(s.render(s.output, `[{"name":"s","parameters":{"Swap":1}}]`), 12, 12) == [255, 0, 0, 255]);
    auto report = agentSamplePoses(s.output, parseJSON(`{"poses":[{"name":"s","parameters":{"Swap":1}}]}`));
    double front, back;
    foreach (probe; report.poses[0].probes) (probe.path == "/Front" ? front : back) = probe.zSort;
    assert(front > back);
}

// MeshGroup deformation moves every child vertex through the cage.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Iris", 8, 8, 8, 8, [200, 100, 50, 255]);
    s.build();
    auto summary = agentApplyRigSpec(s.input, s.output, parseJSON(`{
      "groups":[{"name":"Warp","type":"MeshGroup","paths":["/Iris"],"pivot":[-4,-4],"columns":3,"rows":3,"margin":2}],
      "parameters":[{"name":"Shift","min":0,"max":1,"keys":[0,1],"bindings":[
        {"path":"/Warp","property":"deform","values":[null,{"profiles":[{"type":"translate","x":4}]}]}]}]}`));
    assert(summary.meshGroupCount == 1);
    assert(agentValidateWithSdk(s.output).partCount == 1);
    auto report = agentSamplePoses(s.output, parseJSON(`{"poses":[
      {"name":"rest","parameters":{}},{"name":"shift","parameters":{"Shift":1}}]}`));
    assert(report.poses[0].probes.length == 2, "MeshGroup cages are probed by default.");
    foreach (probe; report.poses[1].probes) {
        if (probe.path != "/Warp/Iris") continue;
        auto rest = report.poses[0].probes[1].worldVertices;
        foreach (i, vertex; probe.worldVertices)
            assert(abs(vertex[0].floating - rest[i][0].floating - 4) < 1e-3);
    }
    auto shifted = s.render(s.output, `[{"name":"s","parameters":{"Shift":1}}]`);
    assert(pixel(shifted, 9, 12)[3] == 0 && pixel(shifted, 18, 12)[3] == 255);

    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"groups":[{"name":"G","paths":["/Iris"],"columns":3}]}`)), "Grid fields need a MeshGroup.");
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"groups":[{"name":"G","type":"MeshGroup","paths":["/Iris"],"opacity":0.5}]}`)));
}

// Composite opacity applies to the flattened group, so overlaps do not
// double up; PSD groups with opacity import as Composites.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Right", 12, 8, 12, 8, [0, 0, 255, 255]);
    s.rect("Left", 4, 8, 12, 8, [255, 0, 0, 255]);
    s.build();
    auto summary = agentApplyRigSpec(s.input, s.output, parseJSON(`{"groups":[
      {"name":"Sleeve","type":"Composite","paths":["/Left","/Right"],"opacity":0.5}]}`));
    assert(summary.compositeCount == 1);
    assert(agentValidateWithSdk(s.output).partCount == 2);
    auto image = s.render(s.output, `[{"name":"n","parameters":{}}]`);
    assert(near(pixel(image, 14, 12), [0, 0, 255, 128]));
    assert(near(pixel(image, 6, 12), [255, 0, 0, 128]));
    assertThrown!Exception(agentApplyRigSpec(s.output, s.input ~ ".nested", parseJSON(`{"groups":[
      {"name":"Outer","type":"Composite","paths":["/Sleeve"]}]}`)));

    auto psd = Scene.create(); scope(exit) psd.cleanup();
    psd.group("Sleeve", 128);
    psd.rect("Right", 12, 8, 12, 8, [0, 0, 255, 255], "norm", 1, "/Sleeve");
    psd.rect("Left", 4, 8, 12, 8, [255, 0, 0, 255], "norm", 1, "/Sleeve");
    psd.build();
    auto payload = agentReadModelPayload(psd.input);
    assert(payload["nodes"]["children"][0]["type"].str == "Composite");
    auto imported = psd.render(psd.input, `[{"name":"n","parameters":{}}]`);
    assert(near(pixel(imported, 14, 12), [0, 0, 255, 128], 2));
}

// Sine automation moves a parameter over time; static poses stay still.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Chest", 8, 8, 8, 8, [200, 100, 50, 255]);
    s.build();
    auto summary = agentApplyRigSpec(s.input, s.output, parseJSON(`{
      "parameters":[{"name":"Breath","min":0,"max":1,"keys":[0,1],"bindings":[
        {"path":"/Chest","property":"transform.t.x","values":[0,8]}]}],
      "automation":[{"name":"Breathing","speed":3,"bindings":[{"parameter":"Breath","range":[0,1]}]}]}`));
    assert(summary.automationCount == 1);
    assert(agentValidateWithSdk(s.output).partCount == 1);
    auto report = agentRenderPoses(s.output, parseJSON(`{"canvas":{"width":32,"height":32},"poses":[
      {"name":"still","parameters":{}},
      {"name":"a","parameters":{},"physics":{"frames":20,"dt":0.05}},
      {"name":"b","parameters":{},"physics":{"frames":20,"dt":0.05}}]}`), buildPath(s.directory, "auto"));
    assert(report.poses[1].rgbaSha256 != report.poses[0].rgbaSha256 ||
        report.poses[2].rgbaSha256 != report.poses[0].rgbaSha256, "Automation must move the part over time.");
    foreach (bad; [
        `{"name":"X","bindings":[{"parameter":"Missing","range":[0,1]}]}`,
        `{"name":"X","bindings":[{"parameter":"Breath","axis":1,"range":[0,1]}]}`,
        `{"name":"X","bindings":[{"parameter":"Breath","range":[0,2]}]}`,
        `{"name":"X","wave":"tan","bindings":[{"parameter":"Breath","range":[0,1]}]}`]) {
        assertThrown!Exception(agentApplyRigSpec(s.output, s.input ~ ".bad", parseJSON(`{"automation":[` ~ bad ~ `]}`)));
    }
}

// Auto mesh follows the alpha silhouette, covers every visible pixel and
// renders identically to the imported quad.
unittest {
    auto s = Scene.create(); scope(exit) s.cleanup();
    s.rect("Disc", 0, 0, 32, 32, [0, 0, 0, 0]);
    foreach (y; 0 .. 32) foreach (x; 0 .. 32) {
        double dx = x + 0.5 - 16, dy = y + 0.5 - 16;
        double d = dx * dx + dy * dy;
        ubyte a = d < 81 ? 255 : d < 110 ? 90 : 0;
        s.layers[0].rgba[(y * 32 + x) * 4 .. (y * 32 + x) * 4 + 4] = [a, cast(ubyte)(a / 2), 0, a];
    }
    s.build();
    auto before = s.render(s.input, `[{"name":"n","parameters":{}}]`);
    agentApplyRigSpec(s.input, s.output, parseJSON(`{"meshes":[{"path":"/Disc","auto":{"spacing":6,"margin":1}}]}`));
    auto after = s.render(s.output, `[{"name":"n","parameters":{}}]`);
    foreach (i; 0 .. before.length) assert(abs(cast(int)before[i] - after[i]) <= 1, "Auto mesh must not change the rest pose.");
    auto mesh = agentReadModelPayload(s.output)["nodes"]["children"][0]["mesh"];
    double area = 0;
    auto v = mesh["verts"], idx = mesh["indices"];
    double coord(size_t i) { return v[i].type == JSONType.float_ ? v[i].floating : v[i].integer; }
    foreach (t; 0 .. idx.array.length / 3) {
        size_t a = idx[t * 3].integer, b = idx[t * 3 + 1].integer, c = idx[t * 3 + 2].integer;
        area += abs((coord(b * 2) - coord(a * 2)) * (coord(c * 2 + 1) - coord(a * 2 + 1)) -
            (coord(b * 2 + 1) - coord(a * 2 + 1)) * (coord(c * 2) - coord(a * 2))) / 2;
    }
    assert(v.array.length / 2 > 4 && area < 32 * 32 * 0.6, "Auto mesh must follow the silhouette, not the quad.");

    // Bound parts migrate their keys through retopology.
    agentApplyRigSpec(s.input, s.output, parseJSON(`{"parameters":[{"name":"Move","min":0,"max":1,"keys":[0,1],
      "bindings":[{"path":"/Disc","property":"deform","values":[null,{"profiles":[{"type":"translate","x":3}]}]}]}]}`));
    agentRetopologizePartByPsdPath(s.output, s.output, "/Disc", parseJSON(`{"auto":{"spacing":6}}`));
    auto moved = agentSamplePoses(s.output, parseJSON(`{"poses":[{"name":"m","parameters":{"Move":1}}]}`));
    foreach (offset; moved.poses[0].probes[0].vertexOffsets) assert(abs(offset[0].floating - 3) < 1e-4);

    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"meshes":[{"path":"/Disc","auto":{"spacing":1}}]}`)));
    assertThrown!Exception(agentApplyRigSpec(s.input, s.output, parseJSON(
        `{"meshes":[{"path":"/Disc","auto":{},"columns":3}]}`)));
}
