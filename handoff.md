# Handoff: optimisation phase

Starting context for a new chat. Written 2026-10-06; everything up to commit `bd39ed6` is committed.

Read first: `CLAUDE.md` (pitfalls, how to run the benchmark) and `docs/performance_findings.md` (all measurements and the remedy plan). This file only says where things stand and what comes next.

## Where the frame stands

- Since the understory moved to `PlantField` (2026-10-06, not committed yet), every benchmark station runs at 6–8.4 ms on Kirill's laptop (RTX 3070 Laptop GPU), inside the 16.7 ms budget of the 60 FPS cap. The road walk averages 8.0 ms.
- Every station is now GPU-limited, at 6.4–7.8 ms of GPU. spawn_ahead and exit_look_back were CPU-limited before (11.0 and 10.3 ms; now 8.3 and 8.4 ms at 5,850 and 5,060 draw calls).
- The last full run, `full_after_trees`, predates the plant renderer: its per-layer figures for flowers and understory are out of date.
- **Target (Kirill, 2026-10-06):** optimise as far as possible without compromising visual fidelity. Anything that changes the look needs his check in game.

## Next steps, in order

1. **Scan every other plant mesh for duplicated leaf cards: done 2026-10-06, nothing to fix.** All 88 mesh assets scanned with `debug_print_duplicate_triangles()` in `tools/setup_understory_assets.gd`. Bushes, elderberry, poppies, wood sorrel, clover: none. Lady ferns and scree stone A: about 1 % stray overlap. `fern_02`'s two layers are not exact copies (0 matches) and the mesh is 440 / 88 triangles, so it stays as it is.

2. **One full benchmark run: done 2026-10-06.** `20261006_112323_bd39ed6d_full_after_trees.json` is the new baseline; figures in `docs/performance_findings.md`. It showed that the trees issue more draw calls than the understory at spawn_ahead (3,115 against 2,186) and that 725 saplings cost 1.44 ms of frame time.

3. **Fewer draw calls for the plants (GPU-driven drawing).** The remaining lever for the CPU-limited views. Scope widened from ferns and bushes to flowers, trees and saplings after the full run. Kirill approved the phased plan on 2026-10-06; the phases, and what each changes visually, are in `docs/performance_findings.md`, step 8.
   - **Phase 1 is built and Kirill approved the look (2026-10-06), but it gained no frame time.** Wood sorrel, dandelion and clover (12,829 plants) are drawn by `PlantField` in 21 draws. Three alternating benchmark pairs showed every station within run-to-run spread and only 20-34 fewer draws: those plants were culled at 60 m and cast no shadows, so they were never the layer's draws. It did remove 2,233 nodes and 55 ms of startup.
   - **Phase 2 is built, approved and measured (2026-10-06): poppies, ferns, bushes, lady ferns, elderberries.** `PlantField` draws 35,926 plants of 34 meshes in 80 draws; Terrain3D keeps shadow-only copies of the shadow casters. Three alternating pairs: spawn_ahead 10.96 → 8.33 ms, exit_look_back 10.29 → 8.37 ms, road walk 9.32 → 8.01 ms, about 2,000 fewer draws at the heavy views.
   - **Open from phase 2: GPU time rose 0.2–0.7 ms at the heavy views.** Cause not established; the suspect is draw order (near plants are no longer drawn before far ones). Test first, since every view is now GPU-limited.
   - **Poppy shadows stop at 40 m since 2026-10-06** (were 150 m), Kirill's decision, "can always change later".
   - **Phase 3, not started: trees and saplings, view pass.** Their meshes have 2–3 surfaces, which the cull shader does not handle yet. Phase 4 is the tree shadow draws.
   - PerfDebug key U switches between the old and the new drawing in a running game. It takes about 5 seconds at a few FPS.

## Smaller open items

- **MSAA, 0.6–1.0 ms of GPU.** A look decision: it smooths geometry edges, and the grass shader notes say thin blades depend on it. An Options toggle would let Kirill judge it live.
- **Saplings casting shadows from their impostors.** A fraction of a layer that cost 0.16–0.29 ms of GPU before the tree fix; their shadows would stop at 80 m instead of 150 m.
- **Radial blur sample count, 16 to 8.** About 0.05 ms, slight look change toward the screen corners.
- **Bringing Angular Distance back (look, not speed).** Only worth doing if the blob-to-leaves switch in tree shadows at about 25 m bothers Kirill. Untried test: one invisible, very tall shadow caster (a tiny mesh with a custom bounding box reaching some 1,000 m above the map, following the player) to stretch each cascade's depth range, so real crowns never sit near the top of it. Set it up as a debug key that switches the caster on and off with Angular Distance at 0.05, and let Kirill look at a spot that used to go grey. If it works, Angular Distance probably needs raising to get the old softness back; it costs 0.14–0.24 ms of GPU. Removing the separate shadow meshes did not change this: the grey shadows also appeared with trees casting from their own mesh.

## Decided, do not reopen without a reason

- **Mid-distance LOD for the visible trees: not worth it.** The view share of the trees is now 1.0–1.2 ms of GPU, a mid LOD recovers only part of it, and leaf cards simplify badly.
- **The pines' lower twig cards stay.** Leaving them out saves one draw call per cell on eight trees (estimated 0.4–0.8 ms at the two slow views, not measured) but removes visible detail. If the saving is ever wanted, combine `Branch.png` with each tree's leaf texture so the twigs can join the main leaf surface.
- **Sun Angular Distance stays 0 unless the tall-caster test above works.** Above 0, a few tree shadows turn grey and see-through at some viewing angles. The cost is that tree shadows switch from blob to leaf detail at about 25 m, which Kirill accepted for now. Likely cause (the engine's soft-shadow formula) and the measured cost: `docs/shadows.md`.
- **No thinned, enlarged or simplified shadow meshes for trees.** Tried and rejected in game: `docs/vegetation.md`.

## How to measure

- Compare two setups with alternating targeted runs, three pairs (about 13 minutes). Single runs of the same setup differ by up to 1 ms at spawn_ahead and road_open, and a pair taken back to back on a warm machine is not reliable.
- Check the report's first line before trusting a run: it must show sun shadows on and 6 post effects. The benchmark uses whatever is saved in the Options menu.
