# Handoff: new cliff meshes from Fab (updated 2026-10-04)

## Goal

Add variety to the cliff layer by trying Megascans (Fab) rock scans as extra cliff-face meshes
next to the two namaqualand cliffs. Kirill drops one glb at a time into
`D:\Downloads\Godot_v4.7.2-stable_win64.exe\raw-assets\models\cliffs\fab\`, it gets converted and
registered, and he judges it in-game. Trying the same models as flat outcrops was mentioned as a
later step and has not been started.

## State

Everything below is committed (last commit `353baf7 feat: new cliffs`); the working tree was
clean when this file was last updated.

| Mesh | Status | Notes |
|---|---|---|
| `namaqualand_cliff_01` | original | 8.3 x 5.0 x 4.4 m (W x H x D) |
| `namaqualand_cliff_02` | original | 20.2 x 7.2 x 6.6 m |
| `nordic_coastal_cliff_huge` | kept | promontory, source x0.7 -> 13.1 x 7.1 x 11.3 m |
| `nordic_coastal_cliff_large` | kept | thin wall, source x2 -> 13.5 x 6.0 x 3.4 m; `top_despike` 2.0, `push_back` 0.75, `top_lift` 0.25 |
| `icelandic_lava_cliff_huge` | kept (added 2026-10-04) | long blocky wall, source x1.3 -> 20.05 x 5.67 x 6.69 m, no rotation; `push_back` 1 (set by Kirill) |
| first wedge (`large_..._ulkiejkva`) | rejected, deleted | curved back edge left a gap behind its tall end |
| `tundra_mossy_boulder` | rejected, deleted | "doesn't look good" at x5 scale |

## What was added

- **Import script** -- `tools/blender/import_megascans_glb.py` got `--out <category>` so it can
  write to `assets/models/cliffs/<name>/` instead of only `ground_debris`. Commands used:
  - nordic huge: `<src> nordic_coastal_cliff_huge --out cliffs --scale 0.7 --recenter --tex-size 2048 --ratios 1,0.5,0.25,0.12`
  - nordic large: same with `nordic_coastal_cliff_large` and `--scale 2`
  - lava: same with `icelandic_lava_cliff_huge` and `--scale 1.3`
  - Output: `<name>.glb` with `<name>_LOD0..3`, textures `_diff_2k.jpg`, `_nor_gl_2k.jpg`, `_orm_2k.png`.
  - A cliff needs its width on X and its rock face toward Godot +Z (Blender -Y); use `--rotate` if
    the source isn't already that way. All three kept meshes needed no rotation.
- **Per-def keys in `CLIFF_DRESSING_DEFS`** (`scripts/terrain/terrain_config.gd`):
  - `"orm"` instead of `"rough"` -- Megascans packs AO (R) and roughness (G) in one texture
    (`cliff_instancer.gd`, `dress_cliff_faces`).
  - `"top_lift"` (REQUIRED on every def) -- metres the raised ground behind overshoots the mesh
    top. Replaced the old global `CLIFF_DRESSING_RAISE_TOP_LIFT`.
  - `"top_despike"` (optional) -- widest knob in metres that the raised ground behind should
    ignore (`cliff_dressing.gd`, `_compute_cliff_dressing_top_profile`).
  - `"push_back"` (optional) -- slides the mesh and its collision backward into the raised ground,
    in world metres. Terrain is not reshaped for it.
- **J debug menu** (`scripts/debug/layer_toggle_panel.gd`) -- toggling trees / rocks / deadfall
  off also disables their colliders, and there is a "Cliff meshes" checkbox (hides the
  `CliffDressing` node and its collision; outcrops not included).

### 2026-10-04: new meshes in knots, even usage

- **Knot rows use all five meshes** (`scripts/terrain/knots.gd`). The two hardcoded names were
  replaced by width classes: `CLIFF_SMALL` (namaqualand_01), `CLIFF_MID` (nordic large),
  `CLIFF_MID_DEEP` (nordic huge), `CLIFF_WIDE` (namaqualand_02, lava). Each row keeps its
  position, facing and rough width and takes one width-matched combo (`_row_combos`):
  - ~20 m rows (floor back, floor upper): one wide, or mid + small
  - ~28 m rows (floor front, wall shelf): wide + small, or two mids
  - bench: two small, one mid, or one wide
  - The promontory (`CLIFF_MID_DEEP`) is only allowed in the wall bench and the floor back row --
    in stacked rows its 11 m depth would dig into the row behind.
  - A new cliff mesh joins the knots by adding its name to the pool matching its width.
- **Even usage** -- Kirill found the lava cliff showing up more than the others.
  - Knots: `_assign_row_models` runs once per PLACED knot (templates are rolled per placement
    candidate, so models are no longer chosen there) and picks the combo whose meshes have been
    used least across all knots so far, ties random.
  - Fault lines: `CliffDressing.plan_cliff_dressing` already picked the least-used model that
    fits; it now starts from the knots' counts (`knot_result.mesh_usage`, passed in
    `heightmap.gd`).
  - Every run prints `TERRAIN_GEN: cliff mesh usage -- ...` with the final per-mesh totals.
  - Seed 858829582 result: namaqualand_01 9, namaqualand_02 7, nordic large 7, nordic huge 5,
    lava 5 (in knots: 4 / 4 / 4 / 2 / 4). Not perfectly even because the landmark brings 3 fixed
    meshes and ~10 planned fault-line meshes are dropped near knots / the landmark after they
    were counted.

## Verified / not verified

- Last run (2026-10-04, seed 858829582): zero errors, 5/5 knots placed, every counted level
  reachable, 33 cliff meshes dressed. Checked from logs only -- looks are Kirill's call.
- Knot #3 (floor, px (168, 251)) has its back row top too small to count as a level
  (8 m2 standable); knots #3 and #4 each needed one fallback ramp.
- Lower meshes stack less: an earlier run had a wall knot whose lava shelf and bench ended at
  nearly the same height (10.9 / 10.8 m). Not addressed.
- The editor's `validate_script` tool is useless here (returns error 43 on untouched files too);
  verify with a run + `get_errors` instead.

## Things to know

- **Adding or removing a def, or changing the knot pools, changes the layout for a pinned seed**
  (`MASTER_SEED` 858829582).
- **The fixed landmark doesn't use the new meshes.** `terrain_data/landmarks/verticality_knot_01.json`
  stores captured mesh names.
- **What makes a mesh fit:** a back rim roughly parallel to its width (the raise pass treats the
  back as one straight line at the bounding-box depth), a base near flat (meshes are sunk 1.5 m x
  scale), and ends that aren't much taller than the surrounding ground. A per-slice back-edge
  profile was proposed to support curved backs; Kirill declined it.
- **Textures** are downscaled 4K -> 2K to match the other cliffs. They import with Godot's
  default settings (lossless, not VRAM-compressed); not revisited.
- **Finding instances in a run:** query `/root/Main/CliffDressing/<def name>` for one instance's
  position, or read the `KNOT #n ... world anchor` lines in the log for knots.
- **Game log on disk:** `%APPDATA%\Godot\app_userdata\Retro FP Walk Demo\logs\godot.log`; knot
  summary also in `godot_notes/knot_diag.txt` (overwritten every run).
- Blender previews for a new source glb: a throwaway analysis script (bbox, area-weighted normal,
  per-slice top and back extents, six rendered views) is written in the session scratchpad each
  time; it is not in the repo.

## Next steps

1. Kirill judges the knots with the mixed meshes and the lava cliff in-game; tune `push_back` /
   `top_lift` per def as needed.
2. More meshes arrive the same way: new glb in the fab folder -> measure -> convert -> add a row
   to `CLIFF_DRESSING_DEFS` -> add its name to a knot pool in `knots.gd` -> rescan -> run. To drop
   one: remove its def row and its pool entry, then delete its folder under `assets/models/cliffs/`.
3. Outcrop trial for these models (`OUTCROP_DEFS` in `scripts/terrain/outcrops.gd`) -- its
   material builder still only reads `"rough"`, so it needs the same `"orm"` support first.
