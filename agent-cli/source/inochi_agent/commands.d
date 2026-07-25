module inochi_agent.commands;

import std.conv : to;
import std.file : exists, read, remove, rename, write;
import std.json : parseJSON;
import std.stdio : writeln;

import creator.agentcore.modelio;
import creator.agentcore.psdimport;
import creator.agentcore.psdinspect;
import inochi_agent.sdkvalidate;

private void printUsage() {
    writeln("Usage:");
    writeln("  inochi-agent inspect <model.inx>");
    writeln("  inochi-agent roundtrip <input.inx> <output.inx>");
    writeln("  inochi-agent mesh-replace <input.inx> <output.inx> <part-uuid> <mesh.json>");
    writeln("  inochi-agent mesh-replace-path <input.inx> <output.inx> <psd-layer-path> <mesh.json>");
    writeln("  inochi-agent psd-inspect <input.psd> <report.json>");
    writeln("  inochi-agent psd-import <input.psd> <output.inx>");
    writeln("  inochi-agent sdk-validate <model.inx>");
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

    if (args.length == 6 && args[1] == "mesh-replace-path") {
        auto mesh = parseJSON(cast(string) read(args[5]));
        auto summary = agentReplacePartMeshByPsdPath(
            args[2],
            args[3],
            args[4],
            mesh
        );
        writeln(summary.toJson());
        return 0;
    }

    if (args.length == 4 && args[1] == "psd-inspect") {
        auto inspection = agentInspectPsd(args[2]);
        write(args[3], inspection.toReportJson());
        writeln(inspection.toSummaryJson());
        return 0;
    }

    if (args.length == 4 && args[1] == "psd-import") {
        string temporaryPath = args[3] ~ ".agent-incomplete";
        if (exists(temporaryPath)) remove(temporaryPath);
        scope (failure) if (exists(temporaryPath)) remove(temporaryPath);

        auto importSummary = agentImportPsdToInx(args[2], temporaryPath);
        auto sdkSummary = agentValidateWithSdk(temporaryPath);
        rename(temporaryPath, args[3]);
        importSummary.outputPath = args[3];
        writeln(importSummary.toJson());
        writeln(sdkSummary.toJson());
        return 0;
    }

    if (args.length == 3 && args[1] == "sdk-validate") {
        writeln(agentValidateWithSdk(args[2]).toJson());
        return 0;
    }

    printUsage();
    return 2;
}
