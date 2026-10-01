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
  there, not utilisation.

## Build order

1. **Colour-match plants and ground to one palette.** Editor tool: average colour of each leaf
   texture over its opaque pixels; setup tools set material tint = palette colour / average (same
   result as the reference's divide-then-colourise, no texture rewrite). Terrain3D textures have a
   per-texture tint too. Anchor: the grass blade colour, unless the user supplies a reference.
   Care: pack trees are tinted by vertex colour (incl. the brown "dry" variants); the colour grade
   remaps by brightness, so judge in-game with the grade on. **Open: palette anchor.**
2. **Litter under canopy.** New Terrain3D texture(s) in `TEXTURES_BY_ID`
   (`tools/assign_flat_textures.gd`; packed albedo+height / normal+roughness, import settings
   matching id 0), painted in `scripts/terrain/ground_paint.gd`. Weight = canopy cover x noise,
   boosted near `DeadfallScatter.deadfall_keep_circles` and uphill of rocks. A vertex holds one
   base/overlay pair: keep base = Ground, pick the overlay (Grass or litter) per vertex and fade
   both blends where neighbours disagree (the `ROCK_TYPE_SEAM_FADE` trick); rocky vertices may
   take litter as their soil. One blended needle+leaf texture: stands are mixed (trees look like a
   uniform pick from 8 pines + 6 deciduous), so per-species litter needs species-biased stands
   first, plus tree ids alongside `TreeScatter.tree_points`.
3. **Moss** as a ground type in shade (canopy / cliff shade grids), not only on rocky ground.
4. **Green gaps and soft patch edges in the open.** Short-grass/moss texture in the gaps between
   blade patches (soil only at road verges, rock, dense canopy); widen the patch edge ramp and
   taper blade height toward it; optionally a 3-6 cm blade band out to 15-20 m as an extra layer
   in `GrassField` (never as placed instances).
5. **Baked grounding.** Darken the ground at patch borders and under ferns/bushes in the ground
   paint (patch map + plant positions are known); fade plant and blade colour toward dark at the
   base in their shaders; soften foliage lighting so shadowed sides don't go black.
6. **Pine cones.** New small kind in `scripts/terrain/deadfall_scatter.gd` + rows in
   `tools/setup_ground_debris_assets.gd` (next free mesh ids, 50+). Clusters under pines, biased
   downhill, a few against logs. No collision, no shadows, cull ~30-40 m, in `SMALL_KINDS`.
   NOT through `_try_place` as is (linear scan of `ctx.placed`): light path with slope / road /
   rock checks only, overlaps allowed.
7. **Mid-storey at grove edges.** Saplings and tall shrubs 2-4 m (pack candidates: `Tree_05`,
   `Branch_C`, `Tree_B`). The one step with a real rendering cost.

Later / optional: grounding decals for stumps, logs, boulders; road ruts and puddles; cliff and
church stains; cloud shadows (no projector on Godot's directional light -- would have to be faked
in the terrain, grass and foliage shaders together).

## Assets on hand

- **Needle / leaf textures and pine cone meshes:** found by the user 2026-10-01; location not
  yet given.
- **`raw-assets/models/forest_ground_soil_pine_free.glb`** (54 MB): photogrammetry scan of pine
  forest floor. 11 chunks, ~500k tris, one 8192 px albedo JPEG, no normal/roughness/height. The
  texture is a scan atlas (patchwork islands, bottom third empty) -- not tileable. Extent ~37 x
  42 units, but texel density suggests ~4 m real size (not measured in Blender). Unusable as is;
  bake top-down in Blender to albedo + normal + mask for grounding decals (preferred), or to a
  tileable ground texture with a true height map.

## Decal notes (if used)

- A decal paints everything in its box (grass, ferns, sticks) unless the cull mask and render
  layers separate them. Unchecked: whether Terrain3D instancer meshes can sit on a different
  layer from the terrain.
- Forward+ shares one clustered-element budget (512 by default) between decals, omni/spot lights
  and reflection probes: use distance fade (~40 m), keep decals small and non-overlapping.
