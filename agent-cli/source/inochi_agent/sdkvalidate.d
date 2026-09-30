module inochi_agent.sdkvalidate;

import std.algorithm : max;
import std.file : read;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, isFinite;
import std.string : split;

import inochi2d : Composite, Drawable, MeshGroup, Node, Part, Puppet, inClearUUIDs, inInit, inLoadINPPuppet;
import inochi2d.core.param : DeformationParameterBinding;
import inochi2d.core.nodes.defstack : Deformation;
import inochi2d.fmt.serialize : inToJson;
import inochi2d.math : vec2, vec2u, vec4;
import inochi2d.integration : inCurrentPuppetTextureSlots;
import inochi_agent.poseinput : agentSetPoseParameters;

struct AgentSdkValidationSummary {
    string name;
    size_t partCount;
    size_t textureSlotCount;
    size_t textureReferenceCount;
    size_t driverCount;
    size_t drivenParameterCount;
    size_t animationCount;
    size_t animationLaneCount;

    string toJson() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["partCount"] = JSONValue(cast(ulong) partCount);
        object["textureSlotCount"] = JSONValue(cast(ulong) textureSlotCount);
        object["textureReferenceCount"] = JSONValue(cast(ulong) textureReferenceCount);
        object["driverCount"] = JSONValue(cast(ulong) driverCount);
        object["drivenParameterCount"] = JSONValue(cast(ulong) drivenParameterCount);
        object["animationCount"] = JSONValue(cast(ulong) animationCount);
        object["animationLaneCount"] = JSONValue(cast(ulong) animationLaneCount);
        return JSONValue(object).toString();
    }
}

struct AgentPoseProbeSummary {
    string path;
    double translationX;
    double translationY;
    double rotationZ;
    double scaleX;
    double scaleY;
    double opacity = 1;
    double zSort = 0;
    double[3] tint = [1, 1, 1];
    double[3] screenTint = [0, 0, 0];
    double deformationMagnitude = 0;
    size_t deformationVertexCount;
    double declaredDeformationMagnitude = 0;
    size_t declaredDeformationVertexCount;
    size_t deformationBindingCount;
    JSONValue[] worldVertices;
    JSONValue[] vertexOffsets;
    size_t flippedTriangleCount;
    size_t collapsedTriangleCount;

    private static double finiteOrZero(double value) {
        if (!isFinite(value)) throw new Exception("Pose probe contains a non-finite value.");
        return value;
    }

    JSONValue toJson() const {
        JSONValue[string] object;
        object["path"] = JSONValue(path);
        object["translationX"] = JSONValue(finiteOrZero(translationX));
        object["translationY"] = JSONValue(finiteOrZero(translationY));
        object["rotationZ"] = JSONValue(finiteOrZero(rotationZ));
        object["scaleX"] = JSONValue(finiteOrZero(scaleX));
        object["scaleY"] = JSONValue(finiteOrZero(scaleY));
        object["opacity"] = JSONValue(finiteOrZero(opacity));
        object["zSort"] = JSONValue(finiteOrZero(zSort));
        object["tint"] = JSONValue([JSONValue(finiteOrZero(tint[0])), JSONValue(finiteOrZero(tint[1])), JSONValue(finiteOrZero(tint[2]))]);
        object["screenTint"] = JSONValue([JSONValue(finiteOrZero(screenTint[0])),
            JSONValue(finiteOrZero(screenTint[1])), JSONValue(finiteOrZero(screenTint[2]))]);
        object["deformationMagnitude"] = JSONValue(finiteOrZero(deformationMagnitude));
        object["deformationVertexCount"] = JSONValue(cast(ulong) deformationVertexCount);
        object["declaredDeformationMagnitude"] = JSONValue(finiteOrZero(declaredDeformationMagnitude));
        object["declaredDeformationVertexCount"] = JSONValue(cast(ulong) declaredDeformationVertexCount);
        object["deformationBindingCount"] = JSONValue(cast(ulong) deformationBindingCount);
        object["worldVertices"] = JSONValue(worldVertices.dup);
        object["vertexOffsets"] = JSONValue(vertexOffsets.dup);
        object["flippedTriangleCount"] = JSONValue(cast(ulong) flippedTriangleCount);
        object["collapsedTriangleCount"] = JSONValue(cast(ulong) collapsedTriangleCount);
        return JSONValue(object);
    }
}

struct AgentPoseSummary {
    string name;
    AgentPoseProbeSummary[] probes;

    JSONValue toJson() const {
        JSONValue[] probeValues;
        foreach (probe; probes) probeValues ~= probe.toJson();

        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["probes"] = JSONValue(probeValues);
        return JSONValue(object);
    }
}

struct AgentPoseReport {
    size_t poseCount;
    size_t probeCount;
    AgentPoseSummary[] poses;

    string toJson() const {
        JSONValue[] poseValues;
        foreach (pose; poses) poseValues ~= pose.toJson();

        JSONValue[string] object;
        object["poseCount"] = JSONValue(cast(ulong) poseCount);
        object["probeCount"] = JSONValue(cast(ulong) probeCount);
        object["poses"] = JSONValue(poseValues);
        return JSONValue(object).toString();
    }
}

private bool sdkInitialized;

/**
 * Loads an INX through the official Inochi2D SDK's renderless configuration.
 * This verifies SDK deserialization, node type registration, mesh data, and
 * texture-slot references without creating an OpenGL context or a window.
 */
AgentSdkValidationSummary agentValidateWithSdk(string path) {
    if (!sdkInitialized) {
        inInit(() => 0.0);
        sdkInitialized = true;
    }

    inClearUUIDs();
    Puppet puppet = inLoadINPPuppet!Puppet(cast(ubyte[]) read(path));
    if (puppet is null || puppet.root is null) {
        throw new Exception("The Inochi2D SDK returned an empty puppet.");
    }

    AgentSdkValidationSummary summary;
    summary.name = puppet.meta.name;
    auto parts = puppet.getAllParts();
    summary.partCount = parts.length;
    summary.textureSlotCount = inCurrentPuppetTextureSlots.length;
    foreach (Part part; parts) {
        foreach (textureId; part.textureIds) {
            if (textureId < 0 || textureId >= summary.textureSlotCount) {
                throw new Exception("A Part references an invalid INX texture slot.");
            }
            summary.textureReferenceCount++;
        }
    }
    summary.driverCount = puppet.getDrivers().length;
    summary.drivenParameterCount = puppet.getParameterDrivers().length;
    foreach (name, ref animation; puppet.getAnimations()) {
        foreach (lane; animation.lanes) {
            // finalize() resolves each lane's parameter UUID; a miss would crash playback.
            if (lane.paramRef is null || lane.paramRef.targetParam is null)
                throw new Exception("Animation '" ~ name ~ "' has a lane without a resolvable parameter.");
            summary.animationLaneCount++;
        }
        summary.animationCount++;
    }
    return summary;
}

private Node findChildByName(Node parent, string name) {
    foreach (child; parent.children) {
        if (child.name == name) return child;
    }
    return null;
}

private Node findNodePath(Node root, string path) {
    if (path.length == 0 || path[0] != '/') {
        throw new Exception("Pose probe paths must start with '/'.");
    }

    Node current = root;
    auto pieces = path[1 .. $].split("/");
    foreach (pieceIndex, piece; pieces) {
        if (piece.length == 0) {
            throw new Exception("Pose probe paths may not contain empty segments.");
        }
        if (pieceIndex == 0 && piece == root.name) continue;
        current = findChildByName(current, piece);
        if (current is null) {
            throw new Exception("Could not find pose probe path '" ~ path ~ "'.");
        }
    }
    return current;
}

private double readPoseNumber(JSONValue value, string label) {
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
            throw new Exception(label ~ " must be a number.");
    }
}

private AgentPoseProbeSummary sampleProbe(
    Node node,
    string path,
    Puppet puppet
) {
    auto transform = node.transform;
    AgentPoseProbeSummary result;
    result.path = path;
    // The SDK's composed Transform.translation is derived from (1,1,1,1),
    // not the local origin. Probe the matrix used by rendering instead.
    auto origin = transform.matrix * vec4(0, 0, 0, 1);
    result.translationX = origin.x;
    result.translationY = origin.y;
    result.rotationZ = transform.rotation.z;
    result.scaleX = transform.scale.x;
    result.scaleY = transform.scale.y;

    result.zSort = node.zSort;
    // Effective shader colors, clamped as the runtime clamps them.
    void colors(float opacity, float[3] tint, float[3] screen) {
        import std.algorithm : clamp;
        result.opacity = clamp(opacity * node.getValue("opacity"), 0.0f, 1.0f);
        foreach (i, key; ["tint.r", "tint.g", "tint.b"]) result.tint[i] = clamp(tint[i] * node.getValue(key), 0.0f, 1.0f);
        foreach (i, key; ["screenTint.r", "screenTint.g", "screenTint.b"])
            result.screenTint[i] = clamp(screen[i] + node.getValue(key), 0.0f, 1.0f);
    }
    if (auto p = cast(Part) node) colors(p.opacity, p.tint.vector, p.screenTint.vector);
    if (auto c = cast(Composite) node) colors(c.opacity, c.tint.vector, c.screenTint.vector);
    // Parts and MeshGroup cages are both Drawables with sampled geometry.
    if (auto part = cast(Drawable) node) {
        result.deformationVertexCount = part.deformation.length;
        auto mesh = part.getMesh();
        if (part.deformation.length != mesh.vertices.length)
            throw new Exception("Pose deformation does not match mesh vertex count.");
        auto matrix = puppet.transform.matrix * part.getDynamicMatrix();
        vec2[] posed;
        foreach (i, vertex; mesh.vertices) {
            auto offset = part.deformation[i];
            if (!offset.isFinite) throw new Exception("Non-finite vertex deformation at " ~ path);
            posed ~= vertex + offset;
            auto world = matrix * vec4(vertex - mesh.origin + offset, 0, 1);
            if (!isFinite(world.x) || !isFinite(world.y)) throw new Exception("Non-finite world vertex at " ~ path);
            result.worldVertices ~= JSONValue([JSONValue(cast(double)world.x), JSONValue(cast(double)world.y)]);
            result.vertexOffsets ~= JSONValue([JSONValue(cast(double)offset.x), JSONValue(cast(double)offset.y)]);
        }
        double area(vec2 a, vec2 b, vec2 c) {
            return (cast(double)b.x-a.x)*(cast(double)c.y-a.y) - (cast(double)b.y-a.y)*(cast(double)c.x-a.x);
        }
        foreach (t; 0 .. mesh.indices.length / 3) {
            auto a = mesh.indices[t*3], b = mesh.indices[t*3+1], c = mesh.indices[t*3+2];
            if (a >= posed.length || b >= posed.length || c >= posed.length)
                throw new Exception("Pose mesh triangle index is out of range.");
            double before = area(mesh.vertices[a], mesh.vertices[b], mesh.vertices[c]);
            double after = area(posed[a], posed[b], posed[c]);
            if (abs(after) <= 1e-8) result.collapsedTriangleCount++;
            else if (before * after < 0) result.flippedTriangleCount++;
        }
        foreach (offset; part.deformation) {
            if (offset.isFinite) {
                result.deformationMagnitude += abs(offset.x) + abs(offset.y);
            }
        }
        foreach (parameter; puppet.parameters) {
            foreach (binding; parameter.bindings) {
                if (binding.getNode() !is node || binding.getName() != "deform") continue;
                result.deformationBindingCount++;
                auto deformBinding = cast(DeformationParameterBinding) binding;
                if (deformBinding is null) continue;
                foreach (x; 0 .. parameter.axisPointCount(0)) foreach (y; 0 .. parameter.axisPointCount(1)) {
                    ref value = deformBinding.getValue(vec2u(cast(uint) x, cast(uint) y));
                    result.declaredDeformationVertexCount = value.vertexOffsets.size;
                    foreach (offset; value.vertexOffsets) {
                        if (offset.isFinite) {
                            result.declaredDeformationMagnitude += abs(offset.x) + abs(offset.y);
                        }
                    }
                }
            }
        }
    }
    return result;
}

/**
 * Applies parameter values in a pose specification and samples the official
 * SDK's resulting node state without creating a renderer or editor window.
 *
 * The specification shape is:
 * {
 *   "poses": [
 *     {"name":"left", "parameters":{"EyeX":-1}, "probes":["/Eyes/Iris"]}
 *   ]
 * }
 */
AgentPoseReport agentSamplePoses(string modelPath, JSONValue specification) {
    if (
        specification.type != JSONType.object ||
        !("poses" in specification.object) ||
        specification["poses"].type != JSONType.array
    ) {
        throw new Exception("Pose specification requires a 'poses' array.");
    }

    if (!sdkInitialized) {
        inInit(() => 0.0);
        sdkInitialized = true;
    }

    inClearUUIDs();
    Puppet puppet = inLoadINPPuppet!Puppet(cast(ubyte[]) read(modelPath));
    if (puppet is null || puppet.root is null) {
        throw new Exception("The Inochi2D SDK returned an empty puppet.");
    }

    AgentPoseReport report;
    foreach (poseIndex, pose; specification["poses"].array) {
        string poseLabel = format("Pose %s", poseIndex);
        if (pose.type != JSONType.object) {
            throw new Exception(poseLabel ~ " must be an object.");
        }
        if (!("name" in pose.object) || pose["name"].type != JSONType.string) {
            throw new Exception(poseLabel ~ " requires a string name.");
        }
        if (!("parameters" in pose.object) || pose["parameters"].type != JSONType.object) {
            throw new Exception(poseLabel ~ " requires a parameters object.");
        }
        auto probes = pose.object.get("probes", JSONValue.init);
        if (probes.type == JSONType.null_) {
            JSONValue[] paths;
            void collect(Node node, string parent, bool root = false) {
                auto path = root ? "" : parent ~ "/" ~ node.name;
                if (cast(Part)node || cast(MeshGroup)node) paths ~= JSONValue(path);
                foreach (child; node.children) collect(child, path);
            }
            collect(puppet.root, "", true);
            probes = JSONValue(paths);
        }
        if (probes.type != JSONType.array) throw new Exception(poseLabel ~ " probes must be an array.");

        foreach (parameter; puppet.parameters) {
            parameter.value = parameter.defaults;
        }
        agentSetPoseParameters(puppet, pose["parameters"], poseLabel);
        // Pose sampling is intentionally deterministic: apply declared
        // parameters without running automation or physics drivers.
        puppet.root.beginUpdate();
        foreach (parameter; puppet.parameters) {
            parameter.update();
        }
        puppet.root.transformChanged();
        puppet.root.update();

        AgentPoseSummary poseSummary;
        poseSummary.name = pose["name"].str;
        foreach (probeValue; probes.array) {
            if (probeValue.type != JSONType.string) {
                throw new Exception(poseLabel ~ " probe paths must be strings.");
            }
            auto probePath = probeValue.str;
            poseSummary.probes ~= sampleProbe(
                findNodePath(puppet.root, probePath),
                probePath,
                puppet
            );
            report.probeCount++;
        }
        report.poses ~= poseSummary;
        report.poseCount++;
    }
    return report;
}

unittest {
    import fghj : deserialize;
    auto source = Deformation([vec2(1, 2), vec2(-3, 4)]);
    auto encoded = inToJson(source);
    auto decoded = deserialize!Deformation(encoded);
    assert(decoded.vertexOffsets.size == 2);
    assert(decoded.vertexOffsets[0] == vec2(1, 2));
    assert(decoded.vertexOffsets[1] == vec2(-3, 4));
}
