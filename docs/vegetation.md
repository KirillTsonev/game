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
  and registers the Terrain3D mesh asset. With a baked impostor (always, since 2026-09-25):
  LOD0 = full tree to 150 m, LOD1 = impostor to 100 km (never culled), 10 m cross-fade,
  `last_shadow_lod = 0`. Without one it falls back to a single LOD visible to
  `PACK_LOD0_RANGE` = 600 m.
- **Far impostors** (2026-09-25). Measured before: trees beyond 150 m cost ~10 M tris, ~3.3k
  draw calls, ~3.9 ms GPU + ~3 ms CPU of a 10.9 ms GPU frame. After, same kind of view:
  7.0 ms GPU, 10.9 M tris (was 21.4 M), 4.5k draws (was 7.2k), and the forest now reaches the
  map edge instead of ending at 600 m.
  - `bake_tree_impostors()` renders each baked tree unlit (bark = UNSHADED copy of its
    material, leaves = `foliage_impostor_capture.gdshader` with the vertex tint) from 4 angles
    (0/45/90/135 deg) with an orthographic camera in an editor SubViewport, at 4x supersampling
    box-averaged down, so thin needles become partial alpha instead of aliasing away. Alpha =
    coverage x 2 (`TREE_IMPOSTOR_ALPHA_GAIN`), so 25 % leaf cover survives the 0.5 cutout.
    Empty pixels get the mean leaf colour (no dark mip fringes). Output per tree:
    `trees/<name>_impostor.png` (256 px tall per view, width from crown/height), `.res`
    (4 vertical planes through the trunk = 8 tris), `_impostor_material.tres`.
  - Material: `foliage_impostor.gdshader` with **baked normals** (`use_normal_tex`,
    `<name>_impostor_normal.png`, lossless + mips). The bake renders a second pass per view that
    writes the object-space normal (back faces flipped, as when the real tree is lit). The shader
    rotates it by the instance transform (`MODELVIEW_MATRIX` in `vertex()`), so each impostor
    pixel is lit like the real crown for any sun direction. History: pure UP normals (what the
    understory impostors use) glowed lime/orange next to dark real crowns; a camera tilt
    (`view_normal_mix`) only helped looking into the light, and the user still saw a very
    noticeable switch. Bake self-check: raw |n| = 1.000 (the sRGB round-trip is exact) and
    n . camera 0.5-0.66 (the flip works). Understory impostors are unchanged (flag off).
  - Matching at the switch (user before/after screenshots, 2026-09-25): mean brightness already
    matched (moon behind 69 vs 67), but the impostors were more saturated (0.66 vs 0.58) and
    fuller. Fix: `saturation` uniform (trees 0.9, `TREE_IMPOSTOR_SATURATION`) and
    `TREE_IMPOSTOR_ALPHA_GAIN` 2.0 -> 1.4. The gain is now a shader uniform (`alpha_gain`); the
    atlas stores true coverage (`TREE_IMPOSTOR_BAKE_GAIN` = 1).
  - **Cross-fade band, as Godot really draws it:** Terrain3D sets real tree end 160 / impostor
    begin 140, both margin 10, and Godot fades symmetrically around each limit
    (renderer_scene_cull.cpp: limit +/- margin). So the impostor fades in over 130-150 m and the
    real tree fades out over 150-170 m, with both fully drawn at 150. Distances are radial to
    each batch's AABB centre.
  - **Distance fullness:** `alpha_gain` applies at 130 m and `alpha_gain_far` at 170 m and
    beyond, smooth in between. Coarser mips thin the impostor with distance, so one gain can't fit
    both ends. The understory keeps `alpha_gain_far = -1` (off).
  - **Dry trees** (ids 14, 16, 17, 19, 22, 24, 26: sparse brown twig cards, no leaves): the shared
    gains turned their twigs into solid brown canopies, so they get their own near/far pair
    (`TREE_IMPOSTOR_DRY_ALPHA_GAIN` / `_FAR`, materials tagged meta `impostor_group = "dry"`).
  - User-tuned values (2026-09-25, final): green trees saturation 1.00, near 0.30, far 2.20,
    brightness 0.80; dry trees near 0.15, far 1.05.
  - Tuned with temporary PerfDebug live keys and a one-of-each tree row with LOD lines (all
    removed 2026-09-25). To retune, edit the TREE_IMPOSTOR_* constants and rerun
    `tree_impostor_import()`; no rebake is needed.
    edit all tree impostor materials in-game, with an on-screen readout. Nothing is saved: copy
    the values into `TREE_IMPOSTOR_SATURATION` / `_ALPHA_GAIN` / `_TINT` and rerun
    `tree_impostor_import()` + `build_pack_trees()` (no rebake needed).
  - Back-side flip (shader): each plane shows the same image from both sides, but its normals
    face the bake camera. Seen from behind, the impostor went black with the sun behind the
    player while the real crown was lit green. The shader now mirrors the normal through the
    plane when viewed from its back (`normal_views` must equal `TREE_IMPOSTOR_VIEWS`), like
    Godot's side check does for real double-sided leaves.
  - The impostor casts no shadow. Sun shadows end at 150 m anyway (docs/shadows.md).
  - Pipeline: `bake_tree_impostors()` -> rescan -> `tree_impostor_import()` (VRAM + mips,
    materials) -> `build_pack_trees()`. Rerun all of it after changing a tree mesh.
  - Gotchas: `lod1_range = 0` ("unlimited") makes Terrain3D clamp `fade_margin` to 0, hence
    the 100 km range. After editing the shader, `tree_impostor_import()` loads it with
    CACHE_MODE_REPLACE, because the editor's stale copy silently drops parameters for new
    uniforms. PackPineB2 and PackDecidB are sparse brown (dead-looking) trees; that is their
    real vertex tint, not a bake fault.
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
- **Material (since 2026-09-25):** leaf/branch cards are baked onto the foliage cutout shader
  (`shaders/foliage/`, via `_foliage_leaf_material()`), not StandardMaterial3D -- so canopy
  shadows don't fade out ~20 m ahead. Keeps the pack's vertex-colour tint (`use_vertex_color`).
  Why and how to tune: `docs/shadows.md`. `debug_print_leaf_materials()` lists them.

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

Tree count scales GPU/shadow cost roughly linearly. **Sun shadows (final, 2026-09-25): PSSM 4
splits at 25 / 67 / 108 / 150 m, blur 0.5, normal bias 0.75, blend splits on -- see
`docs/shadows.md`** (the notes below are the history of how it got there). **Since 2026-09-25: first split at 25 m (`directional_shadow_split_1` = 0.1, Godot's
default -- so it no longer appears in `main.tscn`) and `shadow_normal_bias` 0.75** (were 0.4 =
100 m and 2.0). Needed for the understory: with a 100 m first cascade a shadow texel was ~7-10
cm and the 2.0 bias shifted casters ~15-20 cm, so thin fern fronds / grass blades cast nothing.
If mid-distance (25-250 m) tree shadows ever look too soft, the next step is PSSM 4 splits.
**`directional_shadow_blend_splits` = true** (2026-09-25): with the split moved in to 25 m the
hard sharp-to-coarse cascade seam became visible right around the player (shadows fading in/out
while walking); blending the two cascades hides it.

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

## Understory assets (2026-09-25)

In `assets/models/understory/<dir>/` -- a separate folder from the trees. Setup script:
`tools/setup_understory_assets.gd` (`call_method`, `runtime:false`, scene
`tools/setup_understory_assets.tscn`, node `.`): `configure_imports()` (root_scale + discard
embedded textures, forced reimport), `setup_materials()` (`<dir>_material.tres`, used as
material override), `debug_print_sizes()`.

| dir | role | tris | size (m, w x h) | source |
|---|---|---|---|---|
| `fern_02` | main fern | LOD0-4: 1760/880/440/264/88 | 1.6 x 0.65 | Yughues Fern v2 (credit required) |
| `bush_01` | broad-leaf fern variant | 556 | 1.4 x 1.6 | Nobiax Bushes, CC0 |
| `bush_04` | shrub, grassy/spiky | 500 | 1.1 x 1.0 | Nobiax Bushes, CC0 |
| `bush_05` | shrub, rounded, woody stem | 880 | 1.3 x 1.1 | Nobiax Bushes, CC0 |
| `bush_02` | shrub, dense round (autumn colour -- tint green if it clashes) | 384 | 1.3 x 1.3 | Nobiax Bushes, CC0 |

- FBX files are in cm; Godot's importer converts to metres by itself, so bushes use
  root_scale 1.0. `fern_02` is modelled ~3.6 m wide -> root_scale 0.45.
- `fern_02.fbx` holds all 5 LODs as **sibling nodes** `FernPlantV2_LOD0..4`, all visible
  at once if the scene is instanced -- the placement layer must use one LOD mesh (LOD2 = 440
  tris suggested as default) or give each a distance band.
- Materials: alpha scissor 0.5, roughness 0.85, normal map, backlight (bushes: their
  translucency map; fern: flat colour). Bushes CULL_DISABLED (single-layer cards); fern_02
  CULL_BACK (see below). Specular maps from the packs were not imported (unused by Godot PBR).
  `bush_01`'s normal map is flat (blank in the source pack).
- **bush_02 is used GREEN only** (user's call, 2026-09-25): `bush_02_green_material.tres` with
  `textures/bush_02_diffuse_green.tga`, a hue-shifted (+42 deg, sat x0.88) copy of the
  autumn-orange texture matching the other plants' leaf hue (55-71 deg), and the fern's flat
  backlight (the translucency map is orange-red). The orange `bush_02_material.tres` is kept
  but unused.
- **Brightness matched to the fern** (user: bushes "too bright"): per-material grey
  `albedo_color` and scaled backlight -- see `MATERIALS` in the setup script for the measured
  numbers.
- **Terrain3D mesh assets 28-32** (`build_understory_assets()`): Fern02 28, Bush01 29,
  Bush02Green 30, Bush04 31, Bush05 32. Baked meshes (`<dir>/<name>_<node>.res`) + LOD scenes
  (`<dir>/<Name>.tscn`). **LODs (2026-09-25, final):** fern 440 tris to 50 m -> 88 tris to 150 m -> **impostor**;
  bushes full mesh to 80 m -> **impostor**. The impostor is the last LOD with range **0 = never
  culled** -- plants stay visible at any distance (user requirement; camera far is 4000 m). No
  fades anywhere (fading drops shadows); shadows on every LOD. Each LOD mesh carries its own
  surface material and the asset's `material_override` is null (an override would paint the leaf
  material onto the impostor quads). History: 3-LOD fern popped at 15/35 m, bushes/ferns popped
  in or faded out at 70-136 m. Ranges are measured to each 32 m instancer cell's centre, so a
  whole cell switches together. A single-LOD asset gets NO fade (fade_margin is clamped to half
  the LOD0->LOD1 gap).
- **Impostors** (`bake_impostors()`): each plant's baked mesh rendered unlit (albedo x tint, hard
  cutout) by an orthographic camera in an editor SubViewport, front + side, 256 px each ->
  `<dir>/<name>_impostor.png` (512x256) + `<name>_impostor.res`: two crossed vertical quads
  (4 tris), bottom-aligned squares. Shader `shaders/foliage/foliage_impostor.gdshader` (same
  leaf-alpha/shadow handling as the plants, normal forced UP). Gotcha: call
  `force_update_transform()` on the capture camera before `RenderingServer.force_draw()`, or it
  renders from the camera's default pose (transform changes flush only at the next frame).
  **Why the fern has no fade** (hard LOD switches): with a margin Terrain3D gives each LOD MultiMesh
  Godot's "fade self" visibility range with overlapping bands (fern 7-23 m and 27-43 m, measured
  from each 32 m cell's centre), and instances inside those bands cast no proper shadow -- fern
  shadows faded out as the player approached. Shadows from every LOD (a 35 m shadow cutoff was
  also tried and faded plant shadows in/out the same way). Setup order after changing anything:
  `configure_imports()` -> `leaf_diffuse_import()` -> `setup_materials()` -> `bake_impostors()`
  -> rescan -> `impostor_import()` -> `setup_impostor_materials()` -> `build_understory_assets()`.

### Understory gotchas (all found in-game 2026-09-25)

1. **Z-up source, rotation on the NODE.** Every plant FBX imports with a -90 deg X rotation on
   its mesh node, not in the vertices. A bare `Mesh` (MultiMesh, `mi.mesh`) lies on its side
   unless that basis is re-applied -- bake it into the vertices for the placement layer (like
   `build_pack_trees()` does for the trees).
2. **No import shadow meshes.** `meshes/create_shadow_meshes` makes position-only meshes (no
   UVs), so the alpha-scissor cutout samples a transparent texel in the shadow pass and the
   plant casts NO shadow. Off for all understory FBX (`configure_imports()`).
3. **Leaf shadows need the foliage shader, not StandardMaterial3D.** Plain alpha scissor: the
   shadow pass samples tiny mips where sparse leaf alpha averages below the cutoff -> no
   shadows; without mips, far shadows still fade ~20 m out (coarse cascade). Since 2026-09-25
   all understory materials are ShaderMaterials on `shaders/foliage/foliage_cutout_*.gdshader`
   (mip-scaled alpha + a separate `IN_SHADOW_PASS` cutoff) and leaf diffuse has mips again
   (`leaf_diffuse_import()`). Full explanation + tuning: `docs/shadows.md`.
4. **fern_02 is double-layered** (every frond duplicated back-to-back, normals 50/50 up/down).
   CULL_DISABLED draws both layers -> they self-shadow -> near-black fronds. Must be CULL_BACK.

- Raw source packs stay outside the project in `raw-assets/models/bushes` and
  `raw-assets/models/free_fern_pack_02` (bush_03, 2044 tris with flowers, not imported).

## Understory placement (`scripts/terrain/understory_scatter.gd`, built 2026-09-25)

`UnderstoryScatter.scatter_understory()`, called by WorldGenerator right after the trees
(needs `TreeScatter.tree_points` + `RockScatter.rock_keep_circles`), own rng stream (`'UNDR'`).

- **Density fields** on a 2 m grid: canopy cover (gaussian splat per tree, `CANOPY_SIGMA` 4.5 m x
  tree scale, cover = 1 - exp(-0.9 x sum)); cliff-foot shade (low side of each cliff feature
  whose face points away from the sun, band = cliff height / tan(sun elevation), 3-12 m); a
  small low-ground moisture bonus.
- **Ferns** (fern_02 80 %, bush_01 20 %): `FERN_MAX_P` x smoothstep(0.15, 0.7, shade).
  **Shrubs** (bush_04 40 %, bush_05 35 %, bush_02 green 25 %): peak at grove edges
  (4c(1-c)), some under canopy, `SHRUB_OPEN_P` in the open.
- **Noise**: glades (~50 m, `GLADE_*`) and clumping (~8 m, `CLUMP_*`).
- **Rejects**: slope (normal.y < 0.72), road, rock keep-outs, 0.9 m x scale ring round trunks.
- One jittered candidate per 1.1 m cell (`CANDIDATE_STEP`); cheap probability roll first, the
  costly checks only for survivors.
- **First run (2026-09-25):** ~25k plants (14k fern, 3.5k broad fern, 7.3k shrubs) from ~106k
  candidates; generation 1.27 s. Render cost of the whole layer incl. shadows, measured by
  clearing it in the same view: ~0.37 M of ~11 M tris/frame -- the trees dominate.
- Tuning knobs are the constants at the top of the module (all commented).

### Original plan notes


- Drive it from a **canopy density map** built from the placed trees (not from individual
  trees), so it thickens into groves and thins at their edges.
- **Ferns:** strongly tied to canopy, plus shaded cliff bases (the side facing away from the
  sun) and a small low-ground bonus. **Shrubs:** peak at grove edges, some under canopy, a few
  in the open.
- Same exclusions as trees + a clear ring around trunks + a few open glades.
- Performance: short draw distance (~60-80 m), no collision. Sun shadows: ON is the look the
  user chose (2026-09-25, with the 25 m first split) -- if cost bites, limit casting to the
  first ~20-25 m rather than dropping them.
- Later idea: a rustle sound when walking through foliage, using a spatial grid of the
  understory positions.
