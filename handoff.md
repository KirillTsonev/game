# Handoff: optimisation phase

Starting context for a new chat. Written 2026-10-06; everything up to commit `bd39ed6` is committed.

Read first: `CLAUDE.md` (pitfalls, how to run the benchmark) and `docs/performance_findings.md` (all measurements and the remedy plan). This file only says where things stand and what comes next.

## Where the frame stands

- Every benchmark station runs at 6–12 ms on Kirill's laptop (RTX 3070 Laptop GPU), inside the 16.7 ms budget of the 60 FPS cap. The road walk averages 9.5 ms.
- Two views are CPU-limited: spawn_ahead (11.9 ms) and exit_look_back (10.3 ms), at about 7,200–8,200 draw calls, more than half of them in the shadow passes. Cheaper triangles or pixels do not help them; fewer draw calls and nodes do.
- The other stations are GPU-limited at 6.4–7.5 ms of GPU.
- **Target (Kirill, 2026-10-06):** optimise as far as possible without compromising visual fidelity. Anything that changes the look needs his check in game.

## Next steps, in order

1. **Scan every other plant mesh for duplicated leaf cards: done 2026-10-06, nothing to fix.** All 88 mesh assets scanned with `debug_print_duplicate_triangles()` in `tools/setup_understory_assets.gd`. Bushes, elderberry, poppies, wood sorrel, clover: none. Lady ferns and scree stone A: about 1 % stray overlap. `fern_02`'s two layers are not exact copies (0 matches) and the mesh is 440 / 88 triangles, so it stays as it is.

2. **One full benchmark run: done 2026-10-06.** `20261006_112323_bd39ed6d_full_after_trees.json` is the new baseline; figures in `docs/performance_findings.md`. It showed that the trees issue more draw calls than the understory at spawn_ahead (3,115 against 2,186) and that 725 saplings cost 1.44 ms of frame time.

3. **Fewer draw calls for the plants (GPU-driven drawing).** The remaining lever for the CPU-limited views. Scope widened from ferns and bushes to flowers, trees and saplings after the full run. A design proposal was given to Kirill on 2026-10-06; no code until he approves it. Earlier assessment and caveats: `docs/performance_findings.md`, step 8.

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
