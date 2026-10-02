# Adding, removing and moving models

Step-by-step checklists for getting a new 3D asset into the world. The *why* behind most
steps lives in `CLAUDE.md`'s pitfall sections (named in brackets) -- this file is the
*what, in which order*. Trees and other vegetation: see `docs/vegetation.md`.

Last reviewed: 2026-09-30.

---

## Where things live

| Folder | Contents |
|---|---|
| `assets/models/rocks/<dir>/` | scatter rocks (boulder_01, stone_01, rock_07, rock_09, namaqualand_boulder_02..06): `<dir>_2k.glb`, `<dir>_material.tres`, `textures/<dir>_{diff,nor_gl,rough}_2k.*` (+ optional `_mask_2k.png`) |
| `assets/models/cliffs/<name>/` | cliff / outcrop set dressing (namaqualand_cliff_01/02, mountainside): `<name>_2k.glb`, `textures/` incl. `_patch_diff.png` / `_fill_diff.png` repair textures |
| `assets/models/scree/` | scree rock/stone sets |
| `assets/models/candidates/vegetation/` | the Fab vegetation pack (see `docs/vegetation.md`) |
| `assets/models/understory/<dir>/` | understory shrubs + ferns, kept apart from the trees: `<dir>.fbx`, `<dir>_material.tres`, `textures/<dir>_{diffuse,normal,translucency}.tga` (`lady_fern`: one glb with 9 variants + PNG textures, exported by `tools/blender/import_megascans_plant.py`) -- set up by `tools/setup_understory_assets.gd` (see `docs/vegetation.md`) |
| `assets/models/ground_debris/<dir>/` | deadfall props (Megascans, Fab "mid" glb, 2K): stumps `stump_broken` / `stump_old` / `stump_rotten_large` / `stump_rotten_tall`, logs `log_fallen_nordic` (5.7 m) / `log_fallen_large` (7.1 m), `branch_fallen` (1 m), sticks
`stick_arbem` (FBX, x3) and `sticks_debris/sticks_debris_a..d` (4 glbs sharing one folder, texture set and
material; x3.5-4) -- small Megascans twigs scaled up to 0.6-0.9 m. Embedded textures written out: `<dir>.glb` (one mesh, no images), `textures/<dir>_{diff,nor_gl}_2k.jpg` + `<dir>_orm_2k.png` (R = AO, G = roughness, B = metallic). Logs + branch re-centred on their bbox; stumps keep the scan's pivot. Sources in `raw-assets/models/{stumps,logs}/`. Each glb holds `<dir>_LOD0..2` (source, 35 %, 10 % tris; `stump_broken` 35 / 10 / 3 %, and stood upright with `--rotate 0,90,0` -- its scan lies on its side), built by `tools/blender/import_megascans_glb.py`; materials + Terrain3D ids 38-44 by `tools/setup_ground_debris_assets.gd`; placed by `scripts/terrain/deadfall_scatter.gd` (see `docs/vegetation.md`, "Deadfall") |
| `assets/models/castle-church/` | the church model placed in `main.tscn` |
| `tools/` | editor-only `@tool` setup scripts + their one-node scenes (never loaded by the game) |
| `terrain_assets.tres` | the Terrain3D asset list (textures + mesh ids) |

**Terrain3D mesh ids (as of 2026-09-30):** 0 placeholder, 1-4 rocks, 5-13 scree, 14-27 trees,
28-32 understory (Fern02, Bush01, Bush02Green, Bush04, Bush05), 33-37 rocks (NamaBoulder02-06),
38-49 deadfall (StumpBroken, StumpOld, StumpRottenLarge, StumpRottenTall, LogFallenNordic,
LogFallenLarge, BranchFallen, StickArbem, StickDebrisA-D), 50-52 litter mounds (LitterMoundA-C:
`ground_debris/litter_mound/`, built by `tools/blender/bake_pine_litter.py`, material =
`litter_mound.gdshader` on the PineLitter terrain textures -- see `docs/forest_floor_plan.md`),
53-54 pine cones (ConeOpen, ConeLong: `ground_debris/cone_open/`, `cone_long/`, 1K textures, no
ORM -- same plan, step 6), 55-63 lady ferns (LadyFernA-I, understory -- `docs/vegetation.md`).
Ids are a contiguous list: a new asset is appended at the next id (**64**).

---

## Rules that apply to every model

1. **Use the real source textures**, not the ones Godot extracts from a `.glb`. Poly Haven
   downloads have a `textures/` folder next to the `.blend`. [GLB export byproduct textures]
2. **Check every `.exr`** (normal / roughness). Poly Haven EXRs are often DWAA-compressed,
   which Godot can't import -- and the failure is silent. Re-encode to ZIP or convert to
   PNG *before* the file enters the project. [Rock/boulder EXR ... DWAA]
3. **Import settings don't reapply on rescan.** After editing a `.import` file, force it
   with `EditorInterface.get_resource_filesystem().reimport_files([...])` from a `@tool`
   method. [Rock/boulder mesh scale]
4. **If the model renders through a material override** (rocks, via their
   `<dir>_material.tres`), set its import to **discard textures**
   (`gltf/embedded_image_handling=0`) and reimport. With the default (1 = extract) Godot
   writes loose `<glb>_<name>_diff.jpg` etc. next to the model, and the model *fails to
   load* if those files (or even just their `.import` files) are later deleted -- this broke
   boulder collision once (2026-09-24).
5. **Imported models have no collision.** Add it explicitly -- convex hull for small props,
   trimesh for big walkable set dressing. [Freshly exported/imported meshes need collision]
6. **Verify from disk, not from the editor's memory**: load with
   `ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)` (or `_REPLACE`), and
   check in-game with a fresh run.

---

## A. New scatter rock / small prop (convex collision, material override)

1. Put `<dir>_2k.glb` in `assets/models/rocks/<dir>/`.
2. Copy the source textures into `assets/models/rocks/<dir>/textures/` as
   `<dir>_diff_2k.jpg`, `<dir>_nor_gl_2k.exr`, `<dir>_rough_2k.exr` (EXRs checked per rule 2).
   Optional `<dir>_mask_2k.png` is picked up automatically as ambient occlusion.
   Steps 1-2 in one go from a Poly Haven `.blend` download:
   `tools/blender/import_polyhaven_rock.py` (run with Blender's own Python -- it re-encodes the
   DWAA EXRs to ZIP via Blender's bundled OpenImageIO, copies the diffuse, and exports all
   `*_LODn` meshes to the glb with no embedded images). Usage is in the script header.
3. In `<dir>_2k.glb.import`: set `gltf/embedded_image_handling=0` (rule 4) and
   `nodes/root_scale` so the rock's longest axis lands around 1.0 (Boulder01 is ~1.83 and
   should stay the biggest). Force a reimport (rule 3). [Rock/boulder mesh scale]
4. Add a row to `ROCKS` in `tools/setup_rock_assets.gd`:
   `{"id": 28, "dir": "<dir>", "file": "<dir>_2k", "name": "<Name>"}` (next free id).
5. Run, in the editor (`call_method`, `runtime:false`, scene `tools/setup_rock_assets.tscn`,
   node `.`): `setup_materials([ids])`, then `setup_mesh_assets([ids])` -- pass just the new
   ids so the existing rocks' materials aren't re-saved (empty = all). For a heavy LOD0
   (> ~20k tris) add its id to `ROCK_LOD_RANGES` (one range per LOD the glb actually has)
   and run `configure_rock_lods()`.
6. In `scripts/terrain/rock_scatter.gd`: add the id to `ROCK_MESH_IDS`, its glb to
   `ROCK_SCENE_PATHS` and a `1.0` to `ROCK_BASE_SCALE` -- the collision hull is built at
   runtime from that glb's lowest-poly `*_LODn` mesh (`create_convex_shape(true, true)`,
   simplified to ~32 points). Check the `rock glb load + convex hulls` startup line after.
7. Verify: `debug_print_mesh_sizes()` and `debug_print_mesh_assets()` in the rock tool, then
   in-game -- textured, sensible size next to Boulder01, and **not walk-through**.

## B. New cliff / large set dressing (trimesh collision, placed by terrain_gen)

1. Put `<name>_2k.glb` in `assets/models/cliffs/<name>/`, source textures in its
   `textures/` (EXRs checked per rule 2).
2. The glb's LOD levels must be sibling nodes named `*_LOD0` .. `*_LOD3`:
   `apply_cliff_lod_ranges()` (`scripts/terrain/cliff_instancer.gd`) gives each a distance band (`CLIFF_LOD_END`) so only one
   draws at a time.
3. Add a definition next to the existing ones (`CLIFF_DRESSING_DEFS` in
   `scripts/terrain/terrain_config.gd` for cliff faces, `OUTCROP_DEFS` in
   `scripts/terrain/outcrops.gd` for flat outcrops): `glb`,
   `diff`, `nor`, `rough` paths plus the size fields the existing entries use.
4. Optional repair textures: `<name>_<kind>_diff.png` (kind = `patch`, `fill`, ...) next to
   the diffuse -- found by string replacement on the diffuse path.
5. Collision is added per mesh node as trimesh on one LOD (`_should_add_cliff_collision`,
   `add_cliff_collision_recursive`, both in `scripts/terrain/cliff_instancer.gd`) -- check the new model's node names match what those
   expect.
6. Verify in-game: placement, textures, LOD switching (no visible pop at 40 / 90 m) and
   collision.

## C. Trees and other vegetation

See `docs/vegetation.md` (baking from the Fab pack, `PACK_TREES`, bark, ids).

---

## Removing a model

1. Find every reference first -- including **paths built from pieces** (`"%s"` patterns,
   string `replace()`); a plain filename search misses those.
2. Terrain3D ids **renumber** when one is removed: remove from the highest id down, then
   update every id list (`ROCK_MESH_IDS`, `TREE_IDS_FAB_PACK`, `PACK_TREES`, `ROCKS`, ...).
3. Only then delete the files -- and check nothing loads *through* them (rule 4).

## Moving / renaming folders

- Update every `res://` path in `.tscn`/`.tres`/`.gd`/`.import`/`.md`, **plus** code that
  builds paths from pieces (e.g. `"res://assets/models/rocks/%s/"` in the rock tool).
- UIDs survive a move, so uid-based references keep working; literal paths in scripts
  don't.
- Afterwards: Project -> Reload Current Project (the editor keeps old paths in memory), then
  verify loads from disk.
