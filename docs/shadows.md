# Shadows -- how Godot's sun shadows work here, and how to keep foliage shadows alive

Research + findings from the understory work (2026-09-25). Project-specific settings first,
general Godot knowledge after. Related: `docs/vegetation.md` (understory/trees),
`CLAUDE.md` (pitfalls).

Last reviewed: 2026-09-25 (Godot 4.7.2 stable, Forward+).

---

## Current project settings (and why)

| Setting | Value | Where | Why |
|---|---|---|---|
| `directional_shadow_mode` | PSSM **4** splits (Godot default, so not written in `main.tscn`) | `main.tscn` DirectionalLight3D | chosen by the user in-game 2026-09-25 ("best result") with the values below |
| splits 1 / 2 / 3 | 0.1667 / 0.4444 / 0.7222 = **25 / 67 / 108 m** (of 150) | same | 25 m sharp near cascade so thin fern fronds cast shadows (was 0.4 x 250 = 100 m: ~7-10 cm texels, ferns cast nothing); the rest spread evenly to max distance |
| `directional_shadow_max_distance` | **150 m** (was 250) | same | shorter range = every cascade denser; shadows end at 150 m (fade from ~120 m) |
| `directional_shadow_blend_splits` | true | same | hides the hard 25 m cascade seam right in front of the player |
| `shadow_normal_bias` | 0.75 (was 2.0) | same | 2.0 shifted casters ~15-20 cm and pushed thin leaf cards out of their own shadow |
| `shadow_bias` / `shadow_blur` | 0.1 / **0.5** | same | blur halved: less PCF softening, so thin leaf shadows aren't averaged away |

**Cost of this setup** (measured 2026-09-25, one view, vsync-capped 60 fps so no GPU headroom
number): ~18 M tris / ~6.5k draw calls per frame vs ~11-16 M with 2 splits to 250 m -- every
tree is drawn into 4 shadow passes. Levers if it gets too heavy: shorter max distance, fewer
splits, Terrain3D `last_shadow_lod` / shadow impostors on the trees.

How these were chosen: temporary debug keys (first-split distance, 2/4 splits, atlas 4096/8192,
max distance 250/150/100, blur 1/0.5/0) toggled live in-game; the 4096 atlas was kept.
| `lights_and_shadows/directional_shadow/size` | 4096 | `project.godot` | default; shared by the splits |
| `.../soft_shadow_filter_quality` | 2 (Soft Low) | `project.godot` | default |

Understory (Terrain3D ids 28-32): see `docs/vegetation.md` -- shadows from every LOD, fern has
NO LOD fade (fading kills shadows, below), bushes fade only at the far draw edge.

---

## How directional shadows work (Godot 4)

- The sun renders a **depth map from the light's view**; each screen pixel is projected into it
  and compared: farther than the stored depth = in shadow.
- **PSSM**: the view frustum is split into 2 or 4 slices (cascades); each gets its own region of
  the shadow atlas. Split distances are fractions of `directional_shadow_max_distance` (0 = eye,
  1 = max). With a 4096 atlas each cascade gets ~2048 px, so **texel size ~ cascade span / 2048**:
  here ~2-3 cm in 0-25 m, ~15 cm in 25-250 m. Docs: "tweaking the first split a bit is common to
  give more detail to close objects".
- **Max distance**: "a lower maximum distance will result in better-looking shadows and better
  performance, as fewer objects will need to be included in shadow rendering". **Fade start**
  (0.8) fades shadows out towards max distance.
- **Blend splits** cross-blends neighbouring cascades -- "sacrifices detail and performance in
  exchange for smoother transitions".
- **Bias**: too low = acne, too high = peter-panning. **Normal bias** is preferred over bias,
  "though it may make shadows appear thinner" -- which is exactly what hurts leaf cards. Both
  scale with the cascade's texel size, so the far cascade is biased more in world units.
- **Soft shadows**: `light_angular_distance` > 0 = contact-hardening (PCSS; the Sun is ~0.5 deg),
  expensive -- few lights only. `soft_shadow_filter_quality` sets the PCF kernel; higher = more
  blur, which also averages thin shadows away.
- **16-bit depth** is the default and recommended; 32-bit is rarely visible and costs a lot.
- **Shadow caster mask**: only objects on these layers cast (does not affect receiving).
- Objects spanning all cascades are drawn once per cascade + once for the view -- shadows are the
  single most expensive part of Godot 4 rendering (users report ~1/3 of frame time); the far
  cascades hold the most objects and cost the most.

## Why thin foliage shadows fade with distance (the core problem)

Alpha-scissor leaf cards are solid only where texture alpha >= the cutoff (0.5).

1. **Resolution**: in a coarse cascade a shadow texel (~15 cm) point-samples the leaf texture;
   with sparse fronds (fern leaflets 1-2 cm, ~25% of the card solid) only ~25% of texels hit a
   leaf -> after PCF filtering the shadow is a faint smudge. Seen in-game as fern/tree canopy
   shadows fading out ~20 m ahead (just past the 25 m sharp cascade).
2. **Mipmaps** (the classic alpha-test problem -- Golus, lisyarus): mips AVERAGE alpha, so a
   sparse leaf texture drops below the cutoff at small mips and vanishes. The shadow pass picks
   small mips because a plant covers few shadow texels -> no shadow at all (seen with the
   understory on 2026-09-25, and still true for the trees' `Branch_*.png` cards, which have mips).
3. Moving the split only trades one for the other: split at 50/100 m -> fern shadows vanish up
   close; split at 25 m -> they fade 20 m out (tested live with debug keys).

**The fix used here: a foliage shader** (`shaders/foliage/`, understory since 2026-09-25):
- mipmaps ON (no distant shimmer);
- alpha boosted by the sampled mip level -- `alpha *= 1 + mip * scale` (Golus's
  `CalcMipLevel` trick): far/coarse = high mip = averaged alpha gets pushed back over the cutoff,
  so density is kept; near = mip 0 = unchanged leafy detail;
- a separate, lower cutoff + stronger mip boost **in the shadow pass only** (`IN_SHADOW_PASS`,
  true while rendering shadow maps): near shadows stay dappled, coarse-cascade shadows become soft
  solid-ish blobs instead of fading. Visible look unaffected.
**Tree leaf cards use it too** (2026-09-25): `build_pack_trees()` in `tools/setup_tree_assets.gd`
builds each leaf/branch card's material with `_foliage_leaf_material()` (same texture, tint,
roughness; `use_vertex_color` on -- the Fab pack tints its cards via vertex colours). Cutoff and
boost values are read from the understory tool's constants so both layers stay in sync. Measured
in-game: frame cost unchanged (~17.9 M tris / ~6.6k draw calls vs ~18.1 M / ~6.5k before).

## Techniques & tips (collected)

- `IN_SHADOW_PASS` in a spatial shader lets a material behave differently in shadow maps -- e.g.
  force leaves solid for shadows only (redotcraft does this and reports ~45% less shadow
  "crawling"), use a different alpha cutoff, or skip expensive work.
- Alpha scissor casts shadows (opaque pipeline); real transparency (alpha blend) does not.
- **Visibility-range fade ("fade self") kills shadows** while an instance fades (Godot #91671
  family). Terrain3D `fade_margin` uses it -> keep it off where LODs switch near the player.
- **Terrain3D instancer**: LODs switch per **32 m cell** (distance to the cell centre), not per
  instance; `last_shadow_lod` stops shadows at a LOD; `shadow_impostor` casts a cheaper LOD's
  shadow while showing LOD0 -- the tool for cutting foliage shadow cost later. A single-LOD asset
  gets fade 0 (fade clamps to half the LOD0->LOD1 gap).
- Imported meshes: `meshes/create_shadow_meshes` builds position-only shadow meshes (no UVs) ->
  alpha-scissor casters lose their cutout and cast nothing. Off for foliage.
- Performance: fewer splits (2 here), lower max distance, `shadow_caster_mask` / `cast_shadow`
  off for small props, `last_shadow_lod` / shadow impostors for instanced foliage.
- **Screen-space contact shadows** (Bend-style) are in a draft PR for Godot 4.8 (#118045):
  Forward+, ~1 ms at 4K, can shadow even `cast_shadow`-off objects -- the ideal complement for
  foliage when it ships. Not available in 4.7.
- SSAO grounds small plants cheaply where shadow maps can't resolve them.

## Sources

- Godot docs -- 3D lights and shadows: https://docs.godotengine.org/en/stable/tutorials/3d/lights_and_shadows.html
- Godot docs -- spatial shader reference (`IN_SHADOW_PASS`): https://docs.godotengine.org/en/stable/tutorials/shaders/shader_reference/spatial_shader.html
- Godot docs -- optimizing 3D performance: https://docs.godotengine.org/en/stable/tutorials/performance/optimizing_3d_performance.html
- Solid leaf shadows via IN_SHADOW_PASS: https://github.com/OpenStaticFish/redotcraft/pull/18
- Fade Self hides shadows: https://github.com/godotengine/godot/issues/91671
- Alpha scissor + shadows: https://github.com/godotengine/godot/issues/58924
- Ben Golus, anti-aliased alpha test: https://bgolus.medium.com/anti-aliased-alpha-test-the-esoteric-alpha-to-coverage-8b177335ae4f
- lisyarus, mipmapping alpha-tested textures: https://lisyarus.github.io/blog/posts/exploring-ways-to-mipmap-alpha-tested-textures.html
- Shadow performance discussion: https://github.com/godotengine/godot-proposals/discussions/6046
- Contact shadows PR / 4.8 dev 6: https://github.com/godotengine/godot/pull/118045 , https://godotengine.org/article/dev-snapshot-godot-4-8-dev-6/
- Terrain3D instancer: https://terrain3d.readthedocs.io/en/latest/docs/instancer.html
