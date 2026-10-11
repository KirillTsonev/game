#!/bin/bash
# Builds the TerrainKernels library into addons/terrain_kernels/bin/.
#   ./build.sh            both variants (debug: the editor and debug exports; release: release exports)
#   ./build.sh debug      one variant
# Needs (see docs/native_kernels.md): MinGW-w64 in ../../mingw64, SCons in the Python below,
# godot-cpp in ./godot-cpp (git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp).
set -e
cd "$(dirname "$0")"
MINGW="$(cd ../.. && pwd)/mingw64/bin"
PYTHON="/d/Downloads/Random Things/Python/python.exe"
export PATH="$MINGW:$PATH"
VARIANTS="${1:-debug release}"
for v in $VARIANTS; do
	"$PYTHON" -m SCons platform=windows use_mingw=yes arch=x86_64 target=template_$v api_version=4.7 build_profile=build_profile.json -j"${JOBS:-10}"
done
