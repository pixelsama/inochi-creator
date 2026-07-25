# Inochi Creator
![Image of Inochi Creator](https://user-images.githubusercontent.com/7032834/194462402-74c4a3e0-50ca-4b50-8e8d-164d97371f5a.png)
_Ada model by [ku-ini](https://twitter.com/duckmastah)_

----------------

[![Support me on Patreon](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fshieldsio-patreon.vercel.app%2Fapi%3Fusername%3Dclipsey%26type%3Dpatrons&style=for-the-badge)](https://patreon.com/clipsey)
[![Join the Discord](https://img.shields.io/discord/855173611409506334?label=Community&logo=discord&logoColor=FFFFFF&style=for-the-badge)](https://discord.com/invite/abnxwN6r9v)

Inochi Creator is an open source editor for the [Inochi2D puppet format](https://github.com/Inochi2D/inochi2d).  This application allows you to rig models for use in games or for other real-time applications such as [VTubing](https://en.wikipedia.org/wiki/VTuber). Animation is achieved by morphing, transforming and in other ways distorting layered 2D textures in real-time. These distortions can trick the end user in to perciving 3D depth in the 2D art.

If you are a VTuber wanting to use Inochi2D we highly recommend checking out [Inochi Session](https://github.com/Inochi2D/inochi-session) as well.

&nbsp;

## Downloads

### Stable Builds

&nbsp;&nbsp;&nbsp;&nbsp;
[![Buy on itch.io](https://img.shields.io/github/v/release/Inochi2D/inochi-creator?color=%23fa5c5c&label=itch.io&logo=itch.io&style=for-the-badge)](https://lunafoxgirlvt.itch.io/inochi-creator) [![Wishlist on Steam](https://img.shields.io/github/v/release/Inochi2D/inochi-creator?style=for-the-badge&logo=steam&label=Steam&color=black)](https://store.steampowered.com/app/2108550/Inochi_Creator/)

### Experimental Builds

&nbsp;&nbsp;&nbsp;&nbsp;
[![Nightly Builds](https://img.shields.io/github/actions/workflow/status/Inochi2D/inochi-creator/release-nightly.yml?label=Nightly&style=for-the-badge)](https://github.com/Inochi2D/inochi-creator/releases/tag/nightly)  

&nbsp;

## For package maintainers
We do not officially support packages that we don't officially build ourselves, we ask that you build using the barebones configurations, as the branding assets are copyright the Inochi2D Project.  
You may request permission to use our branding assets in your package by submitting an issue.

Barebones builds are more or less equivalent to official builds with the exception that branding is removed,  
and that we don't accept support tickets unless a problem can be replicated on an official build.

Links in `source/creator/config.d` should be updated to point to your package's issues list, as we do not accept issues from non-official builds.

&nbsp;

## Building
It's occasionally the case that our dependencies are out of sync with dub, so it's somewhat recommended if you're building from source to clone the tip of `main` and `dub add-local . "<version matching inochi-creator dep>"` any of our forked dependencies (i18n-d, psd-d, bindbc-imgui, facetrack-d, inmath, inochi2d). This will generally keep you up to date with what we're doing, and it's how the primary contributors work. Ideally we'd have a script to help set this up, but currently we do it manually, PRs welcome :)

Because our project has dependencies on C++ through bindbc-imgui, and because there's no common way to get imgui binaries across platforms, we require a C++ toolchain as well as a few extra dependencies installed. These will be listed in their respective platform sections below.  
Currently you **have** to _recursively_ clone bindbc-imgui from git and set its version to `0.7.0`, otherwise the build will fail.

Once the below dependencies are met, building and running inochi-creator should be as simple as calling `dub` within this repo.

### Windows
#### Dependencies
- Visual Studio 2022 (With "Desktop development with C++" workflow installed)
  - In theory, "Build Tools for Visual Studio 2022" should also work, but is untested.
- CMake (Currently 3.16 or higher is needed.)
- Dlang, either dmd or ldc (ldc recommended)

### Linux
#### Dependencies
- The equivalent of build-essential on Ubuntu, on centos 7, this was `sudo yum groupinstall 'Development Tools'`, this should get you a working C++ toolchain.
- Dlang, either dmd or ldc (ldc recommended)
- CMake (Currently 3.16 or higher is needed.)
- SDL2 (developer package)
- Freetype (developer package)
- appimagetool (for building an AppImage)

### Agent Core and Apple Silicon development

This fork adds a deliberately renderer-free `agent-core` package and an
`agent-cli` executable. They validate and inspect an `.inx` container without
SDL, OpenGL, ImGui, a window, or `computer use`.

The initial stable command surface is:

```sh
cd agent-cli
dub run -- inspect model.inx
dub run -- roundtrip input.inx output.inx
dub run -- mesh-replace input.inx output.inx 42 replacement-mesh.json
dub run -- mesh-replace-path input.inx output.inx /Eyes/Iris replacement-mesh.json
dub run -- psd-inspect input.psd report.json
dub run -- psd-import input.psd output.inx
dub run -- sdk-validate output.inx
```

`roundtrip` validates the entire container before writing and retains its bytes
unchanged. `mesh-replace` validates an INX-native mesh JSON object
(`verts`/`uvs`/`indices`/`origin`), normalizes triangle winding, replaces only
the selected Part UUID's `mesh`, and retains all texture and extension payload
bytes unchanged. When the Part already has a `deform` parameter binding, a
vertex-count change is rejected until a deformation migration command exists;
a same-topology coordinate adjustment remains safe. The GUI uses the same
validation boundary before it asks Inochi2D to instantiate a puppet and
textures.

`mesh-replace-path` applies the same guarded mesh mutation through the stable
`psdLayerPath` retained by `psd-import`, so Agent workflows do not need to
discover generated UUIDs. Missing or ambiguous paths are rejected.

`psd-inspect` parses the Photoshop layer hierarchy and fully decodes every
usable leaf layer into RGBA without creating a GPU texture. Its JSON report
contains stable layer paths, bounds, visibility, channel/mask counts,
transparent/translucent/opaque pixel totals, and a SHA-256 digest for each
decoded layer. The source PSD is opened read-only.

`psd-import` builds an initial parameter-free INX project directly from a PSD:
groups become Nodes, pixel layers become texture-backed Parts, neutral
placement and visibility/opacity/blending are retained, and every Part keeps a
stable `psdLayerPath`. Each Part starts with the same four-vertex quad used by
Creator's original PSD import. Before the final path is replaced, the command
loads the temporary result through the official Inochi2D SDK in renderless
mode. Unsupported semantics such as unapplied layer/vector masks, non-normal
group blending, or group opacity fail explicitly rather than silently changing
the neutral artwork.

`sdk-validate` independently exercises that official SDK deserializer without
opening a window or creating an OpenGL context. It verifies Part creation and
all texture-slot references.

For this Apple Silicon macOS development environment, the GUI build entry point
is:

```sh
./build-aux/osx/AgentCliBuild.sh test --config=application
./build-aux/osx/AgentCliBuild.sh build --config=application
./build-aux/osx/AgentDevBuild.sh --build=debug
```

It expects LDC 1.41.0 in
`~/.local/share/inochi-agent/toolchain/ldc2-1.41.0-osx-arm64`, or an alternate
toolchain root through `INOCHI_AGENT_TOOLCHAIN`. The script locks the compatible
Inochi2D, Numem, and i2d-imgui generations for this Creator revision, then
builds an arm64 GUI. `AgentCliBuild.sh` applies the small upstream renderless
guard required by Inochi2D 0.8.7 before building or testing the CLI. The
renderer-independent container boundary is complete;
per-Part mesh replacement and initial PSD import also run without the GUI.
Parameter and deformer commands belong to the next Core extraction layers.

## Special Thanks

This project is funded through [NGI0 Entrust](https://nlnet.nl/entrust), a fund established by [NLnet](https://nlnet.nl) with financial support from the European Commission's [Next Generation Internet](https://ngi.eu) program. Learn more at the [NLnet project page](https://nlnet.nl/project/Inochi2D).

[<img src="https://nlnet.nl/logo/banner.svg" alt="NLnet foundation logo" width="20%" />](https://nlnet.nl)
