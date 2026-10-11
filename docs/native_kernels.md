# Native kernels

Since 2026-10-10 the hottest loops of terrain generation can run as compiled C++ instead of
GDScript. This file says what is there, how to build it, and the rules for moving a loop over.

## What it is

- A GDExtension, `addons/terrain_kernels/` (the `.gdextension` file and the built DLLs in `bin/`),
  the same mechanism as Terrain3D. It registers one class, `TerrainKernels`.
- The source is in `native/src/`; `native/` has a `.gdignore`, so the editor does not scan it.
- Scripts never name the class. They ask `TerrainUtil.kernels()`, which returns the object or
  null; on null the caller runs its own GDScript loop. Null when: the DLL is missing,
  `TerrainUtil.NATIVE_KERNELS` is false, the library's `get_version()` is not
  `NATIVE_KERNELS_VERSION`, or the game was started with `-- --no-native-kernels`.
- The log says which it is: `TERRAIN_GEN: native kernels -- in use` / `NOT in use (...)`.

Moved so far:

| Kernel | GDScript original | Before | After |
|---|---|---|---|
| `erode` | `TerrainErosion.erode` | 1.10 s | 0.05 s |
| `mode_filter`, `blend_borders` | `TerrainGroundPaint._mode_band`, `_blend_band` (and the block grid they needed) | 0.45 s | 0.045 s |
| `obstacle_distance` | `TerrainRoad._obstacle_distance` | 0.17 s | 0.005 s |
| `road_search` | the A* loop of `TerrainRoad._find_road_path` | 0.08 s | 0.03 s with the script's node setup |
| `knot_flood` | `TerrainKnots._flood` (also the 22 floods round crease rounding) | crease rounding 0.33 s | 0.16 s |
| `knot_first_clear_pair` | the pair loop of `TerrainKnots._carve_ramp` with `_segment_clear_top` | reach + ramps 1.45 s on seed 2415213935, 0.12 s on 3082472107 | 0.18 s, 0.09 s |
| `dilate`, `height_diff_mask` | `TerrainKnots._dilate`, the first loop of `_build_occupancy` | occupancy 0.17 s | 0.05 s |
| `count_changed_outside` | the self-check at the end of `TerrainKnots.build_knots` | 0.07 s | 0.001 s |
| `cliff_raise` | the two pixel loops of `CliffDressing.raise_terrain_behind_cliff_dressing` (the script still works out each entry's values) | knot rows 0.42 s, cliff dressing 0.23 s | 0.11 s, 0.04 s |
| `paint_main` | `TerrainGroundPaint._paint_band` | 0.22 s (0.88 s from the editor) | 0.08 s |
| `grass_bake`, `height_min_max` | `GrassScatter._bake_band`, the height range loop of `bake` | grass bake 0.39 s (1.0 s from the editor) with the two rows below | 0.19 s |
| `stamp_circles` | `GrassScatter.stamp_circles` / `_stamp_band` (grass bake and ground paint) | | |
| `road_vertex_circles` | the road-vertex scans of `GrassScatter.bake` and `TerrainGroundPaint.paint` | | |
| `smooth` | `TerrainHeightmap.smooth` (first smoothing, the road's graded target, crease rounding) | 0.06 + 0.08 s, crease rounding 0.16 s (0.19 + 0.25 s, 0.37 s from the editor) | 0.01 + 0.005 s, 0.09 s |
| `road_raster`, `road_bed` | `TerrainRoad._raster_band`; `_grade_level_bed` from `_bed_band` to its crease smoothing | 0.03 s, 0.14 s (0.11 s, 0.48 s from the editor) | 0.02 s, 0.03 s |
| `apron_heights`, `apron_colors` | `MountainWalls._apron_height_band`, `_apron_color_band` | the two side aprons 0.36 s (0.60 s from the editor) | 0.16 s |
| `north_heights`, `north_colors` | `TerrainCastle._north_height_band`, `_north_color_band` | north apron 0.28 s (0.37 s from the editor) | 0.20 s |

All times are with the editor's executable in a command-line launch unless they say "from the
editor" (F5, with the debugger attached: see "Started from the editor" below). The rows after
`erode` are from 2026-10-11. With all of them a start that builds its world takes 7.2 s on seed
3082472107 and 7.4 s on 2415213935 (11.1 and 11.8 s the day before; 11.3 and 12.9 s with
`--no-native-kernels`), and the heightmap build 1.66 and 1.73 s (was 3.2 and 4.5 s).

Release export (`builds/startup_timing`, exported with
`--headless --export-release "Windows Desktop" ../builds/startup_timing/herald_timing.exe`):

| | World generation | First frame |
|---|---|---|
| Scripts only (2026-10-10) | 9.9 s | 12.9 s |
| `erode` alone | 8.6 s | 11.5 s |
| All kernels above but `cliff_raise` | 7.5 - 7.8 s | 10.4 - 10.8 s |
| All of them, and the shoulder loops threaded | 6.9 - 7.7 s | 9.9 - 10.8 s |
| All kernels in the table | 6.05 - 6.33 s | 8.9 - 9.2 s |

Three runs each for the last three rows (two on seed 3082472107, one on 2415213935), same
checksums as the editor's executable. Runs of one build differ by up to 0.5 s on this laptop,
more as it warms up: compare stage times, not one total.

## Started from the editor (F5)

A start from the editor is slower than a command-line launch of the same executable: with the
debugger attached GDScript runs 2-4 times slower, loops on worker threads most of all, and a
kernel runs at the same speed either way. Kirill's F5 starts on 2026-10-11, before the kernels
from `paint_main` down: 11.8 - 12.4 s, against 8.1 - 8.4 s from a command line (ground paint
1.79 against 0.74 s, grass bake 1.0 against 0.39 s, aprons and join 1.36 against 0.84 s). After
them: 8.97 s (one run, a random seed; first frame at 12.8 s).

To measure it: the Godot MCP's `run_scene` (after `is_playing` says no game is running), wait
25 s, `get_console_log`, `stop_scene`. What is still slow there and has no kernel is listed in
`docs/performance_findings.md`, "Still slow in a start from the editor".

Notes from the later kernels:

- A script loop that ran in bands on worker threads is one plain loop in the kernel: at these
  sizes it is faster than the threaded script, and the order is the single loop's.
- The script's `Vector2` arithmetic is 32-bit float. A kernel that repeats it uses `float`
  variables for exactly those values (`KVec2`, the `distance_to` in `road_search`), and doubles
  for everything the script keeps in a plain variable.
- `smoothstep`: `Math::smoothstep` from the bindings' `core/math.hpp`, which is the engine's own
  definition compiled into the kernel (the first kernels ask `UtilityFunctions::smoothstep`; a
  loop that calls it twenty times per pixel cannot afford a call into the engine each time).
  `sin` and `cos` are still asked from the engine.
- The script's `Color` arithmetic is 32-bit float as well (`KColor`, `k_color_lerp`).
- A kernel that takes over a whole band function reads the band's own `ctx` dictionary, and the
  module's constants from a dictionary by name (`K_CONST`: a missing name stops the kernel with
  an error and the script falls back). A new constant in the script loop goes into both lists.
- Sums the script adds up per band and then band by band are added the same way in the kernel
  (`paint_main`, `grass_bake`), so the printed statistics match to the last digit.
- A kernel whose time is the engine's noise functions gains nothing from being compiled; the
  four apron kernels run their rows on up to eight threads of their own (`k_parallel_rows`).
  Only for rows that are independent, with counts and extremes merged under a mutex.
- Kernels are called from worker threads too (`knot_flood` and `knot_first_clear_pair`, from
  the knots' reach tasks). They keep no state, so that is safe; a new one must keep none either.
- A kernel may call an engine object passed to it (`cliff_raise` reads two `FastNoiseLite`):
  its class goes into `native/build_profile.json`. Arguments that are `float` in the engine
  (noise coordinates) are cast to `float` in the kernel as the script's call casts them.
- When a function is mostly per-item setup round a hot pixel loop, only the loop moves: the
  script hands the kernel one flat row of numbers per item (`CLIFF_RAISE_ENTRY`).
- A world-cache start skips the heightmap stages: verify road and knot kernels with
  `-- --no-world-cache` on both runs, or the fallback run only reads what the native run wrote.

## Building

One command, from Git Bash: `native/build.sh` (both variants) or `native/build.sh debug`.
About 10 s per variant. The editor may stay open: it loads a copy (`bin/~lib...`), and with
`reloadable = true` it picks the new DLL up.

- `debug` is what the editor, command-line launches and debug exports load; `release` is what a
  release export ships. Build both before an export.
- The export copies the release DLL beside the exe by itself.

What the build needs on this machine (none of it on PATH; `build.sh` has the paths):

- MinGW-w64, the WinLibs GCC 16.1 zip, unpacked at `D:\Downloads\Godot_v4.7.2-stable_win64.exe\mingw64`.
- SCons, `pip install scons` into the Python at `D:\Downloads\Random Things\Python`.
- The bindings: `git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp`
  into `native/godot-cpp` (not versioned). godot-cpp is no longer numbered like the engine; the
  build picks the interface with `api_version=4.7`.
- `native/build_profile.json` limits the bindings to the classes used, which is why a first
  build takes seconds and not ten minutes. A kernel that needs another engine class: add it there.

A new Godot minor version: fetch a godot-cpp release that lists it and change `api_version`.

## Rules for moving a loop

1. The GDScript loop stays, as the reference and the fallback. A change to one is a change to both.
2. The C++ repeats the script operation for operation: doubles for script floats, a 32-bit float
   exactly where the script reads or writes a packed float32 array, the same order of additions.
   `maxf` / `minf` are the engine's macros (`a > b ? a : b`), not `std::max`.
3. Random numbers come from the script's own `RandomNumberGenerator`, passed in, in the same
   order. `sin`, `cos` and the like are asked from the engine (`UtilityFunctions`), so their last
   digit cannot differ; `sqrt` is exact everywhere.
4. Tunables stay in the script and are passed as arguments, so tuning needs no rebuild.
5. A packed array passed to a kernel is not changed (writing to it copies it): the kernel returns
   the result and the script puts it back (`clear()` + `append_array()` keeps the caller's array).
6. `SConstruct` switches off fused multiply-add and fast-math. Leave that.
7. Verify like any speed-only change: two seeds, with and without `--no-native-kernels`, every
   checksum equal (`docs/startup_optimisation.md`). If they differ, the port is wrong.
8. When a kernel's signature or behaviour changes, bump `get_version()` and
   `TerrainUtil.NATIVE_KERNELS_VERSION` together, so an old DLL is refused, not misused.

A bug in native code closes the game with no script error. If a start dies in generation after
a native change, run it once with `-- --no-native-kernels` to see whether the library is the cause.
