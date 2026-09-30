module creator.agentcore.modelio;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.file : read, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs, isFinite;
import creator.agentcore.automesh;

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
    size_t groupCount;
    size_t meshedPartCount;
    size_t maskCount;
    size_t parameterCount;
    size_t bindingCount;
    size_t physicsCount;
    size_t meshGroupCount;
    size_t compositeCount;
    size_t partPropertyCount;
    size_t automationCount;

    string toJson() const {
        return format(
            `{"groupCount":%s,"meshedPartCount":%s,"maskCount":%s,"parameterCount":%s,"bindingCount":%s,"physicsCount":%s,` ~
            `"meshGroupCount":%s,"compositeCount":%s,"partPropertyCount":%s,"automationCount":%s}`,
            groupCount,
            meshedPartCount,
            maskCount,
            parameterCount,
            bindingCount,
            physicsCount,
            meshGroupCount,
            compositeCount,
            partPropertyCount,
            automationCount
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

private JSONValue identityTransformJson() {
    JSONValue[string] transform;
    transform["trans"] = JSONValue([
        JSONValue(0.0),
        JSONValue(0.0),
        JSONValue(0.0)
    ]);
    transform["rot"] = JSONValue([
        JSONValue(0.0),
        JSONValue(0.0),
        JSONValue(0.0)
    ]);
    transform["scale"] = JSONValue([
        JSONValue(1.0),
        JSONValue(1.0)
    ]);
    return JSONValue(transform);
}

private JSONValue transformWithTranslation(double x, double y) {
    auto transform = identityTransformJson();
    transform.object["trans"] = JSONValue([
        JSONValue(x),
        JSONValue(y),
        JSONValue(0.0)
    ]);
    return transform;
}

private void shiftNodeTranslation(ref JSONValue node, double dx, double dy) {
    if (
        node.type != JSONType.object ||
        !("transform" in node.object) ||
        node["transform"].type != JSONType.object ||
        !("trans" in node["transform"].object) ||
        node["transform"]["trans"].type != JSONType.array ||
        node["transform"]["trans"].array.length < 2
    ) {
        throw new Exception("Rig node has no valid transform translation.");
    }
    node["transform"]["trans"].array[0] = JSONValue(
        readFiniteNumber(node["transform"]["trans"].array[0], "Node translation x") + dx
    );
    node["transform"]["trans"].array[1] = JSONValue(
        readFiniteNumber(node["transform"]["trans"].array[1], "Node translation y") + dy
    );
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

private void requireFields(JSONValue value, string[] allowed, string label) {
    import std.algorithm : canFind;
    if (value.type != JSONType.object) throw new Exception(label ~ " must be an object.");
    foreach (key, ignored; value.object) {
        if (!allowed.canFind(key)) throw new Exception(label ~ " has unknown field '" ~ key ~ "'.");
    }
}

private struct RigAxis {
    double minimum, maximum, defaultValue;
    double[] keys;
    double[] normalized;
}

private RigAxis readRigAxis(JSONValue request, string label) {
    RigAxis a;
    a.minimum = readFiniteNumber(objectField(request, "min", JSONValue(0.0)), label ~ " min");
    a.maximum = readFiniteNumber(objectField(request, "max", JSONValue(1.0)), label ~ " max");
    a.defaultValue = readFiniteNumber(objectField(request, "default", JSONValue(0.0)), label ~ " default");
    if (a.minimum >= a.maximum || a.defaultValue < a.minimum || a.defaultValue > a.maximum)
        throw new Exception(label ~ " has invalid range or default.");
    auto values = objectField(request, "keys", JSONValue.init);
    if (values.type != JSONType.array || values.array.length < 2)
        throw new Exception(label ~ " requires at least two keys.");
    foreach (v; values.array) {
        double key = readFiniteNumber(v, label ~ " key");
        if (key < a.minimum || key > a.maximum || (a.keys.length && key <= a.keys[$-1]))
            throw new Exception(label ~ " keys must increase within the range.");
        double normalized = (key - a.minimum) / (a.maximum - a.minimum);
        if (!isFinite(cast(float)normalized) || (a.normalized.length &&
            cast(float)normalized <= cast(float)a.normalized[$-1]))
            throw new Exception(label ~ " keys collapse at SDK float precision.");
        a.keys ~= key;
        a.normalized ~= normalized;
    }
    // SDK interpolation needs end points, including for nonuniform axes.
    if (a.keys[0] != a.minimum || a.keys[$-1] != a.maximum)
        throw new Exception(label ~ " keys must cover both range endpoints.");
    return a;
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

    if (!isFinite(result) || !isFinite(cast(float)result)) {
        throw new Exception(format("%s must be finite and fit the SDK float range.", label));
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
    requireFields(requested, ["verts", "uvs", "indices", "origin", "grid_axes"], "Mesh");

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

/** Resample every deformation key in UV space, including both parameter axes.
 * New UVs must lie in the old triangulation. Textures, parameter identities,
 * interpolation modes, non-deform bindings and extension bytes are retained.
 */
AgentMeshSummary agentRetopologizePartByPsdPath(
    string inputPath, string outputPath, string path, JSONValue requestedMesh
) {
    auto document = parseInx(cast(const(ubyte)[])read(inputPath));
    ulong uuid = requirePartUuidByPsdPath(document.payload, path);
    auto tree = document.payload["nodes"];
    JSONValue oldMesh;
    if (!findPartMesh(tree, uuid, oldMesh)) throw new Exception("Retopology Part not found.");
    size_t vertexCount, triangleCount;
    JSONValue mesh;
    if (requestedMesh.type == JSONType.object && "auto" in requestedMesh.object) {
        requireFields(requestedMesh, ["auto"], "Retopology request");
        JSONValue partNode;
        mutateUniqueNode(document.payload, path, (ref JSONValue node) { partNode = node; });
        mesh = normalizeMesh(autoMeshForPart(document, partNode, requestedMesh["auto"], "Retopology request"),
            vertexCount, triangleCount);
    } else mesh = normalizeMesh(requestedMesh, vertexCount, triangleCount);
    auto oldUV = requireMeshField(oldMesh, "uvs");
    auto newUV = requireMeshField(mesh, "uvs");
    auto oldCount = meshVertexCount(oldMesh, "Source mesh");
    validateNumericArray(oldUV, oldCount * 2, "Source UVs");
    validateNumericArray(newUV, vertexCount * 2, "Destination UVs");
    auto indices = requireMeshField(oldMesh, "indices");
    if (indices.type != JSONType.array || indices.array.length % 3 != 0)
        throw new Exception("Source mesh must contain complete triangles.");
    struct Transfer { size_t[3] vertices; double[3] weights; }
    Transfer[] transfers;
    foreach (v; 0 .. vertexCount) {
        double u = readFiniteNumber(newUV[v*2], "u");
        double w = readFiniteNumber(newUV[v*2+1], "v");
        bool found;
        Transfer transfer;
        foreach (t; 0 .. indices.array.length / 3) {
            size_t[3] ids;
            double[3] xs, ys;
            foreach (i; 0 .. 3) {
                ids[i] = cast(size_t)readIndex(indices[t*3+i], "Source index");
                if (ids[i] >= oldCount) throw new Exception("Source index is out of range.");
                xs[i] = readFiniteNumber(oldUV[ids[i]*2], "Source u");
                ys[i] = readFiniteNumber(oldUV[ids[i]*2+1], "Source v");
            }
            double determinant = (ys[1]-ys[2])*(xs[0]-xs[2]) + (xs[2]-xs[1])*(ys[0]-ys[2]);
            if (abs(determinant) < 1e-12) continue;
            double a = ((ys[1]-ys[2])*(u-xs[2]) + (xs[2]-xs[1])*(w-ys[2])) / determinant;
            double b = ((ys[2]-ys[0])*(u-xs[2]) + (xs[0]-xs[2])*(w-ys[2])) / determinant;
            double c = 1 - a - b;
            if (a < -1e-7 || b < -1e-7 || c < -1e-7) continue;
            if (found) {
                // Shared edges are safe only when both triangles describe the
                // same weighted source vertices. Disconnected UV islands can
                // disagree even at corners, where no weight is strictly interior.
                double[size_t] difference;
                double[3] weights = [a,b,c];
                foreach (i; 0 .. 3) {
                    difference[transfer.vertices[i]] = difference.get(transfer.vertices[i], 0.0) + transfer.weights[i];
                    difference[ids[i]] = difference.get(ids[i], 0.0) - weights[i];
                }
                foreach (delta; difference) if (abs(delta) > 1e-6)
                    throw new Exception("Overlapping source UV triangles make retopology ambiguous.");
            }
            if (!found) { transfer = Transfer(ids, [a,b,c]); found = true; }
        }
        if (!found) throw new Exception(format("Destination vertex %s is outside source UV coverage.", v));
        transfers ~= transfer;
    }
    auto parameters = objectField(document.payload, "param", JSONValue.emptyArray);
    foreach (ref parameter; parameters.array) {
        if (!("bindings" in parameter.object)) continue;
        foreach (ref binding; parameter["bindings"].array) {
            if (binding["param_name"].str != "deform" || readIndex(binding["node"], "Binding node") != uuid) continue;
            foreach (ref column; binding["values"].array) foreach (ref cell; column.array) {
                if (cell.type != JSONType.array || cell.array.length != oldCount)
                    throw new Exception("Existing deformation key does not match source topology.");
                foreach (pair; cell.array) validateNumericArray(pair, 2, "Existing vertex offset");
                JSONValue[] offsets;
                foreach (tr; transfers) {
                    double dx = 0, dy = 0;
                    foreach (i; 0 .. 3) {
                        dx += tr.weights[i] * readFiniteNumber(cell[tr.vertices[i]][0], "Offset x");
                        dy += tr.weights[i] * readFiniteNumber(cell[tr.vertices[i]][1], "Offset y");
                    }
                    offsets ~= numberArray([dx,dy]);
                }
                cell = JSONValue(offsets);
            }
        }
    }
    document.payload.object["param"] = parameters;
    if (!replacePartMesh(tree, uuid, mesh)) throw new Exception("Retopology target disappeared.");
    document.payload.object["nodes"] = tree;
    write(outputPath, serializeInx(document));
    return AgentMeshSummary(uuid, vertexCount, triangleCount);
}

/** Rename an explicitly selected non-root node without changing PSD provenance,
 * UUIDs, texture bytes, geometry or parameter binding identities. */
JSONValue agentRenameNode(string inputPath, string outputPath, ulong uuid, string name) {
    import std.string : indexOf;
    if (!name.length || name == "Root" || name == "." || name == ".." || name.indexOf('/') >= 0)
        throw new Exception("Node name must be a nonempty path segment other than Root, . or ..");
    auto document = parseInx(cast(const(ubyte)[])read(inputPath));
    size_t matches;
    void visit(ref JSONValue parent) {
        if (!("children" in parent.object)) return;
        auto children = parent["children"].array;
        foreach (ref child; children) {
            if (readIndex(child["uuid"], "Node uuid") == uuid) {
                foreach (sibling; children)
                    if (readIndex(sibling["uuid"], "Sibling uuid") != uuid && sibling["name"].str == name)
                        throw new Exception("Node name already exists among siblings.");
                child["name"] = JSONValue(name);
                matches++;
            }
            visit(child);
        }
        parent["children"] = JSONValue(children);
    }
    visit(document.payload["nodes"]);
    if (matches != 1) throw new Exception("Node UUID must select exactly one non-root node.");
    write(outputPath, serializeInx(document));
    return JSONValue(["uuid": JSONValue(uuid), "name": JSONValue(name)]);
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

private string childNodePath(string parentPath, JSONValue child) {
    if (
        child.type == JSONType.object &&
        "name" in child.object &&
        child["name"].type == JSONType.string &&
        child["name"].str != "Root"
    ) {
        return parentPath ~ "/" ~ child["name"].str;
    }
    return parentPath;
}

/**
 * Removes one uniquely addressed node from a node tree while preserving the
 * stable PSD path stored on Parts.  Grouping is intentionally an identity
 * operation: it changes only the parent/child relationship, never a Part's
 * transform, mesh, texture, z-order, or pixels.
 */
private size_t extractNodeByPath(
    ref JSONValue parent,
    string parentPath,
    string requestedPath,
    out JSONValue extracted,
    double shiftX = 0,
    double shiftY = 0
) {
    if (
        parent.type != JSONType.object ||
        !("children" in parent.object) ||
        parent["children"].type != JSONType.array
    ) {
        return 0;
    }

    JSONValue[] remaining;
    size_t matches;
    foreach (child; parent["children"].array) {
        auto path = childNodePath(parentPath, child);
        bool pathMatches = path == requestedPath;
        if (
            child.type == JSONType.object &&
            "psdLayerPath" in child.object &&
            child["psdLayerPath"].type == JSONType.string &&
            child["psdLayerPath"].str == requestedPath
        ) {
            pathMatches = true;
        }

        if (pathMatches) {
            matches++;
            extracted = child;
            shiftNodeTranslation(extracted, shiftX, shiftY);
            continue;
        }

        auto nestedPath = path;
        JSONValue nested;
        auto nestedMatches = extractNodeByPath(
            child,
            nestedPath,
            requestedPath,
            nested,
            shiftX,
            shiftY
        );
        matches += nestedMatches;
        if (nestedMatches > 0) {
            extracted = nested;
        }
        remaining ~= child;
    }
    parent.object["children"] = JSONValue(remaining);
    return matches;
}

private JSONValue buildAgentGroup(
    ulong uuid,
    string name,
    JSONValue[] children,
    double zsort,
    double pivotX,
    double pivotY
) {
    JSONValue[string] group;
    group["uuid"] = JSONValue(uuid);
    group["name"] = JSONValue(name);
    group["type"] = JSONValue("Node");
    group["enabled"] = JSONValue(true);
    group["zsort"] = JSONValue(zsort);
    group["transform"] = transformWithTranslation(pivotX, pivotY);
    group["lockToRoot"] = JSONValue(false);
    group["children"] = JSONValue(children);
    return JSONValue(group);
}

private JSONValue buildSimplePhysicsNode(
    ulong uuid,
    string name,
    ulong parameterUuid,
    string modelType,
    string mapMode,
    double gravity,
    double length,
    double frequency,
    double angleDamping,
    double lengthDamping,
    double outputScaleX,
    double outputScaleY,
    bool localOnly
) {
    JSONValue[string] node;
    node["uuid"] = JSONValue(uuid);
    node["name"] = JSONValue(name);
    node["type"] = JSONValue("SimplePhysics");
    node["enabled"] = JSONValue(true);
    node["zsort"] = JSONValue(0.0);
    node["transform"] = identityTransformJson();
    node["lockToRoot"] = JSONValue(false);
    node["children"] = JSONValue(JSONValue[].init);
    node["param"] = JSONValue(parameterUuid);
    node["model_type"] = JSONValue(modelType);
    node["map_mode"] = JSONValue(mapMode);
    node["gravity"] = JSONValue(gravity);
    node["length"] = JSONValue(length);
    node["frequency"] = JSONValue(frequency);
    node["angle_damping"] = JSONValue(angleDamping);
    node["length_damping"] = JSONValue(lengthDamping);
    node["output_scale"] = JSONValue([
        JSONValue(outputScaleX),
        JSONValue(outputScaleY)
    ]);
    node["local_only"] = JSONValue(localOnly);
    return JSONValue(node);
}

private ulong findParameterUuid(JSONValue parameters, string name) {
    foreach (parameterIndex, parameter; parameters.array) {
        if (
            parameter.type == JSONType.object &&
            "name" in parameter.object &&
            parameter["name"].type == JSONType.string &&
            parameter["name"].str == name
        ) {
            if (!("uuid" in parameter.object)) {
                throw new Exception(format(
                    "Parameter '%s' has no uuid.",
                    name
                ));
            }
            return readIndex(
                parameter["uuid"],
                format("Parameter '%s' uuid", name)
            );
        }
    }
    throw new Exception(format("Could not find parameter '%s'.", name));
}

private void appendNodeToPath(
    ref JSONValue payload,
    string parentPath,
    JSONValue child
) {
    mutateUniqueNode(payload, parentPath, (ref JSONValue parent) {
        if (!("children" in parent.object)) {
            parent.object["children"] = JSONValue(JSONValue[].init);
        }
        if (parent["children"].type != JSONType.array) {
            throw new Exception(format(
                "Node '%s' children must be an array.",
                parentPath
            ));
        }
        parent["children"].array ~= child;
    });
}

private void applyRigPhysics(
    ref JSONValue payload,
    JSONValue physics,
    JSONValue parameters,
    ref AgentRigSummary summary,
    ref ulong nextUuid
) {
    if (physics.type != JSONType.array) {
        throw new Exception("Rig specification physics must be an array.");
    }

    foreach (physicsIndex, physicsRequest; physics.array) {
        string label = format("Physics request %s", physicsIndex);
        requireFields(physicsRequest, ["name", "parent", "parameter", "model_type", "map_mode",
            "output_scale", "gravity", "length", "frequency", "angle_damping", "length_damping", "local_only"], label);
        string name = requiredString(physicsRequest, "name", label);
        string parentPath = requiredString(physicsRequest, "parent", label);
        string parameterName = requiredString(physicsRequest, "parameter", label);
        string modelType = requiredString(physicsRequest, "model_type", label);
        string mapMode = requiredString(physicsRequest, "map_mode", label);
        foreach (field; ["length", "frequency", "angle_damping", "length_damping"]) {
            if (!(field in physicsRequest.object)) continue;
            double value = readFiniteNumber(physicsRequest[field], label ~ " " ~ field);
            if ((field == "length" || field == "frequency") ? value <= 0 : (value < 0 || value > 1))
                throw new Exception(label ~ " invalid " ~ field ~ " (length/frequency > 0; damping in [0,1]).");
        }
        if ("local_only" in physicsRequest.object && physicsRequest["local_only"].type != JSONType.true_ &&
            physicsRequest["local_only"].type != JSONType.false_)
            throw new Exception(label ~ " local_only must be boolean.");
        if (modelType == "pendulum") modelType = "Pendulum";
        if (modelType == "spring_pendulum") modelType = "SpringPendulum";
        if (mapMode == "angle_length") mapMode = "AngleLength";
        if (mapMode == "xy") mapMode = "XY";
        if (mapMode == "length_angle") mapMode = "LengthAngle";
        if (mapMode == "yx") mapMode = "YX";
        if (
            modelType != "Pendulum" &&
            modelType != "SpringPendulum"
        ) {
            throw new Exception(format(
                "%s model_type must be pendulum or spring_pendulum.",
                label
            ));
        }
        if (
            mapMode != "AngleLength" &&
            mapMode != "XY" &&
            mapMode != "LengthAngle" &&
            mapMode != "YX"
        ) {
            throw new Exception(format(
                "%s map_mode is unsupported.",
                label
            ));
        }

        auto parameterUuid = findParameterUuid(parameters, parameterName);
        double outputScaleX;
        double outputScaleY;
        auto outputScale = objectField(
            physicsRequest,
            "output_scale",
            JSONValue([JSONValue(1.0), JSONValue(1.0)])
        );
        if (
            outputScale.type != JSONType.array ||
            outputScale.array.length != 2
        ) {
            throw new Exception(format(
                "%s output_scale must contain [x,y].",
                label
            ));
        }
        outputScaleX = readFiniteNumber(
            outputScale.array[0],
            label ~ " output_scale x"
        );
        outputScaleY = readFiniteNumber(
            outputScale.array[1],
            label ~ " output_scale y"
        );

        auto driver = buildSimplePhysicsNode(
            nextUuid++,
            name,
            parameterUuid,
            modelType,
            mapMode,
            readFiniteNumber(
                objectField(physicsRequest, "gravity", JSONValue(1.0)),
                label ~ " gravity"
            ),
            readFiniteNumber(
                objectField(physicsRequest, "length", JSONValue(100.0)),
                label ~ " length"
            ),
            readFiniteNumber(
                objectField(physicsRequest, "frequency", JSONValue(1.0)),
                label ~ " frequency"
            ),
            readFiniteNumber(
                objectField(physicsRequest, "angle_damping", JSONValue(0.5)),
                label ~ " angle_damping"
            ),
            readFiniteNumber(
                objectField(physicsRequest, "length_damping", JSONValue(0.5)),
                label ~ " length_damping"
            ),
            outputScaleX,
            outputScaleY,
            objectField(
                physicsRequest,
                "local_only",
                JSONValue(false)
            ).type == JSONType.true_
        );
        appendNodeToPath(payload, parentPath, driver);
        summary.physicsCount++;
    }
}

enum string[] agentBlendModes = ["Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten",
    "ColorDodge", "LinearDodge", "AddGlow", "ColorBurn", "HardLight", "SoftLight", "Difference",
    "Exclusion", "Subtract", "Inverse", "DestinationIn", "ClipToLower", "SliceFromLower"];

private string readBlendMode(JSONValue value, string label) {
    import std.algorithm : canFind;
    if (value.type != JSONType.string || !agentBlendModes.canFind(value.str))
        throw new Exception(label ~ " blend_mode must be one of " ~ format("%-(%s, %)", agentBlendModes) ~ ".");
    return value.str;
}

private JSONValue readColor(JSONValue value, string label) {
    if (value.type != JSONType.array || value.array.length != 3)
        throw new Exception(label ~ " must contain [r,g,b].");
    double[] color;
    foreach (i, channel; value.array) {
        double v = readFiniteNumber(channel, format("%s[%s]", label, i));
        if (v < 0 || v > 1) throw new Exception(label ~ " channels must be in [0,1].");
        color ~= v;
    }
    return numberArray(color);
}

private double readUnit(JSONValue value, string label) {
    double v = readFiniteNumber(value, label);
    if (v < 0 || v > 1) throw new Exception(label ~ " must be in [0,1].");
    return v;
}

private bool subtreeHasType(JSONValue node, string type) {
    if (node.type != JSONType.object) return false;
    if (objectField(node, "type", JSONValue("")).str == type) return true;
    foreach (child; objectField(node, "children", JSONValue.emptyArray).array)
        if (subtreeHasType(child, type)) return true;
    return false;
}

// Rest-pose bounds of every Drawable in a subtree, in the coordinate space
// of the subtree's parent. Only translations are supported here; rotated or
// scaled intermediate nodes need an explicit MeshGroup mesh.
private void collectDrawableBounds(JSONValue node, double ox, double oy, ref double[4] bounds, string label) {
    auto transform = objectField(node, "transform", identityTransformJson());
    auto trans = objectField(transform, "trans", numberArray([0.0, 0.0, 0.0]));
    auto rot = objectField(transform, "rot", numberArray([0.0, 0.0, 0.0]));
    auto scale = objectField(transform, "scale", numberArray([1.0, 1.0]));
    foreach (i, v; rot.array) if (readFiniteNumber(v, label ~ " rotation") != 0)
        throw new Exception(label ~ " contains a rotated node; provide an explicit MeshGroup mesh.");
    foreach (i, v; scale.array) if (readFiniteNumber(v, label ~ " scale") != 1)
        throw new Exception(label ~ " contains a scaled node; provide an explicit MeshGroup mesh.");
    double x = ox + readFiniteNumber(trans.array[0], label ~ " translation x");
    double y = oy + readFiniteNumber(trans.array[1], label ~ " translation y");
    if ("mesh" in node.object) {
        auto verts = requireMeshField(node["mesh"], "verts");
        auto origin = objectField(node["mesh"], "origin", numberArray([0.0, 0.0]));
        double originX = readFiniteNumber(origin.array[0], label ~ " origin x");
        double originY = readFiniteNumber(origin.array[1], label ~ " origin y");
        foreach (i; 0 .. verts.array.length / 2) {
            double vx = x + readFiniteNumber(verts.array[i * 2], label ~ " vertex x") - originX;
            double vy = y + readFiniteNumber(verts.array[i * 2 + 1], label ~ " vertex y") - originY;
            if (vx < bounds[0]) bounds[0] = vx;
            if (vy < bounds[1]) bounds[1] = vy;
            if (vx > bounds[2]) bounds[2] = vx;
            if (vy > bounds[3]) bounds[3] = vy;
        }
    }
    foreach (child; objectField(node, "children", JSONValue.emptyArray).array)
        collectDrawableBounds(child, x, y, bounds, label);
}

private JSONValue boundsMesh(double minX, double minY, double maxX, double maxY) {
    JSONValue[string] mesh;
    mesh["verts"] = numberArray([minX, minY, minX, maxY, maxX, minY, maxX, maxY]);
    mesh["uvs"] = numberArray([0.0, 0.0, 0.0, 1.0, 1.0, 0.0, 1.0, 1.0]);
    mesh["indices"] = indexArray([0UL, 1, 2, 2, 1, 3]);
    mesh["origin"] = numberArray([0.0, 0.0]);
    return JSONValue(mesh);
}

private void applyRigGroups(
    ref JSONValue payload,
    JSONValue groups,
    ref AgentRigSummary summary,
    ref ulong nextUuid
) {
    import std.algorithm : canFind;
    if (groups.type != JSONType.array) {
        throw new Exception("Rig specification groups must be an array.");
    }

    foreach (groupIndex, groupRequest; groups.array) {
        string label = format("Group request %s", groupIndex);
        requireFields(groupRequest, ["name", "paths", "pivot", "zsort", "type", "mesh", "columns", "rows",
            "margin", "dynamic", "blend_mode", "opacity", "tint", "screen_tint", "propagate_meshgroup"], label);
        string name = requiredString(groupRequest, "name", label);
        string type = "type" in groupRequest.object ? requiredString(groupRequest, "type", label) : "Node";
        if (type != "Node" && type != "MeshGroup" && type != "Composite")
            throw new Exception(label ~ " type must be Node, MeshGroup or Composite.");
        string[] allowed = ["name", "paths", "pivot", "zsort", "type"];
        if (type == "MeshGroup") allowed ~= ["mesh", "columns", "rows", "margin", "dynamic"];
        if (type == "Composite") allowed ~= ["blend_mode", "opacity", "tint", "screen_tint", "propagate_meshgroup"];
        foreach (key, ignored; groupRequest.object)
            if (!allowed.canFind(key)) throw new Exception(label ~ " field '" ~ key ~ "' does not apply to type " ~ type ~ ".");
        auto paths = objectField(groupRequest, "paths", JSONValue(JSONValue[].init));
        if (paths.type != JSONType.array || paths.array.length == 0) {
            throw new Exception(format("%s requires a non-empty paths array.", label));
        }
        double zsort = readFiniteNumber(
            objectField(groupRequest, "zsort", JSONValue(0.0)),
            label ~ " zsort"
        );
        double pivotX;
        double pivotY;
        auto pivotValue = objectField(
            groupRequest,
            "pivot",
            JSONValue([JSONValue(0.0), JSONValue(0.0)])
        );
        if (
            pivotValue.type != JSONType.array ||
            pivotValue.array.length != 2
        ) {
            throw new Exception(format("%s pivot must contain [x,y].", label));
        }
        pivotX = readFiniteNumber(pivotValue.array[0], label ~ " pivot x");
        pivotY = readFiniteNumber(pivotValue.array[1], label ~ " pivot y");

        JSONValue[] children;
        foreach (pathIndex, pathValue; paths.array) {
            if (pathValue.type != JSONType.string || pathValue.str.length == 0) {
                throw new Exception(format(
                    "%s paths[%s] must be a non-empty string.",
                    label,
                    pathIndex
                ));
            }
            string path = pathValue.str;
            JSONValue extracted;
            auto matches = extractNodeByPath(
                payload["nodes"],
                "",
                path,
                extracted,
                -pivotX,
                -pivotY
            );
            if (matches == 0) {
                throw new Exception(format("Could not find group path '%s'.", path));
            }
            if (matches > 1) {
                throw new Exception(format("Group path '%s' is ambiguous.", path));
            }
            children ~= extracted;
        }

        auto groupNode = buildAgentGroup(
            nextUuid++,
            name,
            children,
            zsort,
            pivotX,
            pivotY
        );
        if (type == "MeshGroup") {
            bool custom = ("mesh" in groupRequest.object) !is null;
            if (custom && ("columns" in groupRequest.object || "rows" in groupRequest.object || "margin" in groupRequest.object))
                throw new Exception(label ~ " cannot combine a custom mesh with grid fields.");
            JSONValue mesh;
            if (custom) {
                size_t vertexCount, triangleCount;
                mesh = normalizeMesh(groupRequest["mesh"], vertexCount, triangleCount);
            } else {
                double[4] bounds = [double.infinity, double.infinity, -double.infinity, -double.infinity];
                foreach (child; children) collectDrawableBounds(child, 0, 0, bounds, label);
                if (!(bounds[0] < bounds[2]) || !(bounds[1] < bounds[3]))
                    throw new Exception(label ~ " children have no drawable area; provide an explicit mesh.");
                double margin = readFiniteNumber(objectField(groupRequest, "margin", JSONValue(8.0)), label ~ " margin");
                if (margin < 0) throw new Exception(label ~ " margin must not be negative.");
                auto columns = cast(size_t)readIndex(objectField(groupRequest, "columns", JSONValue(5)), label ~ " columns");
                auto rows = cast(size_t)readIndex(objectField(groupRequest, "rows", JSONValue(5)), label ~ " rows");
                mesh = buildGridMesh(boundsMesh(bounds[0] - margin, bounds[1] - margin,
                    bounds[2] + margin, bounds[3] + margin), columns, rows);
            }
            auto dynamic = objectField(groupRequest, "dynamic", JSONValue(false));
            if (dynamic.type != JSONType.true_ && dynamic.type != JSONType.false_)
                throw new Exception(label ~ " dynamic must be boolean.");
            groupNode.object["type"] = JSONValue("MeshGroup");
            groupNode.object["mesh"] = mesh;
            groupNode.object["dynamic_deformation"] = dynamic;
            groupNode.object["translate_children"] = JSONValue(true);
            summary.meshGroupCount++;
        } else if (type == "Composite") {
            foreach (child; children) if (subtreeHasType(child, "Composite"))
                throw new Exception(label ~ " cannot contain another Composite; the SDK flattens nested composites.");
            groupNode.object["type"] = JSONValue("Composite");
            groupNode.object["blend_mode"] = JSONValue("blend_mode" in groupRequest.object
                ? readBlendMode(groupRequest["blend_mode"], label) : "Normal");
            groupNode.object["opacity"] = JSONValue("opacity" in groupRequest.object
                ? readUnit(groupRequest["opacity"], label ~ " opacity") : 1.0);
            groupNode.object["tint"] = "tint" in groupRequest.object
                ? readColor(groupRequest["tint"], label ~ " tint") : numberArray([1.0, 1.0, 1.0]);
            groupNode.object["screenTint"] = "screen_tint" in groupRequest.object
                ? readColor(groupRequest["screen_tint"], label ~ " screen_tint") : numberArray([0.0, 0.0, 0.0]);
            groupNode.object["mask_threshold"] = JSONValue(0.5);
            auto propagate = objectField(groupRequest, "propagate_meshgroup", JSONValue(true));
            if (propagate.type != JSONType.true_ && propagate.type != JSONType.false_)
                throw new Exception(label ~ " propagate_meshgroup must be boolean.");
            groupNode.object["propagate_meshgroup"] = propagate;
            summary.compositeCount++;
        }
        payload["nodes"].object["children"].array ~= groupNode;
        summary.groupCount++;
    }
}

// Static appearance of existing Parts and Composites. Parameter bindings
// multiply tint and add screen tint on top of these values at runtime.
private void applyRigParts(ref JSONValue payload, JSONValue parts, ref AgentRigSummary summary) {
    if (parts.type != JSONType.array) throw new Exception("Rig specification parts must be an array.");
    foreach (index, request; parts.array) {
        string label = format("Part request %s", index);
        requireFields(request, ["path", "blend_mode", "opacity", "tint", "screen_tint"], label);
        string path = requiredString(request, "path", label);
        if (request.object.length < 2) throw new Exception(label ~ " sets no property.");
        mutateUniqueNode(payload, path, (ref JSONValue node) {
            string type = objectField(node, "type", JSONValue("")).str;
            if (type != "Part" && type != "Composite")
                throw new Exception(format("%s target '%s' is not a Part or Composite.", label, path));
            if ("blend_mode" in request.object) node.object["blend_mode"] = JSONValue(readBlendMode(request["blend_mode"], label));
            if ("opacity" in request.object) node.object["opacity"] = JSONValue(readUnit(request["opacity"], label ~ " opacity"));
            if ("tint" in request.object) node.object["tint"] = readColor(request["tint"], label ~ " tint");
            if ("screen_tint" in request.object) node.object["screenTint"] = readColor(request["screen_tint"], label ~ " screen_tint");
        });
        summary.partPropertyCount++;
    }
}

// Sine automation drives parameters over time in the runtime (breathing,
// idle sway). Waves are added to the tracked value with the parameter's
// Additive merge mode.
private void applyRigAutomation(ref JSONValue payload, JSONValue automation, ref AgentRigSummary summary) {
    if (automation.type != JSONType.array) throw new Exception("Rig specification automation must be an array.");
    auto parameters = objectField(payload, "param", JSONValue.emptyArray);
    auto existing = objectField(payload, "automation", JSONValue(JSONValue[].init));
    if (existing.type != JSONType.array) throw new Exception("INX automation must be an array.");
    bool[string] names;
    foreach (index, request; automation.array) {
        string label = format("Automation request %s", index);
        requireFields(request, ["name", "type", "speed", "wave", "bindings"], label);
        string name = requiredString(request, "name", label);
        if (name in names) throw new Exception("Duplicate automation '" ~ name ~ "'.");
        names[name] = true;
        string type = "type" in request.object ? requiredString(request, "type", label) : "sine";
        if (type != "sine") throw new Exception(label ~ " type must be sine.");
        double speed = readFiniteNumber(objectField(request, "speed", JSONValue(1.0)), label ~ " speed");
        if (speed <= 0) throw new Exception(label ~ " speed must be positive.");
        string wave = "wave" in request.object ? requiredString(request, "wave", label) : "sin";
        if (wave != "sin" && wave != "cos") throw new Exception(label ~ " wave must be sin or cos.");
        auto bindings = objectField(request, "bindings", JSONValue.init);
        if (bindings.type != JSONType.array || bindings.array.length == 0)
            throw new Exception(label ~ " requires bindings.");
        JSONValue[] written;
        bool[string] targets;
        foreach (bindingIndex, binding; bindings.array) {
            string bindingLabel = format("%s binding[%s]", label, bindingIndex);
            requireFields(binding, ["parameter", "axis", "range"], bindingLabel);
            string parameterName = requiredString(binding, "parameter", bindingLabel);
            auto axis = readIndex(objectField(binding, "axis", JSONValue(0)), bindingLabel ~ " axis");
            JSONValue parameter;
            bool found;
            foreach (candidate; parameters.array)
                if (candidate["name"].str == parameterName) { parameter = candidate; found = true; }
            if (!found) throw new Exception(bindingLabel ~ " references unknown parameter '" ~ parameterName ~ "'.");
            bool isVec2 = objectField(parameter, "is_vec2", JSONValue(false)).type == JSONType.true_;
            if (axis > (isVec2 ? 1 : 0)) throw new Exception(bindingLabel ~ " axis is out of range for " ~ parameterName ~ ".");
            string identity = format("%s#%s", parameterName, axis);
            if (identity in targets) throw new Exception(bindingLabel ~ " duplicates a parameter axis.");
            targets[identity] = true;
            auto range = objectField(binding, "range", JSONValue.init);
            if (range.type != JSONType.array || range.array.length != 2)
                throw new Exception(bindingLabel ~ " range must contain [from,to].");
            double from = readFiniteNumber(range.array[0], bindingLabel ~ " range[0]");
            double to = readFiniteNumber(range.array[1], bindingLabel ~ " range[1]");
            double lo = readFiniteNumber(parameter["min"].array[axis], "Parameter min");
            double hi = readFiniteNumber(parameter["max"].array[axis], "Parameter max");
            if (from < lo || from > hi || to < lo || to > hi)
                throw new Exception(bindingLabel ~ " range must lie within the parameter range.");
            JSONValue[string] entry;
            entry["param"] = JSONValue(parameterName);
            entry["axis"] = JSONValue(axis);
            entry["range"] = numberArray([from, to]);
            written ~= JSONValue(entry);
        }
        JSONValue[string] node;
        node["type"] = JSONValue("sine");
        node["name"] = JSONValue(name);
        node["bindings"] = JSONValue(written);
        node["speed"] = JSONValue(speed);
        // The SDK reads the enum by name (it cannot read back its own integer form).
        node["sine_type"] = JSONValue(wave == "sin" ? "Sin" : "Cos");
        JSONValue[] kept;
        foreach (entry; existing.array)
            if (objectField(entry, "name", JSONValue("")).str != name) kept ~= entry;
        kept ~= JSONValue(node);
        existing = JSONValue(kept);
        summary.automationCount++;
    }
    payload.object["automation"] = existing;
}

private JSONValue buildGridMesh(JSONValue existingMesh, size_t columns, size_t rows) {
    if (columns < 2 || rows < 2) {
        throw new Exception("Grid mesh columns and rows must both be at least two.");
    }
    if (columns > ushort.max + 1 || rows > (ushort.max + 1) / columns) {
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

private void applyRigMasks(
    ref JSONValue payload,
    JSONValue masks,
    ref AgentRigSummary summary
) {
    if (masks.type != JSONType.array) {
        throw new Exception("Rig specification masks must be an array.");
    }

    foreach (maskIndex, maskRequest; masks.array) {
        string label = format("Mask request %s", maskIndex);
        requireFields(maskRequest, ["target", "source", "mode"], label);
        string targetPath = requiredString(maskRequest, "target", label);
        string sourcePath = requiredString(maskRequest, "source", label);
        string mode = requiredString(maskRequest, "mode", label);
        if (mode == "mask") mode = "Mask";
        if (mode == "dodge_mask" || mode == "dodge") mode = "DodgeMask";
        if (mode != "Mask" && mode != "DodgeMask") {
            throw new Exception(format(
                "%s mode must be mask or dodge_mask.",
                label
            ));
        }

        ulong sourceUuid;
        string sourceType;
        JSONValue sourceMesh;
        inspectRigTarget(
            payload,
            sourcePath,
            sourceUuid,
            sourceType,
            sourceMesh
        );
        if (sourceType != "Part") {
            throw new Exception(format(
                "%s source '%s' is not a Part.",
                label,
                sourcePath
            ));
        }

        mutateUniqueNode(payload, targetPath, (ref JSONValue target) {
            if (objectField(target, "type", JSONValue("")).str != "Part") {
                throw new Exception(format(
                    "%s target '%s' is not a Part.",
                    label,
                    targetPath
                ));
            }
            auto targetUuid = readIndex(
                objectField(target, "uuid", JSONValue(0)),
                format("%s target uuid", label)
            );
            if (targetUuid == sourceUuid) {
                throw new Exception(format(
                    "%s cannot mask a Part with itself.",
                    label
                ));
            }

            auto existingMasks = objectField(
                target,
                "masks",
                JSONValue(JSONValue[].init)
            );
            if (existingMasks.type != JSONType.array) {
                throw new Exception(format(
                    "%s target masks must be an array.",
                    label
                ));
            }

            foreach (existing; existingMasks.array) {
                if (
                    existing.type == JSONType.object &&
                    "source" in existing.object &&
                    "mode" in existing.object &&
                    readIndex(existing["source"], label ~ " existing source") == sourceUuid &&
                    existing["mode"].type == JSONType.string &&
                    existing["mode"].str == mode
                ) {
                    return;
                }
            }

            JSONValue[string] binding;
            binding["source"] = JSONValue(sourceUuid);
            binding["mode"] = JSONValue(mode);
            existingMasks.array ~= JSONValue(binding);
            target.object["masks"] = existingMasks;
            summary.maskCount++;
        });
    }
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

private double profileNumberOr(JSONValue profile, string key, double fallback) {
    if (!(key in profile.object)) return fallback;
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

    if (request.type == JSONType.object && "offsets" in request.object) {
        requireFields(request, ["offsets"], label);
        auto values = request["offsets"];
        if (values.type != JSONType.array || values.array.length != vertices.array.length / 2)
            throw new Exception(label ~ " offsets must match mesh vertex count.");
        foreach (index, pair; values.array) validateNumericArray(pair, 2, format("%s offsets[%s]", label, index));
        return values;
    }
    if (request.type != JSONType.null_) requireFields(request, ["profiles"], label);

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
            requireFields(profile, ["type", "amount", "x", "y", "widthScale", "thicknessScale",
                "offsetY", "curvatureY", "slopeY", "anchorLeft", "anchorRight"], profileLabel);
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
                case "curveMorph": {
                    double widthScale = profileNumberOr(profile, "widthScale", 1);
                    double thicknessScale = profileNumberOr(
                        profile,
                        "thicknessScale",
                        1
                    );
                    double offsetY = optionalProfileNumber(profile, "offsetY");
                    double curvatureY = optionalProfileNumber(profile, "curvatureY");
                    double slopeY = optionalProfileNumber(profile, "slopeY");
                    double targetX = centerX + normalizedX * halfWidth * widthScale;
                    double targetCurveY = centerY + offsetY +
                        curvatureY * (1 - normalizedX * normalizedX) +
                        slopeY * normalizedX;
                    double targetY = targetCurveY +
                        normalizedY * halfHeight * thicknessScale;
                    double influence = 1;
                    double unitX = (normalizedX + 1) * 0.5;
                    foreach (anchor; ["anchorLeft", "anchorRight"]) {
                        double width = optionalProfileNumber(profile, anchor);
                        if (width < 0 || width > 1) throw new Exception(profileLabel ~ " anchor width must be in [0,1].");
                        if (width > 0) {
                            import std.algorithm : clamp;
                            double t = clamp((anchor == "anchorLeft" ? unitX : 1 - unitX) / width, 0.0, 1.0);
                            influence *= t * t * (3 - 2 * t);
                        }
                    }
                    dx += amount * (targetX - x) * influence;
                    dy += amount * (targetY - y) * influence;
                    break;
                }
                default:
                    throw new Exception(format(
                        "%s uses unsupported deformation profile '%s'.",
                        profileLabel,
                        profileType
                    ));
            }
        }
        if (!isFinite(dx) || !isFinite(dy) || !isFinite(cast(float)dx) || !isFinite(cast(float)dy)) {
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

/** Builds a mesh that follows a Part's texture alpha. The Part's current mesh
 * must map UVs linearly onto its vertices (imported quads and grids do), so
 * generated UVs and local vertices stay aligned with the texture. */
private JSONValue autoMeshForPart(ref InxDocument document, JSONValue node, JSONValue request, string label) {
    import imagefmt : IF_ERROR, read_image;
    requireFields(request, ["spacing", "margin", "alpha_threshold", "max_vertices"], label ~ " auto");
    auto options = agentReadAutoMeshOptions(request);
    auto textures = objectField(node, "textures", JSONValue.emptyArray);
    if (textures.type != JSONType.array || textures.array.length == 0)
        throw new Exception(label ~ " auto mesh target has no albedo texture.");
    auto slot = readIndex(textures.array[0], label ~ " texture slot");
    if (slot >= document.textureBlobs.length)
        throw new Exception(label ~ " auto mesh target references a missing texture.");
    auto image = read_image(document.textureBlobs[slot].data, 4, 8);
    if (image.e != 0) throw new Exception(format("%s could not decode texture: %s.", label, IF_ERROR[image.e]));
    scope (exit) image.free();

    auto oldMesh = requireMeshField(node, "mesh");
    auto verts = requireMeshField(oldMesh, "verts");
    auto uvs = requireMeshField(oldMesh, "uvs");
    size_t count = verts.array.length / 2;
    validateNumericArray(uvs, count * 2, label ~ " current uvs");
    double[4] vb = [double.infinity, double.infinity, -double.infinity, -double.infinity];
    double[4] ub = vb;
    foreach (i; 0 .. count) {
        double x = readFiniteNumber(verts[i * 2], "vertex x"), y = readFiniteNumber(verts[i * 2 + 1], "vertex y");
        double u = readFiniteNumber(uvs[i * 2], "u"), v = readFiniteNumber(uvs[i * 2 + 1], "v");
        if (x < vb[0]) vb[0] = x;
        if (y < vb[1]) vb[1] = y;
        if (x > vb[2]) vb[2] = x;
        if (y > vb[3]) vb[3] = y;
        if (u < ub[0]) ub[0] = u;
        if (v < ub[1]) ub[1] = v;
        if (u > ub[2]) ub[2] = u;
        if (v > ub[3]) ub[3] = v;
    }
    if (!(vb[0] < vb[2]) || !(vb[1] < vb[3]) || !(ub[0] < ub[2]) || !(ub[1] < ub[3]))
        throw new Exception(label ~ " auto mesh target has degenerate bounds.");
    double sx = (vb[2] - vb[0]) / (ub[2] - ub[0]), sy = (vb[3] - vb[1]) / (ub[3] - ub[1]);
    foreach (i; 0 .. count) {
        double x = readFiniteNumber(verts[i * 2], "vertex x"), y = readFiniteNumber(verts[i * 2 + 1], "vertex y");
        double u = readFiniteNumber(uvs[i * 2], "u"), v = readFiniteNumber(uvs[i * 2 + 1], "v");
        if (abs(vb[0] + (u - ub[0]) * sx - x) > 1e-3 * (vb[2] - vb[0]) + 1e-6 ||
            abs(vb[1] + (v - ub[1]) * sy - y) > 1e-3 * (vb[3] - vb[1]) + 1e-6)
            throw new Exception(label ~ " auto mesh requires a current mesh whose UVs map linearly to vertices.");
    }

    auto generated = agentGenerateAutoMesh(image.buf8, image.w, image.h, options);
    double[] outVerts, outUvs;
    foreach (i; 0 .. generated.pixelPoints.length / 2) {
        double u = generated.pixelPoints[i * 2] / image.w, v = generated.pixelPoints[i * 2 + 1] / image.h;
        outUvs ~= [u, v];
        outVerts ~= [vb[0] + (u - ub[0]) * sx, vb[1] + (v - ub[1]) * sy];
    }
    ulong[] indices;
    foreach (index; generated.indices) indices ~= index;
    JSONValue[string] mesh;
    mesh["verts"] = numberArray(outVerts);
    mesh["uvs"] = numberArray(outUvs);
    mesh["indices"] = indexArray(indices);
    mesh["origin"] = objectField(oldMesh, "origin", numberArray([0.0, 0.0]));
    size_t vertexCount, triangleCount;
    return normalizeMesh(JSONValue(mesh), vertexCount, triangleCount);
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
    requireFields(specification, ["schema_version", "groups", "parts", "masks", "meshes", "parameters", "physics", "automation"], "Rig specification");
    if ("schema_version" in specification.object && readIndex(specification["schema_version"], "schema_version") != 1)
        throw new Exception("Unsupported rig schema_version; expected 1.");
    auto document = parseInx(cast(const(ubyte)[]) read(inputPath));
    AgentRigSummary summary;
    auto existingParameters = objectField(
        document.payload,
        "param",
        JSONValue(JSONValue[].init)
    );
    if (existingParameters.type != JSONType.array) {
        throw new Exception("INX parameters must be an array.");
    }
    ulong nextUuid = maximumUuid(document.payload["nodes"], existingParameters) + 1;

    auto groups = objectField(
        specification,
        "groups",
        JSONValue(JSONValue[].init)
    );
    applyRigGroups(
        document.payload,
        groups,
        summary,
        nextUuid
    );

    applyRigParts(document.payload, objectField(specification, "parts", JSONValue(JSONValue[].init)), summary);

    auto masks = objectField(
        specification,
        "masks",
        JSONValue(JSONValue[].init)
    );
    applyRigMasks(
        document.payload,
        masks,
        summary
    );

    auto meshes = objectField(specification, "meshes", JSONValue(JSONValue[].init));
    if (meshes.type != JSONType.array) {
        throw new Exception("Rig specification meshes must be an array.");
    }
    bool[string] meshPaths;
    foreach (index, meshRequest; meshes.array) {
        string label = format("Mesh request %s", index);
        requireFields(meshRequest, ["path", "mesh", "columns", "rows", "auto"], label);
        string path = requiredString(meshRequest, "path", label);
        if (path in meshPaths) throw new Exception(label ~ " duplicates mesh path '" ~ path ~ "'.");
        meshPaths[path] = true;
        bool custom = ("mesh" in meshRequest.object) !is null;
        bool automatic = ("auto" in meshRequest.object) !is null;
        bool grid = "columns" in meshRequest.object || "rows" in meshRequest.object;
        if ((custom ? 1 : 0) + (automatic ? 1 : 0) + (grid ? 1 : 0) != 1)
            throw new Exception(label ~ " requires exactly one of mesh, auto or columns/rows.");
        size_t columns = cast(size_t) readIndex(
            objectField(meshRequest, "columns", JSONValue(0)),
            label ~ " columns"
        );
        size_t rows = cast(size_t) readIndex(
            objectField(meshRequest, "rows", JSONValue(0)),
            label ~ " rows"
        );
        mutateUniqueNode(document.payload, path, (ref JSONValue node) {
            string targetType = objectField(node, "type", JSONValue("")).str;
            if (targetType != "Part" && !(targetType == "MeshGroup" && !automatic)) {
                throw new Exception(format(automatic ? "Auto mesh target '%s' is not a Part." :
                    "Mesh target '%s' is not a Part or MeshGroup.", path));
            }
            auto oldMesh = requireMeshField(node, "mesh");
            size_t vertexCount, triangleCount;
            auto newMesh = custom
                ? normalizeMesh(meshRequest["mesh"], vertexCount, triangleCount)
                : automatic ? autoMeshForPart(document, node, meshRequest["auto"], label)
                : buildGridMesh(oldMesh, columns, rows);
            if (custom && !("uvs" in newMesh.object)) throw new Exception(label ~ " custom mesh requires uvs.");
            if (hasDeformationBinding(document.payload, readIndex(node["uuid"], "Part uuid")) &&
                (meshVertexCount(oldMesh, label) != meshVertexCount(newMesh, label) || !hasSameIndices(oldMesh, newMesh)))
                throw new Exception(label ~ " changes bound mesh topology; rebuild from an unbound base or migrate deformation keys first.");
            node.object["mesh"] = newMesh;
        });
        summary.meshedPartCount++;
    }

    auto parameters = objectField(
        specification,
        "parameters",
        JSONValue(JSONValue[].init)
    );
    if (parameters.type != JSONType.array) {
        throw new Exception("Rig specification parameters must be an array.");
    }

    bool[string] parameterNames;
    foreach (parameterIndex, parameterRequest; parameters.array) {
        string parameterLabel = format("Parameter request %s", parameterIndex);
        requireFields(parameterRequest, ["name", "min", "max", "default", "keys", "axes", "bindings"], parameterLabel);
        string name = requiredString(parameterRequest, "name", parameterLabel);
        if (name in parameterNames) throw new Exception("Duplicate parameter '" ~ name ~ "'.");
        parameterNames[name] = true;
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
        bool isVec2 = ("axes" in parameterRequest.object) !is null;
        RigAxis xAxis, yAxis;
        yAxis.minimum = 0; yAxis.maximum = 1; yAxis.defaultValue = 0;
        yAxis.keys = [0]; yAxis.normalized = [0];
        if (isVec2) {
            foreach (field; ["min", "max", "default", "keys"])
                if (field in parameterRequest.object) throw new Exception(name ~ " cannot mix axes and scalar fields.");
            auto requestedAxes = parameterRequest["axes"];
            if (requestedAxes.type != JSONType.array || requestedAxes.array.length != 2)
                throw new Exception(name ~ " axes must contain exactly two axis objects.");
            foreach (axis; requestedAxes.array) requireFields(axis, ["min", "max", "default", "keys"], name ~ " axis");
            xAxis = readRigAxis(requestedAxes[0], name ~ " X");
            yAxis = readRigAxis(requestedAxes[1], name ~ " Y");
        } else xAxis = readRigAxis(parameterRequest, name);
        JSONValue[] axes = [numberArray(xAxis.normalized), numberArray(yAxis.normalized)];
        JSONValue[] bindings;
        bool[string] bindingTargets;
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
            requireFields(bindingRequest, ["path", "property", "values", "interpolation"], bindingLabel);
            string path = requiredString(bindingRequest, "path", bindingLabel);
            string property = requiredString(bindingRequest, "property", bindingLabel);
            ulong nodeUuid;
            string nodeType;
            JSONValue mesh;
            inspectRigTarget(document.payload, path, nodeUuid, nodeType, mesh);
            string identity = format("%s:%s", nodeUuid, property);
            if (identity in bindingTargets) throw new Exception(bindingLabel ~ " duplicates a target property.");
            bindingTargets[identity] = true;
            string interpolation = "interpolation" in bindingRequest.object
                ? requiredString(bindingRequest, "interpolation", bindingLabel) : "Linear";
            if (interpolation != "Linear" && interpolation != "Nearest" && interpolation != "Cubic")
                throw new Exception(bindingLabel ~ " interpolation must be Linear, Nearest or Cubic.");

            bool isDeformation = property == "deform";
            bool isOpacity = property == "opacity";
            bool isTint = property == "tint.r" || property == "tint.g" || property == "tint.b";
            bool isScreenTint = property == "screenTint.r" || property == "screenTint.g" || property == "screenTint.b";
            bool isTransform =
                property == "zSort" ||
                property == "transform.t.x" ||
                property == "transform.t.y" ||
                property == "transform.t.z" ||
                property == "transform.r.x" ||
                property == "transform.r.y" ||
                property == "transform.r.z" ||
                property == "transform.s.x" ||
                property == "transform.s.y";
            if (!isDeformation && !isOpacity && !isTransform && !isTint && !isScreenTint) {
                throw new Exception(format(
                    "%s uses unsupported property '%s'.",
                    bindingLabel,
                    property
                ));
            }
            if (isDeformation && nodeType != "Part" && nodeType != "MeshGroup") {
                throw new Exception(format(
                    "%s property '%s' requires a Part or MeshGroup target.",
                    bindingLabel,
                    property
                ));
            }
            if ((isOpacity || isTint || isScreenTint) && nodeType != "Part" && nodeType != "Composite") {
                throw new Exception(format(
                    "%s property '%s' requires a Part or Composite target.",
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
            auto requestedValues = objectField(bindingRequest, "values", JSONValue.init);
            if (requestedValues.type != JSONType.array || requestedValues.array.length != xAxis.keys.length)
                throw new Exception(bindingLabel ~ " values must match X key count.");
            JSONValue[] valueGrid, flagGrid;
            foreach (x, column; requestedValues.array) {
                auto cells = isVec2 ? column : JSONValue([column]);
                if (cells.type != JSONType.array || cells.array.length != yAxis.keys.length)
                    throw new Exception(bindingLabel ~ " values[x] must match Y key count (X-major order).");
                JSONValue[] values, flags;
                foreach (y, cell; cells.array) {
                    string cellLabel = format("%s values[%s][%s]", bindingLabel, x, y);
                    if (isDeformation) values ~= deformationForMesh(mesh, cell, cellLabel);
                    else {
                        double v = readFiniteNumber(cell, cellLabel);
                        if (isOpacity && (v < 0 || v > 1)) throw new Exception(cellLabel ~ " opacity must be in [0,1].");
                        if (isTint && v < 0) throw new Exception(cellLabel ~ " tint multiplier must not be negative.");
                        if (isScreenTint && (v < -1 || v > 1)) throw new Exception(cellLabel ~ " screenTint offset must be in [-1,1].");
                        values ~= JSONValue(v);
                    }
                    flags ~= JSONValue(true);
                }
                valueGrid ~= JSONValue(values); flagGrid ~= JSONValue(flags);
            }
            binding["values"] = JSONValue(valueGrid);
            binding["isSet"] = JSONValue(flagGrid);
            binding["interpolate_mode"] = JSONValue(interpolation);
            bindings ~= JSONValue(binding);
            summary.bindingCount++;
        }

        JSONValue[string] parameter;
        parameter["uuid"] = existingParameterIndex >= 0
            ? existingParameters.array[existingParameterIndex]["uuid"]
            : JSONValue(nextUuid++);
        parameter["name"] = JSONValue(name);
        parameter["is_vec2"] = JSONValue(isVec2);
        parameter["min"] = numberArray([xAxis.minimum, yAxis.minimum]);
        parameter["max"] = numberArray([xAxis.maximum, yAxis.maximum]);
        parameter["defaults"] = numberArray([xAxis.defaultValue, yAxis.defaultValue]);
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
    auto physics = objectField(
        specification,
        "physics",
        JSONValue(JSONValue[].init)
    );
    applyRigPhysics(
        document.payload,
        physics,
        existingParameters,
        summary,
        nextUuid
    );
    applyRigAutomation(document.payload, objectField(specification, "automation", JSONValue(JSONValue[].init)), summary);
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
