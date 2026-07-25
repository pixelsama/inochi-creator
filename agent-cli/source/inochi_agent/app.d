module inochi_agent.app;

import std.stdio : stderr, writeln;

import creator.agentcore.modelio;

private void printUsage() {
    writeln("Usage:");
    writeln("  inochi-agent inspect <model.inx>");
    writeln("  inochi-agent roundtrip <input.inx> <output.inx>");
}

int main(string[] args) {
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

    printUsage();
    return 2;
}
