# Forest floor and density -- plan

Why the forest still reads as "empty patches", what the reference scenes do differently, what was
decided, and the build order. A PLAN: nothing in "Build order" is built yet unless marked.
Related: `docs/vegetation.md` (layers that exist), `docs/shadows.md` (shadow setup).

Written: 2026-10-01.

---

## The problem

With trees, understory, rocks, deadfall and grass all in, there are still patches that read as
empty (user screenshot, night, under canopy). Cause, from comparing against the references:

1. **The gaps show plain soil.** Grass coverage under canopy is 5-15 % by design
   (`GrassScatter.CANOPY_MIN_FACTOR`), and nothing else fills the ground there. The Ground
   texture is a light sandy olive -- the brightest, flattest thing in the frame.
2. **Ground and plants don't match** in hue or value, so every gap and patch outline is visible.
3. **Grass patches end abruptly** (`PATCH_EDGE` 0.06), like cut turf.
4. **No grounding.** Nothing darkens where plants meet the ground.
5. **No mid-storey.** Shrubs top out at 1.0-1.6 m; you can see a long way between bare trunks.
6. **Lighting.** Ambient light was disabled, so everything not moonlit was near black (fixed, below).

The placement RULES are already right (grass thins under canopy, ferns follow shade, shrubs peak
at grove edges). What is missing is the materials that make thin ground read as forest floor.

## References (what was learned)

**Unity HDRP forest video** (the "lush" look the user wants):

- Its "empty" patches are short green ground cover, same colour as the blades, with tall grass
  tapering into them and a dark rim (occlusion / contact shadows) at the border. Not parallax.
- Grass is one continuous detail layer over the whole terrain, no biome rules -- its own
  commenters call it "a meadow with trees". Lushness comes with an open, sunlit canopy.
- Its object pooling exists for choppable plants; not relevant (ours are instanced).

**Godot forest thread** (ToniMacaroniy):

- Stock Godot can do it. Engine changes were only cloud shadows, tonemap tweaks, SSAO/SSIL
  tweaks, and the lighting calculation in the foliage shader.
- "Assets are heavily processed and use specific shaders." Method: **divide each vegetation
  texture by its average colour, then colourise from one palette** (palette from the author's
  own scanned plants, the rest matched by eye).
- Grass: one type = one draw call, only around the player, not in the scene tree. (Ours already
  does this: GPU-culled indirect MultiMesh, 5 bands.)
- Commenters' ecology notes: grass up to the trunks only in the open; leaf litter + herb pockets
  under deciduous; needle mulch, moss and fern pockets under conifers ("chunky dirt"); shrubs,
  cane fruit and young trees at the meadow-to-forest transition.

## Decisions (2026-10-01)

- **Both looks, by zone:** meadow stays grassy; under canopy = dark litter, moss, ferns; the edge
  between gets shrubs and saplings. Zones come from the existing canopy grid.
- **Ambient light ON:** `main.tscn` Environment, source Color, colour ~(0.15, 0.28, 0.72), energy
  1.5; moon energy 3.0 -> 2.0. (Source = Sky did nothing: the sky top is near black.) User-tuned
  in the Inspector; edit the Local scene and re-run -- editing the Environment via the Remote tree
  changed the local resource, not the running game.
- **SSAO ON at quality Low** (`environment/ssao/quality=1` in `project.godot`; radius 2,
  intensity 3, light affect 0.3). At the default quality (Medium) it cost 15-20 points of GPU
  utilisation. Baked grounding (step 5) is still wanted: it survives the painterly pass and
  distance.
- **Shadow handoff:** `light_angular_distance` 0.05. Details and rejected shader attempts:
  `docs/shadows.md`.
- **No texture parallax** for ground depth (both road attempts failed -- see `CLAUDE.md`).
- **Optimisation is deferred** to one dedicated session after all layers exist. Note each layer's
  rough cost as it lands. GPU utilisation readings at ~1906x942 (user's system monitor):
  ambient + angular distance, SSAO off: ~60 % looking at the ground, 75-98 % by view. Later the
  same day, same window / position / direction, with SSAO on at Low as well: 80 % max. UNEXPLAINED
  (adding SSAO can't make it cheaper) -- left for the optimisation session; measure frame time
  there, not utilisation. After the litter layer (step 2) landed: at spawn, looking ahead, nothing
  moving, utilisation wanders in irregular steps between 75 and 98 %. Same range as before the
  litter work, so not attributed to it. The project runs capped (`run/max_fps=60`, vsync on), so
  the percentage also moves with the GPU's clock/power stepping -- measure uncapped frame time.

## Build order

1. **Colour-match plants and ground to one palette.** CLOSED 2026-10-02 (user decision): only the
   Grass ground texture is tinted (`GRASS_TINT` in `ground_paint.gd`); ferns and shrubs look good
   as they are, and a blanket tint would blend everything into one. Lessons: dividing by the
   texture average and matching albedo numbers turned the ground pitch black under the moon +
   grade -- use the averages for hue only, set brightness by eye; and blades need a VALUE
   difference from the ground (lighter tops, darker floor) or they vanish into it. If a single
   asset later looks pasted in, tint that one. Original notes: Editor tool: average colour of each leaf
   texture over its opaque pixels; setup tools set material tint = palette colour / average (same
   result as the reference's divide-then-colourise, no texture rewrite). Terrain3D textures have a
   per-texture tint too. Anchor: the grass blade colour, unless the user supplies a reference.
   Care: pack trees are tinted by vertex colour (incl. the brown "dry" variants); the colour grade
   remaps by brightness, so judge in-game with the grade on. **Open: palette anchor.**
2. **Litter under canopy.** BUILT 2026-10-01, ACCEPTED by the user 2026-10-02 ("litter is good"):
   texture id 8 `PineLitter` (baked from the floor scan, see "Assets on hand"), painted by
   `ground_paint.gd` from canopy cover x noise (`LITTER_*` constants; three vertex pairs, see the
   comment there), and litter mounds at trunk bases and against stumps / logs
   (`DeadfallScatter._scatter_mounds`, mesh ids 50-52, no shadows, no collision). First run: 36 %
   of vertices full litter, 10 % on the ramp, 450 mounds. Not done: the boost near deadfall and
   uphill of rocks, a leaf component, colour matching (step 1). Ground paint now takes ~1.7 s
   (not measured before the change). User feedback the same day: full litter beside the road
   drew a blocky straight edge (pair swap against the road's vertices) -> litter now fades out
   toward the road (`LITTER_ROAD_CLEAR` 1 m / `LITTER_ROAD_REACH` 6 m); the user then found the
   litter too sparse along the road -- 6 m is probably too wide, ~3 m proposed, not yet changed.
   Then: litter also sat on a steep bank and showed through the rock texture up to a cliff mesh.
   User decision: litter is a PATCH UNDER EACH TREE (`LITTER_TREE_*`), not a stand-wide carpet,
   and none on steep ground or at cliffs (`LITTER_NY_*`, `LITTER_CLIFF_*`). Result on the same
   map: 9 % full litter + 9 % ramp (was 35 % + 10 %). Then "strays" added on the user's suggestion,
   all gated by nearby canopy as the supply (`LITTER_SUPPLY_*` etc. in `ground_paint.gd`): a
   collar around boulders / stumps / logs (full on the uphill side), concave ground (ravine
   floors, gullies), and noise-placed wind drifts. Same map: 12 % full + 12 % ramp. Not yet
   judged in-game.
   Original notes: New Terrain3D texture(s) in `TEXTURES_BY_ID`
   (`tools/assign_flat_textures.gd`; packed albedo+height / normal+roughness, import settings
   matching id 0), painted in `scripts/terrain/ground_paint.gd`. Weight = canopy cover x noise,
   boosted near `DeadfallScatter.deadfall_keep_circles` and uphill of rocks. A vertex holds one
   base/overlay pair: keep base = Ground, pick the overlay (Grass or litter) per vertex and fade
   both blends where neighbours disagree (the `ROCK_TYPE_SEAM_FADE` trick); rocky vertices may
   take litter as their soil. One blended needle+leaf texture: stands are mixed (trees look like a
   uniform pick from 8 pines + 6 deciduous), so per-species litter needs species-biased stands
   first, plus tree ids alongside `TreeScatter.tree_points`.
3. **Moss** as a ground type in shade (canopy / cliff shade grids), not only on rocky ground.
4. **Green gaps and soft patch edges in the open.** PARTLY BUILT, not yet judged in-game: Grass is
   the default ground texture since 2026-10-01 (`BARE_*` in `ground_paint.gd`); 2026-10-02 added
   the blade height taper toward patch edges and short blade layers in the gaps to 60 m
   (`PATCH_TAPER` / `EDGE_*` / `SHORT_*` in `grass_cull.glsl`, `SHORT_LAYERS` in `grass_field.gd`;
   the first try, one layer to 40 m, was too sparse and invisible from a distance).
   The worn-soil patches are baked by `GrassScatter` (`worn`, `WORN_*`) since 2026-10-02, so
   grass coverage drops to zero on them and the ground paint reads the same field. Cost not measured. Original notes: Short-grass/moss texture in the gaps between
   blade patches (soil only at road verges, rock, dense canopy); widen the patch edge ramp and
   taper blade height toward it; optionally a 3-6 cm blade band out to 15-20 m as an extra layer
   in `GrassField` (never as placed instances).
   Also 2026-10-02, not yet judged: the Grass texture is tinted toward the blade colour at runtime
   (`GRASS_TINT` in `ground_paint.gd` -- step 1 for the grass texture only), and the ground under
   the tall patches is darkened through the terrain colour map (`PATCH_SHADE` -- the patch part
   of step 5; nothing yet under ferns / bushes, the understory keeps no plant positions).
5. **Baked grounding.** Darken the ground at patch borders and under ferns/bushes in the ground
   paint (patch map + plant positions are known); fade plant and blade colour toward dark at the
   base in their shaders; soften foliage lighting so shadowed sides don't go black.
6. **Pine cones.** BUILT 2026-10-02, not yet judged in-game. Two models from
   `raw-assets/models/cones/`: `cone_open` (`pinecone.fbx`, game-ready, 1.5k tris, scaled x1.6 to
   9 cm) and `cone_long` (`pinecone_photoscan.glb`, 29k tris decimated to 1.7k, 12 cm, albedo
   only), both exported lying along X with 1K textures by `import_megascans_glb.py`
   (`--loose-roles --tex-size 1024`). Mesh ids 53 / 54, no shadows, no collision, cull 40 m.
   Placement: `DeadfallScatter._scatter_cones` (`CONE_*` constants) -- 5-14 cones under 55 % of
   the pines (`TreeScatter.tree_mesh_ids` says which trees are pines), the group shifted downhill
   on a slope, plus 2-6 against the uphill side of logs with a pine within 4 m; kept off rocks,
   cliffs, trunks, stumps / logs and litter mounds. First run: 2281 cones (2232 under 265 of 520
   pines, 49 against logs), 0.1 s. Not used: `source/model.glb` (99k tris, 8K texture, a second
   open cone, very dark). Original notes: New small kind in `scripts/terrain/deadfall_scatter.gd` + rows in
   `tools/setup_ground_debris_assets.gd` (next free mesh ids, 53+). Clusters under pines, biased
   downhill, a few against logs. No collision, no shadows, cull ~30-40 m, in `SMALL_KINDS`.
   NOT through `_try_place` as is (linear scan of `ctx.placed`): light path with slope / road /
   rock checks only, overlaps allowed.
7. **Mid-storey at grove edges.** Saplings and tall shrubs 2-4 m (pack candidates: `Tree_05`,
   `Branch_C`, `Tree_B`). The one step with a real rendering cost.
8. **Sparse litter on the road** (added 2026-10-01; do AFTER step 1 and once the litter look of
   step 2 is accepted -- both change how it should look). Real roads under trees are swept clean
   in the middle; litter collects along the edges, in the joints between stones and in drifts.
   NOT via the terrain texture: the visible road is the ribbon mesh (`TerrainRoad.build_road_mesh`,
   a StandardMaterial3D with heightmap parallax) lying over the terrain, and road vertices keep
   their own Ground + Road pair. Do it in the road mesh's material: a custom shader replacing the
   StandardMaterial3D, blending the PineLitter pair in where the stone height map is low (joints),
   scaled by canopy cover and by closeness to the road edge (both passed per vertex), broken up by
   noise. Cost: two extra texture reads on the road only. Care: the shader must reproduce the
   current parallax; road depth has failed twice before (`CLAUDE.md`, "Road parallax"), so compare
   against the current look before and after. Sample the litter with plain samplers, no
   `hint_normal` (see `litter_mound.gdshader` for why).

Later / optional: grounding decals for stumps, logs, boulders; road ruts and puddles; cliff and
church stains; cloud shadows (no projector on Godot's directional light -- would have to be faked
in the terrain, grass and foliage shaders together).

## Assets on hand

- **Pine cone meshes:** `raw-assets/models/cones/` (three models; two in use, see step 6).
- **Needle / leaf textures:** found by the user 2026-10-01; location not yet given.
- **`raw-assets/models/forest_ground_soil_pine_free.glb`** (54 MB): photogrammetry scan of pine
  forest floor. 11 chunks, ~500k tris, one 8192 px albedo JPEG, no normal/roughness/height. The
  texture is a scan atlas (patchwork islands, bottom third empty) -- not tileable. Measured
  2026-10-01: one continuous patch, 37 x 42 units, ~0.06 m per unit (from the cones and an oak
  leaf) = ~2.2 x 2.5 m; the mesh is upside down and closed by ~200 huge cap triangles on its
  back. `tools/blender/bake_pine_litter.py` fixes both in memory and bakes it top-down to the
  tileable `textures/source/pine_litter_{albedo_height,normal_roughness}_1k.png` (one tile =
  1.56 m, height from one ray per pixel, normal derived from the height) plus three 476-triangle
  mound meshes in `assets/models/ground_debris/litter_mound/`. The mounds have no textures of
  their own: `litter_mound.gdshader` reads the terrain pair, so they match the painted ground.
  Still possible from the same bake: grounding decals (albedo + mask blobs).

## Decal notes (if used)

- A decal paints everything in its box (grass, ferns, sticks) unless the cull mask and render
  layers separate them. Unchecked: whether Terrain3D instancer meshes can sit on a different
  layer from the terrain.
- Forward+ shares one clustered-element budget (512 by default) between decals, omni/spot lights
  and reflection probes: use distance fade (~40 m), keep decals small and non-overlapping.
