#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOLCHAIN_ROOT=${INOCHI_AGENT_TOOLCHAIN:-"$HOME/.local/share/inochi-agent/toolchain/ldc2-1.41.0-osx-arm64"}
DEPS_ROOT=${INOCHI_AGENT_DEPS_ROOT:-"$ROOT/.agent-deps"}
INOCHI2D_DIR="$DEPS_ROOT/inochi2d-0.8.7"
INOCHI2D_RENDERLESS_PATCH="$ROOT/build-aux/osx/patches/inochi2d-renderless-composite.patch"
INOCHI2D_DEFORMATION_PATCH="$ROOT/build-aux/osx/patches/inochi2d-deformation-deserialize.patch"

if [ ! -x "$TOOLCHAIN_ROOT/bin/ldc2" ]; then
    echo "LDC was not found at $TOOLCHAIN_ROOT/bin/ldc2." >&2
    echo "Set INOCHI_AGENT_TOOLCHAIN to an LDC toolchain root." >&2
    exit 1
fi

export PATH="$TOOLCHAIN_ROOT/bin:$PATH"
# LDC 1.41 predates the macOS version-number change. An explicit deployment
# triple avoids deriving invalid macOS 18 from newer Darwin host versions.
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
export INOCHI_AGENT_TOOLCHAIN="$TOOLCHAIN_ROOT"

if [ ! -d "$INOCHI2D_DIR/.git" ]; then
    mkdir -p "$DEPS_ROOT"
    git clone --depth 1 --branch v0.8.7 \
        https://github.com/Inochi2D/inochi2d.git "$INOCHI2D_DIR"
fi

if git -C "$INOCHI2D_DIR" apply --reverse --check "$INOCHI2D_RENDERLESS_PATCH" >/dev/null 2>&1; then
    :
elif git -C "$INOCHI2D_DIR" apply --check "$INOCHI2D_RENDERLESS_PATCH" >/dev/null 2>&1; then
    git -C "$INOCHI2D_DIR" apply "$INOCHI2D_RENDERLESS_PATCH"
elif grep -q 'version (InDoesRender)' \
    "$INOCHI2D_DIR/source/inochi2d/core/nodes/composite/package.d"; then
    :
else
    echo "The Inochi2D renderless patch does not match $INOCHI2D_DIR." >&2
    exit 1
fi

if git -C "$INOCHI2D_DIR" apply --reverse --check "$INOCHI2D_DEFORMATION_PATCH" >/dev/null 2>&1; then
    :
elif git -C "$INOCHI2D_DIR" apply --check "$INOCHI2D_DEFORMATION_PATCH" >/dev/null 2>&1; then
    git -C "$INOCHI2D_DIR" apply "$INOCHI2D_DEFORMATION_PATCH"
elif grep -q 'Deserialize each value into its' \
    "$INOCHI2D_DIR/source/inochi2d/core/param/binding.d"; then
    :
else
    echo "The Inochi2D deformation deserialization patch does not match $INOCHI2D_DIR." >&2
    exit 1
fi

INOCHI2D_MESHGROUP_PATCH="$ROOT/build-aux/osx/patches/inochi2d-meshgroup-point-location.patch"
if git -C "$INOCHI2D_DIR" apply --reverse --check "$INOCHI2D_MESHGROUP_PATCH" >/dev/null 2>&1; then
    :
elif git -C "$INOCHI2D_DIR" apply --check "$INOCHI2D_MESHGROUP_PATCH" >/dev/null 2>&1; then
    git -C "$INOCHI2D_DIR" apply "$INOCHI2D_MESHGROUP_PATCH"
else
    echo "The Inochi2D MeshGroup patch does not match $INOCHI2D_DIR." >&2
    exit 1
fi

# Local registrations are relative to the invoking package's cache. Register
# from the same directory as describe/build/test, otherwise DUB silently picks
# an unpatched registry copy for agent-cli.
cd "$ROOT/agent-cli"
dub add-local "$INOCHI2D_DIR" 0.8.7 --cache=local >/dev/null

ACTION=${1:-build}
if [ "$#" -gt 0 ]; then
    shift
fi

exec dub "$ACTION" --cache=local --compiler="$ROOT/build-aux/osx/agent-ldc2" "$@"
