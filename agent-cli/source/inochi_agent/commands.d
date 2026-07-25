module inochi_agent.commands;

import std.conv : to;
import std.file : read;
import std.json : parseJSON;
import std.stdio : writeln;

import creator.agentcore.modelio;

private void printUsage() {
    writeln("Usage:");
    writeln("  inochi-agent inspect <model.inx>");
    writeln("  inochi-agent roundtrip <input.inx> <output.inx>");
    writeln("  inochi-agent mesh-replace <input.inx> <output.inx> <part-uuid> <mesh.json>");
}

/**
 * Runs a headless Agent command.  The command surface is deliberately
 * separate from `main` so that it can later be called by an IPC server,
 * scheduler, or GUI adapter without synthesizing keyboard input.
 */
int runAgentCommand(string[] args) {
    if (args.length == 3 && args[1] == "inspect") {
        auto summary = agentInspectModel(args[2]);
        writeln(summary.toJson());
        return 0;
    }

    if (args.length == 4 && args[1] == "roundtrip") {
        auto summary = agentRoundTripModel(args[2], args[3]);
        writeln(summary.toJson());
        return 0;
    }

    if (args.length == 6 && args[1] == "mesh-replace") {
        auto partUuid = args[4].to!ulong;
        auto mesh = parseJSON(cast(string) read(args[5]));
        auto summary = agentReplacePartMesh(args[2], args[3], partUuid, mesh);
        writeln(summary.toJson());
        return 0;
    }

    printUsage();
    return 2;
}
