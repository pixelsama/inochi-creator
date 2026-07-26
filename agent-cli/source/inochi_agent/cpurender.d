module inochi_agent.cpurender;

import std.algorithm : clamp, max, min, sort;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : mkdirRecurse, read, write;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, ceil, floor, isFinite;
import std.path : buildPath;
import std.string : replace, split;

import imagefmt : IF_ERROR, read_image, write_image;
import inochi2d : Node, Part, Puppet, inClearUUIDs, inInit, inLoadINPPuppet,
    inSetTimingFunc, inUpdate;
import inochi2d.core.nodes.common : MaskingMode;
import inochi2d.math : mat4, vec2, vec4;

import creator.agentcore.modelio : AgentTextureBlob, agentReadModelTextures;

struct AgentRenderPoseSummary {
    string name;
    string outputPath;
    size_t nonTransparentPixelCount;
    size_t physicsFrameCount;
    double[] physicsParameterValues;
    string rgbaSha256;

    JSONValue toJson() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["outputPath"] = JSONValue(outputPath);
        object["nonTransparentPixelCount"] = JSONValue(
            cast(ulong) nonTransparentPixelCount
        );
        object["physicsFrameCount"] = JSONValue(cast(ulong) physicsFrameCount);
        JSONValue[] physicsValues;
        foreach (value; physicsParameterValues) {
            physicsValues ~= JSONValue(value);
        }
        object["physicsParameterValues"] = JSONValue(physicsValues);
        object["rgbaSha256"] = JSONValue(rgbaSha256);
        return JSONValue(object);
    }
}

struct AgentRenderReport {
    int width;
    int height;
    size_t poseCount;
    AgentRenderPoseSummary[] poses;

    string toJson() const {
        JSONValue[] poseValues;
        foreach (pose; poses) poseValues ~= pose.toJson();

        JSONValue[string] object;
        object["width"] = JSONValue(width);
        object["height"] = JSONValue(height);
        object["poseCount"] = JSONValue(cast(ulong) poseCount);
        object["poses"] = JSONValue(poseValues);
        return JSONValue(object).toString();
    }
}

private struct DecodedTexture {
    int width;
    int height;
    ubyte[] rgba;
}

private struct RenderPart {
    Part part;
    size_t order;
}

private bool sdkInitialized;
private double renderClock;

private double renderClockValue() {
    return renderClock;
}

private double readNumber(JSONValue value, string label) {
    double result;
    final switch (value.type) {
        case JSONType.integer:
            result = cast(double) value.integer;
            break;
        case JSONType.uinteger:
            result = cast(double) value.uinteger;
            break;
        case JSONType.float_:
            result = value.floating;
            break;
        case JSONType.string:
        case JSONType.array:
        case JSONType.object:
        case JSONType.true_:
        case JSONType.false_:
        case JSONType.null_:
            throw new Exception(label ~ " must be a number.");
    }
    if (!isFinite(result)) {
        throw new Exception(label ~ " must be finite.");
    }
    return result;
}

private int readPositiveInteger(JSONValue value, string label) {
    double number = readNumber(value, label);
    int result = cast(int) number;
    if (number != result || result <= 0) {
        throw new Exception(label ~ " must be a positive integer.");
    }
    return result;
}

private string safeFilename(string value, size_t fallbackIndex) {
    auto result = value
        .replace("/", "_")
        .replace("\\", "_")
        .replace(":", "_")
        .replace(" ", "_");
    if (result.length == 0) result = format("pose_%s", fallbackIndex);
    return result;
}

private DecodedTexture decodeTexture(AgentTextureBlob blob) {
    auto image = read_image(blob.data, 4, 8);
    if (image.e != 0) {
        throw new Exception(
            format("Could not decode INX texture: %s.", IF_ERROR[image.e])
        );
    }
    scope (exit) image.free();

    DecodedTexture result;
    result.width = image.w;
    result.height = image.h;
    result.rgba = image.buf8.dup;
    return result;
}

private void collectRenderParts(
    Node node,
    ref RenderPart[] parts,
    ref size_t order
) {
    if (auto part = cast(Part) node) {
        parts ~= RenderPart(part, order++);
    }
    foreach (child; node.children) {
        collectRenderParts(child, parts, order);
    }
}

private float edge(vec2 a, vec2 b, vec2 p) {
    return (p.x - a.x) * (b.y - a.y) -
        (p.y - a.y) * (b.x - a.x);
}

private vec2 worldToPixel(vec4 world, int width, int height) {
    return vec2(
        world.x + width / 2.0f,
        world.y + height / 2.0f
    );
}

private ubyte[] sampleBilinear(
    ref DecodedTexture texture,
    float u,
    float v
) {
    u = clamp(u, 0.0f, 1.0f);
    v = clamp(v, 0.0f, 1.0f);
    float sourceX = u * max(texture.width - 1, 0);
    float sourceY = v * max(texture.height - 1, 0);
    int x0 = cast(int) floor(sourceX);
    int y0 = cast(int) floor(sourceY);
    int x1 = min(x0 + 1, texture.width - 1);
    int y1 = min(y0 + 1, texture.height - 1);
    float tx = sourceX - x0;
    float ty = sourceY - y0;

    ubyte[] result = new ubyte[4];
    foreach (channel; 0 .. 4) {
        float top = texture.rgba[(y0 * texture.width + x0) * 4 + channel] *
                (1 - tx) +
            texture.rgba[(y0 * texture.width + x1) * 4 + channel] * tx;
        float bottom = texture.rgba[(y1 * texture.width + x0) * 4 + channel] *
                (1 - tx) +
            texture.rgba[(y1 * texture.width + x1) * 4 + channel] * tx;
        result[channel] = cast(ubyte) clamp(
            cast(int) (top * (1 - ty) + bottom * ty + 0.5f),
            0,
            255
        );
    }
    return result;
}

private void blendPremultiplied(
    ref ubyte[] canvas,
    size_t pixelOffset,
    const(ubyte)[] source,
    float opacity
) {
    float opacityClamped = clamp(opacity, 0.0f, 1.0f);
    float sourceAlpha = source[3] / 255.0f * opacityClamped;
    if (sourceAlpha <= 0) return;

    float destinationAlpha = canvas[pixelOffset + 3] / 255.0f;
    float inverseSourceAlpha = 1 - sourceAlpha;
    foreach (channel; 0 .. 3) {
        float sourcePremultiplied = source[channel] / 255.0f * opacityClamped;
        float destinationPremultiplied = canvas[pixelOffset + channel] / 255.0f;
        canvas[pixelOffset + channel] = cast(ubyte) clamp(
            cast(int) (
                (sourcePremultiplied +
                    destinationPremultiplied * inverseSourceAlpha) *
                255 +
                0.5f
            ),
            0,
            255
        );
    }
    canvas[pixelOffset + 3] = cast(ubyte) clamp(
        cast(int) (
            (sourceAlpha + destinationAlpha * inverseSourceAlpha) * 255 +
            0.5f
        ),
        0,
        255
    );
}

private ubyte[] straightAlphaCopy(const(ubyte)[] premultiplied) {
    auto result = premultiplied.dup;
    foreach (pixel; 0 .. result.length / 4) {
        size_t offset = pixel * 4;
        int alpha = result[offset + 3];
        if (alpha == 0) {
            result[offset .. offset + 3] = 0;
            continue;
        }
        foreach (channel; 0 .. 3) {
            result[offset + channel] = cast(ubyte) clamp(
                (cast(int) result[offset + channel] * 255 + alpha / 2) / alpha,
                0,
                255
            );
        }
    }
    return result;
}

private void blendPremultipliedCanvas(
    ref ubyte[] destination,
    const(ubyte)[] source
) {
    if (destination.length != source.length) {
        throw new Exception("Premultiplied canvas dimensions do not match.");
    }
    foreach (pixel; 0 .. destination.length / 4) {
        size_t offset = pixel * 4;
        float sourceAlpha = source[offset + 3] / 255.0f;
        if (sourceAlpha <= 0) continue;
        float inverseSourceAlpha = 1 - sourceAlpha;
        foreach (channel; 0 .. 3) {
            float sourcePremultiplied = source[offset + channel] / 255.0f;
            float destinationPremultiplied =
                destination[offset + channel] / 255.0f;
            destination[offset + channel] = cast(ubyte) clamp(
                cast(int) (
                    (sourcePremultiplied +
                        destinationPremultiplied * inverseSourceAlpha) *
                    255 +
                    0.5f
                ),
                0,
                255
            );
        }
        float destinationAlpha = destination[offset + 3] / 255.0f;
        destination[offset + 3] = cast(ubyte) clamp(
            cast(int) (
                (sourceAlpha +
                    destinationAlpha * inverseSourceAlpha) *
                255 +
                0.5f
            ),
            0,
            255
        );
    }
}

private void renderTriangle(
    ref ubyte[] canvas,
    int width,
    int height,
    ref DecodedTexture texture,
    vec2 p0,
    vec2 p1,
    vec2 p2,
    vec2 uv0,
    vec2 uv1,
    vec2 uv2,
    float opacity
) {
    float area = edge(p0, p1, p2);
    if (abs(area) < 0.00001f) return;

    int minimumX = max(
        0,
        cast(int) floor(min(p0.x, min(p1.x, p2.x)))
    );
    int maximumX = min(
        width - 1,
        cast(int) ceil(max(p0.x, max(p1.x, p2.x)))
    );
    int minimumY = max(
        0,
        cast(int) floor(min(p0.y, min(p1.y, p2.y)))
    );
    int maximumY = min(
        height - 1,
        cast(int) ceil(max(p0.y, max(p1.y, p2.y)))
    );
    if (minimumX > maximumX || minimumY > maximumY) return;

    foreach (y; minimumY .. maximumY + 1) {
        foreach (x; minimumX .. maximumX + 1) {
            vec2 point = vec2(x + 0.5f, y + 0.5f);
            float w0 = edge(p1, p2, point) / area;
            float w1 = edge(p2, p0, point) / area;
            float w2 = edge(p0, p1, point) / area;
            if (w0 < -0.0001f || w1 < -0.0001f || w2 < -0.0001f) {
                continue;
            }

            float u = uv0.x * w0 + uv1.x * w1 + uv2.x * w2;
            float v = uv0.y * w0 + uv1.y * w1 + uv2.y * w2;
            auto sample = sampleBilinear(texture, u, v);
            blendPremultiplied(
                canvas,
                cast(size_t) (y * width + x) * 4,
                sample,
                opacity
            );
        }
    }
}

private void renderPartInto(
    ref ubyte[] canvas,
    Puppet puppet,
    Part part,
    ref DecodedTexture[] textures,
    int width,
    int height
) {
    if (!part.renderEnabled || part.textureIds.length == 0) return;
    int textureId = part.textureIds[0];
    if (textureId < 0 || textureId >= textures.length) {
        throw new Exception(
            format("Part '%s' references missing texture %s.", part.name, textureId)
        );
    }

    auto mesh = part.getMesh();
    if (
        mesh.vertices.length == 0 ||
        mesh.uvs.length != mesh.vertices.length ||
        part.deformation.length != mesh.vertices.length ||
        mesh.indices.length % 3 != 0
    ) {
        return;
    }
    mat4 matrix = puppet.transform.matrix * part.getDynamicMatrix();
    vec2[] pixelVertices;
    pixelVertices.length = mesh.vertices.length;
    foreach (index, vertex; mesh.vertices) {
        auto local = vertex - mesh.origin + part.deformation[index];
        pixelVertices[index] = worldToPixel(
            matrix * vec4(local, 0, 1),
            width,
            height
        );
    }

    float opacity = part.opacity * part.getValue("opacity");
    foreach (triangle; 0 .. mesh.indices.length / 3) {
        auto i0 = mesh.indices[triangle * 3];
        auto i1 = mesh.indices[triangle * 3 + 1];
        auto i2 = mesh.indices[triangle * 3 + 2];
        renderTriangle(
            canvas,
            width,
            height,
            textures[textureId],
            pixelVertices[i0],
            pixelVertices[i1],
            pixelVertices[i2],
            mesh.uvs[i0],
            mesh.uvs[i1],
            mesh.uvs[i2],
            opacity
        );
    }
}

private void applyPartMasks(
    ref ubyte[] target,
    Puppet puppet,
    Part part,
    ref DecodedTexture[] textures,
    int width,
    int height
) {
    if (part.masks.length == 0) return;

    bool hasPositiveMask;
    auto combined = new float[cast(size_t) width * height];
    combined[] = 0.0f;
    foreach (binding; part.masks) {
        auto maskPart = cast(Part) binding.maskSrc;
        if (maskPart is null) continue;
        auto maskCanvas = new ubyte[target.length];
        renderPartInto(
            maskCanvas,
            puppet,
            maskPart,
            textures,
            width,
            height
        );
        if (binding.mode == MaskingMode.Mask) {
            hasPositiveMask = true;
            foreach (pixel; 0 .. combined.length) {
                float alpha = maskCanvas[pixel * 4 + 3] / 255.0f;
                combined[pixel] =
                    1 - (1 - combined[pixel]) * (1 - alpha);
            }
        }
    }

    if (!hasPositiveMask) {
        foreach (ref value; combined) value = 1;
    }
    foreach (binding; part.masks) {
        if (binding.mode != MaskingMode.DodgeMask) continue;
        auto maskPart = cast(Part) binding.maskSrc;
        if (maskPart is null) continue;
        auto maskCanvas = new ubyte[target.length];
        renderPartInto(
            maskCanvas,
            puppet,
            maskPart,
            textures,
            width,
            height
        );
        foreach (pixel; 0 .. combined.length) {
            float alpha = maskCanvas[pixel * 4 + 3] / 255.0f;
            combined[pixel] *= 1 - alpha;
        }
    }

    foreach (pixel; 0 .. combined.length) {
        float alpha = clamp(combined[pixel], 0.0f, 1.0f);
        size_t offset = pixel * 4;
        foreach (channel; 0 .. 4) {
            target[offset + channel] = cast(ubyte) clamp(
                cast(int) (target[offset + channel] * alpha + 0.5f),
                0,
                255
            );
        }
    }
}

private ubyte[] renderPuppet(
    Puppet puppet,
    ref DecodedTexture[] textures,
    int width,
    int height
) {
    auto canvas = new ubyte[cast(size_t) width * height * 4];
    RenderPart[] parts;
    size_t order;
    collectRenderParts(puppet.root, parts, order);
    sort!((a, b) => a.part.zSort == b.part.zSort ?
        a.order < b.order : a.part.zSort > b.part.zSort)(parts);

    foreach (entry; parts) {
        auto part = entry.part;
        auto layer = new ubyte[canvas.length];
        renderPartInto(
            layer,
            puppet,
            part,
            textures,
            width,
            height
        );
        applyPartMasks(
            layer,
            puppet,
            part,
            textures,
            width,
            height
        );
        blendPremultipliedCanvas(canvas, layer);
    }
    return canvas;
}

private void setPoseParameters(
    Puppet puppet,
    JSONValue parameters,
    string label
) {
    if (parameters.type != JSONType.object) {
        throw new Exception(label ~ " requires a parameters object.");
    }
    foreach (name, value; parameters.object) {
        auto parameterIndex = puppet.findParameterIndex(name);
        if (parameterIndex < 0) {
            throw new Exception("Pose references unknown parameter '" ~ name ~ "'.");
        }
        auto parameter = puppet.parameters[parameterIndex];
        if (parameter.isVec2) {
            throw new Exception(
                "Pose rendering currently requires scalar parameter '" ~ name ~ "'."
            );
        }
        double requested = readNumber(value, "Pose parameter '" ~ name ~ "'");
        if (requested < parameter.min.x || requested > parameter.max.x) {
            throw new Exception(
                "Pose parameter '" ~ name ~ "' is outside its declared range."
            );
        }
        parameter.value.x = cast(float) requested;
        parameter.value.y = 0;
    }
}

private void applyPose(Puppet puppet, JSONValue pose, size_t poseIndex) {
    string label = format("Pose %s", poseIndex);
    if (pose.type != JSONType.object) {
        throw new Exception(label ~ " must be an object.");
    }
    if (
        !("name" in pose.object) ||
        pose["name"].type != JSONType.string ||
        pose["name"].str.length == 0
    ) {
        throw new Exception(label ~ " requires a non-empty string name.");
    }
    if (
        !("parameters" in pose.object) ||
        pose["parameters"].type != JSONType.object
    ) {
        throw new Exception(label ~ " requires a parameters object.");
    }

    foreach (parameter; puppet.parameters) parameter.value = parameter.defaults;
    setPoseParameters(
        puppet,
        pose["parameters"],
        label ~ " parameters"
    );
    puppet.update();
}

private size_t simulatePhysics(Puppet puppet, JSONValue pose, size_t poseIndex) {
    if (!("physics" in pose.object)) return 0;
    auto physics = pose["physics"];
    string label = format("Pose %s physics", poseIndex);
    if (physics.type != JSONType.object) {
        throw new Exception(label ~ " must be an object.");
    }
    size_t frames = 0;
    double dt = 1.0 / 60.0;
    if ("frames" in physics.object) {
        frames = cast(size_t) readPositiveInteger(
            physics["frames"],
            label ~ " frames"
        );
    }
    if ("dt" in physics.object) {
        dt = readNumber(physics["dt"], label ~ " dt");
        if (!isFinite(dt) || dt <= 0) {
            throw new Exception(label ~ " dt must be positive and finite.");
        }
    }
    if (frames == 0) return 0;

    puppet.resetDrivers();
    auto trajectory = physics.object.get("trajectory", JSONValue.init);
    if (
        trajectory.type != JSONType.null_ &&
        trajectory.type != JSONType.array
    ) {
        throw new Exception(label ~ " trajectory must be an array.");
    }
    if (
        trajectory.type == JSONType.array &&
        trajectory.array.length != frames
    ) {
        throw new Exception(label ~ " trajectory length must equal frames.");
    }
    foreach (frame; 0 .. frames) {
        if (trajectory.type == JSONType.array) {
            setPoseParameters(
                puppet,
                trajectory.array[frame],
                format("%s trajectory[%s]", label, frame)
            );
        }
        renderClock += dt;
        inUpdate();
        puppet.update();
    }
    return frames;
}

private double[] physicsParameterValues(Puppet puppet) {
    double[] values;
    foreach (parameter, driver; puppet.getParameterDrivers()) {
        values ~= parameter.value.x;
    }
    return values;
}

AgentRenderReport agentRenderPoses(
    string modelPath,
    JSONValue specification,
    string outputDirectory
) {
    if (
        specification.type != JSONType.object ||
        !("canvas" in specification.object) ||
        specification["canvas"].type != JSONType.object ||
        !("poses" in specification.object) ||
        specification["poses"].type != JSONType.array
    ) {
        throw new Exception(
            "Render specification requires a canvas object and poses array."
        );
    }
    auto canvas = specification["canvas"];
    if (
        !("width" in canvas.object) ||
        !("height" in canvas.object)
    ) {
        throw new Exception("Render canvas requires width and height.");
    }
    int width = readPositiveInteger(canvas["width"], "Canvas width");
    int height = readPositiveInteger(canvas["height"], "Canvas height");

    if (!sdkInitialized) {
        renderClock = 0;
        inInit(&renderClockValue);
        sdkInitialized = true;
    } else {
        inSetTimingFunc(&renderClockValue);
    }
    inClearUUIDs();
    Puppet puppet = inLoadINPPuppet!Puppet(cast(ubyte[]) read(modelPath));
    if (puppet is null || puppet.root is null) {
        throw new Exception("The Inochi2D SDK returned an empty puppet.");
    }
    puppet.transform.update();

    auto blobs = agentReadModelTextures(modelPath);
    DecodedTexture[] textures;
    textures.reserve(blobs.length);
    foreach (blob; blobs) textures ~= decodeTexture(blob);

    mkdirRecurse(outputDirectory);
    AgentRenderReport report;
    report.width = width;
    report.height = height;
    foreach (poseIndex, pose; specification["poses"].array) {
        applyPose(puppet, pose, poseIndex);
        auto physicsFrameCount = simulatePhysics(puppet, pose, poseIndex);
        auto premultiplied = renderPuppet(puppet, textures, width, height);
        auto rgba = straightAlphaCopy(premultiplied);
        string filename = format(
            "%02s_%s.png",
            poseIndex,
            safeFilename(pose["name"].str, poseIndex)
        );
        string outputPath = buildPath(outputDirectory, filename);
        auto error = write_image(outputPath, width, height, rgba, 4);
        if (error != 0) {
            throw new Exception(
                format("Could not write pose PNG '%s': %s.", outputPath, IF_ERROR[error])
            );
        }

        AgentRenderPoseSummary poseSummary;
        poseSummary.name = pose["name"].str;
        poseSummary.outputPath = outputPath;
        poseSummary.physicsFrameCount = physicsFrameCount;
        poseSummary.physicsParameterValues = physicsParameterValues(puppet);
        foreach (pixel; 0 .. rgba.length / 4) {
            if (rgba[pixel * 4 + 3] > 0) poseSummary.nonTransparentPixelCount++;
        }
        poseSummary.rgbaSha256 = sha256Of(rgba)
            .toHexString!(LetterCase.lower)
            .idup;
        report.poses ~= poseSummary;
        report.poseCount++;
    }
    return report;
}
