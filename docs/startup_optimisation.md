# Keeping startup fast when adding layers and objects

How to add a new generation stage, scatter layer or model without giving back the startup time
won on 2026-10-05 (first frame 16.3 s -> 8.8 s, world generation 12.1 s -> 4.7 s). This is the
method and the reusable pieces; the measurements behind it are in
`docs/performance_findings.md` (step 6), and the pitfalls are repeated in `CLAUDE.md`.

## The budget

Stage times on the dev machine after the work (pinned seed, 256 x 512 map). A new stage should
land in the same range as its neighbours; anything above ~0.3 s deserves a look.

| Stage | Time |
|---|---|
| Heightmap build (knots 0.75, erosion 0.61, road 0.51) | 2.45 s |
| Ground painting | 0.47 s |
| Deadfall scattering | 0.41 s |
| Understory scattering (22,000 plants) | 0.34 s |
| Flower scattering (13,500 pieces) | 0.22 s |
| Grass density bake | 0.16 s |
| Road mesh, boulders, trees, scree, saplings, cliffs, outcrops | 0.04-0.14 s each |

Outside generation: ~3.1 s before it starts (engine boot, Terrain3D asset setup, script
compile) and ~0.9 s of first-frame work, now spent behind the loading screen.

## The procedure

1. **Measure before changing anything.** Launch for a few frames and read the log:
   `Godot_v4.7.2-stable_win64_console.exe --path herald-of-oblivion --quit-after 20`
   (~12 s; a console window and the game window open and close). Every stage prints
   `TERRAIN_GEN: <stage> (N.NNs)`; `_ready() TOTAL` and `first frame drawn at t=` give the
   totals. Run it under a timeout that kills the process -- a threading mistake shows up as a
   frozen window, not an error.
2. **Give the new stage a timing line.** Wrap its call in `WorldGenerator._ready()` with
   `_log_stage("<name>", t_ready_stage)` like the others, so it appears in the log and in the
   benchmark's startup section.
3. **Give it an output checksum.** Print one `hash(...)` of what the stage produced (placed
   transforms, a byte map). Existing examples: `deadfall placement checksum`,
   `GRASS: checksum`, `GROUND_PAINT v2: checksum`. Without it, "the world is unchanged" cannot be
   checked after a speed change.
4. **If the stage is slow, find out which part.** Add temporary `Time.get_ticks_usec()` prints
   around its phases (tag them, e.g. `# PROFTMP`, and delete them afterwards). Guessing was wrong
   more than once: the rock stage's 0.7 s was hull building, not loading; noise images cost
   16 ms each, not the 1 ms a comment claimed.
5. **Apply the matching fix from the table below.**
6. **Verify:** same checksums as before for an output-preserving change; for a change that is
   allowed to move things, the same checksum on two consecutive runs. Then check the stage time.
7. **Record it** in `docs/performance_findings.md`, and retake the benchmark baseline if anything
   visible moved (the stations look at the scene).

## Which fix for which cost

| What is slow | Fix | Reusable piece | Output |
|---|---|---|---|
| Loading models / textures with `load()` during generation | Queue them at the start so they load during the heightmap build | `TerrainPreload.begin()`: add the def list (anything with `glb` / `diff` / `nor` / `orm` / `rough` keys works through `_append_def_paths`) | same |
| Building a collision shape from a glb (hull or trimesh) | Keep the shape on disk | `TerrainUtil.cached_shape(glb_path, tag, version, bake)` | same |
| Scanning a model's vertices for bounds, a profile, a footprint grid | Keep the result on disk | `TerrainUtil.cached_value(glb_path, tag, key, version, compute)` | same |
| A loop over every map pixel that only reads shared data | Row bands on worker threads | pattern: `TerrainGroundPaint._paint_band`, `GrassScatter._bake_band` | same |
| A candidate loop that rolls random numbers per spot | Row bands, one random stream per row | pattern: `UnderstoryScatter._scatter_band`, `FlowerScatter._scatter_band` | changes once, then repeatable |
| Testing each new piece against everything already placed | A lookup grid instead of a full scan | `DeadfallScatter._bucket_index` + the grid loops in `_capsule_blocked` | same |
| The same field built by several stages | Build once per run and reuse | `UnderstoryScatter._build_canopy_grid` (cached; read-only for callers) | same |
| Several `FastNoiseLite.get_image()` calls | Render them together | `GrassScatter.noise_images_parallel(specs)` | same |

Not every loop can be banded. A stage where each placement depends on the earlier ones (deadfall:
pieces must not overlap) stays sequential; make its inner test cheap instead.

## Rules for the fixes

**Disk caches** (`cached_shape`, `cached_value`)
- The file is keyed by the glb's path and modification time, so re-exporting a model rebuilds it
  automatically.
- Put every other input of the computation into the key (`cached_value`'s `key`, e.g.
  `str(def)` plus any constant it reads).
- Bump the version constant next to the bake / scan function whenever that function changes, or
  the old result is silently reused.
- Never cache a failure: return `{}` / `null` when the model could not be loaded.
- The first run after a change pays the old cost once.

**Worker-thread bands**
- Start with `WorkerThreadPool.add_group_task(band_func.bind(ctx), bands, -1, true)` and wait for
  it; `ctx` is a Dictionary of the shared inputs.
- A band only READS shared data. It fills band-sized outputs of its own and stores them in
  `ctx.out[band]` under `ctx.mutex`; the caller joins the bands in order with `append_array`.
- Never write into a shared packed array from a band. With more than one reference it is copied
  first and the write is lost, with no error.
- Keep engine-object and GDExtension calls out of the per-element loop: no `Image.get_pixel()`,
  no `Terrain3DUtil.*`. Read images as bytes (`get_data()`) and do bit packing in GDScript. With
  those calls inside, the ground-paint loop only went from 740 to 504 ms on 12 cores; without
  them, to 88 ms.
- Why (measured 2026-10-10): on a debug build -- the editor's executable too -- a call on any
  engine object from a worker thread waits on one engine-wide lock. Random numbers took 32 ms
  on one thread and 211 ms on twelve; a release build ran them in 5.5 ms. Where the loop cannot
  do without `rng` or noise calls (scatter bands, the aprons), pass
  `TerrainUtil.object_call_threads()` as the thread count in place of -1: 6 threads on a debug
  build beat 12 by a factor of two. Judge such a stage on a release export, not in the editor.
- Shared lookups a band reads per item: packed arrays, not Dictionaries of Arrays
  (`RockScatter.build_keep_grid` is the pattern).
- Randomness: one `RandomNumberGenerator` per band, reseeded per row with
  `hash(row_seed + row)`, where `row_seed` is drawn once from the stage's own stream before the
  bands start. Draw any other seeds (noise) in a fixed order before starting too.
- Float sums joined across bands can differ in the last digits from a single loop. Use them for
  log lines only, never for output.
- A band that calls `load()` hangs for good if the main thread is blocked waiting for it.
  Bands must not load; load before starting them.

**Scatter layers specifically**
- Agreed with Kirill on 2026-10-05: switching a scatter layer to per-row streams may change
  where its plants land for a given seed, once. Terrain, cliffs and the road must not change.
- After such a change, retake the benchmark baseline.

## Hooking a new stage into the loading screen

`WorldGenerator._ready()` hands control back to the engine before each group of stages so the
bar can be redrawn (`LOADING_STEPS` and `_loading_step(index)` in `scripts/terrain_gen.gd`).

- A small stage: put its call inside the existing group it belongs to. Nothing else to do.
- A stage of ~0.3 s or more: give it its own entry in `LOADING_STEPS` (`[text, rough ms]`),
  add `await _loading_step(<index>)` followed by `t_ready_stage = Time.get_ticks_msec()` before
  it, and renumber the later calls. The ms values only set how far the bar moves.
- Each step costs one drawn frame, so do not add one per tiny stage.
- Because of these awaits, other nodes' `_ready()` run before the world exists. Code that needs
  the world waits for `startup_timings.has("settled_at_ms")`.

## Things that were tried and did not pay

- Preloading the rock and deadfall glbs: no gain, their cost was the collision shapes.
- Loading the main scene with a threaded load polled once per frame, to animate the bar: 4.7 s
  instead of 2 s. `scripts/boot.gd` requests the load with sub-threads and fetches it at once.
- Building the heightmap on a thread while the main scene loads: a probe measured 1.4 s saved
  with identical output, but only for a world generated at process launch, and it freezes the
  game if the main thread ever blocks on that thread. Left undone; details in
  `docs/performance_findings.md`.

## Practical notes

- A new `class_name` script is unknown to a command-line launch until the editor has rescanned
  (`rescan_filesystem`); the launch fails with "Identifier not declared".
- `dict[key].append(x)` on a packed array stored in a Dictionary is unreliable; store a plain
  `Array` when a Dictionary's values are appended to.
- The game process exits with an error code after `--quit-after`; that is the known crash on
  quit, not a failed run. Judge the run by its log.
