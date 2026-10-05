Open optimisation items as of 2026-10-05, evening. Details and all figures: `docs/performance_findings.md`.

## Done today

- **Duplicate leaf cards dropped from the trees.** The pack stores every leaf card twice, back to back, and our leaf material already draws both sides, so every card was drawn twice for nothing, in the view and in every shadow cascade. The tree bake now drops the copy: trees are 55–60 % of their triangles with the same shape, and you checked the look in game. Measured over three alternating pairs: GPU 1.2–2.7 ms lower at every station with trees, road walk GPU 9.19 → 7.04 ms and frame 10.30 → 9.49 ms. Setup: `docs/vegetation.md`.
  - How we got there: a separate reduced shadow mesh was built first and removed again once the visible mesh had the same triangles. Also rejected on the way: keeping one card in four and enlarging it (shadows looked like blobs floating beside the trunk), and Godot's mesh simplifier (it shrinks the cards).
- **Sun Angular Distance is 0** (was 0.05). At every value above 0 a few tree shadows turned grey and see-through at some viewing angles. It cost 0.14–0.24 ms of GPU. The price is that the blob-to-leaves switch in tree shadows at about 25 m is back; you accepted that for now. Likely cause and the one untried fix are in `docs/shadows.md`.
- **New tools:** a "Rebuild trees + saplings" Inspector button on `tools/setup_tree_assets.tscn`, and a `sun_angular_distance` toggle in the benchmark.

## Where the frame stands

- Every station runs at 6–12 ms on this machine, inside the 16.7 ms budget of the 60 FPS cap. The road walk averages 9.5 ms.
- The two slowest views, spawn_ahead (11.9 ms) and exit_look_back (10.3 ms), are CPU-limited: about 7,200–8,200 draw calls, more than half of them in the shadow passes. Cheaper triangles or pixels do not help them; the tree change moved them by only 0.3 ms.
- The other stations are GPU-limited at 6.4–7.5 ms of GPU.
- Open question that decides how far to go: are we optimising for this laptop at 60 FPS (then the rest is optional), or for weaker hardware or a higher frame rate?

## Open, for the CPU-limited views (draw calls)

1. **The tiny twig surfaces on eight trees: decided, keep the twigs.** Six pines and two deciduous variants carry 6–32 bare-twig cards as a surface of their own, which costs one extra draw call per cell in the view and in every shadow cascade. Leaving them out was tried and reverted on 2026-10-05: it removes visible detail for an estimated 0.4–0.8 ms at the two slowest views only (not measured). If the saving is ever wanted, the way to get it with the twigs intact is a combined texture (`Branch.png` plus each tree's leaf texture) so the twig cards can join the main leaf surface.

2. **GPU-driven drawing for the ferns and bushes.** 22,000 plants in 5,400 nodes today, about 100 draws afterwards. The biggest CPU lever and the biggest piece of work. It was parked while the frame was GPU-limited; at the two slowest views it no longer is.

## Open, for the GPU-limited views

3. **A mid-distance LOD for the visible trees: not worth it now.** Re-measured after the duplicate-card fix: the trees cost 1.5–1.8 ms of GPU in all (was 3.5–4.7), of which 1.0–1.2 ms is the view and 0.3–0.8 ms the shadow passes. A mid LOD could recover only part of that 1.0–1.2 ms, and it carries the highest visual risk on the list.

4. **MSAA: 0.6–1.0 ms.** A look decision, like SSAO was: it smooths geometry edges, and the grass shader notes say thin blades depend on it. I can add a toggle to the Options pane so you can judge it against the live scene.

## Small

5. **Saplings casting shadows from their impostors.** The whole sapling layer was 0.16–0.29 ms of GPU and 0.33–0.92 ms of CPU before the duplicate-card fix (they share the tree meshes), so the gain is a fraction of that. Their shadows would stop at 80 m instead of 150 m.

6. **Radial blur's sample count, 16 to 8:** about 0.05 ms, a slight look change toward the screen corners.

7. **The other five post effects:** done as far as is worthwhile. What remains is 0.1–0.2 ms and would tie the effects together.

## Parked

- **The tree-shadow handoff at 25 m** (blob far away, leaf detail close up). Untried: an invisible tall shadow caster that stretches the cascade depth range, which may let Angular Distance be used again without the grey shadows. Tried and removed today: coarsening the leaf cutout in the shadow pass.

## Recommendation

Item 2 is the next real lever for the two slowest views. A full benchmark of the current state has not been run yet (the last six were targeted tree runs), and today's last round of changes is not committed.
