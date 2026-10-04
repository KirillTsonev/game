# Handoff: mid-storey saplings (2026-10-04)

## Goal

Step 7 of `docs/forest_floor_plan.md`: a 2-4 m mid-storey at grove edges, between the shrubs and
the canopy.

## State

Built and run once; waiting for Kirill to judge it in-game. Nothing is committed.

- **Decision:** saplings are the canopy trees scaled down per instance. Kirill compared them
  in-game against cut pine tops (4.5 m at true size, 7 m at x0.6) and picked the scaled-down
  whole trees. Each has a stem cylinder collider (`SaplingColliders`, 5 cm minimum radius, 1.6 m
  tall) -- added at Kirill's request after a first version without.
- **Mesh assets 64-68** in `terrain_assets.tres`, built by `build_sapling_assets()` in
  `tools/setup_tree_assets.gd`: PackPineB, PackPineA2, PackPineC2, PackDecidC2, PackDecidA2.
  Full mesh to 80 m, then an impostor copy, never culled; shadows on both.
- **Placement:** `scripts/terrain/sapling_scatter.gd` (`SaplingScatter`), called from
  `WorldGenerator._ready()` after the understory.
- **J layer panel** has a "Saplings" checkbox.
- **Docs:** `docs/vegetation.md` has a "Saplings" section with the ids, scales, LODs and
  placement rules.

Last run (seed 858829582): no errors, 735 saplings (423 pine, 312 deciduous), 0.13 s.

## Not checked yet

- **Density and look in the forest** -- 735 is a first guess. Knobs at the top of
  `sapling_scatter.gd`: `MAX_P`, `PATCH_LO` / `PATCH_HI`, `OPEN_P`, `SIZE_MIN` / `SIZE_MAX`.
- **Render cost** -- not measured. Compare with the "Saplings" checkbox in the same view.
- **The 80 m switch to the impostor** -- hard switch per 32 m cell; the impostor uses the tree
  impostor's far fullness (2.2). May pop or look too thin / too full.
- **Sapling shadows** -- leaf cards are 3-8 times smaller than on the trees and may drop out of
  the shadow pass (`docs/shadows.md`).

## Things to know

- The per-tree scales live in `PINE_MIX` / `DECID_MIX` in the scatter module, not in the mesh
  assets (the assets share the canopy trees' mesh files).
- Rerun `build_sapling_assets()` after `build_pack_trees()`, `bake_tree_impostors()` or
  `tree_impostor_import()`.
- Changing the sapling layer does not change the rest of the map for a pinned seed (own rng
  stream, runs after everything it reads).
- Left out as too heavy: PackPineD2 (11.3k tris), PackDecidB2 (8.6k). The dry colour variants
  are bare twigs and were not considered.

## Dropped options

- `raw-assets/models/saplings/` (4 glbs): 19k-414k tris, wrong scale, two without textures.
  `quick_treeit_tree.glb` is the only salvageable one (decimate, cut cards, cutout shader).
- Pack `Tree_05` (26.6 m tree) and `Tree_B` (6.1 m, needs texture upscaling); `Branch_C` not wanted.
- Cut pine tops: PackPineB / PackPineA2 tops are nearly bare (60 / 72 tris at 4.5 m).
