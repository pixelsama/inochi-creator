module inochi_agent.poseinput;

import std.json : JSONType, JSONValue;
import std.math : isFinite;
import inochi2d : Puppet;

private float number(JSONValue value, string label) {
    double n;
    switch (value.type) {
        case JSONType.integer: n = value.integer; break;
        case JSONType.uinteger: n = value.uinteger; break;
        case JSONType.float_: n = value.floating; break;
        default: throw new Exception(label ~ " must be numeric.");
    }
    if (!isFinite(n) || !isFinite(cast(float)n)) throw new Exception(label ~ " must be finite and fit the SDK float range.");
    return cast(float)n;
}

// Shared by sampling, rendering and physics trajectories. Vector parameters
// always require both axes; malformed input must never be silently truncated.
void agentSetPoseParameters(Puppet puppet, JSONValue parameters, string label) {
    if (parameters.type != JSONType.object) throw new Exception(label ~ " requires a parameters object.");
    foreach (name, value; parameters.object) {
        auto index = puppet.findParameterIndex(name);
        if (index < 0) throw new Exception("Unknown pose parameter '" ~ name ~ "'.");
        auto p = puppet.parameters[index];
        auto cells = p.isVec2 ? value : JSONValue([value]);
        if (cells.type != JSONType.array || cells.array.length != (p.isVec2 ? 2 : 1))
            throw new Exception(name ~ " requires [x,y] for a vector parameter.");
        foreach (axis, v; cells.array) {
            auto n = number(v, name);
            auto lo = axis == 0 ? p.min.x : p.min.y;
            auto hi = axis == 0 ? p.max.x : p.max.y;
            if (n < lo || n > hi) throw new Exception(name ~ " is outside its declared range.");
            if (axis == 0) p.value.x = n; else p.value.y = n;
        }
        if (!p.isVec2) p.value.y = 0;
    }
}
