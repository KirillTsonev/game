# Handoff: optimisation phase

Starting context for a new chat. Written 2026-10-06, afternoon. Committed up to `627980c` (the plant renderer with flowers and understory). Not committed: the reduced fern shadows, the new benchmark options and toggles, the leaf-card scan, and the doc updates for them.

Read first: `CLAUDE.md` (pitfalls, how to run the benchmark) and `docs/performance_findings.md` (all measurements and the remedy plan). This file only says where things stand and what comes next.

## Where the frame stands

- Every benchmark station runs at 6.9–8.4 ms on Kirill's laptop (RTX 3070 Laptop GPU), about 120–145 FPS. The road walk averages 7.9 ms, with the slowest 1 % of frames near 9.7 ms.
- **Every station is GPU-limited**, at 6.2–7.4 ms of GPU. Draw calls no longer limit the frame (3,800–5,850 at the forest stations).
- Against the morning's full run: spawn_ahead 10.55 → 8.06 ms (24 %), road walk 8.93 → 7.90 ms (12 %), exit_look_back 9.18 → 8.29 ms (10 %). forest_dense, road_mid and cliff_face are unchanged: they were GPU-limited already.
- Baseline report: `20261006_125350_627980c4_full_plantfield.json`. It predates the reduced fern shadows (0.1–0.3 ms).
- The benchmark resolution (1906×942 window, 0.85 render scale) is Kirill's real play resolution.
- The frame limiter is at 240 FPS since the afternoon of 2026-10-06: a station at about 4.17 ms is sitting on it.
- **Target (Kirill, 2026-10-06):** optimise as far as possible without compromising visual fidelity. Anything that changes the look needs his check in game.

## What the GPU time goes on

GPU ms saved by switching each thing off, at spawn_ahead / exit_look_back / forest_dense. The rows overlap.

| Thing | GPU ms |
| --- | --- |
| Trees | 2.2 / 1.9 / 1.7 (view 1.0–1.3, shadows 0.6–1.0) |
| Sun shadows, all layers | 1.7 / 2.1 / 1.6 |
| Understory | 1.1 / 1.5 / 0.8 before the reduced shadows (about half view, half shadow) |
| Grass | 1.1 / 1.2 / 1.0 (short-grass layers 0.25–0.5 of it) |
| Post effects, all six | 1.07 / 1.05 / 1.07 |
| MSAA | 0.58 / 0.53 / 0.47 |
| Lantern | 0.30 / 0.33 / 0.46 (its shadow is under 0.12 of it) |
| Ground texturing | 0.15 |
| Saplings, rocks, deadfall, flowers, cliffs | under 0.3 each |

## Done on 2026-10-06

- **Plant renderer (`PlantField`).** Flowers and understory, 35,926 plants of 34 meshes, are drawn in 80 draws with LOD and culling per plant on the GPU. Terrain3D keeps shadow-only copies of the shadow casters. Three alternating pairs: spawn_ahead 10.96 → 8.33 ms, exit_look_back 10.29 → 8.37 ms, road walk 9.32 → 8.01 ms, about 2,000 fewer draws at the heavy views. Kirill compared old and new in game. How it works: `docs/vegetation.md`; measurements and the lessons: `docs/performance_findings.md`, step 8.
- **Reduced fern shadows, on by default.** Fern02, the lady ferns and the elderberries cast from their quarter-size far mesh, through run-time "shadow twin" mesh assets (nothing saved to disk). 0.1–0.3 ms of GPU, 2–4 %. Kirill: "no significant difference". `--plants-full-shadows` starts without it.
- **Poppy shadows stop at 40 m** (were 150 m). Kirill's decision, "can always change later".
- **Probes that found nothing to change:** duplicated cards in the other plant meshes (none); the lantern's shadow (not the cost); rock and scree shadows (not a cost); ground texturing and ground shadows (0.15 and under 0.1 ms); grass by band (all of it Kirill-tuned density).
- **A measuring rule learned the hard way:** GPU ms reads lower while the CPU or a frame limiter is the limit. Compare GPU ms only between runs limited the same way (`CLAUDE.md`, "Performance benchmark").

## Next steps, in the order Kirill set

1. **Hitches.** Averages are 7–8 ms, but single frames of 43 ms (one road walk) and 50 ms (cliff_face station) turned up in two of the day's runs. Cause not looked at. The benchmark's walk records only the worst frame, so the probe needs a per-frame trace with position and time.
2. **Size optimisation.** Kirill wants to look at asset size: compression, disk and video memory. Not started. Known facts: video memory about 2,030 MB, an estimated 1,090 MB of textures, ten cliff and outcrop texture sets at 64 MB each, and the church's oversized textures (left alone by Kirill's decision on 2026-09-16, see `CLAUDE.md`). Start with a survey of what takes the space.

## Open, not scheduled

- **Trees and saplings on `PlantField` (the original phase 3).** Removes about 2,500 draw calls. No gain on this laptop now that the frame is GPU-limited; it would help a CPU-limited machine. Their meshes have 2–3 surfaces, which the cull shader does not handle yet.
- **Reduced shadow meshes for the four plain bushes.** They have no far mesh, so they still cast from their full one. Would need new meshes.
- **MSAA, 0.5 ms of GPU.** A look decision: it smooths geometry edges, and the grass shader notes say thin blades depend on it. An Options toggle would let Kirill judge it live.
- **Cheaper leaf lighting.** About 0.2–0.6 ms of the trees' view cost is per pixel. Leaves would lose their sheen; needs Kirill's eye.
- **Fewer shadow cascades (4 → 3 or 2).** A share of every layer's shadow cost; coarser shadows at middle distance.
- **Radial blur sample count, 16 to 8.** About 0.05 ms, slight look change toward the screen corners.
- **Bringing Angular Distance back (look, not speed).** Only worth doing if the blob-to-leaves switch in tree shadows at about 25 m bothers Kirill. Untried test: one invisible, very tall shadow caster (a tiny mesh with a custom bounding box reaching some 1,000 m above the map, following the player) to stretch each cascade's depth range, so real crowns never sit near the top of it. Set it up as a debug key that switches the caster on and off with Angular Distance at 0.05, and let Kirill look at a spot that used to go grey. If it works, Angular Distance probably needs raising to get the old softness back; it costs 0.14–0.24 ms of GPU.

## Decided, do not reopen without a reason

- **Flattened tree shadow meshes: not worth it** (Kirill, 2026-10-06). The tree leaf cards are curved sheets of 12–22 triangles; a shadow mesh could flatten each to 2–4. Estimated 0.2–0.4 ms, with a risk of leaves shading themselves. Scan: `debug_print_leaf_cards()` in `tools/setup_tree_assets.gd`.
- **Thinned or simplified tree shadow meshes: rejected in game** (2026-10-05). Keeping one card in four made shadows read as blobs beside the trunk; Godot's simplifier shrinks the cards. The separate shadow mesh itself was only removed because, after the duplicate cards were dropped, it held the same triangles as the visible tree.
- **Mid-distance LOD for the visible trees: not worth it.** A mid LOD recovers only part of the 1.0–1.3 ms view share, and leaf cards simplify badly.
- **The pines' lower twig cards stay.** Leaving them out removes visible detail. If the saving is ever wanted, combine `Branch.png` with each tree's leaf texture so the twigs can join the main leaf surface.
- **Sun Angular Distance stays 0 unless the tall-caster test above works.** Above 0, a few tree shadows turn grey and see-through at some viewing angles. Likely cause and the measured cost: `docs/shadows.md`.
- **Shorter sun shadow range: no gain.** Measured again GPU-limited on 2026-10-06: within ±0.16 ms.
- **The lantern stays as it is.** Its cost is two lights shading nearby pixels; every saving changes its look.

## Debug keys and launch arguments added on 2026-10-06

- **U**: plants drawn by Terrain3D (old) or `PlantField` (new). About 5 seconds at a few FPS, because Terrain3D rebuilds its nodes once per shadow-casting mesh.
- **O**: fern shadows from the reduced mesh (default) or the full mesh. Immediate.
- `--plants-terrain3d`: start with every plant on Terrain3D. `--plants-full-shadows`: start without the reduced fern shadows. `--plants-debug`: print drawn counts. `--plants-debug-toggle`: run the U and O switches automatically and print `toggle test: PASSED`.
- Benchmark: `--bench-hide=<layer>,...`, `--bench-lantern-shadow-off`, and the toggles `grass:<band>`, `plants:<layer>:lod<n>`, `terrain_texturing`, `terrain_shadows`, `lantern_shadow`, `lantern_ground_pool`.

## How to measure

- Compare two setups with alternating targeted runs, three pairs (about 9 minutes at 90 seconds a run). Single runs of the same setup differ by up to 1 ms of frame time at spawn_ahead and road_open.
- Check that both sides are limited the same way before comparing GPU ms: frame ms should sit within about 0.7 ms of GPU ms at the station.
- Check the report's first line before trusting a run: it must show sun shadows on and 6 post effects. The benchmark uses whatever is saved in the Options menu.
