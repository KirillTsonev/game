// Grass groundcover -- per-blade "Ghost of Tsushima" look (2026-09-25). Draw material for
// GrassField's BLADE layers (instances placed + culled by grass_cull.glsl).
//
// Port of GodotGrass's grass.gdshader by Ethan Truong (MIT, https://github.com/2Retr0/GodotGrass
// -- see credits.txt), kept as close to the original as possible: hash-driven blade width/height,
// clump-noise clumping of yaw/height/bend, scrolling-noise wind with height-offset turbulence,
// player crush, view-space thickening of blades seen edge-on, distance widening (their LOD
// compensation), base->tip colour with AO darkening, distance colour flattening, rounded normals,
// anisotropy, and their wrap-diffuse + subsurface light().
// NOTE: saving this file from a Godot shader-editor tab that was opened BEFORE an external write
// reverts it to the tab's stale copy (happened 2026-09-30 -- everything after the saturation change
// was lost and restored). Reopen the file before editing it in Godot.
// Changes for this project:
//   - root = the instance origin from the GPU placement (MODEL_MATRIX[3]), already ON our terrain
//     -> their global heightmap offset is gone;
//   - HEIGHT (2026-09-25 "middle ground"): temperate meadow instead of Tsushima's waist-high
//     pampas. GodotGrass: 0.75 m mesh x mix(0.4, 2.0) = 0.3-1.5 m. Now x mix(0.3, 0.8) x the
//     map's tall channel mix(0.6, 1.35) -> ~0.14-0.36 m on ridges/dry ground, ~0.2-0.55 m typical,
//     up to ~0.8 m in hollows; coverage (INSTANCE_CUSTOM.w) trims sparse ground slightly.
//     Change BLADE_MAX_HEIGHT in grass_field.gd (cull sphere) if the range grows.
//   - the dry channel (.y) blends the colours toward straw;
//   - crush uses horizontal distance to the player with a vertical gate (the player origin isn't
//     at their feet), instead of a 3D distance to a ground-level point;
//   - plain uniforms instead of their project-wide global uniforms (set by GrassField);
//   - TANGENT/BINORMAL are rotated with NORMAL (GodotGrass rotates only NORMAL), so the tangent
//     frame ANISOTROPY relies on stays valid when blades yaw/bend.
//   - UV is CLAMPED to [0,1] in fragment() (2026-09-25). ROOT CAUSE of the yellow-green bloom/glare
//     flashes on the blades: the project runs MSAA 2x (rendering/anti_aliasing/quality/msaa_3d=1),
//     and with MSAA a partially covered pixel is shaded at its centre, which on a sub-pixel-thin
//     blade lies OUTSIDE the triangle -> UV is extrapolated (e.g. UV.y = -5). GodotGrass feeds
//     1 - UV.y into ease_in_quartic() and an h^2 AO term unclamped: 6^4 x 6^2 ~ 46000x -> tip-
//     coloured hot pixels, flickering as blades sway, which UnrealBloom + Glare blew up into
//     flashes. Tufts never did this because grass_tuft.gdshader used smoothstep (clamped).
//     Don't remove the clamp while MSAA is on.
//   - distance WIDENING is uniform-driven (2026-09-27): 1 + min(pow(widen_scale * dist,
//     widen_power), widen_max) -- GodotGrass's hard-coded curve is scale 0.033, power 4, max 75.
//     Set by GrassField (and live from the grass tuning panel, debug key Y).
//   - WIND FADE (2026-09-28): wind sway (gust turn + turbulence) x (1 - smoothstep(wind_fade_start,
//     wind_fade_end, camera distance)). Far blades are metres wide and their sway read as a
//     heat-haze shimmer; faded out they keep their resting lean/yaw/bend and just hold still.
//   - OVERHANG CAP (2026-09-29): the widened width is multiplied by INSTANCE_CUSTOM.x, a per-blade
//     factor (1 = full width) from grass_cull.glsl's overhang cap -- far blades on slopes / brows
//     are narrowed so they don't stick out over ground that drops away beneath them (it read as
//     grass floating past slope edges from a distance). The widening curve itself is unchanged.
//   - TOP-SIDE NEON FIX (2026-09-29): the sun-facing (upper) side of bent blades read neon
//     yellow-green while the underside was a nice dark green. Causes: tip_color (0.5, 0.5, 0.1) is
//     yellow (R = G, no B); GodotGrass's wrap diffuse pow(4, N.L)/4 spans 1/16 -> 1.0, so the lit
//     face got ~16x the underside's light (cull_disabled flips NORMAL on the back face); and the
//     orange-yellow SSS term added more on top. Now: greener tip (0.30, 0.42, 0.10), linear wrap
//     mix(backlight_floor, 0.75, N.L*0.5+0.5). GodotGrass originals: tip (0.5,0.5,0.1), SSS
//     (1.0,0.75,0.1) x 0.5.
//   - FACING-THE-MOON FIX (2026-09-29): looking away from the moon was fine, looking toward it the
//     whole field went neon. The SSS lobe max(-V.L, 0) is view-dependent and ~90 deg wide, so
//     facing the light every blade got it (then bloom). Now pow(max(-V.L,0), 4) x 0.2 -- the glow
//     stays near the moon direction (45 deg off: ~0.25x instead of 0.7x) -- and a deeper green SSS
//     colour (0.35, 0.55, 0.12) since it's moonlight. History: GodotGrass linear x 0.5, then
//     linear x 0.3 with (0.55, 0.65, 0.15).
//   - BACKLIGHT FLOOR (2026-09-29): still too saturated facing the moon. Grass casts no shadows
//     (grass_field.gd: SHADOW_CASTING_SETTING_OFF -- keep it; blade counts + shadow bias make it
//     pointless), so nothing darkens a blade's shadowed side except N.L -- and the wrap floor kept
//     backlit faces at 0.25 of full moonlight while the trees (plain Lambert) go to black
//     silhouettes -> the grass read as glowing. Floor is now the uniform backlight_floor (0.08;
//     was 0.25 in the neon fix, 1/16 in GodotGrass). The lit top (0.75) is unchanged, so the
//     facing-away view barely moves.
//   - BLADE SATURATION (2026-09-29): final ALBEDO is pulled toward its own luminance by the uniform
//     blade_saturation (1 = unchanged, 0 = grey). Applied last in fragment(), so it covers green,
//     dry and distance-flattened colours alike -- and the SSS glow too, since the engine
//     multiplies DIFFUSE_LIGHT by ALBEDO. Luminance is kept, so brightness doesn't drop.
//   - SKY-REFLECTION SHEEN (2026-09-30): the glossy tips (ROUGHNESS 0.4, ANISOTROPY 0.85) pick up
//     the engine's sky/radiance reflections, added OUTSIDE light(); at the grazing angle of looking
//     across the field toward the moon, Fresnel pushes them up and they mirror the moon halo.
//     SPECULAR = the uniform blade_specular (0 = no sky reflections; engine default 0.5).
//   - DISTANCE NORMAL TARGET (2026-09-30): facing the moon, grass got BRIGHTER WITH DISTANCE (a
//     near patch dim, patches past a tree bright). GodotGrass blends the blade normal toward
//     straight up with distance (fog_factor: ~40% up at 30 m, ~65% at 60 m) so far grass reads
//     like the ground -- but an up normal is lit by a high moon whichever side of the blade you
//     see, while near blades seen from the moon side show their shadowed face (backlight_floor).
//     Now the far target is normalize(up + VIEW) -- halfway between up and toward the camera,
//     like the visible face of a near blade (cull_disabled flips NORMAL to face the viewer) -- so
//     far grass darkens facing the light and stays lit facing away, matching the near grass.
//     View space: vec3(0,1,0) is camera-up (the same assumption GodotGrass made).
//   - BLADE AMBIENT / SKY OCCLUSION (2026-09-30): an in-game bisection (a since-removed debug
//     cycle on key U) of the white glow facing the moon found: black blades -> no glow (it's the
//     blades, not the terrain's grass ground texture); direct diffuse only -> black; SSS only ->
//     black; ambient-only == normal; ambient x0.1 / x0.01 -> no visible change; all post-FX off ->
//     no change. So light() changes don't reach it, and why the blades' brightness ignores those
//     lighting scales is still unexplained (the only Environment, main.tscn, has
//     ambient_light_source = DISABLED, no SDFGI/SSIL/VoxelGI/ReflectionProbe). Kept anyway as a
//     physically sensible sky occlusion: AO = blade_ambient x mix(0.25, 1.0, height), with
//     AO_LIGHT_AFFECT = 0 (direct light untouched).
//     Side finding: direct diffuse alone rendered black, so direct moonlight barely reaches the
//     blades (likely terrain shadow + shadow_normal_bias 0.75 swallowing 0.3 m blades) -- not
//     investigated yet.
//   - NO BRIGHT TIPS (2026-09-30) -- THE FIX for the white glow facing the moon. Kirill's
//     hypothesis: the TIPS are the glow -- they're the brightest part of each blade (the lower
//     blade is darkened to 10%), and under the pale teal moon light (0.77, 0.90, 0.84) they read
//     white. The "whole blade = base colour" test looked best in-game, so it's the default:
//     t = mix(b, t, tip_blend) with tip_blend = 0 -> base colour root to tip, for green AND dry
//     blades (and the distance-flattened colour, which also uses t). tip_color / dry_tip_color
//     are kept -- raise tip_blend to bring a tip gradient back.
//   - PER-BLADE VARIETY (2026-09-30): blades read as identical copies -- height was 80% clump
//     noise (~13 m features, so neighbours matched), width only 0.6-1.0 and on the same hash as
//     the bend, one mesh shape, no per-blade colour. Now: height_clumping 0.5, a skewed per-blade
//     stature_range multiplier (odd tall stalk), width_range 0.5-1.25, a per-blade taper
//     (needle <-> broad leaf), an independent bend hash with a wider range (0.10-0.30), and
//     per-blade brightness/hue jitter (color_variation, hue_variation). Width/taper fade to 1.0
//     with the wind fade (overhang cap assumes the base width far away); colour jitter fades with
//     fog_factor. Tallest blade now ~1.01 m -> BLADE_MAX_HEIGHT raised to 1.15.
//   - HEIGHT FACTOR (2026-10-02): INSTANCE_CUSTOM.w is no longer the raw coverage but a per-blade
//     height factor from grass_cull.glsl: patch-edge taper (tall layers) or the short gap layer's
//     height, x the old coverage trim mix(0.85, 1, coverage). .x also carries their width factor.
//   - SHORT BLADES FACE EVERY WAY (2026-10-02, Kirill: from some angles the short gap grass
//     looked non-existent). Yaw is +-0.15 turn around the ~13 m clump direction, so a whole area
//     faces one way and is seen edge-on from the side; tall blades survive that through bend and
//     numbers, 10 cm ones vanish. Blades with a low height factor (the short layers and the
//     tapered patch rim) now get a fully random yaw and short_lean extra bend, so some always
//     face the camera and they show their face from above. Then (same day): beyond
//     short_face_range (5-15 m) they turn to face the camera, +-short_face_jitter. Not closer:
//     a blade tracking the camera visibly swivels as the player walks past it.
//   - SHORT BLADE TIPS (2026-10-02, Kirill: after the Grass ground texture was tinted toward
//     the blade colour, the blades -- the short ones most -- blended into it). Short blades get
//     short_tip_blend of the tip colour, over the upper half (h^2, not the quartic) since a 10 cm
//     blade has no room for a tip-only highlight. Full-height blades are unchanged (tip_blend 0,
//     see "NO BRIGHT TIPS" -- if the glow facing the moon comes back in the gaps, lower this).
//     The ground side of the separation is GAP_SHADE / PATCH_SHADE in ground_paint.gd.
//   - SHARED WIND FIELD (2026-10-06): the wind noise lookups moved, unchanged, into
//     shaders/wind.gdshaderinc so the understory and flowers sway in the same gusts.
//   - LESS DRY GRASS (2026-09-29): v_dry threshold smoothstep(0.30, 0.60) -> (0.45, 0.75) so fewer
//     patches turn straw, and dry_tip_color (0.75, 0.62, 0.30) -> (0.58, 0.50, 0.26) so the ones
//     that do are less glaring. The bake's dry channel itself is unchanged.
shader_type spatial;
render_mode cull_disabled, ensure_correct_normals;

uniform vec3 player_position = vec3(0.0, -1000.0, 0.0);

group_uniforms GrassProperties;
uniform float clumping_factor : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D clump_noise : repeat_enable, filter_linear;
// wind_speed, wind_noise and the wind field functions (shared with the foliage since 2026-10-06).
#include "res://shaders/wind.gdshaderinc"
uniform float wind_fade_start = 40.0; // m from the camera -- full wind sway closer than this
uniform float wind_fade_end = 80.0; // m -- no wind sway beyond this
uniform float crush_radius = 0.9; // m (horizontal) -- blades inside this lie down around the player
uniform float crush_height = 2.5; // m -- crush only when the player is within this height of the blade
uniform vec2 height_range = vec2(0.3, 0.8); // x the 0.75 m blade mesh (GodotGrass: 0.4-2.0)
uniform float widen_scale = 0.0333; // distance widening: 1 + min(pow(widen_scale * d, widen_power), widen_max)
uniform float widen_power = 4.0;
uniform float widen_max = 70.0;
// Per-blade variety (see header "PER-BLADE VARIETY").
uniform float height_clumping : hint_range(0.0, 1.0) = 0.5; // clump noise vs per-blade hash for height (GodotGrass: 0.8)
uniform vec2 stature_range = vec2(0.7, 1.25); // per-blade height multiplier, skewed toward the low end
uniform vec2 width_range = vec2(0.5, 1.25); // per-blade width multiplier (was 0.6-1.0)
uniform vec2 taper_range = vec2(0.6, 1.3); // upper-blade width: <1 = needle-like, >1 = broad leaf
// Short blades (see header "SHORT BLADES FACE EVERY WAY"): height factor at/below x = fully
// "short" (random yaw + extra lean), at/above y = a normal clump-aligned blade.
uniform vec2 short_height = vec2(0.45, 0.7);
uniform float short_lean : hint_range(0.0, 0.3) = 0.12; // extra bend, x PI, at the tip
uniform vec2 short_face_range = vec2(5.0, 15.0); // m from the camera: random yaw closer than x, facing the camera from y
uniform float short_face_jitter = 0.44; // rad (+-25 deg) of per-blade yaw kept when facing the camera

group_uniforms GrassColor;
// 2026-10-02 (Kirill, tuning panel, for the lantern): base, tip and dry base lightened --
// were (0.05, 0.2, 0.01), (0.30, 0.42, 0.10), (0.22, 0.17, 0.06).
uniform vec3 base_color : source_color = vec3(0.061, 0.242, 0.012);
uniform vec3 tip_color : source_color = vec3(0.390, 0.559, 0.103); // before 0.30/0.42/0.10: (0.5, 0.5, 0.1) -- see header
uniform vec3 subsurface_scattering_color : source_color = vec3(0.35, 0.55, 0.12); // see header (moon fix)
uniform vec3 dry_base_color : source_color = vec3(0.348, 0.266, 0.090);
uniform vec3 dry_tip_color : source_color = vec3(0.58, 0.50, 0.26); // was (0.75, 0.62, 0.30)
// How much of tip_color / dry_tip_color reaches the blade tips (see header "NO BRIGHT TIPS").
// 0 = base colour root to tip (the fix), 1 = the full GodotGrass base->tip gradient.
uniform float tip_blend : hint_range(0.0, 1.0) = 0.0;
// The same, for short blades only (see header "SHORT BLADE TIPS").
uniform float short_tip_blend : hint_range(0.0, 1.0) = 0.35;
// Direct light on a face pointing straight away from the light (see header "BACKLIGHT FLOOR").
uniform float backlight_floor : hint_range(0.0, 0.5) = 0.08;
// 1 = colours as authored, 0 = greyscale (see header "BLADE SATURATION").
uniform float blade_saturation : hint_range(0.0, 1.0) = 1;
// Sky/reflection strength on the blades (see header "SKY-REFLECTION SHEEN"). Engine default 0.5.
uniform float blade_specular : hint_range(0.0, 1.0) = 0.0;
// Ambient/indirect light on the blades (see header "BLADE AMBIENT").
// 1 = full engine ambient at the tips; the root always gets 25% of this.
uniform float blade_ambient : hint_range(0.0, 1.0) = 0.5;
// Per-blade colour jitter (see header "PER-BLADE VARIETY"). 0 = every blade the same colour.
uniform float color_variation : hint_range(0.0, 0.5) = 0.15; // brightness +-
uniform float hue_variation : hint_range(0.0, 1.0) = 0.5; // bluish-green <-> yellowish-green

varying float v_dry;
varying float v_short; // 1 = short blade (gap layer / patch rim), 0 = full-height blade
varying vec2 v_jitter; // per-blade (brightness, hue) hashes for fragment()

// Source: https://www.shadertoy.com/view/Xt3cDn
float hash12(vec2 x) {
	uvec2 p = floatBitsToUint(x);
	p = 1103515245U * ((p >> 1U) ^ (p.yx));
	uint h32 = 1103515245U * ((p.x) ^ (p.y >> 3U));
	uint n = h32 ^ (h32 >> 16U);
	return float(n) * (1.0 / float(0xffffffffU));
}

mat3 rotate_x(float angle) {
	float s = sin(angle), c = cos(angle);
	return mat3(vec3(1, 0, 0), vec3(0, c, s), vec3(0, -s, c));
}

mat3 rotate_y(float angle) {
	float s = sin(angle), c = cos(angle);
	return mat3(vec3(c, 0, -s), vec3(0, 1, 0), vec3(s, 0, c));
}

mat4 modelview_inverse(mat4 modelview_matrix) {
	mat3 rotation_inv = transpose(mat3(modelview_matrix));
	mat4 modelview_inv = mat4(rotation_inv);
	modelview_inv[3] = vec4(-(rotation_inv * modelview_matrix[3].xyz), 1.0);
	return modelview_inv;
}

float ease_in_quartic(float x) {
	float a = x * x;
	return a * a;
}

float ease_out_quartic(float x) {
	float a = 1.0 - x;
	float b = a * a;
	return 1.0 - b * b;
}

void vertex() {
	vec3 root = MODEL_MATRIX[3].xyz;
	float tall = INSTANCE_CUSTOM.z;
	float height_scale = INSTANCE_CUSTOM.w;
	v_dry = smoothstep(0.45, 0.75, INSTANCE_CUSTOM.y); // was (0.30, 0.60) -- see header

	float height_factor = 1.0 - UV.y;
	float hash0 = hash12(root.xz);
	float hash1 = hash12(-root.zx);
	// Extra independent hashes (see header "PER-BLADE VARIETY") so size, shape, bend and colour
	// don't all move together.
	float hash_stature = hash12(root.xz + vec2(13.7, 71.3));
	float hash_width = hash12(root.zx + vec2(47.1, 5.9));
	float hash_taper = hash12(root.xz - vec2(29.3, 88.7));
	float hash_bend = hash12(-root.xz + vec2(61.9, 23.1));
	v_jitter = vec2(hash12(root.zx - vec2(7.7, 39.1)), hash12(root.xz + vec2(91.3, 3.7)));
	float clump0 = texture(clump_noise, root.zx * 0.075).x;
	float clump1 = texture(clump_noise, root.xz * 0.5).x;
	float clump2 = texture(clump_noise, -root.zx * 0.035).x;

	// --- GRASS BLADE HEIGHT/WIDTH ---
	vec3 camera_offset = root - CAMERA_POSITION_WORLD;
	float camera_distance = length(camera_offset);
	float height_offset = mix(height_range.x, height_range.y, mix(hash0, clump0, height_clumping));
	height_offset *= mix(0.6, 1.35, tall) * height_scale;
	// Stature: pow skews toward short -- mostly mid blades with the odd taller stalk poking out.
	height_offset *= mix(stature_range.x, stature_range.y, pow(hash_stature, 1.5));

	// Width + taper. Fades to a plain 1.0 with the wind fade: far blades are widened slabs where
	// the variety isn't visible, and grass_cull.glsl's overhang cap assumes the base width there.
	float wind_fade = 1.0 - smoothstep(wind_fade_start, wind_fade_end, camera_distance);
	float width_mul = mix(1.0, mix(width_range.x, width_range.y, hash_width), wind_fade);
	float taper = mix(1.0, mix(taper_range.x, taper_range.y, hash_taper), wind_fade);
	VERTEX.x *= width_mul * mix(1.0, taper, height_factor);
	// The further the distance from the camera, the thicker the grass blade will
	// appear to account for decreasing density with distance (the blade layers thin out).
	// x INSTANCE_CUSTOM.x = the overhang cap's width factor (2026-09-29, see header; 1 = full width).
	VERTEX.x *= (1.0 + min(pow(widen_scale * camera_distance, widen_power), widen_max)) * INSTANCE_CUSTOM.x;
	VERTEX.y *= height_offset;
	vec3 vertex_model = VERTEX; // Vertex in model space before any rotations are applied

	// --- WIND ---
	// Wind fade (see header, computed above): 1 near the camera, 0 far away -- far blades hold still.
	vec2 to_player = player_position.xz - root.xz;
	float player_distance = length(to_player) / crush_radius * 0.9;
	float crushed_factor = min(player_distance * player_distance * 1.2, 1.0);
	crushed_factor = mix(1.0, crushed_factor, 1.0 - smoothstep(crush_height * 0.6, crush_height, abs(player_position.y - root.y)));

	float turn_angle_base = (mix(-0.15, 0.15, hash0) + clump2 * clumping_factor) * TAU;
	// Short blades face every way and lean more (see header "SHORT BLADES FACE EVERY WAY").
	float shortness = 1.0 - smoothstep(short_height.x, short_height.y, height_scale);
	v_short = shortness;
	float short_angle = hash12(root.zx + vec2(17.3, 53.9)) * TAU;
	// ... and past short_face_range.x m they turn to show the camera their face. The blade's +Z
	// points AWAY from the camera, so the bend leans the tip away and tilts the face up toward an
	// eye above it (cull_disabled: either side draws). Shortest-arc blend, so a blade never spins
	// the long way round as the player approaches.
	float face_angle = atan(camera_offset.x, camera_offset.z) + (hash1 - 0.5) * 2.0 * short_face_jitter;
	float facing = smoothstep(short_face_range.x, short_face_range.y, camera_distance);
	short_angle += (mod(face_angle - short_angle + PI, TAU) - PI) * facing;
	turn_angle_base = mix(turn_angle_base, short_angle, shortness);
	float wind_angle = wind_direction(root.xz);
	float wind_strength = wind_gust_raw(root.xz, 0.0) * crushed_factor;
	wind_strength *= wind_strength;
	wind_strength *= mix(0.6, 0.7, hash1) * wind_speed * wind_fade;
	mat3 grass_rotate = rotate_y(mix(turn_angle_base, wind_angle, wind_strength));

	// Own hash (was hash1, shared with width) so thin blades don't all bend alike; range widened (0.12-0.25).
	float bend_angle_base = (mix(0.10, 0.30, hash_bend + height_offset * 0.1) + short_lean * shortness) * PI * height_factor;
	// We sample wind noise identically to strength, but with a time offset based on
	// the height to simulate the turbulence as the grass blade shakes from the wind.
	float wind_strength_turbulence = wind_gust_raw(root.xz, height_factor * height_factor * 0.25);
	wind_strength_turbulence *= wind_strength_turbulence;
	wind_strength_turbulence *= mix(0.16, 0.25 * hash0, clump1) * PI * min(wind_speed, 1.0) * wind_fade;
	mat3 grass_bend = rotate_x(mix(0.45 * PI, bend_angle_base + wind_strength_turbulence, crushed_factor));

	// Apply rotations to the vertex and the whole tangent frame (see header).
	mat3 grass_rotation_matrix = grass_rotate * grass_bend;
	VERTEX = grass_rotation_matrix * VERTEX;
	NORMAL = grass_rotation_matrix * NORMAL;
	TANGENT = grass_rotation_matrix * TANGENT;
	BINORMAL = grass_rotation_matrix * BINORMAL;

	// --- VIEW SPACE THICKENING ---
	// Grass blades perpendicular to the camera will appear very thin. We stretch
	// these blades horizontally in view space to make them appear more 'full'.
	vec3 vertex_view = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 normal_world = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float dot_nv = dot(normalize(normal_world), normalize(camera_offset));

	// The direction of thickening in view space will be based on the x-coordinate
	// sign of the vertex position in model space. We multiply by a large factor
	// and round to correct for precision errors from positions at x=0.
	float thicken_direction = sign(round((grass_rotate * vertex_model).x * 1e6));
	float thicken_factor = ease_in_quartic(1.0 - abs(dot_nv)) * abs(vertex_model.x);
	vertex_view.x += thicken_factor * thicken_direction;
	VERTEX = (modelview_inverse(MODELVIEW_MATRIX) * vec4(vertex_view, 1.0)).xyz;
}

void fragment() {
	// MSAA can shade edge pixels outside the triangle -> extrapolated UV (see header). Clamp.
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));

	float fog_factor = exp(-length(VERTEX) * 0.017);
	mat3 normal_offset = rotate_y(mix(-0.12, 0.12, uv.x) * PI);
	NORMAL = normalize(normal_offset * NORMAL);
	// Blend far grass toward a "visible face" normal -- halfway between up and the camera -- not
	// straight up (see header "DISTANCE NORMAL TARGET"; assumes up is 0,1,0 in view space).
	vec3 far_normal = normalize(vec3(0.0, 1.0, 0.0) + VIEW);
	NORMAL = normalize(mix(far_normal, NORMAL, fog_factor));

	vec3 b = mix(base_color, dry_base_color, v_dry);
	vec3 t = mix(tip_color, dry_tip_color, v_dry);
	// No bright tips by default (see header "NO BRIGHT TIPS"): tip_blend 0 = base colour to the tip.
	// Short blades keep some tip colour, spread over the upper half (see header "SHORT BLADE TIPS").
	float short_tip = short_tip_blend * v_short;
	t = mix(b, t, max(tip_blend, short_tip));
	float height_factor = 1.0 - uv.y;
	ALBEDO = mix(b, t, mix(ease_in_quartic(height_factor), height_factor * height_factor, v_short));
	ALBEDO *= mix(0.1, 1.0, height_factor * height_factor); // AO
	// Color becomes more uniform as distance increases
	ALBEDO = mix(mix(b, t, 0.5) * 0.5, ALBEDO, fog_factor);
	// Per-blade colour jitter (see header "PER-BLADE VARIETY"), faded with fog_factor so far
	// grass stays even instead of speckling. Brightness is symmetric around 1 (no net brightening).
	vec3 hue_tint = mix(vec3(0.88, 1.0, 1.12), vec3(1.15, 1.0, 0.82), v_jitter.y);
	vec3 jitter = mix(vec3(1.0), hue_tint, hue_variation) * (1.0 + color_variation * (v_jitter.x * 2.0 - 1.0));
	ALBEDO *= mix(vec3(1.0), jitter, fog_factor);
	// Desaturate toward luminance (see header "BLADE SATURATION").
	float albedo_luma = dot(ALBEDO, vec3(0.2126, 0.7152, 0.0722));
	ALBEDO = mix(vec3(albedo_luma), ALBEDO, blade_saturation);

	ROUGHNESS = mix(1.0, 0.4, ease_out_quartic(height_factor));
	ANISOTROPY = 0.85;
	SPECULAR = blade_specular; // sky-reflection sheen off (see header)
	// Sky occlusion by neighbouring blades: root sees ~25% of the sky, tip all of it, x the
	// blade_ambient control (see header "BLADE AMBIENT"). AO_LIGHT_AFFECT 0 = direct light untouched.
	AO = blade_ambient * mix(0.25, 1.0, height_factor);
	AO_LIGHT_AFFECT = 0.0;
}

void light() {
	// Wrap diffuse (see header "TOP-SIDE NEON FIX" / "BACKLIGHT FLOOR"): backlight_floor facing
	// away -> 0.75 facing the light. GodotGrass's pow(4.0, N.L) / 4.0 spanned 1/16 -> 1.0.
	float diffuse_factor = mix(backlight_floor, 0.75, dot(NORMAL, LIGHT) * 0.5 + 0.5);
	// Narrow back-light lobe (see header "FACING-THE-MOON FIX"): only near the light direction.
	float sss_lobe = max(-dot(VIEW, LIGHT), 0.0);
	sss_lobe *= sss_lobe;
	float sss_factor = sss_lobe * sss_lobe * 0.2; // pow(lobe, 4) x 0.2 (was linear x 0.3)
	DIFFUSE_LIGHT += (diffuse_factor + sss_factor * subsurface_scattering_color) * ATTENUATION * LIGHT_COLOR;
	SPECULAR_LIGHT *= diffuse_factor;
}
