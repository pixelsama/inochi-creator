module inochi_agent.sdkvalidate;

import std.file : read;
import std.json : JSONValue;

import inochi2d : Part, Puppet, inClearUUIDs, inInit, inLoadINPPuppet;
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
