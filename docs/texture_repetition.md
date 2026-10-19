# Texture repetition on the terrain

(2026-10-19.) What breaks the terrain textures' repetition now, what was looked at, and the
options left for a later pass. Started from Kirill's question whether a list of common
techniques (vertex blending, decals, level design, larger textures, editing the texture,
stochastic tiling) could add to what is there, with two links:
<https://iquilezles.org/articles/texturerepetition/> and
<https://github.com/VoidWireInteractive/Unity-Stochastic-Shadergraph>.

## In place

| What | Where | Notes |
|---|---|---|
| Terrain3D detiling: each tile-sized cell turned (up to +-36 deg) and shifted at random, neighbours blended | `DETILING_*` in `scripts/terrain_gen.gd` | Off on RockFace (id 2): `TerrainDisplacement` must repeat the drawn surface in script, and the per-cell random number could not be repeated then. The Road has none while displaced. |
| Ground paint v3: patches of one texture, 50/50 pair at borders | `scripts/terrain/ground_paint.gd` | This is the "vertex blending". A Terrain3D vertex holds two textures; three-way mixes left 1 m steps. |
| Rock detail layer: RockFace and the mountain read again at a small tile near the camera | `ROCK_DETAIL_*` in `terrain_gen.gd` | |
| Per-pixel projection patch | `_apply_projection_override` | The shader patch every option below would go into. |
| Displacement, and the scatter layers on the ground | | |
| **Macro variation** (2026-10-19, option 1 below, TRIAL) | `MACRO_*` and `_apply_macro_variation` in `terrain_gen.gd` | See below. |

## Findings

- **Macro variation was on but did nothing**: Terrain3D enables it by default with both colours
  white (1, 1, 1), and `main.tscn` never set them. Its code (read from the shader text inside
  `addons/terrain_3d/bin/libterrain.windows.release.x86_64.dll`):
  `macrov = mix(macro_variation1, 1, noise1) * mix(macro_variation2, 1, noise2)`, multiplied into
  each texture's albedo, faded by `clamp(normal.y + macro_variation_slope, 0, 1)`. The noises
  are read from `noise_texture` at `uv * noiseN_scale * 0.1`, and `uv` is in metres: the
  defaults 0.04 / 0.076 repeat every 250 / 132 m. Set with `Terrain3DMaterial.set_shader_param`.
  The shader patch copies the generated text, so it keeps the macro variation code.
- Whether Terrain3D supplies a `noise_texture` by itself was not confirmed: the startup log line
  `TERRAIN_GEN: macro variation -- ...` prints it. `<null>` = the noises read 0 and the whole
  ground is tinted evenly. A headless start does not reach the terrain build, so this needs a
  normal start.
- Terrain3D's detiling is technique 1 of Inigo Quilez's article (random change per square tile,
  neighbours blended), with turns instead of mirroring, and already samples with `textureGrad`.
  Its weaknesses as the article gives them: a square grid that can still show, and some blur /
  lost contrast where cells blend.
- The article's three techniques: (1) per-tile random offset / mirror, 4 reads, blended; (2)
  Voronoi blend of randomly shifted and turned copies, 9 reads, best and dearest; (3) eight
  "virtual" copies at fixed offsets, picked by a low-frequency index noise, 2 reads of the
  texture + 1 cheap index read, blended with a weight pushed by the colour difference
  (`f - 0.1 * sum(cola - colb)`) so the transitions keep their contrast.
- The Unity repo is Heitz & Neyret's histogram-preserving hex tiling (3 reads on a hex grid,
  blend that keeps contrast) -- not in iq's article.

## Options, cheapest first

1. **Macro variation** -- DONE as a TRIAL (2026-10-19), not judged in game yet.
   `MACRO_VARIATION_1` (0.82, 0.78, 0.70) darker / warmer, `MACRO_VARIATION_2`
   (0.90, 0.95, 0.88) cooler / greener, `MACRO_VARIATION_SLOPE` 0 (Terrain3D's 0.333 would tint
   the mountain's rock in full; at 0 a 70 deg slope gets a third), noise scales at the defaults.
   No extra cost. Both colours white = off. Aimed at repetition seen from far or above.
2. **Read larger in the distance** (+1 read past a distance): blend each texture with a read of
   itself at 3-4x the tile beyond about 40 m, the reverse of the rock detail layer, in the same
   patch. For repetition at mid and far distance (textures with `uv_scale` 2 repeat every 0.5 m).
3. **iq's technique 3** (+1 read per texture, near): two fixed-offset copies picked by a large
   noise, colour-difference blend; no grid, contrast kept; switchable per texture id. Being
   repeatable, `TerrainDisplacement` could copy it -- which might give RockFace anti-tiling
   back. The displacement buffer shader needs the same change. Most work; measure its cost
   with the benchmark (steep ground already reads three times for the side projection).
4. **Technique 3 on the mountain backdrop** (`shaders/mountain_wall.gdshader`): our own shader,
   no collision or script copy -- the easiest place to try it, if the mountains read as tiled.
5. **For one named texture**: retouch a standout feature (a bright stone the eye finds again),
   or decals at a few spots (road, cliff feet).

Judged not worth it here: vertex blending (done by ground paint), larger textures (Terrain3D's
texture array forces every id to match id 0 -- one texture at 2K means all at 2K, about 4x the
video memory), Heitz-Neyret over technique 3 (one more read for the same gains), and level
design (the scatter layers already do it).

Which to do next depends on where repetition still shows: far / from above -> 1, then 2; near
-> 3; the mountains -> 4.
