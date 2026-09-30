#!/usr/bin/env python3
"""Compare CPU pose previews with real GPU frames from the Agent Session runtime.

For each pose the runtime loads the model with the pose held fixed (physics and
automation frozen, lighting post-process off, transparent background) and
captures its framebuffer. The CPU renderer draws the same pose with the same
camera, and the two images are compared in premultiplied RGBA.

    python3 tools/gpu_acceptance.py model.inx poses.json outdir \
        [--session-app PATH] [--camera-scale 0.5] [--camera-position X Y]

poses.json uses the pose-render format; its canvas is ignored because the GPU
window decides the frame size. Exits 1 when any pose exceeds the thresholds.
Requires Pillow.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "agent-cli/inochi-agent"
DEFAULT_SESSION = (ROOT.parent / "inochi-session-agent/out/Inochi Agent Session.app"
                   / "Contents/MacOS/inochi-session-agent")


def premultiplied(image):
    """Straight RGBA PNG -> list of premultiplied (r, g, b, a) tuples in 0..255."""
    result = []
    for r, g, b, a in image.convert("RGBA").getdata():
        result.append((r * a / 255, g * a / 255, b * a / 255, a))
    return result


def compare(gpu_path, cpu_path, diff_path, tolerance):
    gpu = Image.open(gpu_path).convert("RGBA")
    cpu = Image.open(cpu_path).convert("RGBA")
    if gpu.size != cpu.size:
        raise SystemExit(f"size mismatch: GPU {gpu.size} vs CPU {cpu.size}")
    a, b = premultiplied(gpu), premultiplied(cpu)
    total = 0.0
    over = 0
    worst = 0.0
    visible = 0
    both_visible = 0
    for p, q in zip(a, b):
        d = max(abs(p[i] - q[i]) for i in range(4))
        total += sum(abs(p[i] - q[i]) for i in range(4)) / 4
        worst = max(worst, d)
        if d > tolerance:
            over += 1
        if p[3] > 0 or q[3] > 0:
            visible += 1
            if p[3] > 0 and q[3] > 0:
                both_visible += 1
    diff = ImageChops.difference(gpu, cpu)
    # Amplify so small differences are visible to a reviewer.
    diff = diff.point(lambda v: min(255, v * 8))
    diff.putalpha(255)
    diff.save(diff_path)
    pixels = len(a)
    return {
        "meanAbsoluteDifference": total / pixels,
        "maxChannelDifference": worst,
        "pixelsOverTolerance": over,
        "fractionOverTolerance": over / pixels,
        "alphaCoverageIoU": both_visible / visible if visible else 1.0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model")
    parser.add_argument("poses")
    parser.add_argument("outdir")
    parser.add_argument("--session-app", default=os.environ.get("INOCHI_AGENT_SESSION", str(DEFAULT_SESSION)))
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--camera-scale", type=float, default=0.5)
    parser.add_argument("--camera-position", type=float, nargs=2, default=[0.0, 0.0])
    parser.add_argument("--frames", type=int, default=5, help="Frames rendered before capture.")
    parser.add_argument("--tolerance", type=float, default=8, help="Per-pixel channel difference counted as a mismatch.")
    parser.add_argument("--max-fraction", type=float, default=0.01, help="Allowed fraction of mismatched pixels.")
    parser.add_argument("--min-iou", type=float, default=0.98, help="Required alpha coverage IoU.")
    args = parser.parse_args()

    model = Path(args.model).resolve()
    outdir = Path(args.outdir).resolve()
    outdir.mkdir(parents=True, exist_ok=True)
    poses = json.loads(Path(args.poses).read_text())["poses"]
    camera = {"scale": args.camera_scale, "position": args.camera_position}
    report = {"model": str(model), "camera": camera, "poses": []}
    failed = False

    for index, pose in enumerate(poses):
        stem = f"{index:02d}_{pose['name'].replace('/', '_').replace(' ', '_')}"
        config = {
            "version": 1, "model": str(model),
            "view": {"camera_scale": args.camera_scale, "camera_position": args.camera_position,
                     "show_ui": False, "background": [0, 0, 0, 0], "post_process": False},
            "pose": {"parameters": pose.get("parameters", {}), "freeze_motion": True},
        }
        config_path = outdir / f"{stem}.session.json"
        config_path.write_text(json.dumps(config))
        gpu_path = outdir / f"{stem}.gpu.png"
        run = subprocess.run([args.session_app, "--agent-config", str(config_path),
                              "--agent-capture", str(gpu_path),
                              "--agent-capture-after-frames", str(args.frames)],
                             capture_output=True, text=True, timeout=120)
        if run.returncode != 0 or not gpu_path.exists():
            raise SystemExit(f"GPU capture failed for {pose['name']}:\n{run.stdout}\n{run.stderr}")
        width, height = Image.open(gpu_path).size

        cpu_spec = outdir / f"{stem}.cpu.json"
        cpu_spec.write_text(json.dumps({
            "canvas": {"width": width, "height": height, "camera": camera},
            "poses": [{"name": pose["name"], "parameters": pose.get("parameters", {})}]}))
        cpu_dir = outdir / f"{stem}.cpu"
        result = subprocess.run([args.cli, "--json", "pose-render", str(model), str(cpu_spec), str(cpu_dir)],
                                capture_output=True, text=True, timeout=600)
        payload = json.loads(result.stdout)
        if not payload["ok"]:
            raise SystemExit(f"CPU render failed for {pose['name']}: {payload['error']}")
        cpu_path = Path(payload["result"]["poses"][0]["outputPath"])

        metrics = compare(gpu_path, cpu_path, outdir / f"{stem}.diff.png", args.tolerance)
        passed = (metrics["fractionOverTolerance"] <= args.max_fraction and
                  metrics["alphaCoverageIoU"] >= args.min_iou)
        failed |= not passed
        report["poses"].append({"name": pose["name"], "gpu": str(gpu_path), "cpu": str(cpu_path),
                                "diff": str(outdir / f"{stem}.diff.png"), "passed": passed,
                                "legacyBlendFallbacks": payload["result"]["legacyBlendFallbacks"],
                                **metrics})

    report["passed"] = not failed
    (outdir / "gpu-acceptance.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
