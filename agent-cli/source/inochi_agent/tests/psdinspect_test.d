module inochi_agent.tests.psdinspect_test;

import std.file : exists, remove, tempDir, write;
import std.json : JSONType, JSONValue;
import std.path : buildPath;

import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import creator.agentcore.psdinspect;
import inochi_agent.sdkvalidate;

private double jsonNumber(JSONValue value) {
    final switch (value.type) {
        case JSONType.integer:
            return cast(double) value.integer;
        case JSONType.uinteger:
            return cast(double) value.uinteger;
        case JSONType.float_:
            return value.floating;
        case JSONType.string:
        case JSONType.array:
        case JSONType.object:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            throw new Exception("Expected a JSON number.");
    }
}

unittest {
    auto layout = agentBuildPsdLayout([
        AgentPsdSourceLayer("</Layer set>", AgentPsdLayerKind.sectionDivider, 0),
        AgentPsdSourceLayer("Iris", AgentPsdLayerKind.pixel, 1),
        AgentPsdSourceLayer("Eye", AgentPsdLayerKind.group, 2)
    ]);

    assert(layout.length == 2);
    assert(layout[0].name == "Eye");
    assert(layout[0].path == "/Eye");
    assert(layout[0].depth == 0);
    assert(layout[0].isGroup);
    assert(layout[1].name == "Iris");
    assert(layout[1].path == "/Eye/Iris");
    assert(layout[1].depth == 1);
    assert(!layout[1].isGroup);
    assert(layout[1].sourceIndex == 1);
}

unittest {
    ubyte[] rawChannel = [0, 0, 10, 20, 30, 40];
    assert(agentDecodePsdChannel(rawChannel, 2, 2) == [10, 20, 30, 40]);

    ubyte[] rleChannel = [
        0, 1,
        0, 3,
        0, 2,
        1, 10, 20,
        255, 30
    ];
    assert(agentDecodePsdChannel(rleChannel, 2, 2) == [10, 20, 30, 30]);
}

unittest {
    ubyte[] red = [10, 20];
    ubyte[] green = [30, 40];
    ubyte[] blue = [50, 60];
    auto rgba = agentComposePsdRgba(red, green, blue, null, 2);

    assert(rgba == [
        10, 30, 50, 255,
        20, 40, 60, 255
    ]);
}

unittest {
    ubyte[] truncatedRle = [0, 1, 0, 4, 1, 10];
    bool rejected;
    try {
        agentDecodePsdChannel(truncatedRle, 2, 1);
    } catch (Exception) {
        rejected = true;
    }
    assert(rejected);
}

unittest {
    assert(agentPremultiplyRgba([
        200, 100, 50, 128,
        9, 8, 7, 0,
        1, 2, 3, 255
    ]) == [
        100, 50, 25, 128,
        0, 0, 0, 0,
        1, 2, 3, 255
    ]);
}

unittest {
    AgentPsdImportLayer group;
    group.name = "Eye";
    group.path = "/Eye";
    group.sourceIndex = 2;
    group.depth = 0;
    group.isGroup = true;
    group.visible = true;

    AgentPsdImportLayer iris;
    iris.name = "Iris";
    iris.path = "/Eye/Iris";
    iris.sourceIndex = 1;
    iris.depth = 1;
    iris.visible = true;
    iris.left = 10;
    iris.top = 20;
    iris.width = 2;
    iris.height = 1;
    iris.opacity = 255;
    iris.blendMode = "norm";
    iris.rgba = [
        200, 100, 50, 128,
        1, 2, 3, 255
    ];

    AgentPsdImportDocument document;
    document.width = 100;
    document.height = 80;
    document.sourceLayerRecordCount = 3;
    document.layers = [group, iris];

    auto outputPath = buildPath(tempDir(), "inochi-agent-psdimport-test.agent-incomplete");
    scope (exit) if (exists(outputPath)) remove(outputPath);
    write(outputPath, agentBuildInitialInx(document, "PSD Fixture"));

    auto summary = agentInspectModel(outputPath);
    assert(summary.name == "PSD Fixture");
    assert(summary.nodeCount == 3);
    assert(summary.partCount == 1);
    assert(summary.parameterCount == 0);
    assert(summary.textureCount == 1);

    auto payload = agentReadModelPayload(outputPath);
    auto groupNode = payload["nodes"]["children"].array[0];
    auto partNode = groupNode["children"].array[0];
    assert(groupNode["name"].str == "Eye");
    assert(groupNode["type"].str == "Node");
    assert(partNode["name"].str == "Iris");
    assert(partNode["type"].str == "Part");
    assert(partNode["psdLayerPath"].str == "/Eye/Iris");
    assert(jsonNumber(partNode["textures"].array[0]) == 0);
    assert(partNode["mesh"]["verts"].array.length == 8);
    assert(partNode["mesh"]["indices"].array.length == 6);
    assert(jsonNumber(partNode["transform"]["trans"].array[0]) == -39.0);
    assert(jsonNumber(partNode["transform"]["trans"].array[1]) == -19.5);

    auto textureSummary = agentVerifyInitialInxTextures(document, outputPath);
    assert(textureSummary.verifiedTextureCount == 1);
    assert(textureSummary.verifiedRgbaByteCount == 8);

    auto sdkSummary = agentValidateWithSdk(outputPath);
    assert(sdkSummary.name == "PSD Fixture");
    assert(sdkSummary.partCount == 1);
    assert(sdkSummary.textureReferenceCount == 1);

    document.layers[1].rgba[0] = 203;
    bool mismatchRejected;
    try {
        agentVerifyInitialInxTextures(document, outputPath);
    } catch (Exception) {
        mismatchRejected = true;
    }
    assert(mismatchRejected);
}
