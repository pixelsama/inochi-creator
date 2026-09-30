# Agent modeling upgrade: requirement-to-test matrix

Scope: improve the programmable Inochi2D modeling foundation. Only synthetic
fixtures are used; no existing character PSD or artwork is part of acceptance.
Existing scalar rigs and the user's uncommitted curveMorph work must remain usable.

| Requirement | Executable verification | State |
| --- | --- | --- |
| Build/test resolves the patched renderless SDK from the CLI directory | AgentCliBuild.sh test and build, including invocation outside the repository | PASS; fixed local SDK registration and deployment triple |
| Scalar rigs retain their behavior | Existing D SDK/mesh/PSD/physics/render tests; original curveMorph anchor regression | PASS |
| Two-axis parameters interpolate numeric and vertex values at corners and intermediate poses | advanced_test.d: numeric/deform SDK evaluation, including non-square key grids | PASS |
| Arbitrary per-vertex offsets and custom meshes support artist-defined shapes | advanced_test.d: exact offsets; invalid dimensions/topology fail before output | PASS |
| Bound mesh retopology resamples every key and rejects ambiguous or uncovered UVs | advanced_test.d: 2D keys, spatial gradient at inserted vertex, overlapping UV boundary, preserved texture/output | PASS |
| Interpolation can be selected explicitly | advanced_test.d: SDK Linear/Nearest/Cubic behavioral checks; invalid modes rejected | PASS |
| Rig schema rejects typos, duplicate bindings, invalid numbers and incompatible mesh changes | advanced_test.d: negative contracts, float overflow/precision, physics bounds and unchanged-output checks | PASS |
| Agents can discover capabilities/schema, inspect editable model structure and validate without publishing | test_agent_cli.py: discovery and generated fixture integration | PASS |
| Duplicate PSD layer names can be disambiguated by explicitly renaming one node by UUID | CLI rename test and D duplicate-sibling regression: preserve identity/provenance/textures; reject collisions and invalid names | PASS |
| Machine calls produce one JSON result with stable errors and nonzero exit status on failure | test_agent_cli.py: usage, parse, IO and validation failures | PASS |
| CLI model edits are staged, SDK-validated and atomically published | test_agent_cli.py: failure preservation, unrelated staging file, successful and in-place edits | PASS; publication uses same-filesystem rename, not a durability/concurrency guarantee |
| Pose sampling/rendering agree on scalar/vector input; unsupported CPU features fail explicitly | advanced_test.d: vector poses, Multiply rejection, shared-edge alpha preservation | PASS |
| Pose probes expose real geometry, including flips/collapses, with all Parts as the default | advanced_test.d and test_agent_cli.py: positions, offsets, flip/collapse counts and default probes | PASS |
| A synthetic example demonstrates import → rig → validate → inspect → pose/render | test_agent_cli.py generates its own PSD; AGENT_GUIDE.md documents the flow | PASS |

## Verification record

2026-09-05, macOS arm64, LDC 1.41.0, patched Inochi2D 0.8.7:

- D suite: 4 modules, 41 unittest blocks (14 new advanced blocks plus existing regressions).
- Python public CLI suite: 7 integration tests, using only the standard library.
- Debug application build and invocation from outside the repository: passed.
- Release application build from `/tmp` and all 6 CLI integration tests against
  the resulting executable: passed. The D unittest build was also rerun from `/tmp`.
- New behavior was covered before implementation. The final UV-boundary regression
  first failed because no exception was thrown; the weighted-source comparison
  now rejects disconnected UV islands while preserving ordinary shared edges.
- No old character PSD was opened. Existing uncommitted curveMorph work was retained.

The subsequent user-authorized shounen PSD trial exercised duplicate-name
disambiguation and added the rename regressions above. Its separate artifact
acceptance checks original-source/texture preservation, neutral-image error and
91 authored poses; see `../output/shounen-agent-trial/README.md`.

Completion means the above contracts are verified, not that every Inochi Creator
GUI feature or automatic artistic decision has been implemented. Remaining
limitations are recorded in AGENT_GUIDE.md.

## Advanced rig round (2026-09-29)

Scope: make the Inochi2D features needed for a production avatar operable by
Agents, and make the CPU preview trustworthy against the real GPU runtime.

| Requirement | Executable verification | State |
| --- | --- | --- |
| MeshGroup cages can be created (grid over children or custom mesh) and deformed by parameters; children follow | rigext_test.d: translated cage moves every child vertex and rendered pixels; test_agent_cli.py | PASS |
| zSort can be driven by parameters | rigext_test.d: overlapping parts swap front/back; probe reports zSort | PASS |
| tint / screenTint are bindable on Parts and Composites; static appearance via `parts` | rigext_test.d: rendered colors and probe values; negative ranges rejected | PASS |
| All SDK blend modes can be set and are previewed with the macOS runtime's legacy GL formulas, only where the part rasterizes | rigext_test.d: Multiply result, DestinationIn leaves outside pixels intact; fallbacks reported | PASS |
| Composite groups (rig and PSD import) flatten children before opacity/blend; nesting rejected | rigext_test.d: overlap alpha stays 0.5; PSD group with opacity imports as Composite | PASS |
| Sine automation can be authored and survives SDK loading | rigext_test.d: automation moves a part over simulated frames; invalid bindings rejected | PASS; SDK range/enum deserialization bugs fixed or avoided |
| Parts can be auto-meshed from texture alpha, including bound parts via retopology | rigext_test.d: rest pose within 1/255 of the quad, area follows silhouette, keys migrate; Gate2 89 parts pixel-identical | PASS |
| CPU preview matches the GPU runtime | tools/gpu_acceptance.py on the shounen trial and Gate2 PSD | PASS at 1:1 (max channel diff 2); <1% pixels over 8/255 at 0.25–0.5 scale |

CPU renderer corrections found by GPU comparison (previous behavior differed
from the runtime): GL texel-center addressing with a transparent border,
trilinear mipmaps with UV-aligned area-weighted levels, binary stencil masks
using the mask source's raw alpha and mask_threshold, and OpenGL's coverage
tie rule in y-up window coordinates. The Agent Session capture also wrote
premultiplied framebuffer colors into straight-alpha PNGs; it now
unpremultiplies before encoding.

Verification record, macOS arm64, LDC 1.41.0 (CLI) / 1.42.0 (Session):

- D suite: 5 modules pass, including the new rigext_test.d.
- Python public CLI suite: 9 integration tests pass against the release build.
- Session D suite: 5 modules pass; Agent Session bundle rebuilt.
- Shounen trial acceptance (test_trial.py) still passes.
