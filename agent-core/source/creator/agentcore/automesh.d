module creator.agentcore.automesh;

import std.algorithm : max, min;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, ceil, floor, isFinite, sqrt;

/** Options for generating a Part mesh from its texture alpha. Distances are
 * texture pixels. Every pixel whose alpha reaches `alphaThreshold`, plus its
 * one-pixel bilinear filtering footprint, is covered by an output triangle;
 * `margin` extends the silhouette beyond that footprint so later deformation
 * does not expose the texture's cut line. */
struct AgentAutoMeshOptions {
    double spacing = 16;
    int alphaThreshold = 8;
    double margin = 2;
    size_t maxVertices = 4000;
}

struct AgentAutoMeshResult {
    double[] pixelPoints; // x,y pairs in texture pixel space
    size_t[] indices;
    size_t coveredPixelCount;
}

private struct Point { double x, y; }
private struct Triangle { size_t a, b, c; double cx, cy, r2; }

private Triangle makeTriangle(const(Point)[] points, size_t a, size_t b, size_t c) {
    auto pa = points[a], pb = points[b], pc = points[c];
    double d = 2 * (pa.x * (pb.y - pc.y) + pb.x * (pc.y - pa.y) + pc.x * (pa.y - pb.y));
    Triangle t = Triangle(a, b, c, 0, 0, double.infinity);
    if (abs(d) < 1e-12) return t;
    double a2 = pa.x * pa.x + pa.y * pa.y;
    double b2 = pb.x * pb.x + pb.y * pb.y;
    double c2 = pc.x * pc.x + pc.y * pc.y;
    t.cx = (a2 * (pb.y - pc.y) + b2 * (pc.y - pa.y) + c2 * (pa.y - pb.y)) / d;
    t.cy = (a2 * (pc.x - pb.x) + b2 * (pa.x - pc.x) + c2 * (pb.x - pa.x)) / d;
    t.r2 = (pa.x - t.cx) * (pa.x - t.cx) + (pa.y - t.cy) * (pa.y - t.cy);
    return t;
}

/** Bowyer-Watson Delaunay triangulation. The input is small (a few thousand
 * points), so the quadratic scan keeps the implementation easy to audit. */
private size_t[] delaunay(Point[] input) {
    Point[] points = input.dup;
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    foreach (p; points) {
        minX = min(minX, p.x); minY = min(minY, p.y);
        maxX = max(maxX, p.x); maxY = max(maxY, p.y);
    }
    double span = max(maxX - minX, maxY - minY) + 1;
    double midX = (minX + maxX) / 2, midY = (minY + maxY) / 2;
    size_t s0 = points.length;
    points ~= Point(midX - 20 * span, midY - span);
    points ~= Point(midX, midY + 20 * span);
    points ~= Point(midX + 20 * span, midY - span);
    Triangle[] triangles = [makeTriangle(points, s0, s0 + 1, s0 + 2)];

    foreach (index; 0 .. s0) {
        auto p = points[index];
        size_t[2][] edges;
        Triangle[] kept;
        kept.reserve(triangles.length);
        foreach (t; triangles) {
            double dx = p.x - t.cx, dy = p.y - t.cy;
            // Points exactly on a circumcircle stay outside; the triangulation
            // remains valid and co-circular grids do not flip-flop.
            if (dx * dx + dy * dy < t.r2 * (1 - 1e-12)) {
                edges ~= [t.a, t.b]; edges ~= [t.b, t.c]; edges ~= [t.c, t.a];
            } else kept ~= t;
        }
        // Boundary edges of the cavity appear once; shared edges twice.
        size_t[2][] boundary;
        foreach (i, e; edges) {
            bool shared_;
            foreach (j, f; edges) {
                if (i != j && ((e[0] == f[0] && e[1] == f[1]) || (e[0] == f[1] && e[1] == f[0]))) {
                    shared_ = true;
                    break;
                }
            }
            if (!shared_) boundary ~= e;
        }
        foreach (e; boundary) kept ~= makeTriangle(points, e[0], e[1], index);
        triangles = kept;
    }

    size_t[] result;
    foreach (t; triangles) {
        if (t.a >= s0 || t.b >= s0 || t.c >= s0) continue;
        result ~= [t.a, t.b, t.c];
    }
    return result;
}

private double cross(Point a, Point b, Point p) {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

private bool containsPoint(Point a, Point b, Point c, Point p) {
    double d0 = cross(a, b, p), d1 = cross(b, c, p), d2 = cross(c, a, p);
    bool negative = d0 < -1e-9 || d1 < -1e-9 || d2 < -1e-9;
    bool positive = d0 > 1e-9 || d1 > 1e-9 || d2 > 1e-9;
    return !(negative && positive);
}

/** Generates a triangulation in texture pixel coordinates. `premultipliedRgba`
 * is the INX texture as stored. Throws when the texture has no pixel at the
 * threshold or when the requested density would exceed `maxVertices`. */
AgentAutoMeshResult agentGenerateAutoMesh(
    const(ubyte)[] rgba, int width, int height, AgentAutoMeshOptions options
) {
    if (width <= 0 || height <= 0 || rgba.length != cast(size_t)width * height * 4)
        throw new Exception("Auto mesh texture dimensions do not match its pixels.");
    if (!isFinite(options.spacing) || options.spacing < 2)
        throw new Exception("Auto mesh spacing must be at least 2 pixels.");
    if (!isFinite(options.margin) || options.margin < 0 || options.margin > 256)
        throw new Exception("Auto mesh margin must be in [0,256] pixels.");
    if (options.alphaThreshold < 1 || options.alphaThreshold > 255)
        throw new Exception("Auto mesh alpha_threshold must be in [1,255].");

    size_t pixels = cast(size_t)width * height;
    auto opaque = new bool[pixels];
    size_t opaqueCount;
    foreach (i; 0 .. pixels) {
        if (rgba[i * 4 + 3] >= options.alphaThreshold) { opaque[i] = true; opaqueCount++; }
    }
    if (opaqueCount == 0)
        throw new Exception(format("Auto mesh found no pixel with alpha >= %s.", options.alphaThreshold));

    // Chamfer distance (3-4) from the opaque region; within margin is inside.
    enum double far = 1e18;
    auto distance = new double[pixels];
    foreach (i; 0 .. pixels) distance[i] = opaque[i] ? 0 : far;
    void relax(int x, int y, int nx, int ny, double cost) {
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) return;
        auto candidate = distance[ny * width + nx] + cost;
        if (candidate < distance[y * width + x]) distance[y * width + x] = candidate;
    }
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        relax(x, y, x - 1, y, 1); relax(x, y, x, y - 1, 1);
        relax(x, y, x - 1, y - 1, 1.3333); relax(x, y, x + 1, y - 1, 1.3333);
    }
    foreach_reverse (y; 0 .. height) foreach_reverse (x; 0 .. width) {
        relax(x, y, x + 1, y, 1); relax(x, y, x, y + 1, 1);
        relax(x, y, x + 1, y + 1, 1.3333); relax(x, y, x - 1, y + 1, 1.3333);
    }
    // Linear texture filtering reaches one texel past every visible pixel, so
    // that footprint must be rendered exactly like the original quad.
    enum double footprint = 1.34;
    auto required = new bool[pixels];
    size_t requiredCount;
    foreach (i; 0 .. pixels) if (distance[i] <= footprint) { required[i] = true; requiredCount++; }
    auto inside = new bool[pixels];
    foreach (i; 0 .. pixels) inside[i] = distance[i] <= footprint + options.margin;
    bool insidePixel(int x, int y) {
        return x >= 0 && y >= 0 && x < width && y < height && inside[y * width + x];
    }

    // Points live on pixel corners so each covered square has exact corners.
    // A corner is on the boundary when it touches both inside and outside.
    Point[] points;
    auto cellSize = options.spacing;
    int gridColumns = cast(int)ceil((width + 1) / cellSize) + 1;
    int gridRows = cast(int)ceil((height + 1) / cellSize) + 1;
    size_t[][] buckets;
    buckets.length = cast(size_t)gridColumns * gridRows;
    bool farFrom(Point p, double radius) {
        int bx = cast(int)(p.x / cellSize), by = cast(int)(p.y / cellSize);
        foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
            int cx = bx + dx, cy = by + dy;
            if (cx < 0 || cy < 0 || cx >= gridColumns || cy >= gridRows) continue;
            foreach (index; buckets[cy * gridColumns + cx]) {
                auto q = points[index];
                if ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y) < radius * radius) return false;
            }
        }
        return true;
    }
    void addPoint(Point p) {
        int bx = cast(int)(p.x / cellSize), by = cast(int)(p.y / cellSize);
        buckets[by * gridColumns + bx] ~= points.length;
        points ~= p;
        if (points.length > options.maxVertices)
            throw new Exception(format(
                "Auto mesh exceeds max_vertices %s; increase spacing.", options.maxVertices));
    }

    double boundarySpacing = options.spacing / 2;
    foreach (y; 0 .. height + 1) foreach (x; 0 .. width + 1) {
        bool any, all = true;
        foreach (dy; -1 .. 1) foreach (dx; -1 .. 1) {
            bool v = insidePixel(x + dx, y + dy);
            any |= v; all &= v;
        }
        if (any && !all) {
            auto p = Point(x, y);
            if (farFrom(p, boundarySpacing)) addPoint(p);
        }
    }
    for (double y = cellSize / 2; y < height; y += cellSize) {
        for (double x = cellSize / 2; x < width; x += cellSize) {
            auto p = Point(floor(x), floor(y));
            if (!insidePixel(cast(int)p.x, cast(int)p.y)) continue;
            if (farFrom(p, options.spacing * 0.6)) addPoint(p);
        }
    }

    AgentAutoMeshResult result;
    foreach (attempt; 0 .. 4) {
        auto triangles = delaunay(points);
        size_t[] kept;
        auto covered = new bool[pixels];
        foreach (t; 0 .. triangles.length / 3) {
            auto a = points[triangles[t * 3]], b = points[triangles[t * 3 + 1]], c = points[triangles[t * 3 + 2]];
            if (abs(cross(a, b, c)) < 1e-9) continue;
            auto centroid = Point((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3);
            bool keep = insidePixel(cast(int)floor(centroid.x), cast(int)floor(centroid.y));
            int x0 = max(0, cast(int)floor(min(a.x, min(b.x, c.x))));
            int x1 = min(width - 1, cast(int)ceil(max(a.x, max(b.x, c.x))));
            int y0 = max(0, cast(int)floor(min(a.y, min(b.y, c.y))));
            int y1 = min(height - 1, cast(int)ceil(max(a.y, max(b.y, c.y))));
            bool[] local;
            foreach (py; y0 .. y1 + 1) foreach (px; x0 .. x1 + 1) {
                if (!containsPoint(a, b, c, Point(px + 0.5, py + 0.5))) continue;
                if (required[py * width + px]) keep = true;
            }
            if (!keep) continue;
            kept ~= [triangles[t * 3], triangles[t * 3 + 1], triangles[t * 3 + 2]];
            foreach (py; y0 .. y1 + 1) foreach (px; x0 .. x1 + 1)
                if (containsPoint(a, b, c, Point(px + 0.5, py + 0.5))) covered[py * width + px] = true;
        }
        size_t missing;
        foreach (i; 0 .. pixels) {
            if (!required[i] || covered[i]) continue;
            missing++;
            int px = cast(int)(i % width), py = cast(int)(i / width);
            foreach (corner; [Point(px, py), Point(px + 1, py), Point(px, py + 1), Point(px + 1, py + 1)])
                if (farFrom(corner, 0.5)) addPoint(corner);
        }
        if (missing == 0) {
            // Drop unused points and remap indices.
            auto remap = new ptrdiff_t[points.length];
            remap[] = -1;
            foreach (index; kept) {
                if (remap[index] < 0) {
                    remap[index] = cast(ptrdiff_t)(result.pixelPoints.length / 2);
                    result.pixelPoints ~= [points[index].x, points[index].y];
                }
                result.indices ~= cast(size_t)remap[index];
            }
            result.coveredPixelCount = requiredCount;
            return result;
        }
    }
    throw new Exception("Auto mesh could not cover every opaque pixel; reduce spacing.");
}

/** Reads optional auto mesh fields. Unknown fields are rejected by the caller. */
AgentAutoMeshOptions agentReadAutoMeshOptions(JSONValue request) {
    AgentAutoMeshOptions options;
    double number(string key, double fallback) {
        if (!(key in request.object)) return fallback;
        auto v = request[key];
        double n = v.type == JSONType.integer ? v.integer
            : v.type == JSONType.uinteger ? v.uinteger
            : v.type == JSONType.float_ ? v.floating
            : double.nan;
        if (!isFinite(n)) throw new Exception("Auto mesh '" ~ key ~ "' must be a finite number.");
        return n;
    }
    options.spacing = number("spacing", options.spacing);
    options.margin = number("margin", options.margin);
    double threshold = number("alpha_threshold", options.alphaThreshold);
    if (threshold != floor(threshold)) throw new Exception("Auto mesh alpha_threshold must be an integer.");
    options.alphaThreshold = cast(int)threshold;
    double limit = number("max_vertices", options.maxVertices);
    if (limit != floor(limit) || limit < 3 || limit > 65536)
        throw new Exception("Auto mesh max_vertices must be an integer in [3,65536].");
    options.maxVertices = cast(size_t)limit;
    return options;
}
