module inochi_agent.tests.modelio_test;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : exists, read, remove, rmdirRecurse, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.path : buildPath;
import std.process : environment;
import std.string : representation;
import std.stdio : writeln;

import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import inochi_agent.commands;
import inochi_agent.cpurender;
import inochi_agent.sdkvalidate;

private string testPath(string filename) {
    return buildPath(environment.get("TMPDIR", "/tmp"), filename);
}

private void appendUInt32(ref ubyte[] bytes, uint value) {
    bytes ~= nativeToBigEndian(value)[];
}

private ubyte[] createFixture() {
    string payload = `{
        "meta":{"name":"headless-model"},
        "nodes":{
            "type":"Node",
            "children":[
                {
                    "type":"Part",
                    "uuid":42,
                    "psdLayerPath":"/Eyes/Iris",
                    "mesh":{
                        "verts":[0,0,1,0,1,1,0,1],
                        "uvs":[0,0,1,0,1,1,0,1],
                        "indices":[0,1,2,0,2,3],
                        "origin":[0,0]
                    },
                    "children":[]
                }
            ]
        },
        "param":[{"name":"HeadX"}]
    }`;

    ubyte[] texture = [0xCA, 0xFE, 0xBA, 0xBE];
    ubyte[] extension = [0x01, 0x02, 0x03];
    ubyte[] result = cast(ubyte[])"TRNSRTS\0";
    appendUInt32(result, cast(uint) payload.length);
    result ~= cast(ubyte[]) payload;
    result ~= cast(ubyte[])"TEX_SECT";
    appendUInt32(result, 1);
    appendUInt32(result, cast(uint) texture.length);
    result ~= 1;
    result ~= texture;
    result ~= cast(ubyte[])"EXT_SECT";
    appendUInt32(result, 1);
    string extensionName = "agent.test";
    appendUInt32(result, cast(uint) extensionName.length);
    result ~= cast(ubyte[]) extensionName;
    appendUInt32(result, cast(uint) extension.length);
    result ~= extension;
    return result;
}

private ubyte[] createFixtureWithDeformationBinding() {
    string payload = `{
        "meta":{"name":"bound-mesh-model"},
        "nodes":{
            "type":"Node",
            "children":[
                {
                    "type":"Part",
                    "uuid":42,
                    "mesh":{
                        "verts":[0,0,1,0,1,1,0,1],
                        "uvs":[0,0,1,0,1,1,0,1],
                        "indices":[0,1,2,0,2,3],
                        "origin":[0,0]
                    },
                    "children":[]
                }
            ]
        },
        "param":[{
            "name":"HeadX",
            "bindings":[{"node":42,"param_name":"deform","values":[],"isSet":[]}]
        }]
    }`;

    ubyte[] result = cast(ubyte[])"TRNSRTS\0";
    appendUInt32(result, cast(uint) payload.length);
    result ~= cast(ubyte[]) payload;
    result ~= cast(ubyte[])"TEX_SECT";
    appendUInt32(result, 0);
    return result;
}

private ubyte[] createSdkFixture() {
    AgentPsdImportLayer group;
    group.name = "Eyes";
    group.path = "/Eyes";
    group.sourceIndex = 2;
    group.depth = 0;
    group.isGroup = true;
    group.visible = true;

    AgentPsdImportLayer iris;
    iris.name = "Iris";
    iris.path = "/Eyes/Iris";
    iris.sourceIndex = 1;
    iris.depth = 1;
    iris.visible = true;
    iris.left = 10;
    iris.top = 10;
    iris.width = 4;
    iris.height = 4;
    iris.opacity = 255;
    iris.blendMode = "norm";
    iris.rgba.length = 4 * 4 * 4;
    foreach (pixel; 0 .. 16) {
        iris.rgba[pixel * 4] = 120;
        iris.rgba[pixel * 4 + 1] = 80;
        iris.rgba[pixel * 4 + 2] = 200;
        iris.rgba[pixel * 4 + 3] = 128;
    }

    AgentPsdImportDocument document;
    document.width = 32;
    document.height = 32;
    document.sourceLayerRecordCount = 3;
    document.layers = [group, iris];
    return agentBuildInitialInx(document, "sdk-rig-fixture");
}

private ubyte[] createFlatSdkFixture() {
    AgentPsdImportLayer iris;
    iris.name = "Iris";
    iris.path = "/Iris";
    iris.sourceIndex = 1;
    iris.depth = 0;
    iris.visible = true;
    iris.left = 10;
    iris.top = 10;
    iris.width = 4;
    iris.height = 4;
    iris.opacity = 255;
    iris.blendMode = "norm";
    iris.rgba.length = 4 * 4 * 4;
    foreach (pixel; 0 .. 16) {
        iris.rgba[pixel * 4] = 120;
        iris.rgba[pixel * 4 + 1] = 80;
        iris.rgba[pixel * 4 + 2] = 200;
        iris.rgba[pixel * 4 + 3] = 128;
    }

    AgentPsdImportDocument document;
    document.width = 32;
    document.height = 32;
    document.sourceLayerRecordCount = 1;
    document.layers = [iris];
    return agentBuildInitialInx(document, "flat-rig-fixture");
}

private ubyte[] createMaskSdkFixture() {
    AgentPsdImportLayer sclera;
    sclera.name = "Sclera";
    sclera.path = "/Sclera";
    sclera.sourceIndex = 1;
    sclera.depth = 0;
    sclera.visible = true;
    sclera.left = 12;
    sclera.top = 12;
    sclera.width = 2;
    sclera.height = 2;
    sclera.opacity = 255;
    sclera.blendMode = "norm";
    sclera.rgba.length = 2 * 2 * 4;
    foreach (pixel; 0 .. 4) {
        sclera.rgba[pixel * 4] = 255;
        sclera.rgba[pixel * 4 + 1] = 255;
        sclera.rgba[pixel * 4 + 2] = 255;
        sclera.rgba[pixel * 4 + 3] = 255;
    }

    AgentPsdImportLayer iris;
    iris.name = "Iris";
    iris.path = "/Iris";
    iris.sourceIndex = 2;
    iris.depth = 0;
    iris.visible = true;
    iris.left = 10;
    iris.top = 10;
    iris.width = 6;
    iris.height = 6;
    iris.opacity = 255;
    iris.blendMode = "norm";
    iris.rgba.length = 6 * 6 * 4;
    foreach (pixel; 0 .. 36) {
        iris.rgba[pixel * 4] = 120;
        iris.rgba[pixel * 4 + 1] = 80;
        iris.rgba[pixel * 4 + 2] = 200;
        iris.rgba[pixel * 4 + 3] = 255;
    }

    AgentPsdImportDocument document;
    document.width = 32;
    document.height = 32;
    document.sourceLayerRecordCount = 2;
    document.layers = [sclera, iris];
    return agentBuildInitialInx(document, "mask-rig-fixture");
}

private ubyte[] binarySuffix(const(ubyte)[] document) {
    assert(document.length >= 12);
    ubyte[uint.sizeof] encodedLength = document[8 .. 8 + uint.sizeof];
    size_t suffixOffset = 8 + uint.sizeof + bigEndianToNative!uint(encodedLength);
    assert(suffixOffset <= document.length);
    return document[suffixOffset .. $].dup;
}

private JSONValue replacementMesh() {
    return parseJSON(`{
        "verts":[-1,-1,1,-1,1,1,-1,1],
        "uvs":[0,0,1,0,1,1,0,1],
        "indices":[0,2,1,0,3,2],
        "origin":[0,0]
    }`);
}

private JSONValue threeVertexMesh() {
    return parseJSON(`{
        "verts":[0,0,2,0,1,1],
        "uvs":[0,0,1,0,0.5,1],
        "indices":[0,1,2],
        "origin":[0,0]
    }`);
}

private JSONValue alternativeTopologyMesh() {
    return parseJSON(`{
        "verts":[-1,-1,1,-1,1,1,-1,1],
        "uvs":[0,0,1,0,1,1,0,1],
        "indices":[0,1,3,1,2,3],
        "origin":[0,0]
    }`);
}

private JSONValue simpleRigSpec() {
    return parseJSON(`{
        "meshes":[
            {"path":"/Eyes/Iris","columns":3,"rows":2}
        ],
        "parameters":[
            {
                "name":"EyeX",
                "min":-1,
                "max":1,
                "default":0,
                "keys":[-1,0,1],
                "bindings":[
                    {
                        "path":"/Eyes/Iris",
                        "property":"transform.t.x",
                        "values":[-4,0,4]
                    },
                    {
                        "path":"/Eyes/Iris",
                        "property":"opacity",
                        "values":[0.25,1,0.25]
                    },
                    {
                        "path":"/Eyes/Iris",
                        "property":"deform",
                        "values":[
                            {"profiles":[{"type":"tipX","amount":-2}]},
                            null,
                            {"profiles":[{"type":"tipX","amount":2}]}
                        ]
                    }
                ]
            }
        ]
    }`);
}

private JSONValue curveMorphRigSpec() {
    return parseJSON(`{
        "meshes":[
            {"path":"/Eyes/Iris","columns":3,"rows":3}
        ],
        "parameters":[
            {
                "name":"Blink",
                "min":0,
                "max":1,
                "default":0,
                "keys":[0,1],
                "bindings":[
                    {
                        "path":"/Eyes/Iris",
                        "property":"deform",
                        "values":[
                            null,
                            {
                                "profiles":[{
                                    "type":"curveMorph",
                                    "amount":1,
                                    "offsetY":4,
                                    "curvatureY":6,
                                    "slopeY":3,
                                    "anchorLeft":0.5,
                                    "thicknessScale":0.2,
                                    "widthScale":0.8
                                }]
                            }
                        ]
                    }
                ]
            }
        ]
    }`);
}

private JSONValue groupedRigSpec() {
    return parseJSON(`{
        "groups":[
            {
                "name":"Eyes",
                "paths":["/Iris"],
                "zsort":4
            }
        ]
    }`);
}

private JSONValue nestedGroupedRigSpec() {
    return parseJSON(`{
        "groups":[
            {
                "name":"Eyes",
                "paths":["/Iris"],
                "pivot":[2,3],
                "zsort":4
            },
            {
                "name":"BodyRoot",
                "paths":["/Eyes"],
                "pivot":[5,7],
                "zsort":1
            }
        ]
    }`);
}

private JSONValue physicsRigSpec() {
    return parseJSON(`{
        "parameters":[
            {
                "name":"Swing",
                "min":-1,
                "max":1,
                "default":0,
                "keys":[-1,0,1],
                "bindings":[
                    {
                        "path":"/Eyes/Iris",
                        "property":"transform.r.z",
                        "values":[-0.1,0,0.1]
                    }
                ]
            }
        ],
        "physics":[
            {
                "name":"SwingPhysics",
                "parent":"/Eyes",
                "parameter":"Swing",
                "model_type":"Pendulum",
                "map_mode":"AngleLength",
                "length":100,
                "frequency":1.5,
                "angle_damping":0.7,
                "length_damping":0.7,
                "output_scale":[6,0],
                "local_only":false
            }
        ]
    }`);
}

private JSONValue maskRigSpec() {
    return parseJSON(`{
        "masks":[
            {
                "target":"/Iris",
                "source":"/Sclera",
                "mode":"mask"
            }
        ]
    }`);
}

private JSONValue physicsRenderSpec() {
    return parseJSON(`{
        "canvas":{"width":32,"height":32},
        "poses":[
            {
                "name":"physics_neutral",
                "parameters":{"Swing":0},
                "physics":{"frames":8,"dt":0.0166666667}
            }
        ]
    }`);
}

private JSONValue simplePoseSpec() {
    return parseJSON(`{
        "poses":[
            {
                "name":"left",
                "parameters":{"EyeX":-1},
                "probes":["/Eyes/Iris"]
            },
            {
                "name":"right",
                "parameters":{"EyeX":1},
                "probes":["/Eyes/Iris"]
            }
        ]
    }`);
}

private JSONValue simpleRenderSpec() {
    return parseJSON(`{
        "canvas":{"width":32,"height":32},
        "poses":[
            {
                "name":"neutral",
                "parameters":{"EyeX":0},
                "probes":["/Eyes/Iris"]
            },
            {
                "name":"right",
                "parameters":{"EyeX":1},
                "probes":["/Eyes/Iris"]
            }
        ]
    }`);
}

unittest {
    string inputPath = testPath("inochi-agent-headless-input.inx");
    string outputPath = testPath("inochi-agent-headless-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    agentValidateModel(inputPath);
    auto inputSummary = agentInspectModel(inputPath);
    assert(inputSummary.name == "headless-model");
    assert(inputSummary.nodeCount == 2);
    assert(inputSummary.partCount == 1);
    assert(inputSummary.parameterCount == 1);
    assert(inputSummary.textureCount == 1);
    assert(parseJSON(inputSummary.toJson())["name"].str == "headless-model");
    assert(agentFindPartUuidByPsdPath(inputPath, "/Eyes/Iris") == 42);

    auto outputSummary = agentRoundTripModel(inputPath, outputPath);
    assert(exists(outputPath));
    assert(outputSummary == inputSummary);
    assert(cast(ubyte[]) read(outputPath) == fixture);
}

unittest {
    string inputPath = testPath("inochi-agent-pose-input.inx");
    string rigPath = testPath("inochi-agent-pose-rig.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(rigPath)) remove(rigPath);
    }

    write(inputPath, createSdkFixture());
    agentApplyRigSpec(inputPath, rigPath, simpleRigSpec());
    string rerigPath = rigPath ~ ".rerig";
    scope (exit) if (exists(rerigPath)) remove(rerigPath);
    auto rerigSummary = agentApplyRigSpec(rigPath, rerigPath, simpleRigSpec());
    assert(rerigSummary.parameterCount == 1);
    assert(agentInspectModel(rerigPath).parameterCount == 1);

    auto report = agentSamplePoses(rigPath, simplePoseSpec());
    writeln(report.toJson());
    assert(report.poseCount == 2);
    assert(report.probeCount == 2);
    assert(report.poses[0].name == "left");
    assert(report.poses[1].name == "right");
    assert(report.poses[0].probes[0].translationX < report.poses[1].probes[0].translationX);
    assert(report.poses[0].probes[0].deformationMagnitude > 0);
    assert(report.poses[1].probes[0].deformationMagnitude > 0);
}

unittest {
    string inputPath = testPath("inochi-agent-pose-cli-input.inx");
    string rigPath = testPath("inochi-agent-pose-cli-rig.inx");
    string posePath = testPath("inochi-agent-pose-cli.json");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(rigPath)) remove(rigPath);
        if (exists(posePath)) remove(posePath);
    }

    write(inputPath, createSdkFixture());
    agentApplyRigSpec(inputPath, rigPath, simpleRigSpec());
    write(posePath, simplePoseSpec().toString());

    assert(runAgentCommand([
        "inochi-agent",
        "pose-sample",
        rigPath,
        posePath
    ]) == 0);
}

unittest {
    import imagefmt : read_image;

    string inputPath = testPath("inochi-agent-render-input.inx");
    string rigPath = testPath("inochi-agent-render-rig.inx");
    string specPath = testPath("inochi-agent-render-poses.json");
    string outputDirectory = testPath("inochi-agent-render-output");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(rigPath)) remove(rigPath);
        if (exists(specPath)) remove(specPath);
        if (exists(outputDirectory)) rmdirRecurse(outputDirectory);
    }

    write(inputPath, createSdkFixture());
    agentApplyRigSpec(inputPath, rigPath, simpleRigSpec());
    write(specPath, simpleRenderSpec().toString());

    auto report = agentRenderPoses(rigPath, simpleRenderSpec(), outputDirectory);
    assert(report.poseCount == 2);
    assert(report.poses[0].name == "neutral");
    assert(report.poses[1].name == "right");
    assert(report.poses[0].nonTransparentPixelCount > 0);
    assert(report.poses[1].nonTransparentPixelCount > 0);
    assert(report.poses[0].rgbaSha256 != report.poses[1].rgbaSha256);
    assert(exists(report.poses[0].outputPath));
    assert(exists(report.poses[1].outputPath));

    auto neutral = read_image(report.poses[0].outputPath, 4, 8);
    scope(exit) neutral.free();
    assert(neutral.e == 0);
    assert(neutral.w == 32);
    assert(neutral.h == 32);
    size_t center = cast(size_t) (11 * neutral.w + 11) * 4;
    assert(neutral.buf8[center] >= 118 && neutral.buf8[center] <= 121);
    assert(neutral.buf8[center + 1] >= 78 && neutral.buf8[center + 1] <= 81);
    assert(neutral.buf8[center + 2] >= 198 && neutral.buf8[center + 2] <= 201);
    assert(neutral.buf8[center + 3] >= 127 && neutral.buf8[center + 3] <= 129);

    assert(runAgentCommand([
        "inochi-agent",
        "pose-render",
        rigPath,
        specPath,
        outputDirectory
    ]) == 0);
}

unittest {
    import imagefmt : read_image;

    string inputPath = testPath("inochi-agent-mask-input.inx");
    string rigPath = testPath("inochi-agent-mask-rig.inx");
    string outputDirectory = testPath("inochi-agent-mask-render-output");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(rigPath)) remove(rigPath);
        if (exists(outputDirectory)) rmdirRecurse(outputDirectory);
    }

    write(inputPath, createMaskSdkFixture());
    auto summary = agentApplyRigSpec(inputPath, rigPath, maskRigSpec());
    assert(summary.maskCount == 1);
    agentValidateWithSdk(rigPath);

    auto payload = agentReadModelPayload(rigPath);
    auto rootChildren = payload["nodes"]["children"].array;
    auto sclera = rootChildren[0];
    auto iris = rootChildren[1];
    assert(iris["masks"].array.length == 1);
    assert(iris["masks"].array[0]["source"] == sclera["uuid"]);
    assert(iris["masks"].array[0]["mode"].str == "Mask");

    foreach (scale; [1, 2, 3, 4]) {
    auto renderSpec = parseJSON(`{"canvas":{"width":32,"height":32},"poses":[{"name":"masked","parameters":{}}]}`);
    renderSpec["canvas"]["supersample"] = JSONValue(scale);
    auto report = agentRenderPoses(
        rigPath,
        renderSpec,
        outputDirectory
    );
    auto rendered = read_image(report.poses[0].outputPath, 4, 8);
    scope(exit) rendered.free();
    assert(rendered.e == 0);

    size_t outsideMask = cast(size_t) (10 * rendered.w + 10) * 4;
    size_t insideMask = cast(size_t) (12 * rendered.w + 12) * 4;
    assert(rendered.buf8[outsideMask + 3] == 0);
    assert(rendered.buf8[insideMask + 3] > 0);
    assert(rendered.buf8[insideMask] >= 118 && rendered.buf8[insideMask] <= 121);
    assert(
        rendered.buf8[insideMask + 1] >= 78 &&
        rendered.buf8[insideMask + 1] <= 81
    );
    assert(
        rendered.buf8[insideMask + 2] >= 198 &&
        rendered.buf8[insideMask + 2] <= 201
    );
    }
}

unittest {
    string inputPath = testPath("inochi-agent-rig-input.inx");
    string outputPath = testPath("inochi-agent-rig-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    auto summary = agentApplyRigSpec(
        inputPath,
        outputPath,
        simpleRigSpec()
    );
    assert(summary.meshedPartCount == 1);
    assert(summary.parameterCount == 1);
    assert(summary.bindingCount == 3);
    assert(binarySuffix(cast(ubyte[]) read(outputPath)) == binarySuffix(fixture));

    auto payload = agentReadModelPayload(outputPath);
    auto part = payload["nodes"]["children"].array[0];
    assert(part["mesh"]["verts"].array.length == 12);
    assert(part["mesh"]["uvs"].array.length == 12);
    assert(part["mesh"]["indices"].array.length == 12);
    assert(part["enabled"].type == JSONType.true_);

    auto parameter = payload["param"].array[$ - 1];
    assert(parameter["name"].str == "EyeX");
    assert(parameter["axis_points"].array[0].array.length == 3);
    assert(parameter["bindings"].array.length == 3);
    auto deformation = parameter["bindings"].array[2];
    assert(deformation["values"].array.length == 3);
    assert(deformation["values"].array[0].array[0].array.length == 6);
}

unittest {
    string inputPath = testPath("inochi-agent-curve-morph-input.inx");
    string outputPath = testPath("inochi-agent-curve-morph-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    write(inputPath, createFixture());
    auto summary = agentApplyRigSpec(inputPath, outputPath, curveMorphRigSpec());
    assert(summary.meshedPartCount == 1);

    auto payload = agentReadModelPayload(outputPath);
    auto part = payload["nodes"]["children"].array[0];
    auto vertices = part["mesh"]["verts"].array;
    auto parameter = payload["param"].array[$ - 1];
    auto offsets = parameter["bindings"].array[0]["values"].array[1].array[0].array;
    assert(vertices.length == 18);
    assert(offsets.length == 9);

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    foreach (index; 0 .. vertices.length / 2) {
        double x = vertices[index * 2].floating;
        double y = vertices[index * 2 + 1].floating;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    double centerX = (minX + maxX) * 0.5;
    double centerY = (minY + maxY) * 0.5;
    double halfWidth = (maxX - minX) * 0.5;
    double halfHeight = (maxY - minY) * 0.5;

    foreach (index; 0 .. offsets.length) {
        double x = vertices[index * 2].floating;
        double y = vertices[index * 2 + 1].floating;
        double normalizedX = (x - centerX) / halfWidth;
        double normalizedY = (y - centerY) / halfHeight;
        double expectedX = centerX + normalizedX * halfWidth * 0.8;
        double expectedCurveY = centerY + 4 +
            6 * (1 - normalizedX * normalizedX) + 3 * normalizedX;
        double expectedY = expectedCurveY + normalizedY * halfHeight * 0.2;
        double unitX = (normalizedX + 1) * 0.5;
        double blend = unitX >= 0.5 ? 1 : unitX / 0.5;
        double influence = blend * blend * (3 - 2 * blend);
        assert(abs(offsets[index].array[0].floating - (expectedX - x) * influence) < 0.0001);
        assert(abs(offsets[index].array[1].floating - (expectedY - y) * influence) < 0.0001);
    }
}

unittest {
    string inputPath = testPath("inochi-agent-invalid-rig-input.inx");
    string outputPath = testPath("inochi-agent-invalid-rig-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    auto invalid = simpleRigSpec();
    invalid["parameters"].array[0]["keys"].array[1] = JSONValue(-1.0);
    bool rejected;
    try {
        agentApplyRigSpec(inputPath, outputPath, invalid);
    } catch (Exception) {
        rejected = true;
    }
    assert(rejected);
    assert(!exists(outputPath));
    assert(cast(ubyte[]) read(inputPath) == fixture);
}

unittest {
    string inputPath = testPath("inochi-agent-path-mesh-input.inx");
    string outputPath = testPath("inochi-agent-path-mesh-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    auto replacement = agentReplacePartMeshByPsdPath(
        inputPath,
        outputPath,
        "/Eyes/Iris",
        replacementMesh()
    );
    assert(replacement.partUuid == 42);
    assert(replacement.vertexCount == 4);
    assert(replacement.triangleCount == 2);
    assert(binarySuffix(cast(ubyte[]) read(outputPath)) == binarySuffix(fixture));

    bool missingRejected;
    try {
        agentReplacePartMeshByPsdPath(
            inputPath,
            outputPath,
            "/Eyes/Missing",
            replacementMesh()
        );
    } catch (Exception) {
        missingRejected = true;
    }
    assert(missingRejected);
}

unittest {
    string inputPath = testPath("inochi-agent-malformed-input.inx");
    string outputPath = testPath("inochi-agent-malformed-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto malformed = createFixture();
    malformed ~= 0xFF;
    write(inputPath, malformed);

    bool rejected;
    try {
        agentRoundTripModel(inputPath, outputPath);
    } catch (Exception) {
        rejected = true;
    }

    assert(rejected);
    assert(!exists(outputPath));
}

unittest {
    string inputPath = testPath("inochi-agent-mesh-input.inx");
    string outputPath = testPath("inochi-agent-mesh-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    auto replacement = agentReplacePartMesh(
        inputPath,
        outputPath,
        42,
        replacementMesh()
    );

    assert(replacement.partUuid == 42);
    assert(replacement.vertexCount == 4);
    assert(replacement.triangleCount == 2);
    assert(binarySuffix(cast(ubyte[]) read(outputPath)) == binarySuffix(fixture));

    auto payload = agentReadModelPayload(outputPath);
    auto mesh = payload["nodes"]["children"].array[0]["mesh"];
    assert(mesh["verts"].array.length == 8);
    assert(mesh["uvs"].array.length == 8);
    assert(mesh["indices"].array.length == 6);
    assert(mesh["indices"].array[0].integer == 0);
    assert(mesh["indices"].array[1].integer == 1);
    assert(mesh["indices"].array[2].integer == 2);
    assert(mesh["indices"].array[3].integer == 0);
    assert(mesh["indices"].array[4].integer == 2);
    assert(mesh["indices"].array[5].integer == 3);
}

unittest {
    string inputPath = testPath("inochi-agent-invalid-mesh-input.inx");
    string outputPath = testPath("inochi-agent-invalid-mesh-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    auto invalidMesh = parseJSON(`{
        "verts":[0,0,1,0,1,1],
        "uvs":[0,0,1,0],
        "indices":[0,1,2],
        "origin":[0,0]
    }`);

    bool rejected;
    try {
        agentReplacePartMesh(inputPath, outputPath, 42, invalidMesh);
    } catch (Exception) {
        rejected = true;
    }

    assert(rejected);
    assert(!exists(outputPath));
    assert(cast(ubyte[]) read(inputPath) == fixture);
}

unittest {
    string inputPath = testPath("inochi-agent-topology-input.inx");
    string outputPath = testPath("inochi-agent-topology-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixture();
    write(inputPath, fixture);

    void expectRejected(JSONValue mesh) {
        bool rejected;
        try {
            agentReplacePartMesh(inputPath, outputPath, 42, mesh);
        } catch (Exception) {
            rejected = true;
        }
        assert(rejected);
        assert(!exists(outputPath));
    }

    expectRejected(parseJSON(`{
        "verts":[0,0,1,0,1,1],
        "uvs":[0,0,1,0,1,1],
        "indices":[0,1,3],
        "origin":[0,0]
    }`));
    expectRejected(parseJSON(`{
        "verts":[0,0,1,0,2,0],
        "uvs":[0,0,0.5,0,1,0],
        "indices":[0,1,2],
        "origin":[0,0]
    }`));
    assert(cast(ubyte[]) read(inputPath) == fixture);
}

unittest {
    string inputPath = testPath("inochi-agent-bound-topology-input.inx");
    string outputPath = testPath("inochi-agent-bound-topology-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    auto fixture = createFixtureWithDeformationBinding();
    write(inputPath, fixture);

    bool rejected;
    try {
        agentReplacePartMesh(inputPath, outputPath, 42, threeVertexMesh());
    } catch (Exception) {
        rejected = true;
    }

    assert(rejected);
    assert(!exists(outputPath));
    assert(cast(ubyte[]) read(inputPath) == fixture);

    rejected = false;
    try {
        agentReplacePartMesh(inputPath, outputPath, 42, alternativeTopologyMesh());
    } catch (Exception) {
        rejected = true;
    }
    assert(rejected);
    assert(!exists(outputPath));

    auto result = agentReplacePartMesh(inputPath, outputPath, 42, replacementMesh());
    assert(result.vertexCount == 4);
    assert(exists(outputPath));
}

unittest {
    string inputPath = testPath("inochi-agent-cli-mesh-input.inx");
    string outputPath = testPath("inochi-agent-cli-mesh-output.inx");
    string meshPath = testPath("inochi-agent-cli-mesh.json");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
        if (exists(meshPath)) remove(meshPath);
    }

    write(inputPath, createFixture());
    write(meshPath, replacementMesh().toString());

    assert(runAgentCommand([
        "inochi-agent",
        "mesh-replace",
        inputPath,
        outputPath,
        "42",
        meshPath
    ]) == 0);

    auto payload = agentReadModelPayload(outputPath);
    assert(payload["nodes"]["children"].array[0]["mesh"]["indices"].array.length == 6);
}

unittest {
    string inputPath = testPath("inochi-agent-cli-rig-input.inx");
    string outputPath = testPath("inochi-agent-cli-rig-output.inx");
    string specPath = testPath("inochi-agent-cli-rig.json");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
        if (exists(specPath)) remove(specPath);
    }

    write(inputPath, createSdkFixture());
    write(specPath, simpleRigSpec().toString());

    assert(runAgentCommand([
        "inochi-agent",
        "rig-apply",
        inputPath,
        outputPath,
        specPath
    ]) == 0);

    auto payload = agentReadModelPayload(outputPath);
    assert(payload["param"].array.length == 1);
}

unittest {
    string inputPath = testPath("inochi-agent-cli-group-input.inx");
    string outputPath = testPath("inochi-agent-cli-group-output.inx");
    string specPath = testPath("inochi-agent-cli-group.json");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
        if (exists(specPath)) remove(specPath);
    }

    write(inputPath, createFlatSdkFixture());
    write(specPath, groupedRigSpec().toString());

    assert(runAgentCommand([
        "inochi-agent",
        "rig-apply",
        inputPath,
        outputPath,
        specPath
    ]) == 0);

    auto payload = agentReadModelPayload(outputPath);
    auto rootChildren = payload["nodes"]["children"].array;
    assert(rootChildren.length == 1);
    assert(rootChildren[0]["type"].str == "Node");
    assert(rootChildren[0]["name"].str == "Eyes");
    assert(rootChildren[0]["children"].array.length == 1);
    assert(rootChildren[0]["children"].array[0]["psdLayerPath"].str == "/Iris");
}

unittest {
    string inputPath = testPath("inochi-agent-cli-nested-group-input.inx");
    string outputPath = testPath("inochi-agent-cli-nested-group-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    write(inputPath, createFlatSdkFixture());
    auto summary = agentApplyRigSpec(
        inputPath,
        outputPath,
        nestedGroupedRigSpec()
    );
    assert(summary.groupCount == 2);

    auto payload = agentReadModelPayload(outputPath);
    auto bodyRoot = payload["nodes"]["children"].array[0];
    assert(bodyRoot["name"].str == "BodyRoot");
    assert(bodyRoot["children"].array.length == 1);
    auto eyes = bodyRoot["children"].array[0];
    assert(eyes["name"].str == "Eyes");
    assert(eyes["children"].array.length == 1);
    assert(eyes["children"].array[0]["psdLayerPath"].str == "/Iris");
}

unittest {
    string inputPath = testPath("inochi-agent-cli-physics-input.inx");
    string outputPath = testPath("inochi-agent-cli-physics-output.inx");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
    }

    write(inputPath, createSdkFixture());
    auto summary = agentApplyRigSpec(
        inputPath,
        outputPath,
        physicsRigSpec()
    );
    assert(summary.physicsCount == 1);

    auto sdkSummary = agentValidateWithSdk(outputPath);
    assert(sdkSummary.driverCount == 1);
    assert(sdkSummary.drivenParameterCount == 1);
}

unittest {
    import imagefmt : read_image;

    string inputPath = testPath("inochi-agent-cli-physics-render-input.inx");
    string outputPath = testPath("inochi-agent-cli-physics-render-output.inx");
    string outputDirectory = testPath("inochi-agent-cli-physics-render-output");

    scope(exit) {
        if (exists(inputPath)) remove(inputPath);
        if (exists(outputPath)) remove(outputPath);
        if (exists(outputDirectory)) rmdirRecurse(outputDirectory);
    }

    write(inputPath, createSdkFixture());
    agentApplyRigSpec(inputPath, outputPath, physicsRigSpec());
    auto report = agentRenderPoses(
        outputPath,
        physicsRenderSpec(),
        outputDirectory
    );
    assert(report.poseCount == 1);
    assert(report.poses[0].physicsFrameCount == 8);
    assert(report.poses[0].physicsParameterValues.length == 1);
    assert(report.poses[0].nonTransparentPixelCount > 0);
    assert(exists(report.poses[0].outputPath));
}
