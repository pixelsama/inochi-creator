module inochi_agent.sdkvalidate;

import std.algorithm : max;
import std.file : read;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.math : abs, isFinite;
import std.string : split;

import inochi2d : Node, Part, Puppet, inClearUUIDs, inInit, inLoadINPPuppet;
import inochi2d.core.param : DeformationParameterBinding;
import inochi2d.core.nodes.defstack : Deformation;
import inochi2d.fmt.serialize : inToJson;
import inochi2d.math : vec2, vec2u;
import inochi2d.integration : inCurrentPuppetTextureSlots;

struct AgentSdkValidationSummary {
    string name;
    size_t partCount;
    size_t textureSlotCount;
    size_t textureReferenceCount;

    string toJson() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["partCount"] = JSONValue(cast(ulong) partCount);
        object["textureSlotCount"] = JSONValue(cast(ulong) textureSlotCount);
        object["textureReferenceCount"] = JSONValue(cast(ulong) textureReferenceCount);
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
    double deformationMagnitude = 0;
    size_t deformationVertexCount;
    double declaredDeformationMagnitude = 0;
    size_t declaredDeformationVertexCount;
    size_t deformationBindingCount;

    private static double finiteOrZero(double value) {
        return isFinite(value) ? value : 0;
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
        object["deformationMagnitude"] = JSONValue(finiteOrZero(deformationMagnitude));
        object["deformationVertexCount"] = JSONValue(cast(ulong) deformationVertexCount);
        object["declaredDeformationMagnitude"] = JSONValue(finiteOrZero(declaredDeformationMagnitude));
        object["declaredDeformationVertexCount"] = JSONValue(cast(ulong) declaredDeformationVertexCount);
        object["deformationBindingCount"] = JSONValue(cast(ulong) deformationBindingCount);
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
    result.translationX = transform.translation.x;
    result.translationY = transform.translation.y;
    result.rotationZ = transform.rotation.z;
    result.scaleX = transform.scale.x;
    result.scaleY = transform.scale.y;

    if (auto part = cast(Part) node) {
        result.opacity = node.getValue("opacity");
        result.deformationVertexCount = part.deformation.length;
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
                foreach (x; 0 .. parameter.axisPointCount(0)) {
                    ref value = deformBinding.getValue(vec2u(cast(uint) x, 0));
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
        if (!("probes" in pose.object) || pose["probes"].type != JSONType.array) {
            throw new Exception(poseLabel ~ " requires a probes array.");
        }

        foreach (parameter; puppet.parameters) {
            parameter.value = parameter.defaults;
        }
        foreach (name, value; pose["parameters"].object) {
            auto parameterIndex = puppet.findParameterIndex(name);
            if (parameterIndex < 0) {
                throw new Exception("Pose references unknown parameter '" ~ name ~ "'.");
            }
            auto parameter = puppet.parameters[parameterIndex];
            if (parameter.isVec2) {
                throw new Exception(
                    "Pose sampling currently requires scalar parameter '" ~ name ~ "'."
                );
            }
            double requested = readPoseNumber(value, "Pose parameter '" ~ name ~ "'");
            if (requested < parameter.min.x || requested > parameter.max.x) {
                throw new Exception(
                    "Pose parameter '" ~ name ~ "' is outside its declared range."
                );
            }
            parameter.value.x = cast(float) requested;
            parameter.value.y = 0;
        }
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
        foreach (probeValue; pose["probes"].array) {
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
