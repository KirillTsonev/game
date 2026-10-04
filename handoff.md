# Handoff: new cliff meshes from Fab (2026-10-02)

## Goal

Add variety to the cliff layer by trying Megascans (Fab) rock scans as extra cliff-face meshes
next to the two namaqualand cliffs. Kirill drops one glb at a time into
`D:\Downloads\Godot_v4.7.2-stable_win64.exe\raw-assets\models\cliffs\fab\`, it gets converted and
registered, and he judges it in-game. Trying the same models as flat outcrops was mentioned as a
later step and has not been started.

## State

| Mesh | Status | Notes |
|---|---|---|
| `nordic_coastal_cliff_huge` | kept, committed (`57fe3b1 feat: new cliff`) | promontory, source x0.7 -> 13.1 x 7.1 x 11.3 m (W x H x D) |
| `nordic_coastal_cliff_large` | kept, **uncommitted**, being tuned | thin wall, source x2 -> 13.5 x 6.0 x 3.4 m |
| first wedge (`large_..._ulkiejkva`) | rejected, deleted | curved back edge left a gap behind its tall end |
| `tundra_mossy_boulder` | rejected, deleted | "doesn't look good" at x5 scale |

Uncommitted in the working tree: `assets/models/cliffs/nordic_coastal_cliff_large/`, plus edits to
`cliff_dressing.gd`, `cliff_instancer.gd`, `terrain_config.gd`, `layer_toggle_panel.gd`,
`import_megascans_glb.py`, `docs/adding_models.md`. (`godot_notes/knot_diag.txt` is also modified
but not by this work.)

## What was added

- **Import script** -- `tools/blender/import_megascans_glb.py` got `--out <category>` so it can
  write to `assets/models/cliffs/<name>/` instead of only `ground_debris`. Commands used:
  - huge: `<src> nordic_coastal_cliff_huge --out cliffs --scale 0.7 --recenter --tex-size 2048 --ratios 1,0.5,0.25,0.12`
  - large: same with `nordic_coastal_cliff_large` and `--scale 2`
  - Output: `<name>.glb` with `<name>_LOD0..3`, textures `_diff_2k.jpg`, `_nor_gl_2k.jpg`, `_orm_2k.png`.
  - A cliff needs its width on X and its rock face toward Godot +Z (Blender -Y); use `--rotate` if
    the source isn't already that way. Both kept meshes needed no rotation.
- **`"orm"` def key** (`cliff_instancer.gd`, `dress_cliff_faces`) -- Megascans packs AO (R) and
  roughness (G) in one texture; a def gives `"orm"` instead of `"rough"`.
- **`"top_despike"` def key** (`cliff_dressing.gd`, `_compute_cliff_dressing_top_profile`) --
  widest knob in metres that the raised ground behind should ignore. Added because a boulder
  standing ~0.75 m proud of `nordic_coastal_cliff_large`'s top made a terrain bump behind it.
  Set to 2.0 on that mesh only.
- **`"push_back"` def key** (`cliff_instancer.gd`) -- slides the mesh and its collision backward
  into the raised ground, in world metres. Terrain is not reshaped for it. Kirill is tuning this
  by hand; currently 0.75 on `nordic_coastal_cliff_large`.
- **J debug menu** (`scripts/debug/layer_toggle_panel.gd`) -- toggling trees / rocks / deadfall
  off now also disables their colliders, and there is a new "Cliff meshes" checkbox (hides the
  `CliffDressing` node and its collision; outcrops not included).

Kirill also raised `CLIFF_DRESSING_RAISE_TOP_LIFT` (`cliff_dressing.gd:84`) from 0.1 to 0.2
himself; it is global to all cliffs.

## Not verified

- `top_despike`, `push_back` and both J-menu changes were written while Kirill's game was open
  and have **not** been test-run by Claude. The editor's `validate_script` tool is useless here
  (returns error 43 on untouched files too). If the game fails to start, look at
  `cliff_dressing.gd`, `cliff_instancer.gd` or `layer_toggle_panel.gd` first.
- Both kept meshes loaded and were placed with zero errors in earlier runs, before those edits.

## Things to know

- **Selection is automatic.** Fault-line placement picks the least-used model that fits, so each
  def gets a roughly equal share. Adding or removing a def changes the layout for a pinned seed
  (`MASTER_SEED` 858829582).
- **Knots and the landmark don't use the new meshes.** `knots.gd` hardcodes `CLIFF_SMALL` /
  `CLIFF_BIG` and its row recipes; `terrain_data/landmarks/verticality_knot_01.json` stores
  captured mesh names.
- **What makes a mesh fit:** a back rim roughly parallel to its width (the raise pass treats the
  back as one straight line at the bounding-box depth), a base near flat (meshes are sunk 1.5 m x
  scale), and ends that aren't much taller than the surrounding ground. A per-slice back-edge
  profile was proposed to support curved backs; Kirill declined it.
- **Textures** are downscaled 4K -> 2K to match the other cliffs. They import with Godot's
  default settings (lossless, not VRAM-compressed); not revisited.
- **Finding instances in a run:** query `/root/Main/CliffDressing/<def name>` for one instance's
  position. With the current seed, `nordic_coastal_cliff_large` was at (-231, 11.8, -157) and
  `nordic_coastal_cliff_huge` at (-30, 9.9, 33).
- Blender previews for a new source glb: a throwaway analysis script (bbox, per-slice top and
  back extents, six rendered views) was used from the session scratchpad; it is not in the repo.

## Next steps

1. Restart the game and confirm it launches; check the bump behind the boulder is gone and tune
   `push_back` / `top_despike` on `nordic_coastal_cliff_large`.
2. Commit once it looks right.
3. More meshes arrive the same way: new glb in the fab folder -> measure -> convert -> add a row
   to `CLIFF_DRESSING_DEFS` -> rescan -> run. To drop one: remove its def row, then delete its
   folder under `assets/models/cliffs/`.
4. Outcrop trial for these models (`OUTCROP_DEFS` in `scripts/terrain/outcrops.gd`) -- its
   material builder still only reads `"rough"`, so it needs the same `"orm"` support first.
