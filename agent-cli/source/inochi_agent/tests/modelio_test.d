module inochi_agent.tests.modelio_test;

import std.bitmanip : nativeToBigEndian;
import std.file : exists, read, remove, write;
import std.path : buildPath;
import std.process : environment;
import std.string : representation;

import creator.agentcore.modelio;

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
                {"type":"Part","children":[]}
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

    auto outputSummary = agentRoundTripModel(inputPath, outputPath);
    assert(exists(outputPath));
    assert(outputSummary == inputSummary);
    assert(cast(ubyte[]) read(outputPath) == fixture);
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
