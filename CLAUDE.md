# Project notes for Claude

Read this before making Godot MCP changes to this project. It exists so
gotchas discovered the hard way don't get rediscovered the hard way again.
This file is for gotchas specific to THIS project. For general Godot
concepts/best practices (not specific to this project), see the
`godot-fundamentals` skill (saved to the user's Claude account, loads
automatically) -- a local copy also lives at
`D:\Downloads\Godot_v4.7.2-stable_win64.exe\godot_notes\godot_fundamentals.md`.

## Topic docs (read these for step-by-step workflows)

- `docs/adding_models.md` -- checklists for adding / removing / moving models: rocks and scatter
  props, cliffs and large set dressing, folder layout, Terrain3D id list, general rules.
- `docs/vegetation.md` -- the tree canopy (Fab pack baking, `PACK_TREES`, bark, ids),
  placement knobs, the tree probe (PerfDebug T), pack contents and the understory plan.
- This file stays the reference for pitfalls and *why* things are done the way they are.

## Local tooling paths (this machine)

- Blender is installed at
  `D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe`
  (2026-09-17) -- needed for exporting any new source `.blend` model (e.g.
  `assets/models/cliffs/*`) to `.glb` before Godot can import it. Not on
  PATH as far as is known -- pass the full path explicitly to any Blender
  command-line/background-mode invocation rather than assuming `blender`
  resolves.

## Terrain3D texture pipeline -- ONE authoritative script

- `res://tools/generate_flat_textures.gd` (run via `run_scene`, pure file
  I/O) writes placeholder PNGs, and `res://tools/assign_flat_textures.gd`
  wires real textures into `res://terrain_assets.tres`. This is the ONLY
  texture-setup script -- a duplicate (`setup_terrain_textures.gd`, flat
  colors only, no rock texture) existed and was deleted. If you ever see a
  stale reference to it, it's dead history.
- The real texture source files live at `res://textures/source/*_1k.png`
  (ground/road/rock, each albedo + normal). These are REAL downloaded
  ambientCG PBR textures (Ground106, PavingStones055, Rock058), not
  placeholders, despite the generator script producing similarly-named
  placeholder files during early prototyping. **Never run
  `generate_flat_textures.gd` once the real textures are in place** -- it
  overwrites those exact filenames with 8x8 flat-color placeholders and
  there is no automatic undo for that (it's a runtime `Image.save_png()`
  call, not an MCP-tracked file write). If they ever go missing again,
  check `D:\Downloads\Godot_v4.7.2-stable_win64.exe\` on the user's machine
  first -- the original downloaded ambientCG folders
  (`Ground106_1K-PNG`, `PavingStones055_1K-PNG`, `Rock058_1K-PNG`) live
  there alongside the project, outside the repo.
- **Any change to `terrain_assets.tres` must run through the EDITOR
  process, not Play mode.** Play mode (`run_scene`) spawns a separate OS
  process with its own empty ResourceCache; anything it saves to that file
  never reaches the editor's own live copy, which periodically
  re-serializes over it and silently undoes the "fix." Call
  `assign_flat_textures.gd`'s methods (`fix_textures()`, `force_reimport()`,
  `diag_uv_scale()`) via `call_method(runtime:false, scene_path="res://tools/assign_flat_textures.tscn", node_path=".")`
  instead.
- After overwriting a source PNG on disk, call `rescan_filesystem`, wait a
  few seconds, then call `force_reimport()` before `fix_textures()` --
  Godot's ResourceCache doesn't pick up an external file change on its own.
- Terrain3D refuses to render a texture asset that isn't "connected to a
  file" -- setting only `albedo_color` with no real `albedo_texture` shows
  as a checkerboard placeholder, not a flat color. Always use a real
  (even tiny) image file per texture id.

## Adding a new Terrain3D texture id -- import settings must match the existing set exactly

- Adding a new texture id via `assign_flat_textures.gd`'s `fix_textures()`
  (e.g. re-adding Rock as three separate varieties -- RockFace,
  CoastSandRocks, AerialRocks, added 2026-09-16) isn't enough by itself --
  a texture file that's brand new to the project gets Godot's *default*
  import settings, which don't match the existing set's
  (`compress/mode`, `mipmaps/generate`, `compress/channel_pack`).
  Terrain3D requires every texture id's import settings to match id 0's
  exactly to build its shared texture array, and fails LOUD only at
  Play-mode (`run_scene` + `get_errors`), not in `get_resource_info` or any
  editor-side static check: `Terrain3DAssets:_update_texture_files: Texture
  ID <n> albedo format: 4 doesn't match format of first texture: 17` /
  `...mipmap setting (false) doesn't match first texture (true)`, same
  pattern for the normal map.
- Fix: read the reference `.import` files
  (`res://textures/source/ground_albedo_1k.png.import`,
  `ground_normal_1k.png.import`) and match `compress/mode` (2, VRAM
  Compressed, in this project), `mipmaps/generate` (true), and
  `compress/channel_pack` (1 for albedo, 0 for normal -- these two
  legitimately differ between albedo and normal maps, just not within the
  same map type across different texture ids) on the new file's `.import`
  before reimporting. Editing the `.import` file's `[params]` directly is
  fine -- that's exactly what a reimport re-reads.
- As with the `.glb.import`/`root_scale` gotcha further below, editing a
  `.import` file's `[params]` and calling `rescan_filesystem` alone does
  NOT trigger a real reimport -- same staleness class, `rescan_filesystem`
  only reimports when the *source* file's mtime changed. Use
  `assign_flat_textures.gd`'s `force_reimport()` (calls
  `EditorInterface.get_resource_filesystem().reimport_files(...)`) with
  the new paths added to its list, then re-run `fix_textures()` so the
  freshly-reimported textures -- not stale cached ones -- get wired into
  `terrain_assets.tres`.
- New source images for this pipeline commonly arrive as Poly Haven-style
  packs (`<name>_diff_1k.jpg` + `<name>_nor_gl_1k.exr`) rather than
  ambientCG's pre-flattened PNG pairs. The `nor_gl` EXR is typically
  DWAA-compressed (same compression family as the rock/boulder prop gotcha
  below), but that only matters if Godot itself tries to import the raw
  `.exr` -- converting it to an 8-bit RGB PNG yourself first (in the cloud
  sandbox, with the `OpenEXR` Python package: read the EXR's combined
  `"RGB"` channel -- Poly Haven's files store one multi-channel entry
  named `RGB`, not separate `R`/`G`/`B` channels -- clip to [0,1], scale to
  8-bit) before it ever reaches `res://textures/source/` sidesteps the
  DWAA import problem entirely; it never becomes a Godot-side EXR import
  at all.
- Registering a new texture id in `terrain_assets.tres` only makes it a
  *selectable* Terrain3DTextureAsset -- it does NOT paint anywhere on the
  terrain by itself. Painting requires either hand-painting with the
  Terrain3D dock's paint tool, or control-map logic in `terrain_gen.gd`
  (see "What was already tried and reverted" in
  `godot_notes/handoff_terrain_textures.md` for why slope-based
  auto-painting is a known dead end in this project).

## Rock/boulder EXR normal & roughness maps -- DWAA compression fails to import

- The 2K (and, it turns out, the original 1K) `*_nor_gl_*.exr` and
  `*_rough_*.exr` textures for `boulder_01`/`rock_07`/`rock_09`/`stone_01`
  are encoded with `DWAA_COMPRESSION`. Godot's built-in EXR importer cannot
  decode this and silently marks the import `valid=false` in the
  `.import` sidecar -- no visible error until something actually tries to
  load the resource (`_load: Failed loading resource: ...exr`, then a
  cascading `[ext_resource] referenced non-existent resource` on whatever
  `.tres`/`.glb` references it, then `Terrain3DInstancer ... Mesh ID out
  of range` once the failure reaches `terrain_assets.tres`). This is why
  `boulder_01_material.tres` had `normal_enabled = true` but no
  `normal_texture` actually set for most of this project's history -- the
  map never successfully imported, so it was never wired in; it wasn't
  forgotten.
- Fix: re-encode the EXR to `ZIP_COMPRESSION` (same pixel type/channels,
  different container -- Godot decodes ZIP fine). Done via a short Python
  script using the `OpenEXR` package (`pip install --break-system-packages
  OpenEXR`), reading each channel at its native `pixel_type` (HALF for
  these) and writing a new file with
  `Imath.Compression(Imath.Compression.ZIP_COMPRESSION)`. There's no
  one-line Blender-CLI equivalent for this the way
  `bpy.ops.export_scene.gltf` works for GLB exports; re-encoding via
  Python + the `OpenEXR` bindings (in the cloud sandbox, not on the user's
  machine) is the fastest path. (Alternative, used for the terrain splat
  textures added 2026-09-16: skip Godot's EXR importer entirely and
  convert the DWAA EXR straight to a PNG yourself before it ever reaches
  the project -- see the Terrain3D texture-import section above.)
- **Overwriting the source `.exr` on disk and calling `rescan_filesystem`
  is NOT enough to force a reimport of a file that previously failed
  (`valid=false`).** Godot's EditorFileSystem appears to skip retrying a
  file it already has an invalid-import record for, even once the file's
  mtime/size on disk has clearly changed (confirmed: the `.import`
  sidecar's own mtime stayed untouched across a rescan + 5s wait, while
  the source `.exr`'s mtime updated normally). Fix: `delete_file` the
  stale `.import` sidecar outright (`confirm=true, create_backup=false`),
  then `rescan_filesystem` -- with no cached record at all, Godot treats
  it as a brand-new file and imports fresh. Confirmed by the `.import`
  file gaining a real `dest_files=[...].ctex` entry and losing the
  `valid=false` line.
- Also note: a resource load that *succeeds* via `get_resource_info` in
  the editor process is not proof the texture actually decodes -- it can
  return `ok:true` with a plausible `dependencies` list because that read
  is largely parsing the `.tres` text's `[ext_resource]` lines, not
  necessarily deep-loading every dependency. The only trustworthy check is
  a fresh `run_scene` + `get_errors` (a new Play-mode process, per the
  live-vs-disk gotcha below, re-attempts every load from scratch) or
  reading the `.import` file directly for the `valid=false` flag.
- Found on `boulder_01` originally; `rock_07`/`rock_09`/`stone_01` came
  from the same source pipeline, so check any rock/stone asset's
  normal/roughness `.import` file for `valid=false` before assuming its
  normal map is actually working.

## GLB export byproduct textures -- use the real source textures instead

- **UPDATE 2026-09-24:** the four rock glbs (now in `assets/models/rocks/<dir>/`) import
  with `gltf/embedded_image_handling=0` (discard textures), so these extracted files no
  longer exist for them -- the rocks render through their `<dir>_material.tres` override.
  Lesson from the switch: with extraction on (1), the glb *fails to load* if the extracted
  files -- or even only their `.import` sidecars -- are deleted (this silently removed
  boulder collision once). Change the import setting + reimport first, then delete.
- When Blender's glTF exporter writes a `.glb` next to loose companion
  texture files (e.g. `rock_07_2k.glb` alongside `rock_07_2k_rock_07_diff.jpg`,
  `rock_07_2k_rock_07_nor_gl.png`, `rock_07_2k_rock_07_rough.png` -- these
  appear automatically as a byproduct of the export, not something
  separately requested), Godot's glTF importer latches onto those exact
  file paths as texture dependencies for the mesh's own embedded material
  the first time it imports the `.glb`. **Do not `rename_file` those
  companion textures to a tidier location** -- doing so breaks the
  already-generated `.glb` import (`_load: Failed loading resource:
  ...glb`, cascading into whatever `Terrain3DMeshAsset`/`terrain_assets.tres`
  references it, same `Mesh ID out of range` symptom as the DWAA bug
  above) even though nothing about the `.glb` file itself changed. Just
  leave these byproduct files alone entirely -- don't use them for the
  material either (see next bullet).
- **Better fix, found after the fact: don't use the glTF-export byproduct
  textures at all.** They're lossy re-extractions baked out of the
  `.blend` (JPG diffuse, PNG-not-EXR normal/roughness -- lower precision
  than the originals). The *actual* Poly Haven source textures live in a
  sibling `textures/` folder next to each `*_2k.blend` file on the user's
  machine (e.g.
  `D:\...\assets\models\rock_07_2k.blend\textures\rock_07_diff_2k.jpg`
  + `rock_07_nor_gl_2k.exr` + `rock_07_rough_2k.exr`), one level up from
  the Godot project entirely (`D:\...\assets\models\`, NOT
  `herald-of-oblivion\assets\models\`) -- easy to miss. This is the same
  source `boulder_01` originally used. Always `device_list_dir` on
  `assets\models\<name>_2k.blend\` first before falling back to the
  glb-export byproducts -- it's higher quality AND sidesteps the whole
  don't-rename-these-files problem above, since these proper source files
  can be freely copied into the project's own `<asset>/textures/`
  subfolder under clean names with no import-dependency risk (the glTF
  importer never saw them). `stone_01` specifically was missing a
  byproduct 2K diffuse entirely from its glb export -- but the proper
  source `textures/` folder had one all along.
- These proper source EXRs (normal/roughness) are DWAA-compressed same as
  boulder_01's were -- always check/re-encode per the DWAA section above
  before wiring them in. Confirmed again 2026-09-17 on all 5 cliff-scale
  set-dressing models (`mountainside`, `namaqualand_cliff_01/02`,
  `rock_face_01/02` -- see `_dress_cliff_faces` in `terrain_gen.gd`): every
  one of their `_nor_gl_2k.exr`/`_rough_2k.exr` files failed to load at
  runtime with the exact `Failed loading resource: ...exr` symptom until
  re-encoded DWAA->ZIP and their stale `.import` sidecars deleted +
  rescanned, same fix as below.
- A texture file that's brand new to the project (first time Godot has
  ever seen that exact path) can fail to get a `.import` sidecar generated
  at all on the rescan right after it appears -- `_load: No loader found
  for resource: ...png` even though the file is a completely valid,
  uncorrupted PNG/JPG (confirmed: sibling textures in the same batch
  imported fine, only some stragglers got stuck, and repeated
  `rescan_filesystem` calls with 10-15s waits did not self-resolve it).
  This looks like an import-queue race rather than anything about the
  file itself. Fix: `rename_file` the stuck texture to a throwaway name
  and immediately back to its real name (a no-op move that still counts
  as "file changed" to the scanner), then `rescan_filesystem` again --
  this reliably unstuck every file it was tried on, though occasionally
  took two rounds for a given file. Cheap way to check whether it worked
  without a full `run_scene`: `device_list_dir` the folder and look for
  the texture's `.import` sidecar actually existing (not just the texture
  file itself). (The three terrain splat textures added 2026-09-16 did
  NOT hit this -- all six new PNGs got a `.import` sidecar on the very
  first rescan.)
- `stone_01`'s source `textures/` folder also has a `stone_01_mask_2k.png`
  not present for the other three rock assets. Visually it's a baked
  low-poly-faceted grayscale map, darker in crevices/creases -- an
  ambient occlusion map, wired in as `ao_texture` on the material
  (`ao_enabled = true`, `ao_texture_channel = 0`, since it's a
  single-channel-style grayscale PNG read as RGB).

## Freshly exported/imported meshes need collision added explicitly -- and in an optimized way

- **UPDATE 2026-09-24:** rock collision hulls are now built from the same 2k glbs the rocks
  render with (the 1k glbs were deleted), via `create_convex_shape(true, true)` -- simplify
  on, ~32 points per hull, size within ~1-3% of the old 1k hulls. See `ROCK_SCENE_PATHS`.
  Trees: every tree gets a trunk cylinder (see `docs/vegetation.md`).
- A `.glb` imported into Godot (via `export_scene.gltf`/`export_materials="NONE"`,
  same pipeline as `export_cliffs_to_glb.ps1`) brings in visual geometry only --
  **no physics body, no collision shape, ever, regardless of what the source
  `.blend` had.** This is easy to miss because nothing errors: the mesh renders
  fine, looks solid, and the omission only shows up as the player walking straight
  through it. Found (again) 2026-09-17 wiring in the 5 cliff-scale set-dressing
  models (`mountainside`, `namaqualand_cliff_01/02`, `rock_face_01/02`) -- they
  rendered and placed correctly via `_dress_cliff_faces` for a full pass before
  anyone noticed they had zero collision.
- **Don't reach for one collision approach by default -- pick convex vs. concave
  by what the asset actually is, since "optimized" here means both cheap to
  simulate AND actually shaped right, not just "has a CollisionShape3D":**
  - Small, roughly-rounded scatter props (boulders/rocks the player can only ever
    approach from outside) -- **convex hull**, one shape built once per unique
    mesh id and reused across every scattered instance via a shared `Transform3D`
    (see `_scatter_boulders`'s `rock_shapes` dict + `LOD0` mesh sample +
    `create_convex_shape(true, false)`). Cheap to build, cheap to simulate, and a
    convex hull's inherent "fills in every dent" simplification barely reads as
    wrong on something already fist-sized-to-boulder-sized and roughly convex.
  - Large static set-dressing with real concavities/overhangs the player can walk
    up to, under, or around (cliff faces, arches, anything where a filled-in dent
    would be walked-into or stood-on wrong) -- **concave trimesh**
    (`Mesh.create_trimesh_shape()`), one per `MeshInstance3D` actually present in
    the scene (a multi-mesh GLB like `mountainside`, 5 separate mesh nodes, needs
    one trimesh per node, not one for the whole scene) -- see
    `_add_cliff_collision_recursive` in `terrain_gen.gd`. Costs more to build than
    a hull and can't be shared across instances with different geometry the way
    boulders' repeated mesh ids can, but for a handful of large, always-static
    (`StaticBody3D`, never `RigidBody3D`) world features this is cheap enough --
    the "optimized" concern here is picking the RIGHT shape for a static mesh at
    all, not micro-optimizing shape build cost for a one-digit instance count.
  - Never use a trimesh shape on anything that moves (`RigidBody3D`/
    `CharacterBody3D`) -- Godot's physics engines don't support concave collision
    on non-static bodies. This has never come up for these particular props (all
    static world dressing) but is the actual reason "just always use trimesh, it's
    more accurate" isn't the right default either.
  - Building the collider as a CHILD of the same `MeshInstance3D` its shape came
    from (rather than computing the placed instance's world transform by hand) is
    what makes this correct for free under scale/rotation jitter -- the collider
    inherits its parent's part of the transform stack automatically. This is why
    `_add_cliff_collision_recursive` runs BEFORE/independent of exactly how deep
    the placed instance sits in the scene tree; it never needs to know.

## Rock/boulder mesh scale -- baked into .glb.import root_scale, lost on any GLB swap

- **UPDATE 2026-09-24:** only the 2k glbs remain (1k deleted), under
  `assets/models/rocks/<dir>/`; the rock setup tool is now `tools/setup_rock_assets.gd`
  (Boulder01 merged in as id 1). The root_scale warning below still applies to any new or
  swapped glb. Step-by-step: `docs/adding_models.md`.
- `boulder_01`/`rock_07`/`rock_09`/`stone_01` were modeled at wildly
  different real-world scales in their source .blend files (Poly Haven
  assets aren't normalized to each other). The fix has never been a
  per-instance scatter multiplier -- it's baked directly into each
  `.glb.import`'s `nodes/root_scale` param (with `nodes/apply_root_scale
  =true`), so the imported mesh geometry itself comes out close to
  `boulder_01`'s ~1.83-unit longest-axis AABB (each rock's own longest
  axis lands close to 1.0, deliberately a bit smaller so Boulder01 still
  reads as the standout large rock). See `ROCK_BASE_SCALE` in
  `terrain_gen.gd` (deliberately left at 1.0 for every id -- the
  normalization happens at import time, not scatter time; applying it in
  both places double-scales).
- **Swapping in a new `.glb` file (e.g. `rock_07_1k.glb` -> `rock_07_2k.glb`)
  gets a completely fresh `.import` sidecar with `root_scale` back at the
  default `1.0`.** This is NOT preserved from the old file's import
  settings. Symptom: everything loads/renders fine (no errors), the
  scene just looks wrong -- rocks suddenly tiny next to Boulder01 again,
  exactly the original "very very tiny" bug this was fixed for once
  already. Nothing in `get_errors` flags this since it's not a load
  failure. Always re-check mesh AABB sizes after any GLB swap for these
  four assets (`debug_print_mesh_sizes()` in `setup_rock_assets.gd`,
  updated to point at whichever `.glb` filenames are current -- **use
  `ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)`, not
  plain `load()`**, or a rock loaded once earlier in the same editor
  session will keep returning its stale cached AABB even after you fix
  and reimport its `.glb.import`).
- Correction to the GLB-export-byproduct section above: those loose
  `<name>_2k_<name>_diff.jpg` / `_nor_gl.png` / `_rough.png` files
  appearing next to a `.glb` are NOT a Blender export artifact -- they're
  Godot's OWN glTF importer extracting the embedded textures to loose
  files on disk, because this project's scene-import default is
  `gltf/embedded_image_handling=1` (Extract). Confirmed by watching a
  `rename_file` touch (old name -> temp name -> back) regenerate a fresh
  set of these files under whatever name the `.glb` currently has, with
  no Blender involved at any point in that cycle.
- **Editing a `.glb.import`'s params directly (e.g. `root_scale`) and
  calling `rescan_filesystem` does NOT trigger a reimport** -- same class
  of staleness as the DWAA/PNG `.import`-doesn't-self-heal issues above.
  `rescan_filesystem`'s scan only reimports when the *source* file's
  mtime changed, not when only the sidecar params changed. The correct
  fix is `EditorInterface.get_resource_filesystem().reimport_files
  (PackedStringArray([...]))`, called from an @tool script method via
  `call_method(runtime:false)` -- see `force_reimport_rocks()` in
  `setup_rock_assets.gd` for a working example (mirrors
  `assign_flat_textures.gd`'s `force_reimport()` for textures, just for
  scenes instead).
- **Do NOT use the rename-to-temp-name-and-back "touch" trick on a `.glb`
  file to force a stuck/stale import, especially not repeatedly.** It
  works (confirmed: forces a genuinely fresh import when a `.glb.import`
  is completely missing, e.g. after an interrupted operation), but doing
  it more than once in quick succession on this project has twice
  coincided with the entire Godot MCP connection dropping
  (`get_godot_status` -> `connected:false`, requiring the user to check
  whether the editor process itself is still alive). Each rename-touch
  also leaves a fresh set of the embedded-image-extraction byproduct
  files (previous bullet) under the new/reverted name that need manual
  `delete_file` cleanup afterward -- it's not a clean no-op the way it is
  for a plain texture file. Prefer `reimport_files()` (previous bullet)
  whenever the `.import` sidecar already exists; reserve the rename-touch
  trick for the narrower case where the `.import` is missing entirely,
  do it once, wait, and confirm via `device_list_dir` before considering
  a second attempt.

## Church model textures are oversized for a background prop -- real load-time cost, not yet fixed

- Found 2026-09-16 while investigating why the gap between the Godot boot
  splash and a playable level was ~4s even after `terrain_gen.gd`'s own
  runtime generation was optimized down to ~1.8s (see that script's
  per-stage timing prints, and the `_ready()`-start timestamp print at the
  top of `WorldGenerator._ready()`). Splitting the timeline showed ~2.48s
  happens BEFORE `WorldGenerator._ready()` even starts -- i.e. it's not
  reachable by optimizing generation code at all, it's engine boot +
  loading everything else `main.tscn` references first (`Terrain3D`'s
  subtree, including its ~56 `MultiMeshInstance3D` grass/foliage instancer
  children, comes before `WorldGenerator` as a sibling and must finish
  first; `terrain_assets.tres`; the `Church` GLB).
- The likely dominant piece of that 2.48s: `res://assets/models/castle-
  church/source/Untitled.glb` is **90.8 MB** on disk, and several of its
  33 dependent textures are needlessly high-resolution for a background
  building viewed at normal play distance -- confirmed via
  `get_resource_info`: `walls_Mat_albedo`, `roof_Mat_albedo`,
  `plaster_Mat_albedo`, and `roof_parts_Mat_albedo` are all **4096x4096**,
  with `bricks_Mat_albedo`/`bricks_old_Mat_albedo`/`stained_Mat_albedo` at
  2048x2048. Normal/roughness maps typically match their albedo's
  resolution per material, so the real total is likely 25-30 textures in
  the 2K-4K range, not just the handful of albedo maps sampled. For
  comparison, the terrain's OWN ground/road/rock textures (covering the
  entire playable map, see "Terrain3D texture pipeline" above) are
  deliberately kept at 1K -- this one background prop is carrying up to
  16x the pixel count per texture of everything covering the whole world.
- Checked one `.import` sidecar (`..._walls_Mat_albedo.jpg.import`):
  `process/size_limit=0` (no cap), `mipmaps/generate=true`,
  `compress/mode=2` (VRAM compressed). Nothing is limiting these --
  Godot decodes, VRAM-compresses, and mipmaps every one of them at full
  native resolution, every project (re)import.
- **Not yet fixed -- deliberately left alone per user decision (2026-09-16),
  noted here so it isn't rediscovered/re-investigated from scratch.** The
  planned fix, when/if revisited: set `process/size_limit` (e.g. to 1024,
  or 2048 for anything the player can walk right up to, like `doors`) in
  the `.import` sidecar for each oversized church texture, then trigger a
  reimport (`EditorInterface.get_resource_filesystem().reimport_files
  (...)`, same mechanism as the rock/GLB reimport notes below -- called
  from an editor-mode `call_method`, NOT a `rescan_filesystem` alone,
  which does not pick up sidecar-only param changes). This is fully
  reversible and touches no source asset -- it only caps what Godot
  decodes/uploads at import time. Re-measure with the same `_ready()`-
  start timestamp print afterward to confirm the actual savings before
  assuming it worked.

## Road parallax -- TRIED AND REVERTED (2026-09-16), don't redo this blindly

- The road texture reads flat up close. Tried fixing it with a custom
  Terrain3DMaterial `shader_override` adding a cheap single-sample
  parallax UV offset (push `id_uv` toward the camera, scaled by a
  luminance-derived height map, gated to the Road texture ID only). Fully
  implemented, wired into `main.tscn`, and reverted again in the same
  session after hands-on testing showed it doesn't work well here -- both
  problems below are FUNDAMENTAL to this approach on Terrain3D's pipeline,
  not tuning mistakes:
  1. **Blurry up close.** `textureGrad`'s mip/anisotropy selection used
     the PRE-offset derivatives (`id_dd`), which don't match the true
     rate of change of the POST-offset `id_uv`. Near the camera the
     offset changes quickly per-pixel, so the GPU picks a far blurrier
     mip than the actual surface detail warrants. Fixing this properly
     needs real derivatives of the offset UV itself (e.g.
     `dFdxCoarse(id_uv)`/`dFdyCoarse(id_uv)` computed after the offset),
     which is more invasive shader work layered on top of Terrain3D's
     already-complex per-cell control-map rotation/detiling math.
  2. **Still looks flat from a normal (grazing/side) viewing angle.** A
     single-sample UV offset only changes WHICH TEXEL gets sampled -- it
     never perturbs the surface normal, so lighting never responds to the
     fake height. Perceived "raised stone" depth comes from shading, not
     just color repositioning; without a normal perturbation to match,
     there's no shading cue at all from typical FPS eye-height angles.
  3. Also hit and partially fixed along the way: offsetting by a
     ground-projected "direction to camera" creates a singularity
     directly below the camera (that direction spins through a full
     circle within a couple of screen pixels there), which aliased into
     a visible radiating starburst pattern when looking straight down.
     Fading the offset magnitude to zero near that point (dividing by
     `view_len + fade_radius` instead of normalizing to a constant unit
     vector) fixed the starburst specifically, but didn't touch problems
     1-2 above, which is why this was still reverted.
- **Root cause, and the actual fix if this gets revisited:** Terrain3D's
  own maintainers hit the same wall -- issue #175 requested real parallax
  occlusion mapping, and the PR that addressed it (#747, merged Dec 2025)
  deliberately did NOT use a fragment-shader trick; it added per-texture
  VERTEX DISPLACEMENT with mesh tessellation (real geometry, not sampled
  illusion) specifically because POM-style tricks are awkward on a flat
  clipmap mesh with per-cell UV rotation. That feature is not in our
  installed addon (`res://addons/terrain_3d/plugin.cfg` version 1.0.2,
  May 2025, predates the Dec 2025 merge) -- getting it means building the
  addon (a C++ GDExtension) from source against current `main`, a real
  undertaking with unverified compatibility against Godot 4.7.2. That is
  the path worth taking if road depth matters enough to revisit; another
  fragment-shader attempt without solving problems 1-2 above will just
  reproduce the same result.
- Everything from this attempt was cleanly reverted: `main.tscn`'s
  Terrain3DMaterial is back to stock (no `shader_override`), `res://
  shaders/terrain3d_road_parallax.gdshader` and `res://textures/source/
  road_height_1k.png` were deleted, and `terrain_gen.gd` has no leftover
  `set_shader_param` calls or `ROAD_PARALLAX_SCALE` constant. The LOD-
  range and detiling-strength fixes from the same session (see terrain_
  assets.tres) are unrelated and were NOT reverted -- those addressed a
  different, confirmed-working fix.

### Second attempt -- real displaced-geometry road mesh -- ALSO TRIED AND REVERTED (2026-09-16)

- Since a fragment-shader trick can't work here (see problems 1-2 above),
  tried the "actual fix" path at a much smaller scale than building
  Terrain3D's own GDExtension from source: a dedicated `MeshInstance3D`
  ribbon (`_build_road_mesh` in `terrain_gen.gd`) built by walking the
  same Catmull-Rom-smoothed road centerline `_generate_road()` already
  computes, sampling terrain height with the existing
  `_sample_height_bilinear`, adding small FastNoiseLite-driven bump
  displacement per vertex, and recomputing real per-vertex normals +
  tangents (`SurfaceTool.generate_tangents()` was required -- without it,
  the road_normal_1k normal map lit with garbage tangent-space basis and
  produced harsh black/white blotches on its own). This actually worked
  correctly as geometry: right shape, right position (verified via
  `query_runtime_node` against the live `/root/Main/RoadMesh` node),
  correct winding/normals, no shader bugs.
- Reverted anyway because the RESULT looked bad regardless of sun angle,
  per direct hands-on testing/screenshots -- not a bug, a look the user
  rejected outright ("revert the parallax stuff, it looks awful no matter
  the sun position"). What made it look bad: small per-vertex bump
  displacement (~0.06 world units) combines with a low/grazing directional
  light to cast disproportionately long, hard-edged self-shadows across
  the ribbon -- large solid black patches next to lit patches, not a
  subtle cobblestone look. This is a real, physically-correct consequence
  of adding fine geometric relief under a strong low-angle directional
  light, not something a UV/material tweak fixes; it would need either a
  much softer/shallower bump profile, disabling shadow-casting on the
  mesh (loses the self-shadowed depth cue that was the whole point), or
  moving away from a single hard directional light for this surface.
  Given the user rejected the look outright rather than asking for a
  tuning pass, don't re-attempt this same displaced-ribbon-with-bump-noise
  shape without first addressing the shadow-harshness problem specifically.
- Also found and fixed in passing: `main.tscn` still had a stale
  `ext_resource` (id `9_roadpx`) pointing at the already-deleted
  `terrain3d_road_parallax.gdshader` from the FIRST attempt above, plus a
  leftover `shader_override`/`shader_override_enabled` and three
  `road_*` keys in the `Terrain3DMaterial`'s `_shader_parameters` dict --
  the first attempt's revert had NOT actually fully landed in the saved
  file. This caused a hard crash on scene launch (`resource_format_text.
  cpp: Method/function failed`, surfaced in-editor as a blocking "Cannot
  load shader" dialog) that looked unrelated to road work at first. If a
  road-depth attempt is reverted again in the future, explicitly re-read
  `main.tscn`'s `Terrain3DMaterial` sub_resource afterward and confirm
  it's back to exactly the stock 16-key `_shader_parameters` dict with no
  `shader_override` -- don't just trust an earlier revert claim.
- Everything from this second attempt was cleanly reverted:
  `_build_road_mesh`, `_resample_path`, the `ROAD_MESH_*`/
  `ROAD_BUMP_*`/`ROAD_TEXTURE_TILE_LENGTH` constants, and the
  `_build_road_mesh(...)` call in `_ready()` were all removed from
  `terrain_gen.gd`; the `"path"`/`"road_path"` plumbing added to
  `_generate_road()`'s and `_build_heightmap()`'s return dicts was
  reverted too, since nothing else consumes it.

## Compositor Effects addon -- must live under res://addons/

- The downloaded compositor_effects asset pack (32 post-processing effects
  under `res://compositor_effects/<name>/`, e.g. crt_monitor, glare,
  chromatic_aberration, vignette, unreal_bloom, etc.) ships with every
  `post_process_<name>.gd` script hardcoding its shader load path as
  `res://addons/compositor_effects/<name>/<name>.glsl` -- i.e. it expects
  to be installed as an addon, NOT dropped at the project root. If it's
  placed at `res://compositor_effects/` directly, every effect throws
  "Resource file not found" for its `.glsl` at runtime even though the
  `.gd` scripts themselves load fine (their own path, wherever it is, is
  found by the scene; it's the *shader* load inside the script that fails).
- Fix: move only the `.glsl` files (not the `.gd` scripts, not `.import`
  sidecars -- see below) from `res://compositor_effects/<name>/<name>.glsl`
  to `res://addons/compositor_effects/<name>/<name>.glsl`, one per effect.
  `unreal_bloom` is a special case with 4 glsl files (bloom_extract/down/up/apply)
  instead of one. There's also a shared `res://compositor_effects/shared/copy.glsl`
  used by ~20 effects -- move that one too.
  Leave the `.gd` scripts and the `.tres` resource that references them
  (e.g. `res://assets/compositor.tres`) exactly where they are -- moving
  the whole tree isn't necessary and would just require re-fixing every
  ext_resource path.
- `.glsl.import` sidecar files do NOT need to be moved manually -- attempting
  to `rename_file` one right after moving its `.glsl` fails with "File not
  found," because the editor already reconciled/regenerated it on its own.
  Don't waste calls trying to move these.
- After moving files, `rescan_filesystem` + a `run_scene`/`get_errors` check
  is enough to confirm the fix -- no manual re-attach needed in the
  WorldEnvironment's Compositor Effects list.
- **`write_file`-ing over `res://assets/compositor.tres` while `main.tscn`
  is open in the editor does NOT reliably reach the live, already-running
  scene.** `write_file` reports `cache_evicted: true`, but that only evicts
  ResourceLoader's cache for *future* `load()` calls -- it does not force
  the WorldEnvironment node's already-in-memory `compositor` resource
  reference (held by the currently open scene tab) to swap to the new
  content. Symptom actually observed: the Inspector checkbox for an effect
  (e.g. Painterly's `enabled`) shows one value (freshly read from disk),
  but Play mode launches using a different, stale in-memory value; toggling
  the checkbox once appears to do nothing (because the live instance
  already matched the "new" value you just clicked to), and only the next
  toggle visibly takes effect. There's also a real risk the editor's
  in-memory copy re-serializes over a fresh `write_file` on some later
  autosave/focus-change event, silently reverting it -- same class of bug
  as the `terrain_assets.tres` issue above, just discovered later. Fix /
  going forward: after any `write_file` to `compositor.tres` (or any
  external `.tres` a currently-open scene references), close and reopen
  the scene tab (or restart the editor) before trusting any Inspector or
  Play-mode read of it. Better yet, once a scene is open and being
  actively tuned live, prefer telling the user the exact values to type
  into the Inspector themselves rather than overwriting the file out from
  under the open editor -- that's the only way to guarantee there's a
  single live copy of the truth during an interactive tuning session.

## Painterly (Kuwahara) compositor effect -- performance notes

- Cost is dominated by `stroke_radius` (a `(2*radius+1)^2` full-resolution
  sample loop per pixel -- radius 4 = 81 taps/pixel), NOT by `bin_count`.
  `bin_count` only changes how the sampled colors get bucketed into a
  histogram afterward, a cheap fixed-size step regardless of whether it's
  2 or 32 bins. Turning `bin_count` down without also turning down
  `stroke_radius` buys essentially nothing.
- A shader-level internal-downsampling rewrite (shrink to a lower-res
  buffer, run Kuwahara there, bilinear-upscale back) was tried and
  reverted: at already-low `stroke_radius`, the extra downsample/upsample
  passes cost more than they saved (net *slower*), and independent of
  performance, the bilinear upscale of an already-flattened/painterly
  image visibly softened the result further -- compounded by Radial Blur
  and Gaussian Blur running right after Painterly in the effect chain.
  Not worth revisiting for this effect.
- The `PostProcessGlare` effect (not Painterly) turned out to be the
  single biggest GPU cost in this project's 6-effect compositor stack --
  toggling it alone swung GPU utilization by ~40 percentage points, far
  more than Painterly ever did. Its shader loops `ray_axes * samples_per_arm`
  times per pixel (default 2 * 32 = 64 iterations), each iteration doing 6
  bilinear texture samples (~24 texel reads) for forward/backward
  chromatic-shift sampling -- roughly 1,536 texture fetches per pixel,
  independent of `glare_size` (which only changes sample spacing, not
  sample count). `samples_per_arm` (export range 4-128, default 32) is the
  real lever; dropping it to 8 cut the cost dramatically with an
  acceptable visual trade-off for this project.
- GPU utilization/temperature are not observable via any Godot MCP tool --
  only the user's own system monitor (Task Manager, MSI Afterburner, etc.)
  can report them. When comparing readings across tests, window
  size/resolution must be held constant -- a small windowed Play session
  renders far fewer pixels than fullscreen, and since every compositor
  effect's cost scales with pixel count, this alone can swing readings by
  many multiples and easily gets mistaken for a real regression/fix.
- A SAT (summed-area-table) accelerated classic Kuwahara variant exists as
  a separate, non-destructive addition under
  `res://addons/compositor_effects/painterly_sat/` (does not replace or
  modify the original histogram-bin Painterly effect) -- its cost is
  roughly independent of `stroke_radius`, unlike the original.

## Color grading / AgX tonemap

- `WorldEnvironment.environment.adjustment_color_correction` is a
  `GradientTexture1D` used as a luminance-remapping LUT (dark pixels sample
  the gradient's low-offset colors, bright pixels sample the high-offset
  colors) on top of AgX tonemapping. Two tuned variants exist as
  standalone, swappable files under `res://assets/color_grades/`:
  `grade_nighttime_brown_sage.tres` (warm brown shadows -> pale sage-green
  highlights, the original look carried over from the `d-fantasy`
  reference project) and `grade_daytime_sage_amber.tres` (cool sage/
  blue-violet shadows -> warm amber highlights, matching the general
  color/lighting guide at
  `godot_notes/color_lighting_for_painterly_postprocess.md`). Swap between
  them by repointing `main.tscn`'s `adjustment_color_correction` at the
  desired file -- currently set to the nighttime one (user's choice, since
  the daytime version read as too bright/daytime rather than dark-fantasy
  nighttime). Whichever is live, make sure the gradient has a stop above
  ~0.7-0.8 that keeps trending toward its "bright" hue -- a LUT with no
  stop near the top clamps everything brighter than the last stop to one
  flat color, which mutes intentional bright/saturated accents (torches,
  glowing windows) regardless of their actual source color.

## Terrain3D multi-region import placement -- `import_images()`'s position is NOT a symmetric center

- Discovered 2026-09-16 while making terrain size (`AREA_LENGTH`/`AREA_WIDTH`
  in `terrain_gen.gd`) safely tunable: the assumption that
  `Terrain3DData.import_images(images, import_position, ...)` centers the
  imported heightmap on `import_position` -- i.e. that the map's world-space
  corner is `import_position - Vector3(width/2, 0, length/2)` -- is only
  ever true by coincidence, for the original single-region case where the
  whole heightmap fit inside one `REGION_SIZE` (256) tile.
- Once either axis of the imported image spans more than one region tile
  (e.g. `AREA_LENGTH = 512` with the default `REGION_SIZE = 256`), Terrain3D
  does NOT expand symmetrically around `import_position`. It anchors each
  axis independently via `floor(import_position_component / region_size)`
  and then allocates `ceil(image_size / region_size)` region tiles extending
  in the **positive** direction only from that anchor. The result is that
  the true placed corner silently diverges from the
  `import_position - half_extents` formula as soon as more than one region
  is needed on an axis, with no error or warning anywhere -- it just looks
  like the terrain (and anything positioned relative to it, e.g. the player
  spawn point) is offset or generated "backwards."
- Fix/pattern: never compute the heightmap's world-space corner analytically
  before import. Instead, after calling `import_images(...)`, read back
  Terrain3D's own bookkeeping: `terrain.get_region_size()` and
  `data.get_region_locations()` (an `Array` of region-grid `Vector2i`-like
  coords). The true corner is
  `Vector3(min_region_x * region_size, 0, min_region_z * region_size)`,
  where `min_region_x`/`min_region_z` are the minimums over all returned
  region locations. This is correct for any width/length/region-count
  combination going forward, since it reads what Terrain3D actually did
  rather than predicting it.
- Corollary: if a generator function (like `_generate_road`'s road-path
  endpoints) needs to hand off a world-space position that depends on the
  heightmap corner, prefer returning it in **pixel/local heightmap space**
  and doing the pixel-to-world conversion in `_ready()` *after* the import
  call, once the real corner is known -- rather than pre-baking world-space
  coordinates during heightmap generation (before import has even
  happened), which bakes in the wrong corner the moment more than one
  region is involved.

## Non-destructive per-mesh material tinting (Church node pattern)

- To adjust color/value on an *imported* multi-material mesh (e.g. the
  `castle-church` GLB, 12 child `MeshInstance3D`s each with their own baked
  PBR material) without ever touching the source `.glb` or its textures,
  do NOT try to set `material_override` via the `set_material` MCP tool on
  an internal child of an *instanced* scene -- see the dedicated gotcha
  below, it doesn't persist. Instead, attach a small script to the
  instance's root node (e.g. `res://scripts/church_material_tint.gd` on
  `Church`) that, in `_ready()`, walks the children, calls
  `get_active_material(surface)` to get whatever material is actually in
  effect, `.duplicate()`s it (preserves the baked albedo/roughness/normal
  textures since duplicate keeps texture references, just makes the
  material object itself unique), multiplies `albedo_color` by a per-name
  tint `Color`, and applies it via `set_surface_override_material()`. This
  is fully non-destructive (source files untouched), avoids the
  live/disk-desync issues below entirely (pure runtime code, no scene-file
  property system involved), and is easy to retune (edit the `Color`
  multipliers, re-run) or fully undo (detach the script).

## General Godot MCP gotchas

- `list_dir`'s directory parameter is named `root`, not `path`. (An earlier
  version of this note blamed `list_dir` itself as "unreliable" for
  returning the project ROOT regardless of input -- that was almost
  certainly this exact mistake, calling it with `path` instead of `root`,
  which the tool silently ignores and falls back to its default. Trust
  `list_dir` when called with the correct `root` param.)
- `rename_file` only operates on a single file, never a whole directory --
  passing a folder path fails with "File not found" even though the folder
  exists. Move files one at a time. It DOES auto-create any missing parent
  directories on the destination side, so moving into a brand-new nested
  path (e.g. `res://addons/compositor_effects/<name>/...`) works without a
  separate `create_folder` step.
- `batch_execute` has failed unpredictably for runtime `call_method`
  sub-calls (spurious "Node not found") even when the identical individual
  call succeeds immediately before/after. Prefer individual `call_method`
  calls (batched across one multi-tool-use message) over `batch_execute`
  for runtime calls.
- The Godot editor's live scene state and a `run_scene` Play-mode instance
  are genuinely separate processes. Anything that must persist into the
  editor's own view (resource files the editor holds open, like
  `terrain_assets.tres`) needs an editor-mode (`runtime:false`) call, not
  a Play-mode one. Anything that's pure file I/O (writing new files,
  reading/generating data) is safe either way.
- Writing directly to an external `.tres` resource file that a currently
  open scene references (e.g. `compositor.tres` while `main.tscn` is open)
  has the same class of live-vs-disk desync risk as the Play-mode-process
  issue above, even though it's a same-process editor operation -- see the
  dedicated note under "Compositor Effects addon" above.
- **`set_material` does NOT reliably persist when targeting an internal
  child node of an *instanced* scene** (e.g. `Church/roof_Mesh_roof_Mat_0`,
  where `Church` is an instance of `castle-church/.../Untitled.glb`). The
  tool reports `ok: true` and the change is visible in that moment, but it
  only mutates the live in-editor node -- nothing gets written to
  `main.tscn`, and the override is silently discarded the next time the
  scene runs/stops or reloads. Confirmed by re-reading the node's
  properties immediately after (`material_override` still `null`) and by
  the fact `set_resource_property` -- which DOES explicitly save --
  errors with "Resource at 'material_override' is null" right after
  `set_material` claimed success. Root cause is presumably the same family
  as the other live-vs-disk issues in this file, just surfacing on an
  instanced-scene child instead of an open scene tab. Workaround that
  sidesteps the whole problem: don't try to persist a per-child material
  override through the scene-file property system at all -- use the
  runtime-script tinting pattern documented above instead (attach a script
  to the instance root, apply overrides in `_ready()`).
- `res://addons/godot_mcp/cache/undo/` holds full-content backups of every
  file the MCP tools have overwritten, and it lives under `res://`, so
  Godot's filesystem scanner picks up old copies of any `class_name`-bearing
  script in there as duplicate global classes ("Class X hides a global
  script class"). Fixed by adding a `.gdignore` file directly inside
  `res://addons/godot_mcp/cache/` -- do this once per project if it
  recurs after a fresh checkout/clone.
- User preference: do not call `take_screenshot` -- screenshots are
  user-provided only. Verify changes via console logs, diagnostic stats
  (e.g. `_print_roughness_stats`), and raycasts (`get_intersection`)
  instead.

## Cliff/outcrop collision -- current runtime setup, and a deferred alternative (2026-09-21)

- Current setup: `_add_cliff_collision_recursive` in `terrain_gen.gd`, used by BOTH cliff
  dressing and the rock outcrops. The cliff GLBs ship their own LOD chain as sibling
  `MeshInstance3D`s (`<name>_LOD0` .. `_LOD3`, each ~half the triangles of the previous).
  Collision is built for ONE level per chain only (`CLIFF_COLLISION_LOD`, default 2, used
  as-is -- it's already the artist's low-poly version). Non-LOD pieces (`_FILL`/`_PATCH`
  repair surfaces) still get their own collider, run through a runtime simplifier
  (`_build_simplified_cliff_trimesh`, `CLIFF_COLLISION_TARGET_RATIO`).
- Shapes are cached in memory per `Mesh` resource and on disk in
  `user://cliff_collision_cache/`, keyed by source GLB path + that GLB's mtime +
  `CLIFF_COLLISION_BAKE_VERSION`. Re-exporting a GLB rebakes automatically; bump the
  version constant after changing the bake logic, or old shapes get reused.
- Why: collision used to be built for EVERY LOD -- four stacked, slightly different rock
  surfaces per piece. That cost ~0.5s of physics setup on the first frame and snagged the
  player between disagreeing layers (`STUCK` logs hitting `_LOD1/_LOD2/_LOD3` colliders).
  This supersedes the "one trimesh per MeshInstance3D" wording in the collision section above.
- Result of the 2026-09-21 startup pass as a whole: F6-to-playable went from ~14-15s to ~6.5s.
- **Deferred alternative -- user decided NOT now, revisit only if asked:** generate the
  collision at IMPORT time instead of at runtime. In each cliff GLB's Advanced Import
  dialog, select the `_LOD2` mesh and enable Physics > Generate with a Trimesh shape.
  - Pros: the disk cache, LOD-picking and simplifier code could all be removed; shapes ship
    inside exported builds (a fresh install currently bakes them on its first launch);
    collision becomes visible/tweakable in the editor.
  - Cons: manual per GLB, and must be redone for every new or renamed cliff model (import
    settings are keyed by node name). The speed gain is small now: cached shapes already
    load in ~0.03s, and the physics engine's registration cost happens either way.
  - If revisited: set up ONE GLB first, verify in a run, then do the rest, then strip the
    runtime collision code for those models.
