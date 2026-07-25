module creator.agentcore.modelio;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : read, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : isFinite;
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

/**
 * The result of a mesh replacement request.  Triangle winding is normalized
 * counter-clockwise before it is written into the INX JSON payload.
 */
struct AgentMeshSummary {
    ulong partUuid;
    size_t vertexCount;
    size_t triangleCount;

    string toJson() const {
        return format(
            `{"partUuid":%s,"vertexCount":%s,"triangleCount":%s}`,
            partUuid,
            vertexCount,
            triangleCount
        );
    }
}

private struct InxDocument {
    ubyte[] originalBytes;
    JSONValue payload;
    ubyte[] binarySuffix;
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
    auto binarySuffix = bytes.dup;

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

    return InxDocument(input.dup, payload, binarySuffix, textureCount);
}

private ubyte[] serializeInx(InxDocument document) {
    auto payloadText = document.payload.toString();
    if (payloadText.length > uint.max) {
        throw new Exception("INX JSON payload exceeds the 32-bit container limit.");
    }

    ubyte[] result = agentMagicBytes.dup;
    result ~= nativeToBigEndian(cast(uint) payloadText.length)[];
    result ~= cast(ubyte[]) payloadText;
    result ~= document.binarySuffix;
    return result;
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
 * Returns the raw INX JSON payload after validating the surrounding binary
 * container.  This has no renderer, window, texture, or puppet dependency.
 */
JSONValue agentReadModelPayload(string path) {
    return parseInx(cast(const(ubyte)[]) read(path)).payload;
}

private JSONValue requireMeshField(JSONValue mesh, string field) {
    if (mesh.type != JSONType.object || !(field in mesh.object)) {
        throw new Exception(format("Mesh is missing required '%s' field.", field));
    }
    return mesh[field];
}

private double readFiniteNumber(JSONValue value, string label) {
    double result;
    switch (value.type) {
        case JSONType.integer:
            result = cast(double) value.integer;
            break;
        case JSONType.uinteger:
            result = cast(double) value.uinteger;
            break;
        case JSONType.float_:
            result = value.floating;
            break;
        default:
            throw new Exception(format("%s must be a number.", label));
    }

    if (!isFinite(result)) {
        throw new Exception(format("%s must be finite.", label));
    }
    return result;
}

private void validateNumericArray(JSONValue value, size_t expectedLength, string label) {
    if (value.type != JSONType.array || value.array.length != expectedLength) {
        throw new Exception(format("%s has an invalid length.", label));
    }
    foreach (index, entry; value.array) {
        readFiniteNumber(entry, format("%s[%s]", label, index));
    }
}

private ulong readIndex(JSONValue value, string label) {
    ulong result;
    switch (value.type) {
        case JSONType.integer:
            if (value.integer < 0) {
                throw new Exception(format("%s must not be negative.", label));
            }
            result = cast(ulong) value.integer;
            break;
        case JSONType.uinteger:
            result = value.uinteger;
            break;
        default:
            throw new Exception(format("%s must be an integer.", label));
    }
    return result;
}

private JSONValue normalizeMesh(JSONValue requested, out size_t vertexCount, out size_t triangleCount) {
    if (requested.type != JSONType.object) {
        throw new Exception("Mesh must be a JSON object.");
    }

    auto normalized = parseJSON(requested.toString());
    auto vertices = requireMeshField(normalized, "verts");
    if (vertices.type != JSONType.array || vertices.array.length < 6 || vertices.array.length % 2 != 0) {
        throw new Exception("Mesh verts must contain at least three coordinate pairs.");
    }

    vertexCount = vertices.array.length / 2;
    if (vertexCount > ushort.max + 1) {
        throw new Exception("Mesh has more vertices than INX 16-bit indices support.");
    }

    double[] coordinates;
    coordinates.length = vertices.array.length;
    foreach (index, vertex; vertices.array) {
        coordinates[index] = readFiniteNumber(vertex, format("verts[%s]", index));
    }

    if ("uvs" in normalized.object) {
        validateNumericArray(normalized["uvs"], vertices.array.length, "uvs");
    }
    validateNumericArray(requireMeshField(normalized, "origin"), 2, "origin");

    auto indicesValue = requireMeshField(normalized, "indices");
    if (
        indicesValue.type != JSONType.array ||
        indicesValue.array.length < 3 ||
        indicesValue.array.length % 3 != 0
    ) {
        throw new Exception("Mesh indices must contain complete triangles.");
    }

    ulong[] indices;
    indices.length = indicesValue.array.length;
    foreach (index, entry; indicesValue.array) {
        indices[index] = readIndex(entry, format("indices[%s]", index));
        if (indices[index] >= vertexCount) {
            throw new Exception(format("indices[%s] is outside the vertex array.", index));
        }
    }

    foreach (triangleOffset; 0 .. indices.length / 3) {
        size_t offset = triangleOffset * 3;
        auto first = indices[offset];
        auto second = indices[offset + 1];
        auto third = indices[offset + 2];
        if (first == second || second == third || first == third) {
            throw new Exception(format("Triangle %s repeats a vertex.", triangleOffset));
        }

        double firstX = coordinates[first * 2];
        double firstY = coordinates[first * 2 + 1];
        double secondX = coordinates[second * 2];
        double secondY = coordinates[second * 2 + 1];
        double thirdX = coordinates[third * 2];
        double thirdY = coordinates[third * 2 + 1];
        double twiceArea = (secondX - firstX) * (thirdY - firstY) -
            (secondY - firstY) * (thirdX - firstX);
        if (twiceArea == 0) {
            throw new Exception(format("Triangle %s is degenerate.", triangleOffset));
        }
        if (twiceArea < 0) {
            auto temporary = indices[offset + 1];
            indices[offset + 1] = indices[offset + 2];
            indices[offset + 2] = temporary;
        }
    }

    JSONValue[] normalizedIndices;
    normalizedIndices.length = indices.length;
    foreach (index, value; indices) {
        normalizedIndices[index] = JSONValue(cast(long) value);
    }
    normalized.object["indices"] = JSONValue(normalizedIndices);
    triangleCount = indices.length / 3;
    return normalized;
}

private bool replacePartMesh(ref JSONValue node, ulong requestedUuid, JSONValue mesh) {
    if (node.type != JSONType.object) {
        throw new Exception("Invalid node tree.");
    }

    auto nodeType = objectField(node, "type", JSONValue(""));
    if (
        nodeType.type == JSONType.string &&
        nodeType.str == "Part" &&
        "uuid" in node.object &&
        readIndex(node["uuid"], "Part uuid") == requestedUuid
    ) {
        node.object["mesh"] = mesh;
        return true;
    }

    if ("children" in node.object) {
        if (node["children"].type != JSONType.array) {
            throw new Exception("Invalid node children.");
        }
        foreach (ref child; node["children"].array) {
            if (replacePartMesh(child, requestedUuid, mesh)) {
                return true;
            }
        }
    }
    return false;
}

private bool findPartMesh(JSONValue node, ulong requestedUuid, out JSONValue mesh) {
    if (node.type != JSONType.object) {
        throw new Exception("Invalid node tree.");
    }

    auto nodeType = objectField(node, "type", JSONValue(""));
    if (
        nodeType.type == JSONType.string &&
        nodeType.str == "Part" &&
        "uuid" in node.object &&
        readIndex(node["uuid"], "Part uuid") == requestedUuid
    ) {
        mesh = requireMeshField(node, "mesh");
        return true;
    }

    if ("children" in node.object) {
        if (node["children"].type != JSONType.array) {
            throw new Exception("Invalid node children.");
        }
        foreach (child; node["children"].array) {
            if (findPartMesh(child, requestedUuid, mesh)) {
                return true;
            }
        }
    }
    return false;
}

private size_t meshVertexCount(JSONValue mesh, string label) {
    auto vertices = requireMeshField(mesh, "verts");
    if (vertices.type != JSONType.array || vertices.array.length % 2 != 0) {
        throw new Exception(format("%s has invalid verts.", label));
    }
    return vertices.array.length / 2;
}

private bool hasSameIndices(JSONValue existingMesh, JSONValue replacementMesh) {
    auto existing = requireMeshField(existingMesh, "indices");
    auto replacement = requireMeshField(replacementMesh, "indices");
    if (existing.type != JSONType.array || replacement.type != JSONType.array) {
        throw new Exception("Part mesh indices must be arrays.");
    }
    if (existing.array.length != replacement.array.length) {
        return false;
    }
    foreach (index, value; existing.array) {
        if (
            readIndex(value, format("Existing indices[%s]", index)) !=
            readIndex(replacement.array[index], format("Replacement indices[%s]", index))
        ) {
            return false;
        }
    }
    return true;
}

private bool hasDeformationBinding(JSONValue payload, ulong partUuid) {
    auto parameters = objectField(payload, "param", JSONValue(JSONValue[].init));
    if (parameters.type != JSONType.array) {
        throw new Exception("INX parameters must be an array.");
    }

    foreach (parameter; parameters.array) {
        if (parameter.type != JSONType.object || !("bindings" in parameter.object)) {
            continue;
        }
        auto bindings = parameter["bindings"];
        if (bindings.type != JSONType.array) {
            throw new Exception("Parameter bindings must be an array.");
        }
        foreach (binding; bindings.array) {
            if (
                binding.type == JSONType.object &&
                "node" in binding.object &&
                "param_name" in binding.object &&
                readIndex(binding["node"], "Parameter binding node") == partUuid &&
                binding["param_name"].type == JSONType.string &&
                binding["param_name"].str == "deform"
            ) {
                return true;
            }
        }
    }
    return false;
}

/**
 * Replaces one Part's mesh in a validated INX container without constructing
 * any GUI or renderer state.  The requested mesh must use INX-native
 * `verts`/`uvs`/`indices`/`origin` fields.  Every texture and extension byte
 * is copied from the original container unchanged.  When a Part has existing
 * deformation parameter bindings, topology changes are rejected because their
 * per-vertex deformation arrays would no longer be safe to reuse.  Such Parts
 * may only receive coordinate adjustments with the same vertex count and
 * index order.
 */
AgentMeshSummary agentReplacePartMesh(
    string inputPath,
    string outputPath,
    ulong partUuid,
    JSONValue requestedMesh
) {
    auto document = parseInx(cast(const(ubyte)[]) read(inputPath));
    size_t vertexCount;
    size_t triangleCount;
    auto normalizedMesh = normalizeMesh(requestedMesh, vertexCount, triangleCount);

    auto nodeTree = objectField(document.payload, "nodes", JSONValue.emptyObject);
    JSONValue existingMesh;
    if (!findPartMesh(nodeTree, partUuid, existingMesh)) {
        throw new Exception(format("Could not find Part with uuid %s.", partUuid));
    }
    if (
        hasDeformationBinding(document.payload, partUuid) &&
        (
            meshVertexCount(existingMesh, "Existing Part mesh") != vertexCount ||
            !hasSameIndices(existingMesh, normalizedMesh)
        )
    ) {
        throw new Exception(
            format(
                "Part %s has deformation bindings; changing its topology requires a deformation migration.",
                partUuid
            )
        );
    }
    if (!replacePartMesh(nodeTree, partUuid, normalizedMesh)) {
        throw new Exception(format("Could not find Part with uuid %s.", partUuid));
    }
    document.payload.object["nodes"] = nodeTree;

    write(outputPath, serializeInx(document));
    return AgentMeshSummary(partUuid, vertexCount, triangleCount);
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
