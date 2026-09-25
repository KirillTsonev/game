# Vegetation -- trees, placement and the next layers

How the forest is built and tuned. General model-adding rules: `docs/adding_models.md`.

Last reviewed: 2026-09-24.

---

## Art direction rule

Source textures stay **realistic and flat-lit**; the painterly look comes from the
post-process. Hand-painted leaf textures were tested on the realistic-bark trees and looked
wrong (double stylisation + baked lighting fighting the engine's). Keep foliage textures
realistic too.

---

## The canopy: 14 Fab pack trees (Terrain3D ids 14-27)

- Source: `assets/models/candidates/vegetation/Models/Vegetation.fbx` (the Fab vegetation
  pack -- one FBX with every model). 4 pines + 3 deciduous, each with a second colour
  variant.
- **Baked** by `build_pack_trees()` in `tools/setup_tree_assets.gd` (run in the editor via
  `call_method`, `runtime:false`, scene `tools/setup_tree_assets.tscn`, node `.`). For each
  row of `PACK_TREES` (`id`, FBX `node`, `name`) it bakes the node's rotation/scale into a
  standalone mesh (base at y=0), fixes materials, saves `trees/<name>.res` + `<name>.tscn`
  and registers the Terrain3D mesh asset (single LOD, visible to `PACK_LOD0_RANGE` = 600 m,
  24 m fade).
- **Keep in sync:** `PACK_TREES` ids <-> `TREE_IDS_FAB_PACK` in `scripts/terrain/tree_scatter.gd`.
  (The old Poly Haven fir/pine trees, ids 14-19, were removed 2026-09-24 and the pack trees
  renumbered from 20-33.)
- Collision: **every** tree gets an upright trunk cylinder (`TREE_TRUNK_RADIUS`,
  `TREE_TRUNK_HEIGHT`, scaled per instance) in `_place_one_tree()`.

### Adding another pack tree

1. Add a row to `PACK_TREES` with the next free Terrain3D id (28 as of 2026-09-24 -- shared
   with rocks, ids are one contiguous list).
2. Add the id to `TREE_IDS_FAB_PACK`.
3. Run `build_pack_trees()`, restart the game, check it in-game.

### Bark

- The pack's 256 px bark is replaced at bake time by 2K PBR bark (`PACK_BARK`):
  pines -> `vegetation/bark/pine_bark_*_2k` (Poly Haven pine_tree_01), deciduous ->
  `vegetation/bark/oak_bark_*_2k` (Poly Haven jolcham_oak_bark_01, 2048x4096).
- **World triplanar** mapping, not the pack's UVs: those are mirrored on alternating trunk
  faces, which made the normal-mapped bark look faceted.
- Knobs: `PACK_BARK_TILE_M` (1.4 m per texture width), `PACK_BARK_TRIPLANAR_SHARPNESS` (6).
- The trunks are low-poly (6-7 sides) -- accepted as is.

### Leaf / branch cards

- `vegetation/Textures/Branch*.png` -- 4x upscaled (Upscayl) versions of the originals,
  recombined with each card's original alpha. Originals backed up outside the project in
  `vegetation/Vegetation/backup_textures/`.
- Each card is a single branch, so a card can be replaced by any image with the same aspect
  ratio and stem direction (alpha cut from a black background).
- `Branch.png` is a **bare twig** shared by pines and deciduous trees -- a replacement must
  also be a bare twig.

---

## Placement (`scripts/terrain/tree_scatter.gd`, `scatter_trees` / `_place_one_tree`)

Trees are placed in **stands** (clumps) plus **lone** trees. Counts are per 256x256 m and
scale with the whole map area (the map is 256x512, so x2).

| Constant | Value (2026-09-24) | Effect |
|---|---|---|
| `TREE_STAND_COUNT_MIN/MAX_BASE` | 11 / 17 | clumps |
| `TREE_PER_STAND_MIN/MAX` | 5 / 16 | trees per clump |
| `TREE_STAND_SPREAD` | 13 m | clump tightness (std-dev) |
| `TREE_LONE_COUNT_MIN/MAX_BASE` | 8 / 16 | scattered singles |
| `TREE_STAND_SPACING_CANDIDATES` | 6 | clump centres evenly spread (1 = pure random) |
| `TREE_STAND_LOWGROUND_SAMPLES` | 1 | bias clumps to low ground (1 = none) |
| `TREE_X_BAND_MIN/MAX` | 0.03 / 0.97 | allowed band across the map |
| `TREE_Z_BAND_MIN/MAX` | 0.05 / 0.95 | allowed band along the map |
| `TREE_MAX_SLOPE_NORMAL_Y` | 0.80 (~37 deg max) | keeps trees off steep ground |
| `TREE_MAX_PLACEMENT_ATTEMPTS` | 6 | retries before a tree is dropped |
| `TREE_SCALE_MIN/MAX` | 0.85 / 1.25 | size variety |
| `TREE_LEAN_MAX_DEG` | 4 | random lean |

Also rejected: on the road, inside rock keep-outs (cliffs, outcrops, boulders). There's no
minimum spacing between trees.

Tree count scales GPU/shadow cost roughly linearly; the sun's shadows are PSSM 2 splits to
250 m (split at 100 m).

### Debug: why is there no tree here?

`PerfDebug` (autoload, `scripts/perf_debug.gd`) key **T** calls
`WorldGenerator.debug_tree_probe(player position)`, which re-runs `_place_one_tree`'s checks
at your feet (zone x/z, slope, road, keep-outs) and reports the nearest stand centre. It
relies on `_tree_debug` (~1 MB of generation data kept after `_scatter_trees`). Both are
marked DEBUG -- remove when no longer needed.

---

## Pack contents for later layers

Inside `Vegetation.fbx` (sizes in FBX units; bake one to confirm real size):

- **Shrubs:** `Tree_B` (176 tris, 4 colour variants), leaf clusters `Plane_014`-`017`
  (32 / 192 tris).
- **Sapling-like:** `Branch_C` (~1.8k tris), `Tree_05` (small deciduous, ~2.4k tris).
- **Ground layer:** `Grass_P_001`-`014` (16-408 tris), logs / stumps `Trunk_*` (54-132 tris).
- **Snow variants** (`_N` textures/models) -- kept for a possible snow version.
- **No ferns** in the pack. Plan: build fern meshes from a few crossed cards (16-64 tris)
  with realistic flat-lit frond images on black.
- The Poly Haven saplings (433k - 2.3M polygons) are far too heavy for an understory.

## Understory plan (not built yet)

- Drive it from a **canopy density map** built from the placed trees (not from individual
  trees), so it thickens into groves and thins at their edges.
- **Ferns:** strongly tied to canopy, plus shaded cliff bases (the side facing away from the
  sun) and a small low-ground bonus. **Shrubs:** peak at grove edges, some under canopy, a few
  in the open.
- Same exclusions as trees + a clear ring around trunks + a few open glades.
- Performance: short draw distance (~60-80 m), **no sun shadows** (or only within ~20 m),
  no collision.
- Later idea: a rustle sound when walking through foliage, using a spatial grid of the
  understory positions.
