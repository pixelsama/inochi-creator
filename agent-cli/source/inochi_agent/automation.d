module inochi_agent.automation;

import std.conv : to;
import std.file : exists, read, write, rename, mkdir, rmdirRecurse, tempDir;
import std.path : buildPath, dirName, absolutePath;
import std.json : JSONValue, JSONType, parseJSON;
import std.uuid : randomUUID;
import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import creator.agentcore.psdinspect;
import inochi_agent.sdkvalidate;
import inochi_agent.cpurender;

class AgentUsageError : Exception { this(string message) { super(message); } }

JSONValue agentCapabilities() {
    return parseJSON(`{
      "protocol_version":1,"rig_schema_version":1,
      "commands":["capabilities","schema","model-describe","inspect","rig-validate","rig-apply",
        "mesh-replace","mesh-replace-path","mesh-retopologize-path","psd-inspect","psd-import","roundtrip",
        "sdk-validate","pose-sample","pose-render","node-rename"],
      "parameter_dimensions":[1,2],"interpolation":["Linear","Nearest","Cubic"],
      "deformation_inputs":["profiles","offsets"],"mesh_inputs":["grid","custom","auto"],
      "group_types":["Node","MeshGroup","Composite"],
      "binding_properties":{"any":["transform.t.x","transform.t.y","transform.t.z","transform.r.x",
        "transform.r.y","transform.r.z","transform.s.x","transform.s.y","zSort"],
        "Part":["opacity","tint.r","tint.g","tint.b","screenTint.r","screenTint.g","screenTint.b","deform"],
        "Composite":["opacity","tint.r","tint.g","tint.b","screenTint.r","screenTint.g","screenTint.b"],
        "MeshGroup":["deform"]},
      "blend_modes":["Normal","Multiply","Screen","Overlay","Darken","Lighten","ColorDodge","LinearDodge",
        "AddGlow","ColorBurn","HardLight","SoftLight","Difference","Exclusion","Subtract","Inverse",
        "DestinationIn","ClipToLower","SliceFromLower"],
      "automation":["sine"],
      "physics":["Pendulum","SpringPendulum"],"model_format":"Inochi2D INX",
      "cpu_renderer":{"blend_semantics":"legacy OpenGL (macOS runtime)",
        "legacy_normal_fallbacks":["Overlay","Darken","ColorBurn","HardLight","SoftLight","Difference"],
        "composites":true,"composite_masks":false,"tint":true,"masks":true,"physics":true,"automation":true,
        "supersample":{"default":1,"min":1,"max":4,"max_raster_pixels":16777216}},
      "limits":{"cubism_moc3_export":false,"bound_topology_migration":"UV barycentric; covered UVs only",
        "nested_composites":false},
      "guide":"AGENT_GUIDE.md"
    }`);
}

JSONValue agentDescribeModel(string path) {
    auto payload = agentReadModelPayload(path);
    JSONValue[] nodes;
    void visit(JSONValue node, string parent, bool root = false) {
        if (node.type != JSONType.object) throw new Exception("Model node must be an object.");
        auto name = node.object.get("name", JSONValue("")).str;
        auto nodePath = root ? "" : parent ~ "/" ~ name;
        auto description = parseJSON(node.toString());
        description.object.remove("children");
        description.object["path"] = JSONValue(root ? "/" : nodePath);
        nodes ~= description;
        foreach (child; node.object.get("children", JSONValue.emptyArray).array) visit(child, nodePath);
    }
    visit(payload["nodes"], "", true);
    JSONValue result = JSONValue.emptyObject;
    result.object["summary"] = parseJSON(agentInspectModel(path).toJson());
    result.object["nodes"] = JSONValue(nodes);
    result.object["parameters"] = payload.object.get("param", JSONValue.emptyArray);
    result.object["physics"] = payload.object.get("physics", JSONValue.emptyObject);
    result.object["automation"] = payload.object.get("automation", JSONValue.emptyArray);
    return result;
}

// An operation owns a unique directory. Never delete predictable sidecar files
// from previous runs or other callers. Publication is a same-filesystem rename.
private JSONValue staged(string output, bool dryRun, JSONValue delegate(string) operation, bool sdk = true) {
    string parent = dryRun ? tempDir() : dirName(absolutePath(output));
    string directory = buildPath(parent, ".inochi-agent-" ~ randomUUID().toString());
    mkdir(directory);
    scope(exit) rmdirRecurse(directory);
    string stage = buildPath(directory, "model.inx");
    auto result = operation(stage);
    if (sdk) result.object["sdk"] = parseJSON(agentValidateWithSdk(stage).toJson());
    else agentValidateModel(stage);
    if (!dryRun) rename(stage, output);
    return result;
}

JSONValue agentExecute(string[] args, bool sdkValidation = true) {
    if (args.length == 2 && args[0] == "schema" && args[1] == "rig")
        return parseJSON(import("rig.schema.json"));
    if (args.length == 1 && args[0] == "capabilities") return agentCapabilities();
    if (args.length == 2) {
        switch (args[0]) {
            case "model-describe": return agentDescribeModel(args[1]);
            case "inspect": return parseJSON(agentInspectModel(args[1]).toJson());
            case "sdk-validate": return parseJSON(agentValidateWithSdk(args[1]).toJson());
            default: break;
        }
    }
    if (args.length == 3 && args[0] == "psd-inspect") {
        auto inspection = agentInspectPsd(args[1]);
        write(args[2], inspection.toReportJson());
        return parseJSON(inspection.toSummaryJson());
    }
    if (args.length == 3 && args[0] == "psd-import") {
        return staged(args[2], false, (stage) {
            auto summary = agentImportPsdToInx(args[1], stage);
            summary.outputPath = args[2];
            return JSONValue(["import": parseJSON(summary.toJson())]);
        });
    }
    if (args.length == 3 && args[0] == "roundtrip") {
        return staged(args[2], false, (stage) {
            return JSONValue(["model": parseJSON(agentRoundTripModel(args[1], stage).toJson())]);
        }, sdkValidation);
    }
    if ((args.length == 3 && args[0] == "rig-validate") ||
        (args.length == 4 && args[0] == "rig-apply")) {
        bool dryRun = args[0] == "rig-validate";
        auto spec = parseJSON(cast(string) read(args[$-1]));
        return staged(dryRun ? "" : args[2], dryRun, (stage) {
            return JSONValue(["rig": parseJSON(agentApplyRigSpec(args[1], stage, spec).toJson())]);
        });
    }
    if (args.length == 5 && args[0] == "node-rename") {
        return staged(args[2], false, (stage) {
            return JSONValue(["node": agentRenameNode(args[1], stage, args[3].to!ulong, args[4])]);
        });
    }
    if (args.length == 5 && (args[0] == "mesh-replace" || args[0] == "mesh-replace-path" || args[0] == "mesh-retopologize-path")) {
        auto mesh = parseJSON(cast(string) read(args[4]));
        return staged(args[2], false, (stage) {
            auto summary = args[0] == "mesh-retopologize-path"
                ? agentRetopologizePartByPsdPath(args[1], stage, args[3], mesh)
                : args[0] == "mesh-replace"
                ? agentReplacePartMesh(args[1], stage, args[3].to!ulong, mesh)
                : agentReplacePartMeshByPsdPath(args[1], stage, args[3], mesh);
            return JSONValue(["mesh": parseJSON(summary.toJson())]);
        }, sdkValidation);
    }
    if (args.length == 3 && args[0] == "pose-sample") {
        return parseJSON(agentSamplePoses(args[1], parseJSON(cast(string)read(args[2]))).toJson());
    }
    if (args.length == 4 && args[0] == "pose-render") {
        return parseJSON(agentRenderPoses(args[1], parseJSON(cast(string)read(args[2])), args[3]).toJson());
    }
    throw new AgentUsageError("Unknown command or wrong arguments. Use capabilities and AGENT_GUIDE.md.");
}
