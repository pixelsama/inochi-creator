module creator.agentcore.psdinspect;

import std.bitmanip : bigEndianToNative;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : write;
import std.format : format;
import std.json : JSONValue;
import std.stdio : File;

import psd : BlendingMode, ChannelInfo, ChannelType, ColorMode, LayerFlags,
    LayerType, PSD, parseDocument;

enum AgentPsdLayerKind {
    pixel,
    group,
    sectionDivider
}

struct AgentPsdSourceLayer {
    string name;
    AgentPsdLayerKind kind;
    size_t sourceIndex;
}

struct AgentPsdLayoutEntry {
    string name;
    string path;
    size_t sourceIndex;
    size_t depth;
    bool isGroup;
}

struct AgentPsdLayerInspection {
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
    size_t channelCount;
    size_t maskChannelCount;
    bool pixelsDecoded;
    ulong transparentPixelCount;
    ulong translucentPixelCount;
    ulong opaquePixelCount;
    string rgbaSha256;
    string blendMode;

    private JSONValue toJsonValue() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["path"] = JSONValue(path);
        object["sourceIndex"] = JSONValue(cast(long) sourceIndex);
        object["depth"] = JSONValue(cast(long) depth);
        object["isGroup"] = JSONValue(isGroup);
        object["visible"] = JSONValue(visible);
        object["left"] = JSONValue(cast(long) left);
        object["top"] = JSONValue(cast(long) top);
        object["width"] = JSONValue(cast(long) width);
        object["height"] = JSONValue(cast(long) height);
        object["channelCount"] = JSONValue(cast(long) channelCount);
        object["maskChannelCount"] = JSONValue(cast(long) maskChannelCount);
        object["pixelsDecoded"] = JSONValue(pixelsDecoded);
        object["transparentPixelCount"] = JSONValue(cast(long) transparentPixelCount);
        object["translucentPixelCount"] = JSONValue(cast(long) translucentPixelCount);
        object["opaquePixelCount"] = JSONValue(cast(long) opaquePixelCount);
        object["rgbaSha256"] = JSONValue(rgbaSha256);
        object["blendMode"] = JSONValue(blendMode);
        return JSONValue(object);
    }
}

struct AgentPsdInspection {
    string sourcePath;
    int width;
    int height;
    ushort bitsPerChannel;
    ushort documentChannels;
    string colorMode;
    size_t sourceLayerRecordCount;
    size_t groupCount;
    size_t leafLayerCount;
    size_t decodedLayerCount;
    size_t emptyLayerCount;
    ulong transparentPixelCount;
    ulong translucentPixelCount;
    ulong opaquePixelCount;
    AgentPsdLayerInspection[] layers;

    private JSONValue toJsonValue(bool includeLayers) const {
        JSONValue[string] object;
        object["sourcePath"] = JSONValue(sourcePath);
        object["width"] = JSONValue(cast(long) width);
        object["height"] = JSONValue(cast(long) height);
        object["bitsPerChannel"] = JSONValue(cast(long) bitsPerChannel);
        object["documentChannels"] = JSONValue(cast(long) documentChannels);
        object["colorMode"] = JSONValue(colorMode);
        object["sourceLayerRecordCount"] = JSONValue(cast(long) sourceLayerRecordCount);
        object["groupCount"] = JSONValue(cast(long) groupCount);
        object["leafLayerCount"] = JSONValue(cast(long) leafLayerCount);
        object["decodedLayerCount"] = JSONValue(cast(long) decodedLayerCount);
        object["emptyLayerCount"] = JSONValue(cast(long) emptyLayerCount);
        object["transparentPixelCount"] = JSONValue(cast(long) transparentPixelCount);
        object["translucentPixelCount"] = JSONValue(cast(long) translucentPixelCount);
        object["opaquePixelCount"] = JSONValue(cast(long) opaquePixelCount);

        if (includeLayers) {
            JSONValue[] layerValues;
            layerValues.reserve(layers.length);
            foreach (layer; layers) {
                layerValues ~= layer.toJsonValue();
            }
            object["layers"] = JSONValue(layerValues);
        }
        return JSONValue(object);
    }

    string toSummaryJson() const {
        return toJsonValue(false).toString();
    }

    string toReportJson() const {
        return toJsonValue(true).toPrettyString();
    }
}

private final class LayoutNode {
    AgentPsdSourceLayer source;
    LayoutNode parent;
    LayoutNode[] children;

    this(AgentPsdSourceLayer source, LayoutNode parent = null) {
        this.source = source;
        this.parent = parent;
    }
}

private void appendLayout(
    ref AgentPsdLayoutEntry[] output,
    LayoutNode node,
    size_t depth,
    string parentPath
) {
    string path = parentPath ~ "/" ~ node.source.name;
    output ~= AgentPsdLayoutEntry(
        node.source.name,
        path,
        node.source.sourceIndex,
        depth,
        node.source.kind == AgentPsdLayerKind.group
    );
    foreach (child; node.children) {
        appendLayout(output, child, depth + 1, path);
    }
}

/**
 * Converts PSD's flat layer/group marker sequence into stable layer paths.
 * The algorithm mirrors Photoshop's reverse-ordered group record layout but
 * does not construct any renderer or Creator GUI objects.
 */
AgentPsdLayoutEntry[] agentBuildPsdLayout(const(AgentPsdSourceLayer)[] sourceLayers) {
    LayoutNode[] roots;
    LayoutNode[] groupStack;

    foreach_reverse (source; sourceLayers) {
        if (source.kind == AgentPsdLayerKind.sectionDivider) {
            if (groupStack.length == 0) {
                throw new Exception("PSD has an unexpected closing layer group.");
            }

            auto completed = groupStack[$ - 1];
            groupStack.length--;
            if (groupStack.length > 0) {
                completed.parent = groupStack[$ - 1];
                groupStack[$ - 1].children ~= completed;
            } else {
                roots ~= completed;
            }
            continue;
        }

        auto node = new LayoutNode(
            source,
            groupStack.length > 0 ? groupStack[$ - 1] : null
        );
        if (source.kind == AgentPsdLayerKind.group) {
            groupStack ~= node;
        } else if (groupStack.length > 0) {
            groupStack[$ - 1].children ~= node;
        } else {
            roots ~= node;
        }
    }

    if (groupStack.length != 0) {
        throw new Exception("PSD has an unclosed layer group.");
    }

    AgentPsdLayoutEntry[] output;
    foreach (root; roots) {
        appendLayout(output, root, 0, "");
    }
    return output;
}

private ushort readBigEndianUshort(const(ubyte)[] bytes, ref size_t cursor, string label) {
    if (cursor + ushort.sizeof > bytes.length) {
        throw new Exception(format("Truncated %s.", label));
    }
    ubyte[ushort.sizeof] encoded = bytes[cursor .. cursor + ushort.sizeof];
    cursor += ushort.sizeof;
    return bigEndianToNative!ushort(encoded);
}

private ubyte[] decodePackBitsRow(const(ubyte)[] source, size_t expectedLength) {
    ubyte[] output;
    output.reserve(expectedLength);
    size_t cursor;

    while (output.length < expectedLength) {
        if (cursor >= source.length) {
            throw new Exception("Truncated PSD PackBits row.");
        }

        ubyte tag = source[cursor++];
        if (tag == 128) {
            continue;
        }

        if (tag <= 127) {
            size_t count = cast(size_t) tag + 1;
            if (cursor + count > source.length || output.length + count > expectedLength) {
                throw new Exception("Invalid PSD PackBits literal run.");
            }
            output ~= source[cursor .. cursor + count];
            cursor += count;
        } else {
            size_t count = 257 - cast(size_t) tag;
            if (cursor >= source.length || output.length + count > expectedLength) {
                throw new Exception("Invalid PSD PackBits repeated run.");
            }
            output.length += count;
            output[$ - count .. $] = source[cursor];
            cursor++;
        }
    }

    if (cursor != source.length) {
        throw new Exception("PSD PackBits row contains trailing bytes.");
    }
    return output;
}

/**
 * Safely decodes one PSD channel including its two-byte compression tag.
 * RAW and per-scanline PackBits/RLE are supported.
 */
ubyte[] agentDecodePsdChannel(
    const(ubyte)[] encoded,
    uint width,
    uint height
) {
    size_t pixelCount = cast(size_t) width * height;
    size_t cursor;
    ushort compression = readBigEndianUshort(encoded, cursor, "PSD channel compression");

    if (compression == 0) {
        if (encoded.length - cursor != pixelCount) {
            throw new Exception("PSD RAW channel has an invalid byte length.");
        }
        return encoded[cursor .. $].dup;
    }

    if (compression != 1) {
        throw new Exception(format("Unsupported PSD channel compression %s.", compression));
    }

    size_t[] rowLengths;
    rowLengths.length = height;
    foreach (row; 0 .. height) {
        rowLengths[row] = readBigEndianUshort(
            encoded,
            cursor,
            format("PSD RLE row %s length", row)
        );
    }

    ubyte[] output;
    output.reserve(pixelCount);
    foreach (row, rowLength; rowLengths) {
        if (cursor + rowLength > encoded.length) {
            throw new Exception(format("Truncated PSD RLE row %s.", row));
        }
        output ~= decodePackBitsRow(encoded[cursor .. cursor + rowLength], width);
        cursor += rowLength;
    }

    if (cursor != encoded.length || output.length != pixelCount) {
        throw new Exception("PSD RLE channel has trailing or missing data.");
    }
    return output;
}

/**
 * Composes RGBA without treating PSD layer/vector mask channels as colors.
 * Missing alpha means fully opaque, which matches Photoshop layer semantics.
 */
ubyte[] agentComposePsdRgba(
    const(ubyte)[] red,
    const(ubyte)[] green,
    const(ubyte)[] blue,
    const(ubyte)[] alpha,
    size_t pixelCount
) {
    if (
        red.length != pixelCount ||
        green.length != pixelCount ||
        blue.length != pixelCount ||
        (alpha.length != 0 && alpha.length != pixelCount)
    ) {
        throw new Exception("PSD color channel lengths do not match the layer bounds.");
    }

    ubyte[] rgba;
    rgba.length = pixelCount * 4;
    foreach (pixel; 0 .. pixelCount) {
        size_t offset = pixel * 4;
        rgba[offset] = red[pixel];
        rgba[offset + 1] = green[pixel];
        rgba[offset + 2] = blue[pixel];
        rgba[offset + 3] = alpha.length > 0 ? alpha[pixel] : 255;
    }
    return rgba;
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

private string colorModeName(ColorMode mode) {
    switch (mode) {
        case ColorMode.RGB:
            return "RGB";
        case ColorMode.Grayscale:
            return "Grayscale";
        case ColorMode.CMYK:
            return "CMYK";
        case ColorMode.Lab:
            return "Lab";
        default:
            return format("%s", cast(int) mode);
    }
}

/**
 * Parses and fully pixel-validates a PSD without SDL, OpenGL, ImGui, or an
 * Inochi2D Texture.  The source PSD is opened read-only.
 */
AgentPsdInspection agentInspectPsd(string path) {
    PSD document = parseDocument(path);
    if (document.bitsPerChannel != 8) {
        throw new Exception("Agent PSD inspection currently requires 8-bit channels.");
    }
    if (document.colorMode != ColorMode.RGB) {
        throw new Exception("Agent PSD inspection currently requires RGB color mode.");
    }

    AgentPsdSourceLayer[] sources;
    sources.length = document.layers.length;
    foreach (index, layer; document.layers) {
        sources[index] = AgentPsdSourceLayer(layer.name, layerKind(layer.type), index);
    }
    auto layout = agentBuildPsdLayout(sources);
    auto file = File(path, "rb");

    AgentPsdInspection inspection;
    inspection.sourcePath = path;
    inspection.width = document.width;
    inspection.height = document.height;
    inspection.bitsPerChannel = document.bitsPerChannel;
    inspection.documentChannels = cast(ushort) document.channels;
    inspection.colorMode = colorModeName(document.colorMode);
    inspection.sourceLayerRecordCount = document.layers.length;

    foreach (entry; layout) {
        auto layer = document.layers[entry.sourceIndex];
        AgentPsdLayerInspection result;
        result.name = entry.name;
        result.path = entry.path;
        result.sourceIndex = entry.sourceIndex;
        result.depth = entry.depth;
        result.isGroup = entry.isGroup;
        result.visible = (layer.flags & LayerFlags.Visible) == 0;
        result.left = layer.left;
        result.top = layer.top;
        result.width = layer.width;
        result.height = layer.height;
        result.channelCount = layer.channels.length;
        result.blendMode = cast(string) layer.blendModeKey;
        foreach (channel; layer.channels) {
            if (
                channel.type == ChannelType.LAYER_OR_VECTOR_MASK ||
                channel.type == ChannelType.LAYER_MASK
            ) {
                result.maskChannelCount++;
            }
        }

        if (entry.isGroup) {
            inspection.groupCount++;
            inspection.layers ~= result;
            continue;
        }

        inspection.leafLayerCount++;
        if (layer.width == 0 || layer.height == 0) {
            inspection.emptyLayerCount++;
            inspection.layers ~= result;
            continue;
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

        size_t pixelCount = cast(size_t) layer.width * layer.height;
        auto rgba = agentComposePsdRgba(red, green, blue, alpha, pixelCount);
        foreach (pixel; 0 .. pixelCount) {
            ubyte opacity = rgba[pixel * 4 + 3];
            if (opacity == 0) {
                result.transparentPixelCount++;
            } else if (opacity == 255) {
                result.opaquePixelCount++;
            } else {
                result.translucentPixelCount++;
            }
        }
        auto rgbaDigest = sha256Of(rgba);
        result.rgbaSha256 = rgbaDigest.toHexString!(LetterCase.lower).idup;
        result.pixelsDecoded = true;
        inspection.decodedLayerCount++;
        inspection.transparentPixelCount += result.transparentPixelCount;
        inspection.translucentPixelCount += result.translucentPixelCount;
        inspection.opaquePixelCount += result.opaquePixelCount;
        inspection.layers ~= result;
    }

    return inspection;
}

void agentWritePsdReport(string inputPath, string reportPath) {
    write(reportPath, agentInspectPsd(inputPath).toReportJson());
}
