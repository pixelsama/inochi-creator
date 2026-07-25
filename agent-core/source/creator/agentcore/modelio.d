module creator.agentcore.modelio;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : read, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : representation;

enum ubyte[] agentMagicBytes = cast(ubyte[])"TRNSRTS\0";
enum ubyte[] agentTextureSection = cast(ubyte[])"TEX_SECT";
enum ubyte[] agentExtensionSection = cast(ubyte[])"EXT_SECT";

struct ModelSummary {
    string name;
    size_t nodeCount;
    size_t partCount;
    size_t parameterCount;
    size_t textureCount;

    string toJson() const {
        return format(
            `{"name":%s,"nodeCount":%s,"partCount":%s,"parameterCount":%s,"textureCount":%s}`,
            representation(name),
            nodeCount,
            partCount,
            parameterCount,
            textureCount
        );
    }
}

private struct InxDocument {
    ubyte[] originalBytes;
    JSONValue payload;
    size_t textureCount;
}

private void requireSection(const(ubyte)[] actual, const(ubyte)[] expected, string label) {
    if (actual != expected) {
        throw new Exception(format("Invalid %s section.", label));
    }
}

private uint readUInt32(ref const(ubyte)[] bytes, string label) {
    if (bytes.length < uint.sizeof) {
        throw new Exception(format("Truncated %s.", label));
    }

    ubyte[uint.sizeof] encoded = bytes[0 .. uint.sizeof];
    bytes = bytes[uint.sizeof .. $];
    return bigEndianToNative!uint(encoded);
}

private const(ubyte)[] readSlice(ref const(ubyte)[] bytes, size_t length, string label) {
    if (bytes.length < length) {
        throw new Exception(format("Truncated %s.", label));
    }

    auto result = bytes[0 .. length];
    bytes = bytes[length .. $];
    return result;
}

private InxDocument parseInx(const(ubyte)[] input) {
    auto bytes = input;
    requireSection(readSlice(bytes, agentMagicBytes.length, "magic"), agentMagicBytes, "magic");

    uint payloadLength = readUInt32(bytes, "payload length");
    auto payloadBytes = readSlice(bytes, payloadLength, "JSON payload");
    auto payload = parseJSON(cast(string) payloadBytes);

    requireSection(
        readSlice(bytes, agentTextureSection.length, "texture section"),
        agentTextureSection,
        "texture"
    );

    uint textureCount = readUInt32(bytes, "texture count");
    foreach (textureIndex; 0 .. textureCount) {
        uint textureLength = readUInt32(bytes, format("texture %s length", textureIndex));
        readSlice(bytes, 1, format("texture %s tag", textureIndex));
        readSlice(bytes, textureLength, format("texture %s data", textureIndex));
    }

    if (bytes.length > 0) {
        requireSection(
            readSlice(bytes, agentExtensionSection.length, "extension section"),
            agentExtensionSection,
            "extension"
        );

        uint extensionCount = readUInt32(bytes, "extension count");
        foreach (extensionIndex; 0 .. extensionCount) {
            uint nameLength = readUInt32(bytes, format("extension %s name length", extensionIndex));
            readSlice(bytes, nameLength, format("extension %s name", extensionIndex));
            uint dataLength = readUInt32(bytes, format("extension %s data length", extensionIndex));
            readSlice(bytes, dataLength, format("extension %s data", extensionIndex));
        }
    }

    if (bytes.length != 0) {
        throw new Exception("Unexpected trailing bytes in INX document.");
    }

    return InxDocument(input.dup, payload, textureCount);
}

private size_t countNodes(JSONValue node) {
    if (node.type == JSONType.null_) return 0;
    if (node.type != JSONType.object) throw new Exception("Invalid node tree.");

    size_t total = 1;
    if ("children" in node.object) {
        foreach (child; node["children"].array) {
            total += countNodes(child);
        }
    }
    return total;
}

private JSONValue objectField(JSONValue object, string key, JSONValue fallback) {
    if (object.type != JSONType.object) return fallback;
    if (key in object.object) return object[key];
    return fallback;
}

private size_t countParts(JSONValue node) {
    if (node.type == JSONType.null_) return 0;
    if (node.type != JSONType.object) throw new Exception("Invalid node tree.");

    auto nodeType = objectField(node, "type", JSONValue(""));
    size_t total = nodeType.type == JSONType.string && nodeType.str == "Part" ? 1 : 0;
    if ("children" in node.object) {
        foreach (child; node["children"].array) {
            total += countParts(child);
        }
    }
    return total;
}

private ModelSummary summarize(InxDocument document) {
    if (document.payload.type != JSONType.object) {
        throw new Exception("INX JSON payload must be an object.");
    }

    auto meta = objectField(document.payload, "meta", JSONValue.emptyObject);
    auto nodeTree = objectField(document.payload, "nodes", JSONValue.emptyObject);
    auto parameters = objectField(document.payload, "param", JSONValue(JSONValue[].init));

    return ModelSummary(
        objectField(meta, "name", JSONValue("")).str,
        countNodes(nodeTree),
        countParts(nodeTree),
        parameters.array.length,
        document.textureCount
    );
}

/**
 * Validates the complete INX container without creating a renderer, window,
 * texture, or puppet object.
 */
void agentValidateModel(string path) {
    parseInx(cast(const(ubyte)[]) read(path));
}

ModelSummary agentInspectModel(string path) {
    return summarize(parseInx(cast(const(ubyte)[]) read(path)));
}

/**
 * Copies a validated INX container byte-for-byte. This deliberately retains
 * every original texture and extension payload and requires no renderer.
 */
ModelSummary agentRoundTripModel(string inputPath, string outputPath) {
    auto document = parseInx(cast(const(ubyte)[]) read(inputPath));
    write(outputPath, document.originalBytes);
    return summarize(document);
}
