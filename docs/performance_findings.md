# Performance findings and remedy plan (2026-10-05)

What the first uncapped benchmark run showed, and what to do about it, in order. Update the
"Status" column as steps are done, and add the measured saving next to each one.

How to run and compare benchmarks: the "Performance benchmark" section of `CLAUDE.md`.

## The run these numbers come from

- Report: `perf_reports/20261005_094745_ea72f831_uncapped.json` (+ `.txt`), git `ea72f831`.
  This is the baseline for every later comparison.
- Setup: 1906x942 window, 3D render scale 0.85, RTX 3070 Laptop GPU, Godot 4.7.2, seed 858829582.
  Fullscreen at a higher resolution will be slower than these figures.
- **Baseline for later comparisons, since 2026-10-05 afternoon:
  `20261005_143830_40598523_baseline3.json`.** Three things changed against `baseline2`: SSAO
  off (step 5), understory shadows from the nearest LOD only (step 3), and Kirill's short-grass
  range, 25 / 60 m -> 50 / 100 m (`SHORT_LAYERS`; grass now costs 1.3-1.6 ms of GPU where it
  cost 0.9-1.0, instance buffers 64 -> 111 MB). baseline2 -> baseline3:

  | Station        | GPU ms         | Frame ms       | Render CPU ms | Draws           |
  | -------------- | -------------- | -------------- | ------------- | --------------- |
  | spawn_ahead    | 11.37 -> 10.59 | 13.12 -> 15.92 (disturbed) | 9.58 -> 11.89 (disturbed) | 10,875 -> 8,137 |
  | road_open      | 10.91 -> 10.31 | 12.90 -> 11.33 | 9.25 -> 7.62  | 9,593 -> 6,995  |
  | exit_look_back | 10.94 -> 10.05 | 11.98 -> 11.24 | 8.57 -> 7.57  | 8,391 -> 7,117  |
  | forest_dense   | 10.48 -> 9.55  | 11.57 -> 10.46 | 7.73 -> 5.90  | 8,202 -> 5,797  |
  | road_mid       | 10.06 -> 9.12  | 10.51 -> 9.69  | 5.87 -> 4.66  | 6,970 -> 4,973  |
  | cliff_face     | 9.23 -> 8.31   | 9.57 -> 8.96   | 3.19 -> 2.73  | 2,967 -> 2,374  |
  | spawn_ground   | 6.79 -> 5.94   | 7.45 -> 6.61   | 5.02 -> 3.29  | 6,165 -> 3,568  |

  Road walk: 12.25 -> 10.94 ms (82 -> 91 FPS), p99 16.09 -> 13.16 ms, frames over 16.7 ms
  10 -> 0. spawn_ahead's station reading had frame spikes (p95 26 ms; it is the first station
  measured) -- its GPU figure is usable, its frame and CPU figures are not. The tables under
  "Findings" still describe the first report.
- Baseline before that: `20261005_105951_ea72f831_baseline2.json`, taken after the
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

| Station        | Frame ms | GPU ms | CPU render ms | Draws  | Tris (M) | FPS                          |
| -------------- | -------- | ------ | ------------- | ------ | -------- | ---------------------------- |
| spawn_ahead    | 12.84    | 11.27  | 9.29          | 10,902 | 21.03    | 78                           |
| road_open      | 12.00    | 11.30  | 8.46          | 9,629  | 19.96    | 83                           |
| exit_look_back | 11.49    | 11.06  | 7.75          | 8,393  | 21.34    | 87                           |
| forest_dense   | 10.97    | 10.62  | 6.91          | 8,204  | 17.16    | 91                           |
| road_mid       | 10.40    | 10.05  | 5.57          | 6,976  | 17.00    | 96                           |
| cliff_face     | 9.40     | 9.08   | 3.13          | 2,978  | 13.79    | 106                          |
| spawn_ground   | 7.23     | 6.80   | 4.60          | 6,178  | 15.87    | 138                          |
| spawn_sky      | 5.00     | 2.77   | 0.72          | 265    | 6.56     | 200 (on the RivaTuner limit) |

- 200 m walk: 11.90 ms average (84 FPS), p99 14.96 ms, worst 16.26 ms, no frame over 16.7 ms and
  none over twice the median. There is no stutter problem.
- VRAM: 1,764 MB at every station. Textures used by meshes and terrain: about 1,089 MB estimated.

### What the frame is spent on

GPU ms saved by switching each thing off, at the three ablation stations
(spawn_ahead / exit_look_back / forest_dense):

| Switched off             | GPU ms saved       | Draws saved            | Tris saved (M)     |
| ------------------------ | ------------------ | ---------------------- | ------------------ |
| All scattered layers     | 7.95 / 7.88 / 7.09 | 10,790 / 8,291 / 8,110 | 20.5 / 20.7 / 16.7 |
| Trees                    | 4.79 / 3.94 / 3.65 | 3,115 / 2,605 / 2,094  | 8.3 / 6.1 / 5.7    |
| Sun shadows              | 3.15 / 3.31 / 2.82 | 6,731 / 4,594 / 5,624  | 11.2 / 12.2 / 8.3  |
| Understory               | 1.09 / 1.78 / 1.01 | 4,841 / 3,538 / 3,677  | 4.3 / 6.4 / 3.1    |
| Grass                    | 0.97 / 0.88 / 0.91 | 11 / 8 / 7             | 5.7 / 5.7 / 5.7    |
| Saplings                 | 0.20 / 0.43 / 0.28 | 1,062 / 906 / 789      | 1.2 / 1.4 / 0.7    |
| Half render scale        | 4.13 / 4.36 / 3.67 | -                      | -                  |
| SSAO                     | 1.63 / 1.48 / 1.28 | -                      | -                  |
| All post effects         | 1.79 / 1.61 / 1.51 | -                      | -                  |
| - of which painterly_sat | 0.88 / 0.94 / 0.74 | -                      | -                  |
| 3D MSAA                  | 1.19 / 1.03 / 0.81 | -                      | -                  |
| Lantern                  | 0.33 / 0.49 / 0.50 | -                      | -                  |

Rocks, cliffs, outcrops, flowers, deadfall and cones are each under 0.4 ms. The rows overlap:
switching a layer off also removes its shadow draws, so "trees" and "sun shadows" share cost and
must not be added together.

### Per-pass profile (2026-10-05, editor Visual Profiler)

Direct readings, not ablation. Taken with the game run from the editor and held at a benchmark
station (PerfDebug F10; F11 = sun shadows, J = layers). One frame per capture, read from
Kirill's screenshots of Debugger > Visual Profiler. CPU times are higher than the benchmark's
(13.99 ms against 9.6 ms render CPU at this station): the game runs under the editor's debugger
with profiling on. GPU total matches the benchmark (11.33 against 11.3 ms).

spawn_ahead, normal -- "Render 3D Scene" 13.99 ms CPU / 11.33 ms GPU:

| Pass                                   | CPU ms | CPU % | GPU ms | GPU % |
| -------------------------------------- | ------ | ----- | ------ | ----- |
| Sun shadow passes                      | 5.31   | 38    | 3.40   | 30    |
| Opaque pass                            | 2.69   | 19    | 3.32   | 29    |
| Depth pre-pass                         | 3.55   | 25    | 2.36   | 21    |
| Post effects (compositor) + tonemap    | 0.27   | 2     | 1.78   | 16    |
| Setup 3D scene                         | 1.29   | 9     | 0.00   | 0     |
| Culling (all of it in shadow split 3)  | 0.58   | 4     | 0.00   | 0     |
| Transparent pass                       | 0.15   | 1     | 0.16   | 1     |
| SSAO (prepare + process)               | 0.03   | 0     | 0.08   | 1     |
| Everything else (MSAA resolves, sky, cluster) | 0.12 | 1  | 0.23   | 2     |

- Three passes each submit the scene's draws again: shadows, depth pre-pass, opaque. Together
  they are 80 % of the GPU time and, in the three captures with shadows on, 79-83 % of the CPU
  time.
- The depth pre-pass was not in any earlier analysis. It costs more CPU than the opaque pass in
  all four captures.
- This capture was a slow frame on the CPU side (see "CPU: use the benchmark's averages" below):
  its CPU column shows the order of the passes, not their usual size.
- SSAO's own passes are 0.08 ms GPU, so the 1.3-1.9 ms that switching SSAO off saves is spent
  in another pass. Which one needs a capture with SSAO off.

spawn_ahead, sun shadows off -- "Render 3D Scene" 7.39 ms CPU / 8.49 ms GPU (the benchmark's
shadows-off run read 8.54 ms GPU here):

| Pass                                | CPU ms | vs normal | GPU ms | vs normal |
| ----------------------------------- | ------ | --------- | ------ | --------- |
| Sun shadow passes                   | 0.00   | -5.31     | 0.00   | -3.40     |
| Opaque pass                         | 2.21   | -0.48     | 3.06   | -0.26     |
| Depth pre-pass                      | 3.10   | -0.45     | 3.09   | +0.73     |
| Post effects (compositor) + tonemap | 0.28   | +0.01     | 1.90   | +0.12     |
| Setup 3D scene                      | 1.33   | +0.04     | 0.00   | 0         |
| Culling                             | 0.21   | -0.37     | 0.00   | 0         |
| Total                               | 7.39   | -6.60     | 8.49   | -2.84     |

- Sun shadows cost 2.84 ms of GPU at this station. (The 6.6 ms CPU difference is against the
  slow normal frame; the benchmark's average is 3.5-3.8 ms -- see "CPU: use the benchmark's
  averages" below.)
- The depth pre-pass read 0.73 ms higher on the GPU with shadows off. One frame each, so this
  may be how the GPU timestamps fall and not a real change; not explained.

spawn_ahead, trees hidden (J panel), sun shadows on -- "Render 3D Scene" 7.37 ms CPU / 7.50 ms GPU:

| Pass                                | CPU ms | vs normal | GPU ms | vs normal |
| ----------------------------------- | ------ | --------- | ------ | --------- |
| Sun shadow passes                   | 2.70   | -2.61     | 1.26   | -2.14     |
| Opaque pass                         | 1.21   | -1.48     | 2.09   | -1.23     |
| Depth pre-pass                      | 1.91   | -1.64     | 1.52   | -0.84     |
| Transparent pass                    | 0.01   | -0.14     | 0.01   | -0.15     |
| Setup 3D scene                      | 0.75   | -0.54     | 0.00   | 0         |
| Culling                             | 0.44   | -0.14     | 0.00   | 0         |
| Sky                                 | 0.01   | 0         | 0.32   | +0.31     |
| Post effects (compositor) + tonemap | 0.25   | -0.02     | 2.03   | +0.25     |
| Total                               | 7.37   | -6.62     | 7.50   | -3.83     |

- The trees are 4.4 ms of GPU in their own passes (shadows 2.14, opaque 1.23, depth pre-pass
  0.84, transparent 0.15). The net GPU saving is 3.83 ms because the sky they hid now has to be
  drawn and the post effects read 0.25 ms higher.
- Shadow share of the trees' GPU cost: 2.14 of 4.36 ms, 49 %. The benchmark's split gave 2.07 ms
  at this station.
- The transparent pass empties when the trees are hidden, so its 0.15 ms is tree geometry.
  Probably the trees inside the LOD cross-fade band, which Godot draws as transparent; not checked.
- **Do not use the CPU "vs normal" columns of these tables.** See "CPU: use the benchmark's
  averages" below. (A first reading of this capture said the trees were 47 % of the CPU time and
  that a tree draw costs twice an average draw. Both were artefacts of the normal capture.)

spawn_ahead, SSAO off (Options menu), everything else on -- "Render 3D Scene" 9.84 ms CPU /
10.68 ms GPU:

| Pass                                | CPU ms | GPU ms | GPU vs normal |
| ----------------------------------- | ------ | ------ | ------------- |
| Sun shadow passes                   | 3.46   | 3.57   | +0.17         |
| Opaque pass                         | 1.76   | 3.53   | +0.21         |
| Depth pre-pass (+ its MSAA resolve) | 2.57   | 1.40   | -1.03         |
| Post effects (compositor) + tonemap | 0.29   | 1.87   | +0.09         |
| SSAO (prepare + process)            | 0.00   | 0.00   | -0.08         |
| Transparent pass                    | 0.10   | 0.17   | +0.01         |
| Total                               | 9.84   | 10.68  | -0.65         |

- **SSAO's cost sits in the depth pre-pass**: 1.03 ms of it there, 0.08 ms in SSAO's own
  passes. With SSAO on, the pre-pass also writes normals and roughness for everything it draws.
  That is why the quality level changes nothing (step 5): the level only affects the 0.08 ms.
- The total saving reads 0.65 ms here against 1.3-1.9 ms in the benchmark. One frame; the
  shadow and opaque passes each read about 0.2 ms higher in this capture.

**CPU: use the benchmark's averages, not these captures.** The four captures had every layer and
the sun shadows on in two of them (normal, SSAO off), yet their CPU totals are 13.99 and 9.84 ms
and their shadow-pass CPU 5.31 and 3.46 ms. A single profiler frame is not repeatable on the CPU
side (the frame graph shows spikes); the normal capture was a slow frame. The benchmark records
render CPU averaged over 120+ frames for every toggle (`cpu_render_ms` in the json; not in the
.txt). Render CPU ms saved, spawn_ahead / exit_look_back / forest_dense, first full report and
`baseline2`:

| Switched off      | Render CPU ms saved (uncapped) | (baseline2)        | Draws saved           |
| ----------------- | ------------------------------ | ------------------ | --------------------- |
| All scattered layers | 8.81 / 7.28 / 5.88          | 9.56 / 8.72 / 6.98 | 10,790 / 8,291 / 8,110 |
| Understory        | 4.68 / 3.57 / 2.77             | 3.99 / 4.18 / 2.93 | 4,841 / 3,538 / 3,677 |
| Sun shadows       | 3.80 / 1.92 / 2.86             | 3.56 / 3.04 / 3.40 | 6,731 / 4,594 / 5,624 |
| Trees             | 2.85 / 2.43 / 1.61             | 2.45 / 3.13 / 2.22 | 3,115 / 2,605 / 2,094 |
| Saplings          | 1.27 / 1.07 / 0.60             | 0.52 / 0.84 / 0.45 | 1,062 / 906 / 789     |
| Rocks             | 1.03 / 0.62 / 0.72             | 0.45 / 0.34 / 0.96 | 581 / 296 / 530       |
| Sun shadows at 100 m (later run) | 0.39 / 0.94 / 0.50 | -              | 1,845 / 1,424 / 1,445 |
| SSAO, MSAA, half render scale | under 0.6 each (one outlier) | under 0.6 each | -            |

Baseline render CPU: 9.2-10.0 / 7.6-9.1 / 6.2-7.4 ms.

- **The scattered layers are 95 % of the render CPU time**, and it follows the draw count at
  about 0.8-1.0 microseconds per draw for every layer (shadow draws about 0.5).
- **The understory is the largest CPU item, 40-50 %**, ahead of the trees (25-35 %). On the GPU
  it is only 0.9-1.6 ms. The trees are the largest GPU item.
- The spread between the two reports for the same toggle is up to about 1 ms.
- Not explained: at the heavy stations the frame is about 3 ms longer than the render CPU time
  even when the GPU is far from the limit (spawn_ahead at half render scale: frame 12.62, render
  CPU 9.14, GPU 7.81 ms). Something on the CPU outside the measured render time takes it.

### Conclusions

1. **The game is GPU-bound.** Frame time is 0.3-1.6 ms above GPU time at every station.
   **Corrected 2026-10-05 (step 1):** at the two heaviest ablation stations the CPU limits the
   frame just as much. Halving render scale there saves 4.0-4.4 ms of GPU time but only
   0.05-0.6 ms of frame time (both full reports; at forest_dense it saves 1.9-2.7 ms). GPU and
   CPU are about level, so both have to come down.
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
   **Corrected 2026-10-05 (step 1):** this is already the case at spawn_ahead, exit_look_back and
   road_open, not only below 9 ms. See the correction to conclusion 1.
8. **Startup is slow but separate.** First frame at 15.8 s; world generation takes 12.0 s.
   Largest steps: heightmap build 2.9 s, ground painting 1.5 s, cliff dressing 1.4 s, outcrop
   placement 1.3 s, understory scattering 1.3 s, deadfall scattering 1.0 s.

## Remedy plan

Run the benchmark before and after each step and record the saving here. Expected savings are
left blank where nothing supports an estimate yet.

| #   | Remedy                                                                  | Addresses              | Status                                          |
| --- | ----------------------------------------------------------------------- | ---------------------- | ----------------------------------------------- |
| 1   | Split the tree cost: view vs shadow, and pixels vs triangles            | sizes steps 2, 4 and 7 | done 2026-10-05, results below                  |
| 2   | Mid LOD for trees, also used as the shadow mesh (`shadow_impostor`)     | conclusions 3, 4       | not started                                     |
| 3   | Cheaper understory shadows: limit casting first, then `shadow_impostor` | conclusions 3, 5, 7    | limit casting done 2026-10-05 (draws -15 to -42 %); `shadow_impostor` not tried |
| 4   | Shorter sun shadow distance                                             | conclusions 3, 4       | range alone measured: no gain; impostor part untested |
| 5   | Cheaper screen-space settings                                           | conclusion 6           | SSAO switched off 2026-10-05; MSAA and post effects undecided |
| 6   | Startup time                                                            | conclusion 8           | cheap wins done: 16.3 s -> 8.8 s to first frame |
| 7   | Cheaper leaf shading                                                    | conclusions 2, 6       | worth a trial (step 1: part of the view cost is per pixel) |
| 8   | GPU-driven drawing for the understory view pass                         | conclusion 7           | deferred; reassess after step 3                 |

Steps 1-3 were revised and steps 7-8 added on 2026-10-05, after the web research recorded under
"Research" below.

### 1. Split the tree cost: view vs shadow, and pixels vs triangles

Benchmark runs only, no change to the game. About two minutes per run.

- **View vs shadow.** Run the targeted tree ablation (`--bench-only=layer:trees`) once with sun
  shadows on and once with them off. The difference between the two "trees" figures is the
  shadow share. Decides how much steps 2 and 4 can save.
- **Pixels vs triangles** (added 2026-10-05). Run the same ablation at half render scale. If the
  tree cost falls with resolution it is pixel cost (leaf cards overdrawing each other): the mid
  LOD in step 2 should then aim for fewer, larger cards, and step 7 is worth doing. If it does
  not fall, it is vertex cost and triangle reduction is the lever. The two have never been
  separated.

**Results (2026-10-05, git `4a046554`).** Four tree-only runs, reports
`perf_reports/20261005_13*_4a046554_trees_{base,noshadow,half,noshadow_half}`. The whole-run
conditions are two new benchmark arguments, `--bench-no-shadows` and `--bench-scale=0.5`. One
run per condition, so differences under about 0.5 ms are not reliable.

What hiding the trees saves (spawn_ahead / exit_look_back / forest_dense):

| Run condition                   | GPU ms saved       | Draws saved           | Tris saved (M)     |
| ------------------------------- | ------------------ | --------------------- | ------------------ |
| Normal                          | 4.66 / 3.85 / 3.54 | 3,111 / 2,604 / 2,094 | 8.21 / 6.12 / 5.71 |
| Sun shadows off                 | 2.59 / 2.38 / 2.25 | 1,177 / 1,054 / 710   | 2.07 / 1.54 / 1.49 |
| Half render scale               | 3.46 / 2.49 / 2.73 | as normal             | as normal          |
| Shadows off + half render scale | 1.78 / 1.69 / 1.35 | as shadows off        | as shadows off     |

- **Shadow share of the trees: 1.3-2.1 ms, 36-44 %** (normal minus shadows off). The shadow
  passes are 1,400-1,900 draws and 4.2-6.1 M triangles, three times the triangles of the view.
- **View share: 2.3-2.6 ms, 56-64 %**, for only 1.5-2.1 M triangles and 700-1,200 draws.
- **Part of the view cost is per pixel.** At half render scale (a quarter of the pixels) the view
  cost drops by 0.7-0.9 ms, about a third. The 1.35-1.8 ms that remains is not attributed:
  vertex work, very small triangles and MSAA are the candidates.
- **The frame is CPU-limited at the heavy stations.** Whole scene at half render scale:
  spawn_ahead GPU 11.34 -> 7.81 ms but frame 13.29 -> 12.62 ms; exit_look_back and road_open the
  same pattern. With sun shadows off (10,875 -> 4,157 draws) the frame goes 13.29 -> 9.24 ms.
  Conclusions 1 and 7 are corrected above.

What this means for the plan:

- Cutting draw calls now matters as much as cutting GPU time. A change that only makes pixels or
  triangles cheaper will not raise the frame rate at spawn_ahead, exit_look_back or road_open.
- Step 2: both halves pay. The shadow mesh should be as few triangles as possible (4-6 M of
  shadow triangles today); the visible mid LOD should use fewer, larger cards, since a third of
  the view cost is per pixel. It does not cut draws.
- Step 3: "limit casting" goes first, because it removes draws; the `shadow_impostor` trial only
  removes triangles. In the full reports hiding the understory saves 2.0-2.7 ms of frame time at
  spawn_ahead for 0.85-1.1 ms of GPU time.
- Step 4 (shadow distance): measured later the same day, the range alone gains nothing. See step 4.
- Step 8: its condition (draws are the limit) is met at the heavy stations. Reassess after step 3.
- Stations that read exactly 6.06 ms frame time are on an external 165 FPS limit (it was 5.00 ms /
  200 FPS in the morning runs). Read GPU ms there.

### 2. Mid LOD for trees, also used as the shadow mesh

Add a reduced mesh between the full tree and the impostor (roughly 40-60 m to 175 m) and render
shadows from it instead of the full mesh.

- How the shadow part is done: Terrain3D's `shadow_impostor` on the mesh asset. Set to N, LODs
  nearer than N are drawn without shadows and LOD N is drawn shadows-only in their place.
  `build_pack_trees()` sets it to 0 (off) today. The trees have only the full mesh and the
  8-triangle impostor, so this needs the mid LOD first.
- **Ceiling for the shadow half, measured 2026-10-05** (run
  `20261005_144958_40598523_trial_tree_shadow_from_impostor` against `baseline3`): for one run
  the trees cast their shadows from the 8-triangle impostor (`shadow_impostor` 1,
  `last_shadow_lod` 1, set and restored with `set_tree_shadow_lods()` in
  `tools/setup_tree_assets.gd`). The setting works as documented: 4-6 M fewer triangles per
  frame. GPU 0.6-1.3 ms lower at every station with trees (spawn_ahead 10.59 -> 9.28,
  road_open 10.31 -> 9.19, exit_look_back 10.05 -> 9.18, forest_dense 9.55 -> 8.94); road walk
  10.94 -> 9.99 ms frame (91 -> 100 FPS), GPU 10.28 -> 8.98 ms. Draws barely change (the shadow
  draws remain, with a smaller mesh). So of the trees' ~2.1 ms shadow cost about half depends on
  triangle count; a real reduced shadow mesh can recover at most this much, and less the more
  triangles it keeps. How the impostor's own shadow looks was not checked.
- Upper bound on the saving: the whole tree cost, 3.7-4.8 ms. The real figure depends on step 1.
- Risk: the crowns are leaf cards, which simplify badly. Each tree needs a visual check, both for
  the crown silhouette and for the shadow it casts.
- Constraints already documented: the impostor must stay at least 23 m beyond the shadow distance
  (`docs/vegetation.md`), and thin foliage shadows are fragile (`docs/shadows.md`). Read both
  before changing tree LODs.

### 3. Cheaper understory shadows

The understory is 3,500-4,800 draws and 1.0-1.8 ms. Two parts, in this order (swapped
2026-10-05 after step 1 showed the frame is draw-limited at the heavy stations):

**View vs shadow, measured 2026-10-05** (reports `20261005_133241_..._understory_ssao_shadowdist`
and `20261005_133435_..._understory_noshadow`; spawn_ahead / exit_look_back / forest_dense).
Both runs were taken while something else loaded the CPU (station frame times about 2 ms above
the runs before and after), so only their GPU, draw and triangle columns are used.

| Hiding the understory saves | GPU ms             | Draws                 | Tris (M)           |
| --------------------------- | ------------------ | --------------------- | ------------------ |
| Normal                      | 0.89 / 1.57 / 1.17 | 4,844 / 3,541 / 3,701 | 4.48 / 6.53 / 3.32 |
| Sun shadows off             | 0.68 / 0.59 / 0.67 | 1,891 / 1,786 / 1,099 | 1.17 / 1.13 / 0.84 |

- **Shadows are 50-70 % of the understory's draws** (1,750-2,950) and 74-83 % of its triangles
  (2.5-5.4 M). In GPU time the shadow share is 0.2-1.0 ms; the view share is steady at 0.6-0.7 ms.
- That is the most "limit casting" can remove. What it does to frame time has to be measured
  after the change: step 4's trial removed a similar number of draws for no gain.

**"Limit casting" done 2026-10-05. Kirill checked it in-game the same day: "looks fine". Kept.**
`last_shadow_lod` 0 for Fern02, the four bushes, the nine lady ferns and the two elderberries
(was 2, bushes 1): only the nearest LOD casts, to 50 m (bushes 80 m), measured per 32 m cell.
Later the same day Kirill asked for 60 m instead of 50: the shadow limit is the near LOD's
range, so the ferns' and elderberries' near-to-far mesh switch moved from 50 to 60 m with it
(`ranges` in `UNDERSTORY_ASSETS`). Not benchmarked; `baseline3` was taken at 50 m.
Poppies unchanged. Set by `apply_shadow_lods()` in `tools/setup_understory_assets.gd`, which
writes only that field; to undo, restore 2 / 1 in `UNDERSTORY_ASSETS` and run it again.
Full run `20261005_141550_40598523_understory_shadow_lod0_rerun` against `baseline2`:

| Station        | Draws           | Tris (M)       | Render CPU ms | GPU ms         | Frame ms       |
| -------------- | --------------- | -------------- | ------------- | -------------- | -------------- |
| spawn_ahead    | 10,875 -> 8,137 | 21.21 -> 19.79 | 9.58 -> 8.52  | 11.37 -> 11.63 | 13.12 -> 12.38 |
| road_open      | 9,593 -> 6,995  | 19.88 -> 18.47 | 9.25 -> 7.60  | 10.91 -> 11.27 | 12.90 -> 11.76 |
| exit_look_back | 8,391 -> 7,117  | 21.45 -> 20.08 | 8.57 -> 8.54  | 10.94 -> 11.27 | 11.98 -> 12.31 |
| forest_dense   | 8,202 -> 5,797  | 17.40 -> 16.29 | 7.73 -> 7.34  | 10.48 -> 11.05 | 11.57 -> 12.21 |
| road_mid       | 6,970 -> 4,973  | 17.03 -> 15.90 | 5.87 -> 5.87  | 10.06 -> 10.46 | 10.51 -> 11.83 |
| spawn_ground   | 6,165 -> 3,568  | 15.89 -> 14.69 | 5.02 -> 3.33  | 6.79 -> 6.91   | 7.45 -> 7.78   |
| cliff_face     | 2,967 -> 2,374  | 14.10 -> 13.29 | 3.19 -> 2.76  | 9.23 -> 9.20   | 9.57 -> 9.65   |
| spawn_sky      | 265 -> 265      | 6.56 -> 6.56   | 0.79 -> 0.78  | 2.65 -> 3.08   | 6.06 -> 6.06   |

- **Draws down 15-42 %** (1,270-2,740 fewer), triangles down 1.1-1.4 M, render CPU down by
  0-1.7 ms.
- **No GPU gain and no reliable frame-time gain.** GPU reads 0.1-0.6 ms higher at every station
  that has plants, but also 0.43 ms higher at spawn_sky, which draws none, so that is drift
  between the two runs (four hours apart), not the change. Frame time is better at two stations
  and worse at three; the walk is 12.25 -> 12.78 ms with 25 frames over 16.7 ms (was 10).
- **The frame is now GPU-limited at the heavy stations.** Before, switching SSAO or the post
  effects off at spawn_ahead saved 0.5-0.6 ms of frame time for 1.7-1.8 ms of GPU time; now it
  saves 2.3 ms for 1.9 ms. So the CPU limit is lifted there, and the next frame-time gains have
  to come from the GPU side (trees, SSAO, post effects).
- A first run of this had sun shadows, SSAO and the post effects off in the saved Options
  settings and was discarded. The benchmark now records those three and warns if one is off.

- **Limit casting.** Stop ferns and small bushes casting sun shadows beyond their nearest LOD, or
  switch shadows off for the smallest ferns entirely. This is the part that cuts draw calls. An
  earlier 35 m shadow cutoff faded plant shadows in and out (`docs/vegetation.md`), so it needs
  a hard switch.
- **`shadow_impostor` trial** (added 2026-10-05). Fern02, the lady ferns, the elderberry and the
  poppies already have a reduced mesh as LOD 1. Setting `shadow_impostor` to 1 in
  `build_understory_assets()` (it is 0 today) casts the near plants' shadows from that mesh. No
  new assets. It cuts shadow triangles, not draws. Needs an in-game check that fern shadows
  survive near the player, which was the reason for the 25 m first cascade.

### 4. Shorter sun shadow distance (needs a decision)

Sun shadows reach 150 m over four cascades. Dropping to about 100 m cuts shadow work and would
let the tree impostor switch move in from 175 m to about 125 m, which also cuts visible tree
triangles. It is a visible change, and the current setup is recorded as final in
`docs/vegetation.md`, so it is the user's call.

**Measured 2026-10-05** (`sun_shadow_100m` toggle, report `20261005_133704_4a046554_ssao_shadowdist2`):
the range alone, 150 -> 100 m, with every LOD range left as it is.

| Station        | GPU ms saved | Frame ms saved | Draws saved | Tris saved (M) |
| -------------- | ------------ | -------------- | ----------- | -------------- |
| spawn_ahead    | -0.29        | -0.28          | 1,845       | 0.87           |
| exit_look_back | 0.20         | 0.43           | 1,424       | 2.41           |
| forest_dense   | -0.20        | -0.20          | 1,445       | 0.82           |

- **No measurable gain from the range alone**, although 1,400-1,800 draws go. This does not fit
  "frame time follows the draw count" (hiding the understory removes 3,500-4,800 draws and saves
  2-2.7 ms of frame time at spawn_ahead). Not explained.
- Not measured: the second half of this step, moving the tree impostor switch in from 175 m to
  about 125 m. That needs the tree assets rebuilt, so it is a change to the game, not a toggle.
- So this step is no longer "the largest lever". Whatever it gains would come from the impostor
  switch, and that is not known yet.

### 5. Cheaper screen-space settings (needs a decision)

Look-versus-speed choices, each independent:

- SSAO: 1.3-1.6 ms at Low quality. The Options menu has a toggle and a quality dropdown
  (added 2026-10-05); try Very Low first.
  **Measured 2026-10-05** (same report as step 4's table): switching SSAO off saves
  1.91 / 1.43 / 1.31 ms GPU; switching the quality to Very Low, Low, Medium, High or Ultra changes
  GPU time by -0.23 to +0.20 ms, which is the measuring noise. **The quality level makes no
  measurable difference to cost; only on/off does.** Two explanations, not told apart: the cost
  is in parts that do not depend on the level (with SSAO on, Godot's depth prepass also has to
  write normals and roughness for every mesh, foliage included -- an inference, not checked), or
  the runtime quality setter the dropdown uses has no effect. Nobody has compared the levels by
  eye in-game.
  **Switched off 2026-10-05** (Kirill: "not worth"): `ssao_enabled` removed from `main.tscn`'s
  Environment, the Ambient Occlusion toggle and quality dropdown removed from the Options menu
  (`scenes/pause_menu.tscn`, `scripts/pause_menu.gd`), the benchmark's quality toggles removed.
  New baseline with it off: see "The run these numbers come from".
- 3D MSAA (2x): 0.8-1.2 ms.
- Post effects: 1.5-1.8 ms in total, about half of it the painterly effect.

### 6. Startup time (in progress, started 2026-10-05)

Does not affect frame rate. Measured with a 20-frame launch
(`Godot_v4.7.2-stable_win64_console.exe --path herald-of-oblivion --quit-after 20`) and the
`TERRAIN_GEN` timing lines it prints.

Done 2026-10-05 -- world generation 12.11 s -> 8.61 s, first frame 16.26 s -> 12.83 s, generated
world unchanged (identical log output for the pinned seed):

| Change                                                                                                       | Stage               | Before | After  |
| ------------------------------------------------------------------------------------------------------------ | ------------------- | ------ | ------ |
| Cliff / outcrop models and textures load on background threads during the heightmap build (`TerrainPreload`) | cliff face dressing | 1.37 s | 0.06 s |
| same                                                                                                         | outcrop placement   | 1.35 s | 0.04 s |
| Rock collision hulls cached on disk (`TerrainUtil.cached_shape`)                                             | boulder scattering  | 0.82 s | 0.12 s |
| Deadfall collision shapes cached on disk (same helper)                                                       | deadfall scattering | 1.04 s | 0.92 s |

Second pass, same day -- hot loops moved onto the engine's worker threads (12 logical cores on
this machine). World generation 8.61 s -> 6.3 s, first frame 12.83 s -> 10.5 s:

| Change                                                                                        | Stage                 | Before | After  | Output                                                                                  |
| --------------------------------------------------------------------------------------------- | --------------------- | ------ | ------ | --------------------------------------------------------------------------------------- |
| Main per-vertex loop and rock-type majority filter in row bands (`_paint_band`, `_mode_band`) | ground painting       | 1.49 s | 0.60 s | identical (control-map checksum 2130175883 before and after)                            |
| Candidate rows in bands, one random stream per row (`_scatter_band`)                          | understory scattering | 1.30 s | 0.40 s | changed once: 22,132 -> 22,442 plants; repeatable per seed (placement checksum printed) |
| same                                                                                          | flower scattering     | 0.84 s | 0.27 s | changed once: 13,701 -> 13,484 pieces; repeatable per seed                              |

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

| Part                                                                                            | Time   |
| ----------------------------------------------------------------------------------------------- | ------ |
| Before world generation starts (engine boot, loading `main.tscn` and what it references)        | 3.2 s  |
| Heightmap build: knots 0.73, erosion 0.62, road 0.51, outcrop planning 0.28, about 0.45 untimed | 2.9 s  |
| Deadfall scattering                                                                             | 0.93 s |
| Ground painting (0.26 setup, 0.23 threaded passes, 0.10 region write)                           | 0.60 s |
| Grass density bake                                                                              | 0.48 s |
| Understory scattering                                                                           | 0.40 s |
| Flower scattering                                                                               | 0.27 s |
| Everything else                                                                                 | 0.7 s  |
| After generation, to the first drawn frame (shader pipelines)                                   | 1.0 s  |

Investigation of the two largest remaining parts (2026-10-05, measurements only, no changes
beyond three extra timing prints in `heightmap.gd`):

Heightmap build, 2.92 s:

| Part                                 | Time   | Note                                                                       |
| ------------------------------------ | ------ | -------------------------------------------------------------------------- |
| Knots                                | 0.75 s | reach + ramps 0.41, rows 0.21 (its own `KNOT_PROFILE` line)                |
| Erosion (main + post-feature)        | 0.61 s | ~300k droplet steps, already a tight loop; sequential                      |
| Road                                 | 0.51 s | grading 0.23, pathfinding 0.11, blur 0.11, rasterising 0.06                |
| Cliff top profiles                   | 0.27 s | was the untimed part. Per model, no terrain input -> can be cached on disk |
| Outcrop planning + fitting           | 0.23 s | includes analysing each outcrop model, which is also per model             |
| Cliff dressing plan                  | 0.13 s |                                                                            |
| Base noise                           | 0.12 s |                                                                            |
| Knot restore + landmark stamp        | 0.09 s |                                                                            |
| Smoothing, colour map, stats, images | 0.17 s |                                                                            |

Before generation starts, 3.2 s (probe scripts that load `main.tscn`'s dependencies one by one):

| Part                                                             | Time      | Note                                                                                                                                                   |
| ---------------------------------------------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Engine boot until the first script runs                          | 1.1 s     | fixed cost                                                                                                                                             |
| `terrain_assets.tres`                                            | 1.1 s     | still 1.1 s with all 129 of its dependencies already loaded, so it is Terrain3D's own setup of the 85 mesh assets and texture arrays, not file loading |
| Compiling the terrain scripts (`terrain_gen.gd` and its modules) | 0.3-0.5 s | paid by whichever resource touches them first                                                                                                          |
| `main.tscn` itself                                               | 0.5 s     | 28 KB; holds a 548-line embedded shader                                                                                                                |

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

|                            | Runs | Scene loaded at | Heightmap ready at | Build time |
| -------------------------- | ---- | --------------- | ------------------ | ---------- |
| Sequential (today's order) | 3    | 2.88 s          | 5.84 s             | 2.96 s     |
| Overlapped                 | 25   | 2.86 s          | 4.40 s             | 3.06 s     |

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

| Change                                                             | Part                       | Before | After  |
| ------------------------------------------------------------------ | -------------------------- | ------ | ------ |
| Cliff top-profile scan cached (`_scan_cliff_dressing_top_profile`) | cliff top profiles         | 0.27 s | 0.00 s |
| Outcrop model scan cached (`_scan_outcrop_model`)                  | outcrop planning + fitting | 0.23 s | 0.03 s |

Fourth pass, same day -- profiled deadfall, the grass bake, ground-paint setup and the gap to
the first frame, then fixed what was exact and cheap. World generation 5.87 s -> 4.72 s, first
frame 9.98 s -> 8.81 s. Output identical: deadfall, understory, flower, grass (density / worn /
patch) and ground-paint checksums, plus the mound and cone counts, all match the run before.

| Change                                                                                                                                                | Stage                            | Before        | After         |
| ----------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------- | ------------- |
| `_capsule_blocked` looks up circles and placed pieces through grids (`circle_grid`, `placed_grid`) instead of scanning every one; the scan was 0.67 s | deadfall scattering              | 0.93 s        | 0.41 s        |
| Per-pixel combine in row bands (`_bake_band`); its 6 noise images rendered together (`noise_images_parallel`)                                         | grass density bake               | 0.48 s        | 0.16 s        |
| Its 7 noise images rendered together                                                                                                                  | ground painting                  | 0.60 s        | 0.47 s        |
| Canopy grid built once per run and reused (`UnderstoryScatter._build_canopy_grid` cache); it was rebuilt 5 times at ~50 ms                            | understory / flowers / the above | 0.40 / 0.27 s | 0.34 / 0.22 s |

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

- Heightmap build, the rest: sequential by nature (droplets, A\*, knot placement), so only loop
  tightening applies; knots (0.75 s) is the largest piece.
- A per-seed world cache on disk would skip most of generation while the seed is pinned, but
  does nothing for a fresh random seed.

### 7. Cheaper leaf shading (worth a trial)

Step 1 found that about a third of the trees' view cost (0.7-0.9 ms) falls with render scale, so
there is per-pixel cost to cut. It saves GPU time only, not draws.

The foliage shaders (`shaders/foliage/foliage_cutout_*.gdshader`) use Burley diffuse and GGX
specular. The usual advice for leaves is a simpler lighting model, because stacked cards run the
shader several times per pixel. Try Lambert diffuse and specular off, and measure. It is a visible
change, so it needs an in-game check.

### 8. GPU-driven drawing for the understory view pass (deferred)

Assessed 2026-10-05: could trees and ferns be culled on the GPU the way the grass is?

- Possible, but it does not address their measured cost. They are already frustum-culled per
  32 m cell by Godot; their cost is the triangles and shadow passes of plants that are in view.
- Shadows break the grass approach. Grass casts none, so one camera-culled buffer is enough. A
  tree outside the view must still cast into it, so shadows need a second buffer, and with one
  bounding box for the whole buffer every cascade would draw every tree in range. Today the cells
  are culled per cascade.
- What it would gain: draw calls. The understory is 22,132 plants in 5,414 nodes, about 4 per
  draw; one indirect MultiMesh per mesh and LOD would make the view pass about a hundred draws.
  Also per-plant LOD switching, which would remove the 23 m margin rule for the tree impostor.
- What it would cost: a cull shader reading a plant list, a separate shadow path (probably
  Terrain3D drawing shadows only -- not checked), LOD selection and the tree cross-fade in the
  foliage shaders, and rewiring the layer panel and the benchmark toggles.
- When: after steps 1-3, for the understory view pass only, and only if the draw count has become
  the limit (conclusion 7). Not for trees.

## Research (2026-10-05)

A web search for optimisation guidance, read against the findings above.

What the sources agree on:

- Measure first, then work on the side that limits the frame: overdraw, shader cost, resolution
  and post effects when GPU-bound, draw calls when CPU-bound.
- Shadow max distance is the most effective single shadow setting. Every shadow-casting light
  redraws its casters, so shadows multiply both draws and triangles.
- Vegetation shadows are cast from a cheaper mesh than the visible one (Unreal's proxy geometry
  shadows, Terrain3D's `shadow_impostor`).
- Leaf cards cost per pixel as well as per triangle: stacked alpha-tested cards run the leaf
  shader many times per pixel (one blog claims 8-15x in dense forest; not measured here). The
  usual fixes are a depth prepass for cutout geometry, merged larger cards at mid distance and a
  cheaper leaf shader.
- MultiMesh chunk size trades culling against draw calls. Terrain3D's cells are fixed at 32 m.
- GPU-driven culling with occlusion tests is what large engines use (claimed 20-40 % of triangles
  culled), on cluster and depth-pyramid systems Godot does not have.

What does not apply here:

- Cached or less often updated far cascades: not in Godot. Proposal #2745 has been open since
  2021 and its pull request (#76291) is unmerged; only forks have it.
- Occlusion culling: marginal in open terrain, and foliage cannot be an occluder. Only the cliffs
  could hide anything.
- Alpha-to-coverage, hashed alpha and dithered LOD fades: quality techniques that mostly rely on
  temporal anti-aliasing, which the project does not use. LOD fading also drops shadows here
  (`docs/shadows.md`).

Not confirmed: whether Godot's depth prepass stops the colour pass shading hidden leaf pixels for
our cutout shaders. A 2023 fix (PR #79865) removed an unneeded `discard` from opaque shaders, but
foliage still needs its own. The pixels-vs-triangles run in step 1 answers it indirectly.

Not read: the Cyberpunk 2077 shadow talk (SIGGRAPH 2021) and Godot proposal #6948 failed to load.

Sources:

- Godot docs, optimizing 3D performance: https://docs.godotengine.org/en/stable/tutorials/performance/optimizing_3d_performance.html
- Terrain3D instancer: https://terrain3d.readthedocs.io/en/latest/docs/instancer.html
- Foliage overdraw (Cinevva blog): https://app.cinevva.com/blog/2026-05-11-foliage-overdraw
- Godot 3D optimization guide 2026 (StraySpark): https://www.strayspark.studio/blog/godot-3d-optimization-guide-2026
- Shadow proxy mesh for vegetation: https://winter-crown-works.com/en/tech/004
- Unreal proxy geometry shadows: https://dev.epicgames.com/documentation/unreal-engine/proxy-geometry-shadows-in-unreal-engine
- CRYENGINE cached shadows: https://www.cryengine.com/docs/static/engines/cryengine-3/categories/1114113/pages/21267738
- Godot proposal #2745, distant shadow update rate: https://github.com/godotengine/godot-proposals/issues/2745
- Godot proposal #7366, renderer performance problems: https://github.com/godotengine/godot-proposals/issues/7366
- CPU-bound or GPU-bound (Bugnet): https://bugnet.io/blog/how-to-find-whether-your-game-is-cpu-or-gpu-bound
- GodotFest 2025, large-scale vegetation rendering: https://api.media.ccc.de/v/godotfest2025-plants-polygons-and-pixels-large-scale-vegetation-rendering-in-godot
- GDQuest, optimizing a 3D scene: https://www.gdquest.com/library/optimization_3d_rendering

## Not worth touching yet

- Rocks: 35.7 M triangles at LOD 0 on paper, but under 0.4 ms measured. Their LODs and culling
  already work.
- Cliffs, outcrops, flowers, deadfall, cones: each under 0.4 ms.
- Grass: about 0.9 ms for a million instances in 7 nodes. Already cheap per instance.
