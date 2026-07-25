module creator.agentcore.modelio;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : read, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, isFinite;

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
            JSONValue(name).toString(),
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

/**
 * Summary of a deterministic rig specification application.
 */
struct AgentRigSummary {
    size_t meshedPartCount;
    size_t parameterCount;
    size_t bindingCount;

    string toJson() const {
        return format(
            `{"meshedPartCount":%s,"parameterCount":%s,"bindingCount":%s}`,
            meshedPartCount,
            parameterCount,
            bindingCount
        );
    }
}

struct AgentTextureBlob {
    ubyte type;
    ubyte[] data;
}

private struct InxDocument {
    ubyte[] originalBytes;
    JSONValue payload;
    ubyte[] binarySuffix;
    size_t textureCount;
    AgentTextureBlob[] textureBlobs;
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
    AgentTextureBlob[] textureBlobs;
    textureBlobs.reserve(textureCount);
    foreach (textureIndex; 0 .. textureCount) {
        uint textureLength = readUInt32(bytes, format("texture %s length", textureIndex));
        auto textureType = readSlice(bytes, 1, format("texture %s tag", textureIndex))[0];
        auto textureData = readSlice(
            bytes,
            textureLength,
            format("texture %s data", textureIndex)
        );
        textureBlobs ~= AgentTextureBlob(textureType, textureData.dup);
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

    return InxDocument(input.dup, payload, binarySuffix, textureCount, textureBlobs);
}

private ubyte[] serializeInx(InxDocument document) {
    void requireFiniteJson(JSONValue value, string path) {
        final switch (value.type) {
            case JSONType.float_:
                if (!isFinite(value.floating)) {
                    throw new Exception(format("INX JSON field '%s' is not finite.", path));
                }
                break;
            case JSONType.array:
                foreach (index, child; value.array) {
                    requireFiniteJson(child, format("%s[%s]", path, index));
                }
                break;
            case JSONType.object:
                foreach (key, child; value.object) {
                    requireFiniteJson(child, path ~ "." ~ key);
                }
                break;
            case JSONType.string:
            case JSONType.integer:
            case JSONType.uinteger:
            case JSONType.true_:
            case JSONType.false_:
            case JSONType.null_:
                break;
        }
    }
    requireFiniteJson(document.payload, "$payload");
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

private string requiredString(JSONValue object, string key, string label) {
    if (
        object.type != JSONType.object ||
        !(key in object.object) ||
        object[key].type != JSONType.string ||
        object[key].str.length == 0
    ) {
        throw new Exception(format("%s requires a non-empty '%s' string.", label, key));
    }
    return object[key].str;
}

private JSONValue numberArray(const(double)[] values) {
    JSONValue[] result;
    result.reserve(values.length);
    foreach (value; values) {
        result ~= JSONValue(value);
    }
    return JSONValue(result);
}

private JSONValue indexArray(const(ulong)[] values) {
    JSONValue[] result;
    result.reserve(values.length);
    foreach (value; values) {
        result ~= JSONValue(value);
    }
    return JSONValue(result);
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

/**
 * Returns decoded INX texture container records without instantiating GPU
 * textures. The encoded image bytes are copied out of the source document.
 */
AgentTextureBlob[] agentReadModelTextures(string path) {
    return parseInx(cast(const(ubyte)[]) read(path)).textureBlobs;
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

private void findPartUuidsByPsdPath(
    JSONValue node,
    string requestedPath,
    ref ulong[] matches
) {
    if (node.type != JSONType.object) {
        throw new Exception("Invalid node tree.");
    }

    auto nodeType = objectField(node, "type", JSONValue(""));
    if (
        nodeType.type == JSONType.string &&
        nodeType.str == "Part" &&
        "uuid" in node.object &&
        "psdLayerPath" in node.object &&
        node["psdLayerPath"].type == JSONType.string &&
        node["psdLayerPath"].str == requestedPath
    ) {
        matches ~= readIndex(node["uuid"], "Part uuid");
    }

    if ("children" in node.object) {
        if (node["children"].type != JSONType.array) {
            throw new Exception("Invalid node children.");
        }
        foreach (child; node["children"].array) {
            findPartUuidsByPsdPath(child, requestedPath, matches);
        }
    }
}

private ulong requirePartUuidByPsdPath(JSONValue payload, string requestedPath) {
    auto nodeTree = objectField(payload, "nodes", JSONValue.emptyObject);
    ulong[] matches;
    findPartUuidsByPsdPath(nodeTree, requestedPath, matches);
    if (matches.length == 0) {
        throw new Exception(format(
            "Could not find Part with psdLayerPath '%s'.",
            requestedPath
        ));
    }
    if (matches.length > 1) {
        throw new Exception(format(
            "PSD layer path '%s' is ambiguous across %s Parts.",
            requestedPath,
            matches.length
        ));
    }
    return matches[0];
}

ulong agentFindPartUuidByPsdPath(string inputPath, string requestedPath) {
    auto document = parseInx(cast(const(ubyte)[]) read(inputPath));
    return requirePartUuidByPsdPath(document.payload, requestedPath);
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
 * Replaces a Part mesh through the stable PSD hierarchy path retained by
 * `psd-import`, avoiding generated UUID discovery in Agent workflows.
 */
AgentMeshSummary agentReplacePartMeshByPsdPath(
    string inputPath,
    string outputPath,
    string psdLayerPath,
    JSONValue requestedMesh
) {
    ulong partUuid = agentFindPartUuidByPsdPath(inputPath, psdLayerPath);
    return agentReplacePartMesh(
        inputPath,
        outputPath,
        partUuid,
        requestedMesh
    );
}

private size_t mutateNodesByPath(
    ref JSONValue node,
    string parentPath,
    string requestedPath,
    scope void delegate(ref JSONValue) mutation
) {
    if (node.type != JSONType.object) {
        throw new Exception("Invalid node tree.");
    }

    string nodePath = parentPath;
    if (
        "name" in node.object &&
        node["name"].type == JSONType.string &&
        node["name"].str != "Root"
    ) {
        nodePath ~= "/" ~ node["name"].str;
    }

    bool pathMatches = nodePath == requestedPath;
    if (
        "psdLayerPath" in node.object &&
        node["psdLayerPath"].type == JSONType.string &&
        node["psdLayerPath"].str == requestedPath
    ) {
        pathMatches = true;
    }

    size_t matches;
    if (pathMatches) {
        mutation(node);
        matches++;
    }

    if ("children" in node.object) {
        if (node["children"].type != JSONType.array) {
            throw new Exception("Invalid node children.");
        }
        foreach (ref child; node["children"].array) {
            matches += mutateNodesByPath(child, nodePath, requestedPath, mutation);
        }
    }
    return matches;
}

private void mutateUniqueNode(
    ref JSONValue payload,
    string requestedPath,
    scope void delegate(ref JSONValue) mutation
) {
    if (!("nodes" in payload.object)) {
        throw new Exception("INX payload has no node tree.");
    }
    auto matches = mutateNodesByPath(payload["nodes"], "", requestedPath, mutation);
    if (matches == 0) {
        throw new Exception(format("Could not find node path '%s'.", requestedPath));
    }
    if (matches > 1) {
        throw new Exception(format("Node path '%s' is ambiguous.", requestedPath));
    }
}

private JSONValue buildGridMesh(JSONValue existingMesh, size_t columns, size_t rows) {
    if (columns < 2 || rows < 2) {
        throw new Exception("Grid mesh columns and rows must both be at least two.");
    }
    if (columns * rows > ushort.max + 1) {
        throw new Exception("Grid mesh exceeds INX 16-bit vertex indices.");
    }

    auto existingVertices = requireMeshField(existingMesh, "verts");
    if (
        existingVertices.type != JSONType.array ||
        existingVertices.array.length < 6 ||
        existingVertices.array.length % 2 != 0
    ) {
        throw new Exception("Existing Part mesh has invalid verts.");
    }

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    foreach (offset; 0 .. existingVertices.array.length / 2) {
        double x = readFiniteNumber(existingVertices.array[offset * 2], "Existing vertex x");
        double y = readFiniteNumber(existingVertices.array[offset * 2 + 1], "Existing vertex y");
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    if (minX == maxX || minY == maxY) {
        throw new Exception("Existing Part mesh has zero-sized bounds.");
    }

    double[] vertices;
    double[] uvs;
    double[] xAxis;
    double[] yAxis;
    foreach (column; 0 .. columns) {
        double unit = cast(double) column / (columns - 1);
        xAxis ~= minX + (maxX - minX) * unit;
    }
    foreach (row; 0 .. rows) {
        double unit = cast(double) row / (rows - 1);
        yAxis ~= minY + (maxY - minY) * unit;
        foreach (column; 0 .. columns) {
            vertices ~= xAxis[column];
            vertices ~= yAxis[$ - 1];
            uvs ~= cast(double) column / (columns - 1);
            uvs ~= unit;
        }
    }

    ulong[] indices;
    foreach (row; 0 .. rows - 1) {
        foreach (column; 0 .. columns - 1) {
            ulong topLeft = row * columns + column;
            ulong topRight = topLeft + 1;
            ulong bottomLeft = topLeft + columns;
            ulong bottomRight = bottomLeft + 1;
            indices ~= [topLeft, topRight, bottomLeft];
            indices ~= [topRight, bottomRight, bottomLeft];
        }
    }

    JSONValue[string] gridAxes;
    JSONValue[] axes = [numberArray(xAxis), numberArray(yAxis)];
    JSONValue[string] mesh;
    mesh["verts"] = numberArray(vertices);
    mesh["uvs"] = numberArray(uvs);
    mesh["indices"] = indexArray(indices);
    mesh["origin"] = objectField(existingMesh, "origin", numberArray([0.0, 0.0]));
    mesh["grid_axes"] = JSONValue(axes);
    return JSONValue(mesh);
}

private void inspectRigTarget(
    ref JSONValue payload,
    string path,
    out ulong uuid,
    out string nodeType,
    out JSONValue mesh
) {
    size_t matches;
    mutateUniqueNode(payload, path, (ref JSONValue node) {
        matches++;
        if (!("uuid" in node.object)) {
            throw new Exception(format("Node '%s' has no uuid.", path));
        }
        uuid = readIndex(node["uuid"], format("Node '%s' uuid", path));
        nodeType = objectField(node, "type", JSONValue("")).str;
        mesh = objectField(node, "mesh", JSONValue.init);
    });
}

private ulong maximumUuid(JSONValue node, JSONValue parameters) {
    ulong result;
    void scanNode(JSONValue current) {
        if (current.type != JSONType.object) return;
        if ("uuid" in current.object) {
            auto value = readIndex(current["uuid"], "Node uuid");
            if (value > result) result = value;
        }
        if ("children" in current.object && current["children"].type == JSONType.array) {
            foreach (child; current["children"].array) scanNode(child);
        }
    }
    scanNode(node);
    if (parameters.type == JSONType.array) {
        foreach (parameter; parameters.array) {
            if (parameter.type == JSONType.object && "uuid" in parameter.object) {
                auto value = readIndex(parameter["uuid"], "Parameter uuid");
                if (value > result) result = value;
            }
        }
    }
    return result;
}

private JSONValue bindingSetFlags(size_t keyCount) {
    JSONValue[] result;
    foreach (_; 0 .. keyCount) {
        result ~= JSONValue([JSONValue(true)]);
    }
    return JSONValue(result);
}

private JSONValue numericBindingValues(JSONValue values, size_t keyCount, string label) {
    if (values.type != JSONType.array || values.array.length != keyCount) {
        throw new Exception(format("%s values must match the parameter key count.", label));
    }
    JSONValue[] result;
    foreach (index, value; values.array) {
        result ~= JSONValue([
            JSONValue(readFiniteNumber(value, format("%s values[%s]", label, index)))
        ]);
    }
    return JSONValue(result);
}

private double optionalProfileNumber(JSONValue profile, string key) {
    if (!(key in profile.object)) return 0;
    return readFiniteNumber(profile[key], format("Deformation profile '%s'", key));
}

private JSONValue deformationForMesh(JSONValue mesh, JSONValue request, string label) {
    auto vertices = requireMeshField(mesh, "verts");
    if (
        vertices.type != JSONType.array ||
        vertices.array.length < 6 ||
        vertices.array.length % 2 != 0
    ) {
        throw new Exception(format("%s targets a Part without a valid mesh.", label));
    }

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;
    foreach (offset; 0 .. vertices.array.length / 2) {
        double x = readFiniteNumber(vertices.array[offset * 2], "Mesh vertex x");
        double y = readFiniteNumber(vertices.array[offset * 2 + 1], "Mesh vertex y");
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
    }
    double centerX = (minX + maxX) * 0.5;
    double centerY = (minY + maxY) * 0.5;
    double halfWidth = (maxX - minX) * 0.5;
    double halfHeight = (maxY - minY) * 0.5;
    if (
        !isFinite(centerX) || !isFinite(centerY) ||
        !isFinite(halfWidth) || !isFinite(halfHeight) ||
        halfWidth <= 0 || halfHeight <= 0
    ) {
        throw new Exception(format(
            "%s targets a mesh with invalid bounds (%s, %s)-(%s, %s).",
            label,
            minX,
            minY,
            maxX,
            maxY
        ));
    }

    JSONValue[] profiles;
    if (request.type == JSONType.null_) {
        profiles = [];
    } else if (
        request.type == JSONType.object &&
        "profiles" in request.object &&
        request["profiles"].type == JSONType.array
    ) {
        profiles = request["profiles"].array;
    } else {
        throw new Exception(format("%s deformation key must be null or contain profiles.", label));
    }

    JSONValue[] offsets;
    foreach (vertexIndex; 0 .. vertices.array.length / 2) {
        double x = readFiniteNumber(vertices.array[vertexIndex * 2], "Mesh vertex x");
        double y = readFiniteNumber(vertices.array[vertexIndex * 2 + 1], "Mesh vertex y");
        double normalizedX = (x - centerX) / halfWidth;
        double normalizedY = (y - centerY) / halfHeight;
        // D intentionally initializes floating-point locals to NaN.  These
        // accumulators must start at the additive identity because a profile
        // is allowed to affect only one axis.
        double dx = 0;
        double dy = 0;

        foreach (profileIndex, profile; profiles) {
            string profileLabel = format("%s profile[%s]", label, profileIndex);
            string profileType = requiredString(profile, "type", profileLabel);
            double amount = optionalProfileNumber(profile, "amount");
            switch (profileType) {
                case "translate":
                    dx += optionalProfileNumber(profile, "x");
                    dy += optionalProfileNumber(profile, "y");
                    break;
                case "archX":
                    dx += amount * (1 - normalizedX * normalizedX);
                    break;
                case "archY":
                    dy += amount * (1 - normalizedY * normalizedY);
                    break;
                case "shearX":
                    dx += amount * normalizedY;
                    break;
                case "shearY":
                    dy += amount * normalizedX;
                    break;
                case "tipX": {
                    double tip = (normalizedY + 1) * 0.5;
                    dx += amount * tip * tip;
                    break;
                }
                case "tipY": {
                    double tip = (normalizedY + 1) * 0.5;
                    dy += amount * tip * tip;
                    break;
                }
                case "scaleX":
                    dx += amount * (x - centerX);
                    break;
                case "scaleY":
                    dy += amount * (y - centerY);
                    break;
                case "pinchX":
                    dx += amount * normalizedX * (1 - abs(normalizedX));
                    break;
                case "pinchY":
                    dy += amount * normalizedY * (1 - abs(normalizedY));
                    break;
                default:
                    throw new Exception(format(
                        "%s uses unsupported deformation profile '%s'.",
                        profileLabel,
                        profileType
                    ));
            }
        }
        if (!isFinite(dx) || !isFinite(dy)) {
            throw new Exception(format(
                "%s produced a non-finite offset at vertex %s (%s, %s), normalized (%s, %s).",
                label,
                vertexIndex,
                x,
                y,
                normalizedX,
                normalizedY
            ));
        }
        offsets ~= numberArray([dx, dy]);
    }
    return JSONValue(offsets);
}

private JSONValue deformationBindingValues(
    JSONValue mesh,
    JSONValue values,
    size_t keyCount,
    string label
) {
    if (values.type != JSONType.array || values.array.length != keyCount) {
        throw new Exception(format("%s values must match the parameter key count.", label));
    }
    JSONValue[] result;
    foreach (index, value; values.array) {
        auto deformation = deformationForMesh(
            mesh,
            value,
            format("%s values[%s]", label, index)
        );
        result ~= JSONValue([deformation]);
    }
    return JSONValue(result);
}

/**
 * Applies a declarative, renderer-free rig specification to an INX document.
 *
 * The specification may first replace selected Part quads with regular grids,
 * then add one-dimensional parameters whose bindings target transform,
 * opacity, or per-vertex deformation properties.  Texture and extension bytes
 * remain unchanged.
 */
AgentRigSummary agentApplyRigSpec(
    string inputPath,
    string outputPath,
    JSONValue specification
) {
    if (specification.type != JSONType.object) {
        throw new Exception("Rig specification must be a JSON object.");
    }
    auto document = parseInx(cast(const(ubyte)[]) read(inputPath));
    AgentRigSummary summary;

    auto meshes = objectField(specification, "meshes", JSONValue(JSONValue[].init));
    if (meshes.type != JSONType.array) {
        throw new Exception("Rig specification meshes must be an array.");
    }
    foreach (index, meshRequest; meshes.array) {
        string label = format("Mesh request %s", index);
        string path = requiredString(meshRequest, "path", label);
        size_t columns = cast(size_t) readIndex(
            objectField(meshRequest, "columns", JSONValue(0)),
            label ~ " columns"
        );
        size_t rows = cast(size_t) readIndex(
            objectField(meshRequest, "rows", JSONValue(0)),
            label ~ " rows"
        );
        mutateUniqueNode(document.payload, path, (ref JSONValue node) {
            if (objectField(node, "type", JSONValue("")).str != "Part") {
                throw new Exception(format("Grid target '%s' is not a Part.", path));
            }
            node.object["mesh"] = buildGridMesh(
                requireMeshField(node, "mesh"),
                columns,
                rows
            );
        });
        summary.meshedPartCount++;
    }

    auto existingParameters = objectField(
        document.payload,
        "param",
        JSONValue(JSONValue[].init)
    );
    if (existingParameters.type != JSONType.array) {
        throw new Exception("INX parameters must be an array.");
    }
    auto parameters = objectField(
        specification,
        "parameters",
        JSONValue(JSONValue[].init)
    );
    if (parameters.type != JSONType.array) {
        throw new Exception("Rig specification parameters must be an array.");
    }

    ulong nextUuid = maximumUuid(document.payload["nodes"], existingParameters) + 1;
    foreach (parameterIndex, parameterRequest; parameters.array) {
        string parameterLabel = format("Parameter request %s", parameterIndex);
        string name = requiredString(parameterRequest, "name", parameterLabel);
        ptrdiff_t existingParameterIndex = -1;
        foreach (index, existingParameter; existingParameters.array) {
            if (
                existingParameter.type == JSONType.object &&
                "name" in existingParameter.object &&
                existingParameter["name"].type == JSONType.string &&
                existingParameter["name"].str == name
            ) {
                existingParameterIndex = cast(ptrdiff_t) index;
                break;
            }
        }
        double minimum = readFiniteNumber(
            objectField(parameterRequest, "min", JSONValue(0.0)),
            name ~ " min"
        );
        double maximum = readFiniteNumber(
            objectField(parameterRequest, "max", JSONValue(1.0)),
            name ~ " max"
        );
        double defaultValue = readFiniteNumber(
            objectField(parameterRequest, "default", JSONValue(0.0)),
            name ~ " default"
        );
        if (minimum >= maximum) {
            throw new Exception(format("Parameter '%s' min must be below max.", name));
        }
        if (defaultValue < minimum || defaultValue > maximum) {
            throw new Exception(format("Parameter '%s' default is outside its range.", name));
        }

        auto keysValue = objectField(parameterRequest, "keys", JSONValue.init);
        if (keysValue.type != JSONType.array || keysValue.array.length < 2) {
            throw new Exception(format("Parameter '%s' requires at least two keys.", name));
        }
        double[] keys;
        foreach (keyIndex, keyValue; keysValue.array) {
            double key = readFiniteNumber(keyValue, format("%s keys[%s]", name, keyIndex));
            if (key < minimum || key > maximum) {
                throw new Exception(format("Parameter '%s' key is outside its range.", name));
            }
            if (keys.length > 0 && key <= keys[$ - 1]) {
                throw new Exception(format("Parameter '%s' keys must be strictly increasing.", name));
            }
            keys ~= key;
        }

        double[] axisPoints;
        foreach (key; keys) axisPoints ~= (key - minimum) / (maximum - minimum);
        JSONValue[] axes = [numberArray(axisPoints), numberArray([0.0])];
        JSONValue[] bindings;
        auto bindingRequests = objectField(
            parameterRequest,
            "bindings",
            JSONValue(JSONValue[].init)
        );
        if (bindingRequests.type != JSONType.array || bindingRequests.array.length == 0) {
            throw new Exception(format("Parameter '%s' requires bindings.", name));
        }

        foreach (bindingIndex, bindingRequest; bindingRequests.array) {
            string bindingLabel = format("%s binding[%s]", name, bindingIndex);
            string path = requiredString(bindingRequest, "path", bindingLabel);
            string property = requiredString(bindingRequest, "property", bindingLabel);
            ulong nodeUuid;
            string nodeType;
            JSONValue mesh;
            inspectRigTarget(document.payload, path, nodeUuid, nodeType, mesh);

            bool isDeformation = property == "deform";
            bool isOpacity = property == "opacity";
            bool isTransform =
                property == "transform.t.x" ||
                property == "transform.t.y" ||
                property == "transform.t.z" ||
                property == "transform.r.x" ||
                property == "transform.r.y" ||
                property == "transform.r.z" ||
                property == "transform.s.x" ||
                property == "transform.s.y";
            if (!isDeformation && !isOpacity && !isTransform) {
                throw new Exception(format(
                    "%s uses unsupported property '%s'.",
                    bindingLabel,
                    property
                ));
            }
            if ((isDeformation || isOpacity) && nodeType != "Part") {
                throw new Exception(format(
                    "%s property '%s' requires a Part target.",
                    bindingLabel,
                    property
                ));
            }
            if (isOpacity) {
                mutateUniqueNode(document.payload, path, (ref JSONValue node) {
                    node.object["enabled"] = JSONValue(true);
                });
            }

            JSONValue[string] binding;
            binding["node"] = JSONValue(nodeUuid);
            binding["param_name"] = JSONValue(property);
            binding["values"] = isDeformation
                ? deformationBindingValues(
                    mesh,
                    objectField(bindingRequest, "values", JSONValue.init),
                    keys.length,
                    bindingLabel
                )
                : numericBindingValues(
                    objectField(bindingRequest, "values", JSONValue.init),
                    keys.length,
                    bindingLabel
                );
            binding["isSet"] = bindingSetFlags(keys.length);
            binding["interpolate_mode"] = JSONValue("Linear");
            bindings ~= JSONValue(binding);
            summary.bindingCount++;
        }

        JSONValue[string] parameter;
        parameter["uuid"] = existingParameterIndex >= 0
            ? existingParameters.array[existingParameterIndex]["uuid"]
            : JSONValue(nextUuid++);
        parameter["name"] = JSONValue(name);
        parameter["is_vec2"] = JSONValue(false);
        parameter["min"] = numberArray([minimum, 0.0]);
        parameter["max"] = numberArray([maximum, 1.0]);
        parameter["defaults"] = numberArray([defaultValue, 0.0]);
        parameter["axis_points"] = JSONValue(axes);
        parameter["merge_mode"] = JSONValue("Additive");
        parameter["bindings"] = JSONValue(bindings);
        if (existingParameterIndex >= 0) {
            existingParameters.array[existingParameterIndex] = JSONValue(parameter);
        } else {
            existingParameters.array ~= JSONValue(parameter);
        }
        summary.parameterCount++;
    }

    document.payload.object["param"] = existingParameters;
    write(outputPath, serializeInx(document));
    return summary;
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
