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
import inochi2d : Composite, Node, Part, Puppet, inClearUUIDs, inInit, inLoadINPPuppet,
    inSetTimingFunc, inUpdate;
import inochi2d.core.nodes.common : BlendMode, MaskingMode;
import inochi2d.core.animation.player : AnimationPlayer;
import inochi2d.math : mat4, vec2, vec4;

import creator.agentcore.modelio : AgentTextureBlob, agentReadModelTextures, agentReadModelPayload;
import inochi_agent.poseinput : agentSetPoseParameters;

struct AgentRenderPoseSummary {
    string name;
    string outputPath;
    size_t nonTransparentPixelCount;
    size_t physicsFrameCount;
    double[] physicsParameterValues;
    double[2][string] physicsParameters;
    string rgbaSha256;
    string[] frameOutputPaths;

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
        JSONValue[string] namedPhysics;
        foreach (name, value; physicsParameters) {
            namedPhysics[name] = JSONValue([JSONValue(value[0]), JSONValue(value[1])]);
        }
        object["physicsParameters"] = JSONValue(namedPhysics);
        object["rgbaSha256"] = JSONValue(rgbaSha256);
        JSONValue[] frames;
        foreach (path; frameOutputPaths) frames ~= JSONValue(path);
        object["frameOutputPaths"] = JSONValue(frames);
        return JSONValue(object);
    }
}

struct AgentRenderReport {
    int width;
    int height;
    int supersample = 1;
    size_t poseCount;
    AgentRenderPoseSummary[] poses;
    string[] legacyBlendFallbacks;

    string toJson() const {
        JSONValue[] poseValues;
        foreach (pose; poses) poseValues ~= pose.toJson();

        JSONValue[string] object;
        object["width"] = JSONValue(width);
        object["height"] = JSONValue(height);
        object["supersample"] = JSONValue(supersample);
        object["poseCount"] = JSONValue(cast(ulong) poseCount);
        object["poses"] = JSONValue(poseValues);
        JSONValue[] fallbackPaths;
        foreach (path; legacyBlendFallbacks) fallbackPaths ~= JSONValue(path);
        // These modes render as Normal on macOS OpenGL (no advanced blending).
        object["legacyBlendFallbacks"] = JSONValue(fallbackPaths);
        return JSONValue(object).toString();
    }
}

private struct MipLevel {
    int width;
    int height;
    float[] rgba; // premultiplied, 0..1
}

private struct DecodedTexture {
    int width;
    int height;
    MipLevel[] levels;
}

// Each mip level spans the same UV range, so odd sizes need area-weighted
// resampling (a plain 2x2 box drifts by up to a texel across the image).
private float[] reduceAxis(const(float)[] source, int width, int height, int newWidth, bool horizontal) {
    int count = horizontal ? width : height, newCount = newWidth;
    int other = horizontal ? height : width;
    auto result = new float[cast(size_t)(horizontal ? newCount * height : width * newCount) * 4];
    double ratio = cast(double) count / newCount;
    foreach (o; 0 .. other) foreach (n; 0 .. newCount) {
        double start = n * ratio, end = (n + 1) * ratio;
        float[4] sum = 0;
        for (int k = cast(int) floor(start); k < end && k < count; k++) {
            double weight = min(end, k + 1.0) - max(start, cast(double) k);
            if (weight <= 0) continue;
            size_t index = horizontal ? (cast(size_t) o * width + k) : (cast(size_t) k * width + o);
            foreach (c; 0 .. 4) sum[c] += source[index * 4 + c] * weight;
        }
        size_t outIndex = horizontal ? (cast(size_t) o * newCount + n) : (cast(size_t) n * width + o);
        foreach (c; 0 .. 4) result[outIndex * 4 + c] = cast(float)(sum[c] / ratio);
    }
    return result;
}

private MipLevel[] buildMipChain(int width, int height, const(ubyte)[] rgba) {
    MipLevel base = MipLevel(width, height, new float[rgba.length]);
    foreach (i, v; rgba) base.rgba[i] = v / 255.0f;
    MipLevel[] levels = [base];
    while (levels[$ - 1].width > 1 || levels[$ - 1].height > 1) {
        auto previous = levels[$ - 1];
        int w = max(1, previous.width / 2), h = max(1, previous.height / 2);
        auto horizontal = reduceAxis(previous.rgba, previous.width, previous.height, w, true);
        levels ~= MipLevel(w, h, reduceAxis(horizontal, w, previous.height, h, false));
    }
    return levels;
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
    result.levels = buildMipChain(image.w, image.h, image.buf8);
    return result;
}

private float edge(vec2 a, vec2 b, vec2 p) {
    return (p.x - a.x) * (b.y - a.y) -
        (p.y - a.y) * (b.x - a.x);
}

// Inochi2D Camera: pixel = (world + position) * scale + viewport / 2.
private float viewScale = 1;
private vec2 viewPosition = vec2(0, 0);

private vec2 worldToPixel(vec4 world, int width, int height, int rasterScale) {
    return vec2(
        (world.x + viewPosition.x) * viewScale * rasterScale + width / 2.0f,
        (world.y + viewPosition.y) * viewScale * rasterScale + height / 2.0f
    );
}

// GL_LINEAR on one level with texel-center addressing. Textures use
// GL_CLAMP_TO_BORDER with a transparent border, so edges fade to zero.
private float[4] sampleLevel(ref MipLevel level, float u, float v) {
    float sx = u * level.width - 0.5f, sy = v * level.height - 0.5f;
    int x0 = cast(int) floor(sx), y0 = cast(int) floor(sy);
    float tx = sx - x0, ty = sy - y0;
    float[4] result = 0;
    foreach (dy; 0 .. 2) foreach (dx; 0 .. 2) {
        int x = x0 + dx, y = y0 + dy;
        if (x < 0 || y < 0 || x >= level.width || y >= level.height) continue;
        float weight = (dx ? tx : 1 - tx) * (dy ? ty : 1 - ty);
        size_t o = (cast(size_t) y * level.width + x) * 4;
        foreach (c; 0 .. 4) result[c] += level.rgba[o + c] * weight;
    }
    return result;
}

// GL_LINEAR_MIPMAP_LINEAR minification, GL_LINEAR magnification.
private float[4] sampleTexture(ref DecodedTexture texture, float u, float v, float lod) {
    if (lod <= 0) return sampleLevel(texture.levels[0], u, v);
    float top = texture.levels.length - 1;
    if (lod >= top) return sampleLevel(texture.levels[$ - 1], u, v);
    int lower = cast(int) floor(lod);
    float t = lod - lower;
    auto a = sampleLevel(texture.levels[lower], u, v);
    auto b = sampleLevel(texture.levels[lower + 1], u, v);
    float[4] result;
    foreach (c; 0 .. 4) result[c] = a[c] * (1 - t) + b[c] * t;
    return result;
}

// Premultiplied float RGBA plus fragment coverage. GL blending only touches
// pixels a triangle actually rasterizes, which matters for modes such as
// DestinationIn that would otherwise erase everything outside the part.
private struct Layer {
    float[] rgba;
    bool[] covered;
    int width, height;
    // Inclusive bounds of every pixel written since the last reset; empty
    // when x0 > x1. Parts usually touch a small part of the canvas.
    int x0 = int.max, y0 = int.max, x1 = -1, y1 = -1;

    this(int width, int height) {
        this.width = width;
        this.height = height;
        rgba = new float[cast(size_t) width * height * 4];
        rgba[] = 0;
        covered = new bool[cast(size_t) width * height];
    }

    void mark(int x, int y) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
    }

    void reset() {
        foreach (y; max(y0, 0) .. y1 + 1) {
            size_t start = cast(size_t) y * width + x0, end = cast(size_t) y * width + x1 + 1;
            covered[start .. end] = false;
            rgba[start * 4 .. end * 4] = 0;
        }
        x0 = y0 = int.max;
        x1 = y1 = -1;
    }
}

// Scratch layers reused across parts; clearing only dirty bounds avoids a
// full-canvas allocation per part and mask.
private Layer scratchPart, scratchMask;

private ref Layer scratch(ref Layer layer, int width, int height) {
    if (layer.width != width || layer.height != height) layer = Layer(width, height);
    else layer.reset();
    return layer;
}

private struct ShaderColor {
    float opacity = 1;
    float[3] tint = [1, 1, 1];
    float[3] screen = [0, 0, 0];
}

// Mirrors Part.setupShaderStage / Composite.drawSelf: multiplicative tint and
// opacity are clamped products, screen tint is a clamped sum.
private ShaderColor partShaderColor(Part part) {
    ShaderColor c;
    c.opacity = clamp(part.opacity * part.getValue("opacity"), 0.0f, 1.0f);
    foreach (i, key; ["tint.r", "tint.g", "tint.b"])
        c.tint[i] = clamp(part.tint.vector[i] * part.getValue(key), 0.0f, 1.0f);
    foreach (i, key; ["screenTint.r", "screenTint.g", "screenTint.b"])
        c.screen[i] = clamp(part.screenTint.vector[i] + part.getValue(key), 0.0f, 1.0f);
    return c;
}

private ShaderColor compositeShaderColor(Composite composite) {
    ShaderColor c;
    c.opacity = clamp(composite.opacity * composite.getValue("opacity"), 0.0f, 1.0f);
    foreach (i, key; ["tint.r", "tint.g", "tint.b"])
        c.tint[i] = clamp(composite.tint.vector[i] * composite.getValue(key), 0.0f, 1.0f);
    foreach (i, key; ["screenTint.r", "screenTint.g", "screenTint.b"])
        c.screen[i] = clamp(composite.screenTint.vector[i] + composite.getValue(key), 0.0f, 1.0f);
    return c;
}

// basic.frag / composite.frag: screen(tex.rgb, a) * multColor * opacity on
// premultiplied texels.
private void shade(ref float[4] texel, ShaderColor c) {
    float a = texel[3];
    foreach (i; 0 .. 3) {
        float screened = 1 - (1 - texel[i]) * (1 - c.screen[i] * a);
        texel[i] = screened * c.tint[i] * c.opacity;
    }
    texel[3] = a * c.opacity;
}

/** Blend modes as the macOS OpenGL runtime draws them. Without
 * KHR_blend_equation_advanced, Inochi2D uses fixed-function legacy blending
 * and Overlay, Darken, ColorBurn, HardLight, SoftLight and Difference fall
 * back to Normal. The GPU framebuffer clamps every write to [0,1]. */
private void blendPixel(float[] d, const(float)[] s, BlendMode mode) {
    float[4] o;
    final switch (mode) {
        case BlendMode.Multiply:
            foreach (i; 0 .. 3) o[i] = s[i] * d[i] + d[i] * (1 - s[3]);
            o[3] = s[3] * d[3] + d[3] * (1 - s[3]);
            break;
        case BlendMode.Screen:
        case BlendMode.LinearDodge:
            foreach (i; 0 .. 3) o[i] = s[i] + d[i] * (1 - s[i]);
            o[3] = s[3] + d[3] * (1 - s[3]);
            break;
        case BlendMode.Lighten:
            foreach (i; 0 .. 4) o[i] = max(s[i], d[i]);
            break;
        case BlendMode.ColorDodge:
            foreach (i; 0 .. 4) o[i] = s[i] * d[i] + d[i];
            break;
        case BlendMode.AddGlow:
            foreach (i; 0 .. 3) o[i] = s[i] + d[i];
            o[3] = s[3] + d[3] * (1 - s[3]);
            break;
        case BlendMode.Subtract:
            foreach (i; 0 .. 3) o[i] = d[i] - s[i] * (1 - d[i]);
            o[3] = s[3] * (1 - d[3]) + d[3];
            break;
        case BlendMode.Exclusion:
            foreach (i; 0 .. 3) o[i] = s[i] * (1 - d[i]) + d[i] * (1 - s[i]);
            o[3] = s[3] + d[3];
            break;
        case BlendMode.Inverse:
            foreach (i; 0 .. 4) o[i] = s[i] * (1 - d[i]) + d[i] * (1 - s[3]);
            break;
        case BlendMode.DestinationIn:
            foreach (i; 0 .. 4) o[i] = d[i] * s[3];
            break;
        case BlendMode.ClipToLower:
            foreach (i; 0 .. 4) o[i] = s[i] * d[3] + d[i] * (1 - s[3]);
            break;
        case BlendMode.SliceFromLower:
            foreach (i; 0 .. 4) o[i] = d[i] * (1 - s[3]);
            break;
        case BlendMode.Normal:
        case BlendMode.Overlay:
        case BlendMode.Darken:
        case BlendMode.ColorBurn:
        case BlendMode.HardLight:
        case BlendMode.SoftLight:
        case BlendMode.Difference:
            foreach (i; 0 .. 4) o[i] = s[i] + d[i] * (1 - s[3]);
            break;
    }
    foreach (i; 0 .. 4) d[i] = clamp(o[i], 0.0f, 1.0f);
}

bool agentIsLegacyBlendFallback(BlendMode mode) {
    return mode == BlendMode.Overlay || mode == BlendMode.Darken || mode == BlendMode.ColorBurn ||
        mode == BlendMode.HardLight || mode == BlendMode.SoftLight || mode == BlendMode.Difference;
}

private void blendLayer(ref float[] destination, ref Layer layer, BlendMode mode, bool fullCoverage = false) {
    if (fullCoverage) {
        foreach (pixel; 0 .. layer.covered.length)
            blendPixel(destination[pixel * 4 .. pixel * 4 + 4], layer.rgba[pixel * 4 .. pixel * 4 + 4], mode);
        return;
    }
    foreach (y; max(layer.y0, 0) .. layer.y1 + 1) foreach (x; layer.x0 .. layer.x1 + 1) {
        size_t pixel = cast(size_t) y * layer.width + x;
        if (!layer.covered[pixel]) continue;
        blendPixel(destination[pixel * 4 .. pixel * 4 + 4], layer.rgba[pixel * 4 .. pixel * 4 + 4], mode);
    }
}

private void renderTriangle(
    ref Layer layer,
    int width,
    int height,
    ref DecodedTexture texture,
    vec2 p0,
    vec2 p1,
    vec2 p2,
    vec2 uv0,
    vec2 uv1,
    vec2 uv2,
    ShaderColor color
) {
    // Coverage ties follow OpenGL, whose window y axis points up: edge tests
    // run in flipped coordinates so a pixel center exactly on an edge lands
    // on the same side as on the GPU (visible with odd canvas sizes).
    vec2 flip(vec2 p) { return vec2(p.x, height - p.y); }
    vec2 q0 = flip(p0), q1 = flip(p1), q2 = flip(p2);
    float area = edge(q0, q1, q2);
    if (abs(area) < 0.00001f) return;
    if (area < 0) {
        auto point = p1; p1 = p2; p2 = point;
        auto flipped = q1; q1 = q2; q2 = flipped;
        auto uv = uv1; uv1 = uv2; uv2 = uv;
        area = -area;
    }
    bool topLeft(vec2 a, vec2 b) {
        return b.y > a.y || (b.y == a.y && b.x < a.x);
    }

    int minimumX = max(0, cast(int) floor(min(p0.x, min(p1.x, p2.x))));
    int maximumX = min(width - 1, cast(int) ceil(max(p0.x, max(p1.x, p2.x))));
    int minimumY = max(0, cast(int) floor(min(p0.y, min(p1.y, p2.y))));
    int maximumY = min(height - 1, cast(int) ceil(max(p0.y, max(p1.y, p2.y))));
    if (minimumX > maximumX || minimumY > maximumY) return;

    // Affine triangles have constant UV derivatives; the mip level follows
    // the GL scale factor rho = max(|d(uv*size)/dx|, |d(uv*size)/dy|).
    import std.math : log2, sqrt;
    float d = (p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y);
    float dudx = ((uv1.x - uv0.x) * (p2.y - p0.y) - (uv2.x - uv0.x) * (p1.y - p0.y)) / d;
    float dudy = ((uv2.x - uv0.x) * (p1.x - p0.x) - (uv1.x - uv0.x) * (p2.x - p0.x)) / d;
    float dvdx = ((uv1.y - uv0.y) * (p2.y - p0.y) - (uv2.y - uv0.y) * (p1.y - p0.y)) / d;
    float dvdy = ((uv2.y - uv0.y) * (p1.x - p0.x) - (uv1.y - uv0.y) * (p2.x - p0.x)) / d;
    float rhoX = sqrt((dudx * texture.width) ^^ 2 + (dvdx * texture.height) ^^ 2);
    float rhoY = sqrt((dudy * texture.width) ^^ 2 + (dvdy * texture.height) ^^ 2);
    float rho = max(rhoX, rhoY);
    float lod = rho > 0 && isFinite(rho) ? log2(rho) : 0;

    foreach (y; minimumY .. maximumY + 1) {
        foreach (x; minimumX .. maximumX + 1) {
            vec2 point = vec2(x + 0.5f, height - (y + 0.5f));
            float e0 = edge(q1, q2, point);
            float e1 = edge(q2, q0, point);
            float e2 = edge(q0, q1, point);
            // Each shared edge belongs to exactly one triangle. Inclusive
            // barycentric tests blend semi-transparent mesh diagonals twice.
            if (e0 < 0 || (e0 == 0 && !topLeft(q1, q2)) ||
                e1 < 0 || (e1 == 0 && !topLeft(q2, q0)) ||
                e2 < 0 || (e2 == 0 && !topLeft(q0, q1))) {
                continue;
            }
            float w0 = e0 / area, w1 = e1 / area, w2 = e2 / area;

            float u = uv0.x * w0 + uv1.x * w1 + uv2.x * w2;
            float v = uv0.y * w0 + uv1.y * w1 + uv2.y * w2;
            auto texel = sampleTexture(texture, u, v, lod);
            shade(texel, color);
            size_t pixel = cast(size_t) y * width + x;
            blendPixel(layer.rgba[pixel * 4 .. pixel * 4 + 4], texel[], BlendMode.Normal);
            layer.covered[pixel] = true;
            layer.mark(x, y);
        }
    }
}

private void renderPartInto(
    ref Layer layer,
    Puppet puppet,
    Part part,
    ref DecodedTexture[] textures,
    int width,
    int height,
    int rasterScale,
    bool rawAlpha = false
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
            height,
            rasterScale
        );
    }

    auto color = rawAlpha ? ShaderColor.init : partShaderColor(part);
    foreach (triangle; 0 .. mesh.indices.length / 3) {
        auto i0 = mesh.indices[triangle * 3];
        auto i1 = mesh.indices[triangle * 3 + 1];
        auto i2 = mesh.indices[triangle * 3 + 2];
        renderTriangle(
            layer,
            width,
            height,
            textures[textureId],
            pixelVertices[i0],
            pixelVertices[i1],
            pixelVertices[i2],
            mesh.uvs[i0],
            mesh.uvs[i1],
            mesh.uvs[i2],
            color
        );
    }
}

// Part.renderMask draws the mask source's raw texture alpha into the stencil
// buffer, discarding samples at or below its mask_threshold. Stencil starts at
// 0 when any positive mask exists (else 1); masks are drawn in order, positive
// ones writing 1 and dodge masks writing 0. Content draws where the stencil is
// 1. Supersampling antialiases the binary result. Only the target's written
// bounds matter, since nothing else of the part can be drawn.
private void applyPartMasks(
    ref Layer target,
    Puppet puppet,
    Part part,
    ref DecodedTexture[] textures,
    int width,
    int height,
    int rasterScale
) {
    if (part.masks.length == 0 || target.x0 > target.x1) return;
    bool hasPositiveMask;
    foreach (binding; part.masks) if (binding.mode == MaskingMode.Mask) hasPositiveMask = true;
    int boundsWidth = target.x1 - target.x0 + 1;
    auto stencil = new bool[cast(size_t) boundsWidth * (target.y1 - target.y0 + 1)];
    stencil[] = !hasPositiveMask;
    foreach (binding; part.masks) {
        auto maskPart = cast(Part) binding.maskSrc;
        if (maskPart is null) continue;
        auto mask = &scratch(scratchMask, width, height);
        renderPartInto(*mask, puppet, maskPart, textures, width, height, rasterScale, true);
        float threshold = clamp(maskPart.maskAlphaThreshold + maskPart.getValue("alphaThreshold"), 0.0f, 1.0f);
        bool value = binding.mode == MaskingMode.Mask;
        foreach (y; target.y0 .. target.y1 + 1) foreach (x; target.x0 .. target.x1 + 1) {
            size_t pixel = cast(size_t) y * width + x;
            if (mask.covered[pixel] && mask.rgba[pixel * 4 + 3] > threshold)
                stencil[(y - target.y0) * boundsWidth + (x - target.x0)] = value;
        }
    }
    foreach (y; target.y0 .. target.y1 + 1) foreach (x; target.x0 .. target.x1 + 1) {
        if (stencil[(y - target.y0) * boundsWidth + (x - target.x0)]) continue;
        size_t pixel = cast(size_t) y * width + x;
        target.covered[pixel] = false;
        target.rgba[pixel * 4 .. pixel * 4 + 4] = 0;
    }
}

private struct RenderEntry {
    Node node;
    size_t order;
}

// Puppet.scanPartsRecurse: Parts and Composites are root drawables; a
// Composite owns every Part below it.
private void collectRootDrawables(Node node, ref RenderEntry[] entries, ref size_t order) {
    if (auto composite = cast(Composite) node) {
        entries ~= RenderEntry(composite, order++);
        return;
    }
    if (auto part = cast(Part) node) entries ~= RenderEntry(part, order++);
    foreach (child; node.children) collectRootDrawables(child, entries, order);
}

private void collectCompositeParts(Node node, ref RenderEntry[] entries, ref size_t order) {
    if (auto part = cast(Part) node) entries ~= RenderEntry(part, order++);
    foreach (child; node.children) collectCompositeParts(child, entries, order);
}

private void sortByZ(ref RenderEntry[] entries) {
    sort!((a, b) => a.node.zSort == b.node.zSort ?
        a.order < b.order : a.node.zSort > b.node.zSort)(entries);
}

private void drawPart(
    ref float[] destination, Puppet puppet, Part part, ref DecodedTexture[] textures,
    int width, int height, int rasterScale
) {
    auto layer = &scratch(scratchPart, width, height);
    renderPartInto(*layer, puppet, part, textures, width, height, rasterScale);
    applyPartMasks(*layer, puppet, part, textures, width, height, rasterScale);
    blendLayer(destination, *layer, part.blendingMode);
}

private float[] renderPuppet(
    Puppet puppet,
    ref DecodedTexture[] textures,
    int width,
    int height,
    int rasterScale
) {
    size_t pixels = cast(size_t) width * height;
    auto canvas = new float[pixels * 4];
    canvas[] = 0;
    RenderEntry[] entries;
    size_t order;
    collectRootDrawables(puppet.root, entries, order);
    sortByZ(entries);

    foreach (entry; entries) {
        if (auto part = cast(Part) entry.node) {
            drawPart(canvas, puppet, part, textures, width, height, rasterScale);
            continue;
        }
        auto composite = cast(Composite) entry.node;
        if (!composite.renderEnabled) continue;
        RenderEntry[] members;
        size_t memberOrder;
        foreach (child; composite.children) collectCompositeParts(child, members, memberOrder);
        if (members.length == 0) continue;
        sortByZ(members);
        auto offscreen = Layer(width, height);
        foreach (member; members)
            drawPart(offscreen.rgba, puppet, cast(Part) member.node, textures, width, height, rasterScale);
        // The composite quad covers the whole framebuffer.
        auto color = compositeShaderColor(composite);
        foreach (pixel; 0 .. pixels) {
            float[4] texel = offscreen.rgba[pixel * 4 .. pixel * 4 + 4];
            shade(texel, color);
            offscreen.rgba[pixel * 4 .. pixel * 4 + 4] = texel[];
        }
        blendLayer(canvas, offscreen, composite.blendingMode, true);
    }
    return canvas;
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

// Box filtering premultiplied channels prevents transparent edge colors from
// darkening the final straight-alpha PNG. Raster scale never changes SDK state.
private ubyte[] downsamplePremultiplied(
    float[] source, int width, int height, int scale
) {
    auto result = new ubyte[cast(size_t) width * height * 4];
    int sourceWidth = width * scale;
    float count = scale * scale;
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        float[4] sum = 0;
        foreach (dy; 0 .. scale) foreach (dx; 0 .. scale) {
            size_t sourceOffset = (cast(size_t)(y * scale + dy) * sourceWidth + x * scale + dx) * 4;
            foreach (channel; 0 .. 4) sum[channel] += source[sourceOffset + channel];
        }
        size_t offset = (cast(size_t)y * width + x) * 4;
        foreach (channel; 0 .. 4)
            result[offset + channel] = cast(ubyte) clamp(cast(int)(sum[channel] / count * 255 + 0.5f), 0, 255);
    }
    return result;
}

private void setPoseParameters(
    Puppet puppet,
    JSONValue parameters,
    string label
) {
    agentSetPoseParameters(puppet, parameters, label);
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
    // Static poses evaluate all explicit parameters, including driven axes.
    // Only simulatePhysics advances automation and physics state.
    puppet.root.beginUpdate();
    foreach (parameter; puppet.parameters) parameter.update();
    puppet.root.transformChanged();
    puppet.root.update();
}

/// Reads the optional physics.capture_every stride (0 = final frame only).
private size_t captureStride(JSONValue pose, size_t poseIndex) {
    if (!("physics" in pose.object) || pose["physics"].type != JSONType.object) return 0;
    auto physics = pose["physics"];
    if (!("capture_every" in physics.object)) return 0;
    return cast(size_t) readPositiveInteger(
        physics["capture_every"],
        format("Pose %s physics capture_every", poseIndex)
    );
}

private size_t simulatePhysics(
    Puppet puppet,
    JSONValue pose,
    size_t poseIndex,
    void delegate(size_t frame) onFrame = null
) {
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

    // An embedded animation plays through the SDK AnimationPlayer, in the
    // same order as the runtime: player update, then puppet update.
    AnimationPlayer player;
    if ("animation" in physics.object) {
        auto request = physics["animation"];
        if (request.type != JSONType.object || !("name" in request.object) || request["name"].type != JSONType.string)
            throw new Exception(label ~ " animation must be an object with a name.");
        foreach (key, ignored; request.object)
            if (key != "name" && key != "loop") throw new Exception(label ~ " animation has unknown field '" ~ key ~ "'.");
        bool loop = "loop" in request.object && request["loop"].type == JSONType.true_;
        player = new AnimationPlayer(puppet);
        auto playback = player.createOrGet(request["name"].str);
        if (playback is null)
            throw new Exception(label ~ " animation '" ~ request["name"].str ~ "' is not in the model.");
        playback.play(loop);
    }

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
        if (player !is null) player.update(dt);
        puppet.update();
        if (onFrame !is null) onFrame(frame);
    }
    return frames;
}

private double[2][string] namedPhysicsParameters(Puppet puppet) {
    double[2][string] values;
    foreach (parameter, driver; puppet.getParameterDrivers()) {
        values[parameter.name] = [cast(double)parameter.value.x, cast(double)parameter.value.y];
    }
    return values;
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
    // This renderer is an explicit subset of the GPU runtime. Reject assets
    // we cannot faithfully preview, rather than silently producing wrong art.
    auto payload = agentReadModelPayload(modelPath);
    string[] fallbacks;
    void checkNode(JSONValue node, string path) {
        string type = node.object.get("type", JSONValue("Node")).str;
        if (type != "Node" && type != "Part" && type != "SimplePhysics" && type != "MeshGroup" && type != "Composite")
            throw new Exception("CPU renderer does not support node type '" ~ type ~ "'; use the GPU runtime.");
        if (type == "Composite" && node.object.get("masks", JSONValue.emptyArray).array.length)
            throw new Exception("CPU renderer does not support masked Composites; use the GPU runtime.");
        if (type == "Part" || type == "Composite") {
            import std.conv : to;
            auto mode = node.object.get("blend_mode", JSONValue("Normal")).str;
            try {
                if (agentIsLegacyBlendFallback(mode.to!BlendMode)) fallbacks ~= path;
            } catch (Exception) throw new Exception("Unknown blend mode '" ~ mode ~ "' at " ~ path ~ ".");
        }
        foreach (child; node.object.get("children", JSONValue.emptyArray).array)
            checkNode(child, path ~ "/" ~ child.object.get("name", JSONValue("")).str);
    }
    checkNode(payload["nodes"], "");
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
    int supersample = 1;
    if ("supersample" in canvas.object)
        supersample = readPositiveInteger(canvas["supersample"], "Canvas supersample");
    if (supersample > 4)
        throw new Exception("Canvas supersample must be an integer from 1 to 4.");
    viewScale = 1;
    viewPosition = vec2(0, 0);
    if ("camera" in canvas.object) {
        auto camera = canvas["camera"];
        if (camera.type != JSONType.object) throw new Exception("Canvas camera must be an object.");
        foreach (key, ignored; camera.object)
            if (key != "scale" && key != "position") throw new Exception("Canvas camera has unknown field '" ~ key ~ "'.");
        if ("scale" in camera.object) {
            viewScale = cast(float) readNumber(camera["scale"], "Camera scale");
            if (!(viewScale > 0) || !isFinite(viewScale)) throw new Exception("Camera scale must be positive.");
        }
        if ("position" in camera.object) {
            auto position = camera["position"];
            if (position.type != JSONType.array || position.array.length != 2)
                throw new Exception("Camera position must contain [x,y].");
            viewPosition = vec2(cast(float) readNumber(position[0], "Camera position x"),
                cast(float) readNumber(position[1], "Camera position y"));
        }
    }
    scope (exit) { viewScale = 1; viewPosition = vec2(0, 0); }
    if (cast(ulong)width * height > 16_777_216UL / (supersample * supersample))
        throw new Exception("CPU raster exceeds 16777216 pixels including supersampling; reduce canvas size or supersample.");

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
    report.supersample = supersample;
    report.legacyBlendFallbacks = fallbacks;
    ubyte[] renderTo(string outputPath) {
        auto raster = renderPuppet(
            puppet, textures, width * supersample, height * supersample, supersample);
        auto premultiplied = downsamplePremultiplied(raster, width, height, supersample);
        auto rgba = straightAlphaCopy(premultiplied);
        auto error = write_image(outputPath, width, height, rgba, 4);
        if (error != 0) {
            throw new Exception(
                format("Could not write pose PNG '%s': %s.", outputPath, IF_ERROR[error])
            );
        }
        return rgba;
    }

    foreach (poseIndex, pose; specification["poses"].array) {
        applyPose(puppet, pose, poseIndex);
        string stem = format("%02s_%s", poseIndex, safeFilename(pose["name"].str, poseIndex));
        // capture_every renders intermediate simulation frames in one pass,
        // so a motion preview costs one simulation instead of one per frame.
        size_t stride = captureStride(pose, poseIndex);
        string[] framePaths;
        void captureFrame(size_t frame) {
            if ((frame + 1) % stride != 0) return;
            string framePath = buildPath(outputDirectory, format("%s_f%05s.png", stem, frame + 1));
            renderTo(framePath);
            framePaths ~= framePath;
        }
        auto physicsFrameCount = simulatePhysics(
            puppet, pose, poseIndex, stride > 0 ? &captureFrame : null);
        string outputPath = buildPath(outputDirectory, stem ~ ".png");
        auto rgba = renderTo(outputPath);

        AgentRenderPoseSummary poseSummary;
        poseSummary.frameOutputPaths = framePaths;
        poseSummary.name = pose["name"].str;
        poseSummary.outputPath = outputPath;
        poseSummary.physicsFrameCount = physicsFrameCount;
        poseSummary.physicsParameterValues = physicsParameterValues(puppet);
        poseSummary.physicsParameters = namedPhysicsParameters(puppet);
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
