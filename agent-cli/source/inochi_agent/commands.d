module inochi_agent.commands;

import std.json : JSONValue, JSONException;
import std.file : FileException;
import std.stdio : writeln, stderr;
import inochi_agent.automation;

/** Machine calls have one envelope, stable error codes and a nonzero status.
 * Legacy invocations retain their result-only output and scalar contracts.
 */
int runAgentCommand(string[] args) {
    bool machine = args.length > 1 && args[1] == "--json";
    auto command = args[(machine ? 2 : 1) .. $];
    if (!machine && (command.length == 0 || command[0] == "--help" || command[0] == "help")) {
        writeln("Usage: inochi-agent [--json] <command> <args...>");
        writeln("Use 'capabilities' for supported commands and AGENT_GUIDE.md for schemas and examples.");
        return command.length == 0 ? 2 : 0;
    }
    JSONValue envelope = JSONValue.emptyObject;
    envelope.object["protocol_version"] = JSONValue(1);
    try {
        auto result = agentExecute(command, machine);
        if (machine) {
            envelope.object["result"] = result;
            envelope.object["ok"] = JSONValue(true);
            writeln(envelope.toString());
        } else if (command[0] == "rig-apply") {
            writeln(result["rig"].toString());
            writeln(result["sdk"].toString());
        } else if (command[0] == "psd-import") {
            writeln(result["import"].toString());
            writeln(result["sdk"].toString());
        } else if (command[0] == "mesh-replace" || command[0] == "mesh-replace-path" || command[0] == "mesh-retopologize-path") {
            writeln(result["mesh"].toString());
        } else if (command[0] == "roundtrip") {
            writeln(result["model"].toString());
        } else writeln(result.toString());
        return 0;
    } catch (Exception e) {
        string code = "VALIDATION_ERROR";
        int status = 1;
        if (cast(AgentUsageError)e) { code = "USAGE_ERROR"; status = 2; }
        else if (cast(JSONException)e) code = "INVALID_JSON";
        else if (cast(FileException)e) code = "IO_ERROR";
        if (machine) {
            envelope.object["ok"] = JSONValue(false);
            envelope.object["error"] = JSONValue(["code":JSONValue(code), "message":JSONValue(e.msg)]);
            writeln(envelope.toString());
        } else stderr.writeln(code ~ ": " ~ e.msg);
        return status;
    }
}
