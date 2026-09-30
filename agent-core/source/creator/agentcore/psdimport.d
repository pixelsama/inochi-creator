module creator.agentcore.psdimport;

import std.bitmanip : nativeToBigEndian;
import std.file : write;
import std.format : format;
import std.json : JSONValue;
import std.path : baseName, stripExtension;
import std.stdio : File;

import imagefmt : IF_TGA, read_image, write_image_mem;
import psd : BlendingMode, ChannelInfo, ChannelType, ColorMode, LayerFlags,
    LayerType, PSD, parseDocument;

import creator.agentcore.modelio : agentMagicBytes, agentReadModelTextures,
    agentTextureSection;
import creator.agentcore.psdinspect : AgentPsdLayerKind, AgentPsdSourceLayer,
    agentBuildPsdLayout, agentComposePsdRgba, agentDecodePsdChannel;

private enum uint noTexture = uint.max;

struct AgentPsdImportLayer {
    string name;
    string path;
    size_t sourceIndex;
    size_t depth;
    bool isGroup;
    bool visible;
    int left;
    int top;
    uint width;
    uint height;
    ubyte opacity = 255;
    string blendMode = "norm";
    ubyte[] rgba;
}

struct AgentPsdImportDocument {
    int width;
    int height;
    size_t sourceLayerRecordCount;
    AgentPsdImportLayer[] layers;
}

struct AgentPsdImportSummary {
    string sourcePath;
    string outputPath;
    size_t groupCount;
    size_t partCount;
    size_t textureCount;

    string toJson() const {
        JSONValue[string] object;
        object["sourcePath"] = JSONValue(sourcePath);
        object["outputPath"] = JSONValue(outputPath);
        object["groupCount"] = JSONValue(cast(ulong) groupCount);
        object["partCount"] = JSONValue(cast(ulong) partCount);
        object["textureCount"] = JSONValue(cast(ulong) textureCount);
        return JSONValue(object).toString();
    }
}

struct AgentPsdTextureVerificationSummary {
    size_t verifiedTextureCount;
    ulong verifiedRgbaByteCount;
}

private final class ImportTreeNode {
    AgentPsdImportLayer layer;
    ImportTreeNode[] children;

    this(AgentPsdImportLayer layer) {
        this.layer = layer;
    }
}

private JSONValue jsonArray(const(double)[] values) {
    JSONValue[] result;
    result.reserve(values.length);
    foreach (value; values) {
        result ~= JSONValue(value);
    }
    return JSONValue(result);
}

private JSONValue jsonArray(const(ulong)[] values) {
    JSONValue[] result;
    result.reserve(values.length);
    foreach (value; values) {
        result ~= JSONValue(value);
    }
    return JSONValue(result);
}

private JSONValue transformJson(double x = 0, double y = 0, double z = 0) {
    JSONValue[string] transform;
    transform["trans"] = jsonArray([x, y, z]);
    transform["rot"] = jsonArray([0.0, 0.0, 0.0]);
    transform["scale"] = jsonArray([1.0, 1.0]);
    return JSONValue(transform);
}

private JSONValue baseNodeJson(
    uint uuid,
    string name,
    string type,
    bool enabled,
    double zSort,
    double x = 0,
    double y = 0
) {
    JSONValue[string] node;
    node["uuid"] = JSONValue(cast(ulong) uuid);
    node["name"] = JSONValue(name);
    node["type"] = JSONValue(type);
    node["enabled"] = JSONValue(enabled);
    node["zsort"] = JSONValue(zSort);
    node["transform"] = transformJson(x, y);
    node["lockToRoot"] = JSONValue(false);
    return JSONValue(node);
}

private string inochiBlendMode(string psdMode) {
    switch (psdMode) {
        case "":
        case "pass":
        case "norm":
            return "Normal";
        case "mul ":
            return "Multiply";
        case "scrn":
            return "Screen";
        case "over":
            return "Overlay";
        case "dark":
            return "Darken";
        case "lite":
            return "Lighten";
        case "div ":
            return "ColorDodge";
        case "lddg":
            return "LinearDodge";
        case "idiv":
            return "ColorBurn";
        case "hLit":
            return "HardLight";
        case "sLit":
            return "SoftLight";
        case "diff":
            return "Difference";
        case "smud":
            return "Exclusion";
        case "fsub":
            return "Subtract";
        default:
            throw new Exception(format(
                "PSD blend mode '%s' has no lossless Inochi2D mapping.",
                psdMode
            ));
    }
}

/**
 * Premultiplies RGB exactly as the Inochi2D texture loader does.
 */
ubyte[] agentPremultiplyRgba(const(ubyte)[] rgba) {
    if (rgba.length % 4 != 0) {
        throw new Exception("RGBA byte length must be divisible by four.");
    }

    auto result = rgba.dup;
    foreach (pixel; 0 .. result.length / 4) {
        size_t offset = pixel * 4;
        int alpha = result[offset + 3];
        result[offset] = cast(ubyte)((cast(int) result[offset] * alpha) / 255);
        result[offset + 1] = cast(ubyte)((cast(int) result[offset + 1] * alpha) / 255);
        result[offset + 2] = cast(ubyte)((cast(int) result[offset + 2] * alpha) / 255);
    }
    return result;
}

private ImportTreeNode[] buildTree(AgentPsdImportLayer[] layers) {
    ImportTreeNode[] roots;
    ImportTreeNode[] groupStack;

    foreach (layer; layers) {
        if (layer.depth > groupStack.length) {
            throw new Exception(format(
                "PSD layer '%s' has no group at depth %s.",
                layer.path,
                layer.depth
            ));
        }

        groupStack.length = layer.depth;
        auto node = new ImportTreeNode(layer);
        if (layer.depth == 0) {
            roots ~= node;
        } else {
            groupStack[$ - 1].children ~= node;
        }

        if (layer.isGroup) {
            groupStack ~= node;
        }
    }
    return roots;
}

private JSONValue buildNodeJson(
    ImportTreeNode treeNode,
    AgentPsdImportDocument document,
    ref uint nextUuid,
    ref ubyte[][] textureBlobs,
    bool insideComposite = false
) {
    auto layer = treeNode.layer;
    uint uuid = nextUuid++;

    if (layer.isGroup) {
        // Isolated PSD groups (non-pass blending or reduced opacity) become
        // Composites, which render children offscreen and blend the result.
        bool composite = layer.opacity != 255 ||
            (layer.blendMode.length > 0 && layer.blendMode != "norm" && layer.blendMode != "pass");
        if (composite && insideComposite) {
            throw new Exception(format(
                "PSD group '%s' needs a Composite inside another Composite; Inochi2D flattens nested composites.",
                layer.path
            ));
        }
        if (composite) {
            auto node = baseNodeJson(uuid, layer.name, "Composite", layer.visible, 0);
            node.object["blend_mode"] = JSONValue(inochiBlendMode(layer.blendMode == "pass" ? "norm" : layer.blendMode));
            node.object["tint"] = jsonArray([1.0, 1.0, 1.0]);
            node.object["screenTint"] = jsonArray([0.0, 0.0, 0.0]);
            node.object["mask_threshold"] = JSONValue(0.5);
            node.object["opacity"] = JSONValue(layer.opacity / 255.0);
            node.object["propagate_meshgroup"] = JSONValue(true);
            JSONValue[] children;
            foreach (child; treeNode.children)
                children ~= buildNodeJson(child, document, nextUuid, textureBlobs, true);
            if (children.length > 0) node.object["children"] = JSONValue(children);
            return node;
        }

        auto node = baseNodeJson(uuid, layer.name, "Node", layer.visible, 0);
        JSONValue[] children;
        children.reserve(treeNode.children.length);
        foreach (child; treeNode.children) {
            children ~= buildNodeJson(child, document, nextUuid, textureBlobs, insideComposite);
        }
        if (children.length > 0) {
            node.object["children"] = JSONValue(children);
        }
        return node;
    }

    if (layer.width == 0 || layer.height == 0) {
        throw new Exception(format("PSD layer '%s' has empty pixel bounds.", layer.path));
    }
    if (layer.rgba.length != cast(size_t) layer.width * layer.height * 4) {
        throw new Exception(format("PSD layer '%s' has invalid RGBA data.", layer.path));
    }

    auto premultiplied = agentPremultiplyRgba(layer.rgba);
    int imageError;
    auto encodedTexture = write_image_mem(
        IF_TGA,
        cast(int) layer.width,
        cast(int) layer.height,
        premultiplied,
        4,
        imageError
    );
    if (imageError != 0 || encodedTexture.length == 0) {
        throw new Exception(format(
            "Failed to encode PSD layer '%s' as an INX texture (imagefmt error %s).",
            layer.path,
            imageError
        ));
    }

    ulong textureSlot = textureBlobs.length;
    textureBlobs ~= encodedTexture.dup;

    double centerX = layer.left + layer.width / 2.0 - document.width / 2.0;
    double centerY = layer.top + layer.height / 2.0 - document.height / 2.0;
    double halfWidth = layer.width / 2.0;
    double halfHeight = layer.height / 2.0;
    double zSort = cast(double)(document.sourceLayerRecordCount - layer.sourceIndex);

    auto node = baseNodeJson(
        uuid,
        layer.name,
        "Part",
        layer.visible,
        zSort,
        centerX,
        centerY
    );

    JSONValue[string] mesh;
    mesh["verts"] = jsonArray([
        -halfWidth, -halfHeight,
        -halfWidth, halfHeight,
        halfWidth, -halfHeight,
        halfWidth, halfHeight
    ]);
    mesh["uvs"] = jsonArray([
        0.0, 0.0,
        0.0, 1.0,
        1.0, 0.0,
        1.0, 1.0
    ]);
    mesh["indices"] = jsonArray([0UL, 1, 2, 2, 1, 3]);
    mesh["origin"] = jsonArray([0.0, 0.0]);

    node.object["mesh"] = JSONValue(mesh);
    node.object["textures"] = jsonArray([
        textureSlot,
        cast(ulong) noTexture,
        cast(ulong) noTexture
    ]);
    node.object["blend_mode"] = JSONValue(inochiBlendMode(layer.blendMode));
    node.object["tint"] = jsonArray([1.0, 1.0, 1.0]);
    node.object["screenTint"] = jsonArray([0.0, 0.0, 0.0]);
    node.object["emissionStrength"] = JSONValue(1.0);
    node.object["mask_threshold"] = JSONValue(0.5);
    node.object["opacity"] = JSONValue(layer.opacity / 255.0);
    node.object["psdLayerPath"] = JSONValue(layer.path);
    return node;
}

/**
 * Builds a texture-backed, parameter-free INX project from decoded PSD layers.
 * The result is intentionally an initial rig: it preserves layer hierarchy,
 * neutral placement, visibility, opacity, blend mode, texture data, and stable
 * PSD paths, while leaving mesh refinement and parameter bindings to later
 * deterministic Agent passes.
 */
ubyte[] agentBuildInitialInx(AgentPsdImportDocument document, string modelName) {
    if (document.width <= 0 || document.height <= 0) {
        throw new Exception("PSD document dimensions must be positive.");
    }
    if (document.sourceLayerRecordCount == 0) {
        throw new Exception("PSD document has no layer records.");
    }

    auto roots = buildTree(document.layers);
    uint nextUuid = 2;
    ubyte[][] textureBlobs;
    JSONValue[] children;
    children.reserve(roots.length);
    foreach (root; roots) {
        children ~= buildNodeJson(root, document, nextUuid, textureBlobs);
    }

    auto rootNode = baseNodeJson(1, "Root", "Node", true, 0);
    rootNode.object["children"] = JSONValue(children);

    JSONValue[string] meta;
    meta["name"] = JSONValue(modelName);
    meta["version"] = JSONValue("1.0-alpha");
    meta["thumbnailId"] = JSONValue(cast(ulong) noTexture);
    meta["preservePixels"] = JSONValue(false);

    JSONValue[string] physics;
    physics["pixelsPerMeter"] = JSONValue(1000.0);
    physics["gravity"] = JSONValue(9.8);

    JSONValue[string] payload;
    payload["meta"] = JSONValue(meta);
    payload["physics"] = JSONValue(physics);
    payload["nodes"] = rootNode;
    payload["param"] = JSONValue(JSONValue[].init);
    payload["automation"] = JSONValue(JSONValue[].init);
    payload["animations"] = JSONValue.emptyObject;

    auto payloadText = JSONValue(payload).toString();
    if (payloadText.length > uint.max || textureBlobs.length > uint.max) {
        throw new Exception("INX container exceeds its 32-bit length limits.");
    }

    ubyte[] result = agentMagicBytes.dup;
    result ~= nativeToBigEndian(cast(uint) payloadText.length)[];
    result ~= cast(ubyte[]) payloadText;
    result ~= agentTextureSection;
    result ~= nativeToBigEndian(cast(uint) textureBlobs.length)[];
    foreach (texture; textureBlobs) {
        if (texture.length > uint.max) {
            throw new Exception("An encoded INX texture exceeds the 32-bit length limit.");
        }
        result ~= nativeToBigEndian(cast(uint) texture.length)[];
        result ~= cast(ubyte) 1;
        result ~= texture;
    }
    return result;
}

/**
 * Decodes every texture from an initial INX and compares it byte-for-byte with
 * the source PSD layer after Inochi2D's required alpha premultiplication.
 */
AgentPsdTextureVerificationSummary agentVerifyInitialInxTextures(
    AgentPsdImportDocument document,
    string inxPath
) {
    auto textures = agentReadModelTextures(inxPath);
    size_t expectedTextureCount;
    foreach (layer; document.layers) {
        if (!layer.isGroup) expectedTextureCount++;
    }
    if (textures.length != expectedTextureCount) {
        throw new Exception(format(
            "INX texture count %s does not match PSD pixel layer count %s.",
            textures.length,
            expectedTextureCount
        ));
    }

    AgentPsdTextureVerificationSummary summary;
    size_t textureIndex;
    foreach (layer; document.layers) {
        if (layer.isGroup) continue;

        auto texture = textures[textureIndex];
        if (texture.type != 1) {
            throw new Exception(format(
                "INX texture %s for PSD layer '%s' is not a TGA blob.",
                textureIndex,
                layer.path
            ));
        }

        auto image = read_image(texture.data, 4, 8);
        scope (exit) image.free();
        if (
            image.e != 0 ||
            image.w != layer.width ||
            image.h != layer.height ||
            image.c != 4
        ) {
            throw new Exception(format(
                "INX texture %s for PSD layer '%s' failed RGBA dimension validation.",
                textureIndex,
                layer.path
            ));
        }

        auto expected = agentPremultiplyRgba(layer.rgba);
        if (image.buf8 != expected) {
            throw new Exception(format(
                "INX texture %s differs from premultiplied PSD layer '%s'.",
                textureIndex,
                layer.path
            ));
        }

        summary.verifiedTextureCount++;
        summary.verifiedRgbaByteCount += image.buf8.length;
        textureIndex++;
    }
    return summary;
}

private AgentPsdLayerKind layerKind(LayerType type) {
    switch (type) {
        case LayerType.OpenFolder:
        case LayerType.ClosedFolder:
            return AgentPsdLayerKind.group;
        case LayerType.SectionDivider:
            return AgentPsdLayerKind.sectionDivider;
        default:
            return AgentPsdLayerKind.pixel;
    }
}

private ubyte[] readChannel(File file, const ChannelInfo channel) {
    if (channel.dataLength < ushort.sizeof) {
        throw new Exception("PSD channel is shorter than its compression tag.");
    }
    file.seek(channel.fileOffset);
    auto result = new ubyte[channel.dataLength];
    file.rawRead(result);
    return result;
}

private const(ChannelInfo)* findChannel(
    ref const(ChannelInfo)[] channels,
    short channelType
) {
    foreach (ref channel; channels) {
        if (channel.type == channelType) {
            return &channel;
        }
    }
    return null;
}

/**
 * Decodes the supported, appearance-preserving subset of PSD needed for an
 * initial Agent project. Unsupported semantics fail explicitly instead of
 * silently changing the neutral image.
 */
AgentPsdImportDocument agentReadPsdForImport(string path) {
    PSD source = parseDocument(path);
    if (source.bitsPerChannel != 8 || source.colorMode != ColorMode.RGB) {
        throw new Exception("Agent PSD import requires an 8-bit RGB document.");
    }

    AgentPsdSourceLayer[] sourceLayers;
    sourceLayers.length = source.layers.length;
    foreach (index, layer; source.layers) {
        sourceLayers[index] = AgentPsdSourceLayer(layer.name, layerKind(layer.type), index);
    }

    auto layout = agentBuildPsdLayout(sourceLayers);
    auto file = File(path, "rb");
    AgentPsdImportDocument document;
    document.width = source.width;
    document.height = source.height;
    document.sourceLayerRecordCount = source.layers.length;

    foreach (entry; layout) {
        auto layer = source.layers[entry.sourceIndex];
        AgentPsdImportLayer decoded;
        decoded.name = entry.name;
        decoded.path = entry.path;
        decoded.sourceIndex = entry.sourceIndex;
        decoded.depth = entry.depth;
        decoded.isGroup = entry.isGroup;
        decoded.visible = (layer.flags & LayerFlags.Visible) == 0;
        decoded.left = layer.left;
        decoded.top = layer.top;
        decoded.width = layer.width;
        decoded.height = layer.height;
        decoded.opacity = layer.opacity;
        decoded.blendMode = cast(string) layer.blendModeKey;

        if (entry.isGroup) {
            document.layers ~= decoded;
            continue;
        }
        if (layer.width == 0 || layer.height == 0) {
            throw new Exception(format("PSD layer '%s' has empty pixel bounds.", entry.path));
        }
        foreach (channel; layer.channels) {
            if (
                channel.type == ChannelType.LAYER_OR_VECTOR_MASK ||
                channel.type == ChannelType.LAYER_MASK
            ) {
                throw new Exception(format(
                    "PSD layer '%s' has a layer/vector mask; mask application must be resolved before import.",
                    entry.path
                ));
            }
        }

        auto channels = cast(const(ChannelInfo)[]) layer.channels;
        auto redInfo = findChannel(channels, ChannelType.R);
        auto greenInfo = findChannel(channels, ChannelType.G);
        auto blueInfo = findChannel(channels, ChannelType.B);
        auto alphaInfo = findChannel(channels, ChannelType.TRANSPARENCY_MASK);
        if (redInfo is null || greenInfo is null || blueInfo is null) {
            throw new Exception(format("PSD layer '%s' is missing an RGB channel.", entry.path));
        }

        auto red = agentDecodePsdChannel(readChannel(file, *redInfo), layer.width, layer.height);
        auto green = agentDecodePsdChannel(readChannel(file, *greenInfo), layer.width, layer.height);
        auto blue = agentDecodePsdChannel(readChannel(file, *blueInfo), layer.width, layer.height);
        ubyte[] alpha;
        if (alphaInfo !is null) {
            alpha = agentDecodePsdChannel(readChannel(file, *alphaInfo), layer.width, layer.height);
        }
        decoded.rgba = agentComposePsdRgba(
            red,
            green,
            blue,
            alpha,
            cast(size_t) layer.width * layer.height
        );
        document.layers ~= decoded;
    }
    return document;
}

AgentPsdImportSummary agentImportPsdToInx(string inputPath, string outputPath) {
    auto document = agentReadPsdForImport(inputPath);
    auto modelName = stripExtension(baseName(inputPath));
    write(outputPath, agentBuildInitialInx(document, modelName));
    agentVerifyInitialInxTextures(document, outputPath);

    AgentPsdImportSummary summary;
    summary.sourcePath = inputPath;
    summary.outputPath = outputPath;
    foreach (layer; document.layers) {
        if (layer.isGroup) {
            summary.groupCount++;
        } else {
            summary.partCount++;
            summary.textureCount++;
        }
    }
    return summary;
}
