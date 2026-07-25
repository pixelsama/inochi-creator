module inochi_agent.tests.modelio_test;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : exists, read, remove, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : representation;

import creator.agentcore.modelio;
import inochi_agent.commands;

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
