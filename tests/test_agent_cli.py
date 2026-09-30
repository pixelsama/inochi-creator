"""Public CLI contracts using a tiny generated PSD, never character artwork.

Run after building: python3 -m unittest discover -s tests -v
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("INOCHI_AGENT_TEST_CLI", ROOT / "agent-cli/inochi-agent"))


def synthetic_psd(empty_layer=False):
    """32x32 RGB PSD, one ordinary four-channel 4x4 pixel layer.

    With empty_layer, an extra pixel layer with zero bounds sits above it."""
    u32 = lambda n: struct.pack(">I", n)
    header = b"8BPS" + struct.pack(">H6sHIIHH", 1, b"\0" * 6, 4, 32, 32, 8, 3)

    def layer(name, bounds, channel_length):
        pascal = bytes([len(name)]) + name
        pascal += b"\0" * (-len(pascal) % 4)
        extra = u32(0) + u32(0) + pascal
        record = struct.pack(">iiiiH", *bounds, 4)
        record += b"".join(struct.pack(">hI", c, channel_length) for c in [-1, 0, 1, 2])
        return record + b"8BIMnorm" + bytes([255, 0, 0, 0]) + u32(len(extra)) + extra

    records = layer(b"Iris", (14, 14, 18, 18), 18)
    pixels = b"".join(b"\0\0" + bytes([v]) * 16 for v in [255, 200, 80, 40])
    count = 1
    if empty_layer:
        records += layer(b"Empty", (0, 0, 0, 0), 2)
        pixels += b"\0\0" * 4
        count = 2
    info = struct.pack(">h", count) + records + pixels
    section = u32(len(info)) + info + u32(0)
    return header + u32(0) + u32(0) + u32(len(section)) + section + b"\0\0" + bytes(4096)


def rig_spec():
    return {"schema_version": 1, "parameters": [{
        "name": "HeadXY",
        "axes": [{"min": -1, "max": 1, "default": 0, "keys": [-1, 0, 1]},
                 {"min": 0, "max": 1, "default": 0, "keys": [0, 1]}],
        "bindings": [{"path": "/Iris", "property": "transform.t.x",
                      "interpolation": "Linear", "values": [[0, 8], [2, 10], [4, 12]]}]
    }]}


class AgentCLIContracts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="inochi-cli-contract-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.psd = self.directory / "synthetic.psd"
        self.psd.write_bytes(synthetic_psd())
        self.model = self.directory / "base.inx"
        self.rig = self.directory / "rig.json"
        self.rig.write_text(json.dumps(rig_spec()))

    def call(self, *args, ok=True, code=None):
        result = subprocess.run([str(CLI), "--json", *map(str, args)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        payload = json.loads(result.stdout)  # Exactly one JSON document.
        self.assertEqual(payload["protocol_version"], 1)
        self.assertEqual(payload["ok"], ok)
        if code:
            self.assertEqual(payload["error"]["code"], code)
        return payload.get("result", payload)

    def import_model(self):
        self.call("psd-import", self.psd, self.model)

    def test_capabilities_and_usage_error(self):
        caps = self.call("capabilities")
        self.assertIn("rig-validate", caps["commands"])
        self.assertIn(2, caps["parameter_dimensions"])
        self.call("unknown-command", ok=False, code="USAGE_ERROR")

    def test_empty_pixel_layer_is_skipped_and_reported(self):
        self.psd.write_bytes(synthetic_psd(empty_layer=True))
        summary = self.call("psd-import", self.psd, self.model)["import"]
        self.assertEqual(summary["partCount"], 1)
        self.assertEqual(summary["skippedEmptyLayers"], ["/Empty"])
        self.assertEqual(self.call("sdk-validate", self.model)["partCount"], 1)

    def test_physics_render_captures_trajectory_frames(self):
        self.import_model()
        self.call("rig-apply", self.model, self.model, self.rig)
        trajectory = [{"HeadXY": [x, 0]} for x in (-1, -0.5, 0.5, 1)]
        poses = self.directory / "motion.json"
        poses.write_text(json.dumps({"canvas": {"width": 32, "height": 32}, "poses": [
            {"name": "motion", "parameters": {},
             "physics": {"frames": 4, "dt": 0.05, "trajectory": trajectory, "capture_every": 2}}]}))
        pose = self.call("pose-render", self.model, poses, self.directory / "motion")["poses"][0]
        frames = [Path(p) for p in pose["frameOutputPaths"]]
        self.assertEqual([p.name for p in frames], ["00_motion_f00002.png", "00_motion_f00004.png"])
        self.assertNotEqual(frames[0].read_bytes(), frames[1].read_bytes())
        self.assertEqual(frames[1].read_bytes(), Path(pose["outputPath"]).read_bytes())
        poses.write_text(json.dumps({"canvas": {"width": 32, "height": 32}, "poses": [
            {"name": "bad", "parameters": {}, "physics": {"frames": 4, "capture_every": 0}}]}))
        self.call("pose-render", self.model, poses, self.directory / "bad", ok=False, code="VALIDATION_ERROR")

    def test_discoverable_rig_schema(self):
        schema = self.call("schema", "rig")
        self.assertEqual(schema["type"], "object")
        self.assertIn("parameters", schema["properties"])
        self.assertFalse(schema["additionalProperties"])

    def test_sampling_defaults_to_all_parts_and_reports_geometry(self):
        self.import_model()
        self.call("rig-apply", self.model, self.model, self.rig)
        poses = self.directory / "poses.json"
        poses.write_text(json.dumps({"poses": [{"name": "sample", "parameters": {"HeadXY": [0, 0]}}]}))
        result = self.call("pose-sample", self.model, poses)
        self.assertEqual(result["probeCount"], 1)
        probe = result["poses"][0]["probes"][0]
        self.assertEqual(len(probe["worldVertices"]), 4)
        self.assertEqual(probe["flippedTriangleCount"], 0)
        self.assertEqual(probe["collapsedTriangleCount"], 0)

    def test_import_describe_validate_apply_and_sample(self):
        self.import_model()
        description = self.call("model-describe", self.model)
        self.assertIn("/Iris", [n["path"] for n in description["nodes"]])
        original = self.model.read_bytes()
        files_before = set(self.directory.iterdir())
        validated = self.call("rig-validate", self.model, self.rig)
        self.assertEqual(validated["sdk"]["partCount"], 1)
        self.assertEqual(files_before, set(self.directory.iterdir()))
        self.assertEqual(self.model.read_bytes(), original)
        output = self.directory / "rigged.inx"
        applied = self.call("rig-apply", self.model, output, self.rig)
        self.assertEqual(applied["rig"]["parameterCount"], 1)
        description = self.call("model-describe", output)
        self.assertEqual(description["parameters"][0]["name"], "HeadXY")
        suite = self.directory / "poses.json"
        suite.write_text(json.dumps({"canvas": {"width": 32, "height": 32}, "poses": [
            {"name": "neutral", "parameters": {"HeadXY": [0, 0]}, "probes": ["/Iris"]},
            {"name": "diagonal", "parameters": {"HeadXY": [1, 1]}, "probes": ["/Iris"]}]}))
        sampled = self.call("pose-sample", output, suite)
        self.assertEqual(sampled["poseCount"], 2)
        self.assertAlmostEqual(sampled["poses"][1]["probes"][0]["translationX"], 12)
        rendered = self.call("pose-render", output, suite, self.directory / "renders")
        self.assertEqual(rendered["poseCount"], 2)
        self.assertNotEqual(rendered["poses"][0]["rgbaSha256"], rendered["poses"][1]["rgbaSha256"])

    def test_failure_preserves_output_and_unrelated_staging_file(self):
        self.import_model()
        output = self.directory / "rigged.inx"
        output.write_bytes(b"existing output")
        sibling = Path(str(output) + ".agent-incomplete")
        sibling.write_bytes(b"another caller owns this")
        self.rig.write_text('{"paramters":[]}')
        self.call("rig-apply", self.model, output, self.rig, ok=False, code="VALIDATION_ERROR")
        self.assertEqual(output.read_bytes(), b"existing output")
        self.assertEqual(sibling.read_bytes(), b"another caller owns this")
        self.rig.write_text(json.dumps(rig_spec()))
        self.call("rig-apply", self.model, output, self.rig)
        self.assertEqual(sibling.read_bytes(), b"another caller owns this")

    def test_node_rename_preserves_identity_and_allows_new_path_binding(self):
        self.import_model()
        before = self.call("model-describe", self.model)
        part = next(n for n in before["nodes"] if n["path"] == "/Iris")
        self.call("node-rename", self.model, self.model, part["uuid"], "EyeRight")
        after = self.call("model-describe", self.model)
        renamed = next(n for n in after["nodes"] if n["path"] == "/EyeRight")
        self.assertEqual(renamed["uuid"], part["uuid"])
        self.assertEqual(renamed["mesh"], part["mesh"])
        self.assertEqual(renamed["psdLayerPath"], part["psdLayerPath"])
        spec = rig_spec()
        spec["parameters"][0]["bindings"][0]["path"] = "/EyeRight"
        self.rig.write_text(json.dumps(spec))
        self.call("rig-validate", self.model, self.rig)
        unchanged = self.model.read_bytes()
        for name in ["", "Bad/Path", "Root"]:
            self.call("node-rename", self.model, self.model, part["uuid"], name,
                      ok=False, code="VALIDATION_ERROR")
            self.assertEqual(self.model.read_bytes(), unchanged)
        self.call("node-rename", self.model, self.model, 99999999, "Absent",
                  ok=False, code="VALIDATION_ERROR")
        self.assertEqual(self.model.read_bytes(), unchanged)

    def test_supersampling_public_contract(self):
        self.import_model()
        caps = self.call("capabilities")["cpu_renderer"]["supersample"]
        self.assertEqual((caps["default"], caps["min"], caps["max"]), (1, 1, 4))
        specification = {"canvas": {"width": 32, "height": 32, "supersample": 2},
                         "poses": [{"name": "sample", "parameters": {}}]}
        poses = self.directory / "render.json"
        poses.write_text(json.dumps(specification))
        result = self.call("pose-render", self.model, poses, self.directory / "images")
        self.assertEqual((result["width"], result["height"], result["supersample"]), (32, 32, 2))
        for size, scale in [(32, 0), (32, 5), (32, 1.5), (4096, 2), (2147483647, 4)]:
            specification["canvas"].update(width=size, height=size, supersample=scale)
            poses.write_text(json.dumps(specification))
            self.call("pose-render", self.model, poses, self.directory / "invalid",
                      ok=False, code="VALIDATION_ERROR")
        self.assertFalse((self.directory / "invalid").exists())

    def test_advanced_rig_features_through_public_cli(self):
        caps = self.call("capabilities")
        self.assertEqual(caps["group_types"], ["Node", "MeshGroup", "Composite"])
        self.assertIn("auto", caps["mesh_inputs"])
        self.assertIn("zSort", caps["binding_properties"]["any"])
        schema = self.call("schema", "rig")
        self.assertIn("automation", schema["properties"])
        self.import_model()
        spec = {"schema_version": 1,
                "groups": [{"name": "Warp", "type": "MeshGroup", "paths": ["/Iris"], "columns": 3, "rows": 3},
                           {"name": "Look", "type": "Composite", "paths": ["/Warp"], "opacity": 0.5}],
                "parts": [{"path": "/Look/Warp/Iris", "tint": [1, 0.5, 1]}],
                "meshes": [{"path": "/Look/Warp/Iris", "auto": {"spacing": 2, "margin": 0}}],
                "parameters": [{"name": "Face", "min": 0, "max": 1, "keys": [0, 1], "bindings": [
                    {"path": "/Look/Warp", "property": "deform",
                     "values": [None, {"profiles": [{"type": "translate", "x": 3}]}]},
                    {"path": "/Look/Warp/Iris", "property": "zSort", "values": [0, 5]},
                    {"path": "/Look", "property": "screenTint.r", "values": [0, 1]}]}],
                "automation": [{"name": "Idle", "speed": 2, "bindings": [{"parameter": "Face", "range": [0, 1]}]}]}
        self.rig.write_text(json.dumps(spec))
        output = self.directory / "advanced.inx"
        applied = self.call("rig-apply", self.model, output, self.rig)["rig"]
        self.assertEqual((applied["meshGroupCount"], applied["compositeCount"],
                          applied["partPropertyCount"], applied["automationCount"]), (1, 1, 1, 1))
        described = self.call("model-describe", output)
        self.assertEqual(described["automation"][0]["name"], "Idle")
        self.assertEqual([n["type"] for n in described["nodes"] if n["path"] in ("/Look", "/Look/Warp")],
                         ["Composite", "MeshGroup"])
        poses = self.directory / "poses.json"
        poses.write_text(json.dumps({"canvas": {"width": 32, "height": 32}, "poses": [
            {"name": "rest", "parameters": {}},
            {"name": "face", "parameters": {"Face": 1}},
            {"name": "idle", "parameters": {}, "physics": {"frames": 10, "dt": 0.1}}]}))
        sampled = self.call("pose-sample", output, poses)
        paths = [p["path"] for p in sampled["poses"][1]["probes"]]
        self.assertEqual(paths, ["/Look/Warp", "/Look/Warp/Iris"])
        rest, face = (sampled["poses"][i]["probes"][1] for i in (0, 1))
        self.assertAlmostEqual(face["worldVertices"][0][0] - rest["worldVertices"][0][0], 3, places=3)
        self.assertEqual(face["zSort"] - rest["zSort"], 5)
        rendered = self.call("pose-render", output, poses, self.directory / "advanced")
        hashes = [p["rgbaSha256"] for p in rendered["poses"]]
        self.assertEqual(len(set(hashes)), 3)
        self.assertEqual(rendered["legacyBlendFallbacks"], [])
        bad = dict(spec, groups=[{"name": "G", "type": "Composite", "paths": ["/Iris"], "columns": 3}])
        self.rig.write_text(json.dumps(bad))
        self.call("rig-validate", self.model, self.rig, ok=False, code="VALIDATION_ERROR")

    def test_parse_and_missing_file_errors(self):
        self.import_model()
        self.rig.write_text('{')
        self.call("rig-validate", self.model, self.rig, ok=False, code="INVALID_JSON")
        self.call("inspect", self.directory / "missing.inx", ok=False, code="IO_ERROR")


if __name__ == "__main__":
    unittest.main()
