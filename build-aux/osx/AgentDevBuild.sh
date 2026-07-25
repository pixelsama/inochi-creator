#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOLCHAIN_ROOT=${INOCHI_AGENT_TOOLCHAIN:-"$HOME/.local/share/inochi-agent/toolchain/ldc2-1.41.0-osx-arm64"}
DEPS_ROOT=${INOCHI_AGENT_DEPS_ROOT:-"$ROOT/.agent-deps"}
I2D_IMGUI_DIR="$DEPS_ROOT/i2d-imgui-0.8.1"
I2D_PATCH="$ROOT/build-aux/osx/patches/i2d-imgui-arm64-development.patch"
INOCHI2D_DIR="$DEPS_ROOT/inochi2d-0.8.7"
NUMEM_DIR="$DEPS_ROOT/numem-0.20.1"

if [ ! -x "$TOOLCHAIN_ROOT/bin/ldc2" ]; then
    echo "LDC was not found at $TOOLCHAIN_ROOT/bin/ldc2." >&2
    echo "Set INOCHI_AGENT_TOOLCHAIN to an LDC toolchain root." >&2
    exit 1
fi

export PATH="$TOOLCHAIN_ROOT/bin:$PATH"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export INOCHI_AGENT_OSX_ARCHITECTURES=${INOCHI_AGENT_OSX_ARCHITECTURES:-arm64}

cd "$ROOT"

if [ ! -d "$I2D_IMGUI_DIR/.git" ]; then
    mkdir -p "$DEPS_ROOT"
    git clone --depth 1 --branch v0.8.1 --recurse-submodules \
        https://github.com/Inochi2D/i2d-imgui.git "$I2D_IMGUI_DIR"
fi

if ! git -C "$I2D_IMGUI_DIR" apply --reverse --check "$I2D_PATCH" >/dev/null 2>&1; then
    git -C "$I2D_IMGUI_DIR" apply "$I2D_PATCH"
fi

if [ ! -d "$NUMEM_DIR/.git" ]; then
    git clone --depth 1 --branch v0.20.1 \
        https://github.com/Inochi2D/numem.git "$NUMEM_DIR"
fi

if [ ! -d "$INOCHI2D_DIR/.git" ]; then
    git clone --depth 1 --branch v0.8.7 \
        https://github.com/Inochi2D/inochi2d.git "$INOCHI2D_DIR"
fi

dub add-local "$I2D_IMGUI_DIR" 0.8.1 --cache=local >/dev/null
dub add-local "$NUMEM_DIR" 0.20.1 --cache=local >/dev/null
dub add-local "$INOCHI2D_DIR" 0.8.7 --cache=local >/dev/null
dub upgrade numem --cache=local >/dev/null
exec dub build --cache=local --compiler=ldc2 --config=osx-full "$@"
