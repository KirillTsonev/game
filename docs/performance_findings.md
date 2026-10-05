# Performance findings and remedy plan (2026-10-05)

What the first uncapped benchmark run showed, and what to do about it, in order. Update the
"Status" column as steps are done, and add the measured saving next to each one.

How to run and compare benchmarks: the "Performance benchmark" section of `CLAUDE.md`.

## The run these numbers come from

- Report: `perf_reports/20261005_094745_ea72f831_uncapped.json` (+ `.txt`), git `ea72f831`.
  This is the baseline for every later comparison.
- Setup: 1906x942 window, 3D render scale 0.85, RTX 3070 Laptop GPU, Godot 4.7.2, seed 858829582.
  Fullscreen at a higher resolution will be slower than these figures.
- **Baseline for later comparisons: `20261005_105951_ea72f831_baseline2.json`**, taken after the
  startup work in step 6 changed understory and flower placement. Against the report above its
  GPU ms are within 4 % at every station and its frame ms 1-7 % higher (apart from `spawn_sky`),
  with 10 frames over 16.7 ms in the walk where there were none. GPU time did not move, so that
  is on the CPU side; whether it is run-to-run noise or a real effect has not been checked. The
  findings below were not redone and still describe the first report.
- Do not compare against `20261005_000713_ea72f831_baseline.json`. That run was held at 60 FPS by
  a RivaTuner limiter, and its GPU ms read 2-19 % lower at seven of the eight stations for the
  same scene (cause unknown).

## Findings

### Frame times

| Station | Frame ms | GPU ms | CPU render ms | Draws | Tris (M) | FPS |
|---|---|---|---|---|---|---|
| spawn_ahead | 12.84 | 11.27 | 9.29 | 10,902 | 21.03 | 78 |
| road_open | 12.00 | 11.30 | 8.46 | 9,629 | 19.96 | 83 |
| exit_look_back | 11.49 | 11.06 | 7.75 | 8,393 | 21.34 | 87 |
| forest_dense | 10.97 | 10.62 | 6.91 | 8,204 | 17.16 | 91 |
| road_mid | 10.40 | 10.05 | 5.57 | 6,976 | 17.00 | 96 |
| cliff_face | 9.40 | 9.08 | 3.13 | 2,978 | 13.79 | 106 |
| spawn_ground | 7.23 | 6.80 | 4.60 | 6,178 | 15.87 | 138 |
| spawn_sky | 5.00 | 2.77 | 0.72 | 265 | 6.56 | 200 (on the RivaTuner limit) |

- 200 m walk: 11.90 ms average (84 FPS), p99 14.96 ms, worst 16.26 ms, no frame over 16.7 ms and
  none over twice the median. There is no stutter problem.
- VRAM: 1,764 MB at every station. Textures used by meshes and terrain: about 1,089 MB estimated.

### What the frame is spent on

GPU ms saved by switching each thing off, at the three ablation stations
(spawn_ahead / exit_look_back / forest_dense):

| Switched off | GPU ms saved | Draws saved | Tris saved (M) |
|---|---|---|---|
| All scattered layers | 7.95 / 7.88 / 7.09 | 10,790 / 8,291 / 8,110 | 20.5 / 20.7 / 16.7 |
| Trees | 4.79 / 3.94 / 3.65 | 3,115 / 2,605 / 2,094 | 8.3 / 6.1 / 5.7 |
| Sun shadows | 3.15 / 3.31 / 2.82 | 6,731 / 4,594 / 5,624 | 11.2 / 12.2 / 8.3 |
| Understory | 1.09 / 1.78 / 1.01 | 4,841 / 3,538 / 3,677 | 4.3 / 6.4 / 3.1 |
| Grass | 0.97 / 0.88 / 0.91 | 11 / 8 / 7 | 5.7 / 5.7 / 5.7 |
| Saplings | 0.20 / 0.43 / 0.28 | 1,062 / 906 / 789 | 1.2 / 1.4 / 0.7 |
| Half render scale | 4.13 / 4.36 / 3.67 | - | - |
| SSAO | 1.63 / 1.48 / 1.28 | - | - |
| All post effects | 1.79 / 1.61 / 1.51 | - | - |
| - of which painterly_sat | 0.88 / 0.94 / 0.74 | - | - |
| 3D MSAA | 1.19 / 1.03 / 0.81 | - | - |
| Lantern | 0.33 / 0.49 / 0.50 | - | - |

Rocks, cliffs, outcrops, flowers, deadfall and cones are each under 0.4 ms. The rows overlap:
switching a layer off also removes its shadow draws, so "trees" and "sun shadows" share cost and
must not be added together.

### Conclusions

1. **The game is GPU-bound.** Frame time is 0.3-1.6 ms above GPU time at every station.
2. **Vegetation is most of the frame.** All scattered layers together are 7-8 ms of an 11 ms GPU
   frame; trees alone are 3.7-4.8 ms.
3. **More than half of what is drawn is shadow passes.** Sun shadows account for 4,600-6,700 of
   the 8,000-11,000 draws and 8-12 M of the 17-21 M triangles.
4. **Trees have no middle level of detail.** Each is the full mesh (5,800-11,300 triangles) out to
   175 m, then an 8-triangle impostor. Shadows use the full mesh in every cascade out to 150 m.
5. **The understory casts shadows on every LOD**, including its 4-triangle impostors
   (22,132 instances in 5,414 nodes).
6. **About a third of the GPU frame scales with pixels.** Halving render scale saves 3.7-4.4 ms;
   SSAO, post effects and MSAA are the main parts.
7. **Draw calls are the next limit.** At spawn_ahead the CPU spends 9.3 ms submitting 10,900
   draws against a 12.8 ms frame. Once GPU time drops below about 9 ms, the draw count caps the
   frame rate, so remedies that cut draws are worth more than their GPU saving alone.
8. **Startup is slow but separate.** First frame at 15.8 s; world generation takes 12.0 s.
   Largest steps: heightmap build 2.9 s, ground painting 1.5 s, cliff dressing 1.4 s, outcrop
   placement 1.3 s, understory scattering 1.3 s, deadfall scattering 1.0 s.

## Remedy plan

Run the benchmark before and after each step and record the saving here. Expected savings are
left blank where nothing supports an estimate yet.

| # | Remedy | Addresses | Status |
|---|---|---|---|
| 1 | Split the tree cost into view and shadow | sizes steps 2 and 4 | not started |
| 2 | Mid LOD for trees, also used as the shadow mesh | conclusions 3, 4 | not started |
| 3 | Limit understory shadow casting | conclusions 3, 5, 7 | not started |
| 4 | Shorter sun shadow distance | conclusions 3, 4 | needs a decision |
| 5 | Cheaper screen-space settings | conclusion 6 | needs a decision |
| 6 | Startup time | conclusion 8 | cheap wins done: 16.3 s -> 8.8 s to first frame |

### 1. Split the tree cost into view and shadow

Run the targeted tree ablation (`--bench-only=layer:trees`) once with sun shadows on and once
with them off. The difference between the two "trees" figures is the shadow share. About two
minutes per run. No change to the game; this only decides how much steps 2 and 4 can save.

### 2. Mid LOD for trees, also used as the shadow mesh

Add a reduced mesh between the full tree and the impostor (roughly 40-60 m to 175 m) and render
shadows from it instead of the full mesh.

- Upper bound on the saving: the whole tree cost, 3.7-4.8 ms. The real figure depends on step 1.
- Risk: the crowns are leaf cards, which simplify badly. Each tree needs a visual check, both for
  the crown silhouette and for the shadow it casts.
- Constraints already documented: the impostor must stay at least 23 m beyond the shadow distance
  (`docs/vegetation.md`), and thin foliage shadows are fragile (`docs/shadows.md`). Read both
  before changing tree LODs.

### 3. Limit understory shadow casting

Stop ferns and small bushes casting sun shadows beyond their nearest LOD, or switch shadows off
for the smallest ferns entirely. The understory is 3,500-4,800 draws and 1.0-1.8 ms; this removes
the shadow part of it and cuts draw calls, which also helps the CPU side.

### 4. Shorter sun shadow distance (needs a decision)

Sun shadows reach 150 m over four cascades. Dropping to about 100 m cuts shadow work and would
let the tree impostor switch move in from 175 m to about 125 m, which also cuts visible tree
triangles. It is a visible change, and the current setup is recorded as final in
`docs/vegetation.md`, so it is the user's call.

### 5. Cheaper screen-space settings (needs a decision)

Look-versus-speed choices, each independent:

- SSAO: 1.3-1.6 ms at Low quality. The Options menu has a toggle and a quality dropdown
  (added 2026-10-05); try Very Low first.
- 3D MSAA (2x): 0.8-1.2 ms.
- Post effects: 1.5-1.8 ms in total, about half of it the painterly effect.

### 6. Startup time (in progress, started 2026-10-05)

Does not affect frame rate. Measured with a 20-frame launch
(`Godot_v4.7.2-stable_win64_console.exe --path herald-of-oblivion --quit-after 20`) and the
`TERRAIN_GEN` timing lines it prints.

Done 2026-10-05 -- world generation 12.11 s -> 8.61 s, first frame 16.26 s -> 12.83 s, generated
world unchanged (identical log output for the pinned seed):

| Change | Stage | Before | After |
|---|---|---|---|
| Cliff / outcrop models and textures load on background threads during the heightmap build (`TerrainPreload`) | cliff face dressing | 1.37 s | 0.06 s |
| same | outcrop placement | 1.35 s | 0.04 s |
| Rock collision hulls cached on disk (`TerrainUtil.cached_shape`) | boulder scattering | 0.82 s | 0.12 s |
| Deadfall collision shapes cached on disk (same helper) | deadfall scattering | 1.04 s | 0.92 s |

Second pass, same day -- hot loops moved onto the engine's worker threads (12 logical cores on
this machine). World generation 8.61 s -> 6.3 s, first frame 12.83 s -> 10.5 s:

| Change | Stage | Before | After | Output |
|---|---|---|---|---|
| Main per-vertex loop and rock-type majority filter in row bands (`_paint_band`, `_mode_band`) | ground painting | 1.49 s | 0.60 s | identical (control-map checksum 2130175883 before and after) |
| Candidate rows in bands, one random stream per row (`_scatter_band`) | understory scattering | 1.30 s | 0.40 s | changed once: 22,132 -> 22,442 plants; repeatable per seed (placement checksum printed) |
| same | flower scattering | 0.84 s | 0.27 s | changed once: 13,701 -> 13,484 pieces; repeatable per seed |

Kirill agreed on 2026-10-05 that plant placement for a given seed may change once for this. The
terrain, cliffs, road, rocks, trees, deadfall, saplings and grass are as before. Because the
plants in view changed, the frame-time baseline was retaken (see "The run these numbers come from").

How the threading is done, for the next stage that gets it:

- `WorkerThreadPool.add_group_task(band_func.bind(ctx), bands, -1, true)` + wait; `ctx` is a
  Dictionary of shared inputs. A band function only READS them, fills band-sized outputs of its
  own, and stores them in `ctx.out[band]` under `ctx.mutex`; the caller joins the bands in order.
- Never write to a shared packed array from a band: with more than one reference it is silently
  copied first, and the write is lost.
- Keep engine-object and GDExtension calls out of the per-element loop. With
  `Image.get_pixel()` and `Terrain3DUtil.get_base/enc_*` inside it, the ground-paint loop only went
  740 -> 504 ms on 12 cores; with the image read as bytes and the control bits packed in GDScript
  it went to 88 ms.
- Randomness: one `RandomNumberGenerator` per band, reseeded per row with
  `hash(row_seed + row)`, so the result does not depend on thread timing.
- Each threaded stage prints a checksum of its output. An output-preserving change must keep it;
  a threaded scatter must print the same value on two runs of the same seed.

What is left of the ~10.5 s:

| Part | Time |
|---|---|
| Before world generation starts (engine boot, loading `main.tscn` and what it references) | 3.2 s |
| Heightmap build: knots 0.73, erosion 0.62, road 0.51, outcrop planning 0.28, about 0.45 untimed | 2.9 s |
| Deadfall scattering | 0.93 s |
| Ground painting (0.26 setup, 0.23 threaded passes, 0.10 region write) | 0.60 s |
| Grass density bake | 0.48 s |
| Understory scattering | 0.40 s |
| Flower scattering | 0.27 s |
| Everything else | 0.7 s |
| After generation, to the first drawn frame (shader pipelines) | 1.0 s |

Investigation of the two largest remaining parts (2026-10-05, measurements only, no changes
beyond three extra timing prints in `heightmap.gd`):

Heightmap build, 2.92 s:

| Part | Time | Note |
|---|---|---|
| Knots | 0.75 s | reach + ramps 0.41, rows 0.21 (its own `KNOT_PROFILE` line) |
| Erosion (main + post-feature) | 0.61 s | ~300k droplet steps, already a tight loop; sequential |
| Road | 0.51 s | grading 0.23, pathfinding 0.11, blur 0.11, rasterising 0.06 |
| Cliff top profiles | 0.27 s | was the untimed part. Per model, no terrain input -> can be cached on disk |
| Outcrop planning + fitting | 0.23 s | includes analysing each outcrop model, which is also per model |
| Cliff dressing plan | 0.13 s | |
| Base noise | 0.12 s | |
| Knot restore + landmark stamp | 0.09 s | |
| Smoothing, colour map, stats, images | 0.17 s | |

Before generation starts, 3.2 s (probe scripts that load `main.tscn`'s dependencies one by one):

| Part | Time | Note |
|---|---|---|
| Engine boot until the first script runs | 1.1 s | fixed cost |
| `terrain_assets.tres` | 1.1 s | still 1.1 s with all 129 of its dependencies already loaded, so it is Terrain3D's own setup of the 85 mesh assets and texture arrays, not file loading |
| Compiling the terrain scripts (`terrain_gen.gd` and its modules) | 0.3-0.5 s | paid by whichever resource touches them first |
| `main.tscn` itself | 0.5 s | 28 KB; holds a 548-line embedded shader |

- The church model is no longer referenced by `main.tscn`, so the "oversized church textures"
  suspect in `CLAUDE.md` does not apply to startup any more.
- Loading `main.tscn` through the threaded loader with sub-threads took 1.8 s instead of 2.2 s:
  the dependencies already load in parallel, so there is little to gain that way.
- Nothing in this 3.2 s is cheap to remove. But the main thread spends ~2.2 s of it loading
  while the heightmap build (2.9 s) is pure computation that needs only the seed. Starting the
  heightmap build on a thread from an autoload, before the main scene loads, would overlap the
  two and save up to ~2 s. Not done: it adds an autoload and moves seed selection and the
  per-run state reset out of `WorldGenerator._ready()`.

Overlap probe (2026-10-05; a throwaway script outside the project, run with `-s`, that builds
the heightmap for the pinned seed either after loading `main.tscn` or on a `Thread` during it):

| | Runs | Scene loaded at | Heightmap ready at | Build time |
|---|---|---|---|---|
| Sequential (today's order) | 3 | 2.88 s | 5.84 s | 2.96 s |
| Overlapped | 25 | 2.86 s | 4.40 s | 3.06 s |

- Saving: 1.43 s on average (1.3-1.5 s), not the ~2 s first guessed. The build runs 3.5 %
  slower while it shares the machine with scene loading.
- Output: one identical checksum line across all 28 runs (heights, control map, colour map, road
  weight and path, spawn/exit, cliff plan, outcrop plan, cliff features, knots, top profiles).
  No errors, no hangs in the 25 overlapped runs.
- **Hard requirement found:** the main thread must NOT block in `Thread.wait_to_finish()` while
  the build is still running. When it did, the build thread hung for good at its next model load
  (`TerrainOutcrops.load_outcrop_models`), 2 times out of 2 -- the game window froze. With the
  main thread polling `while thread.is_alive(): RenderingServer.force_sync()` first, all 25 runs
  completed. So a thread that loads resources needs the main thread to keep servicing the
  renderer; this applies to any future threaded stage that calls `load()`.
- Module state the heightmap build writes (what the per-run reset must not wipe afterwards):
  only `CliffDressing._raise_debug_heights` / `_raise_debug_entry_index` and
  `TerrainLandmarks._cache`.
- Not covered by the probe: the real launch path (autoload, the wait inside
  `WorldGenerator._ready()`, the benchmark's startup timings).

Third pass, same day -- the two model-only scans cached on disk (`TerrainUtil.cached_value`,
files in `user://model_analysis_cache/`, keyed by glb path + mtime + the def's text + a version
constant per scan). Heightmap build 2.92 s -> 2.48 s, world generation 6.25 s -> 5.87 s, first
frame 10.3 s -> 9.98 s. Output identical: the probe's full checksum line matches on the
cache-filling run and on cache hits, and the in-game understory / flower / ground-paint
checksums are unchanged.

| Change | Part | Before | After |
|---|---|---|---|
| Cliff top-profile scan cached (`_scan_cliff_dressing_top_profile`) | cliff top profiles | 0.27 s | 0.00 s |
| Outcrop model scan cached (`_scan_outcrop_model`) | outcrop planning + fitting | 0.23 s | 0.03 s |

Fourth pass, same day -- profiled deadfall, the grass bake, ground-paint setup and the gap to
the first frame, then fixed what was exact and cheap. World generation 5.87 s -> 4.72 s, first
frame 9.98 s -> 8.81 s. Output identical: deadfall, understory, flower, grass (density / worn /
patch) and ground-paint checksums, plus the mound and cone counts, all match the run before.

| Change | Stage | Before | After |
|---|---|---|---|
| `_capsule_blocked` looks up circles and placed pieces through grids (`circle_grid`, `placed_grid`) instead of scanning every one; the scan was 0.67 s | deadfall scattering | 0.93 s | 0.41 s |
| Per-pixel combine in row bands (`_bake_band`); its 6 noise images rendered together (`noise_images_parallel`) | grass density bake | 0.48 s | 0.16 s |
| Its 7 noise images rendered together | ground painting | 0.60 s | 0.47 s |
| Canopy grid built once per run and reused (`UnderstoryScatter._build_canopy_grid` cache); it was rebuilt 5 times at ~50 ms | understory / flowers / the above | 0.40 / 0.27 s | 0.34 / 0.22 s |

Things learned while profiling:

- One `FastNoiseLite.get_image()` at map size is ~16 ms, not the ~1 ms an old comment claimed.
- From the end of `_ready()` to the first drawn frame (0.94 s), measured with one-shot signal
  hooks and `node_added`: ~0.19 s before the deferred containers are added (first physics step),
  ~0.01 s for the boulder / tree / deadfall collider containers, ~0.23 s for `GrassField`
  entering the tree, ~0.13 s for the outcrop and cliff containers (their trimesh colliders),
  ~0.08 s unaccounted, then ~0.30 s drawing the first frame (120 shader pipelines compile there).
  No cheap fix was identified in any of these.

What is left of the 8.8 s: 3.15 s before generation, heightmap build 2.45 s (knots 0.75,
erosion 0.61, road 0.51, the rest ~0.6), ground painting 0.47 (road scan + stamps 0.08, seam and
litter passes 0.10, region write 0.10, threaded passes ~0.15), deadfall 0.41 (stands loop 0.22,
cones 0.10), understory 0.34, flowers 0.22, grass 0.16, the other stages ~0.6, and 0.94 s to the
first frame.

Candidates still open, none started:

- Overlap the heightmap build with main-scene loading (above): ~1.4 s, but only for a world
  generated at process launch (a later in-game regeneration has no scene load to overlap with),
  and with the wait rule above. Kirill chose the disk caches first; the overlap is undecided.

- Heightmap build, the rest: sequential by nature (droplets, A*, knot placement), so only loop
  tightening applies; knots (0.75 s) is the largest piece.
- A per-seed world cache on disk would skip most of generation while the seed is pinned, but
  does nothing for a fresh random seed.

## Not worth touching yet

- Rocks: 35.7 M triangles at LOD 0 on paper, but under 0.4 ms measured. Their LODs and culling
  already work.
- Cliffs, outcrops, flowers, deadfall, cones: each under 0.4 ms.
- Grass: about 0.9 ms for a million instances in 7 nodes. Already cheap per instance.
