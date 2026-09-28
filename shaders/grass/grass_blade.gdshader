// Grass groundcover -- per-blade "Ghost of Tsushima" look (2026-09-25). Draw material for
// GrassField's BLADE layers (instances placed + culled by grass_cull.glsl).
//
// Port of GodotGrass's grass.gdshader by Ethan Truong (MIT, https://github.com/2Retr0/GodotGrass
// -- see credits.txt), kept as close to the original as possible: hash-driven blade width/height,
// clump-noise clumping of yaw/height/bend, scrolling-noise wind with height-offset turbulence,
// player crush, view-space thickening of blades seen edge-on, distance widening (their LOD
// compensation), base->tip colour with AO darkening, distance colour flattening, rounded normals,
// anisotropy, and their wrap-diffuse + subsurface light().
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
shader_type spatial;
render_mode cull_disabled, ensure_correct_normals;

uniform vec3 player_position = vec3(0.0, -1000.0, 0.0);

group_uniforms GrassProperties;
uniform float clumping_factor : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D clump_noise : repeat_enable, filter_linear;
uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform sampler2D wind_noise : repeat_enable, filter_linear;
uniform float wind_fade_start = 40.0; // m from the camera -- full wind sway closer than this
uniform float wind_fade_end = 80.0; // m -- no wind sway beyond this
uniform float crush_radius = 0.9; // m (horizontal) -- blades inside this lie down around the player
uniform float crush_height = 2.5; // m -- crush only when the player is within this height of the blade
uniform vec2 height_range = vec2(0.3, 0.8); // x the 0.75 m blade mesh (GodotGrass: 0.4-2.0)
uniform float widen_scale = 0.0333; // distance widening: 1 + min(pow(widen_scale * d, widen_power), widen_max)
uniform float widen_power = 4.0;
uniform float widen_max = 70.0;

group_uniforms GrassColor;
uniform vec3 base_color : source_color = vec3(0.05, 0.2, 0.01);
uniform vec3 tip_color : source_color = vec3(0.5, 0.5, 0.1);
uniform vec3 subsurface_scattering_color : source_color = vec3(1.0, 0.75, 0.1);
uniform vec3 dry_base_color : source_color = vec3(0.22, 0.17, 0.06);
uniform vec3 dry_tip_color : source_color = vec3(0.75, 0.62, 0.30);

varying float v_dry;

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
	float coverage = INSTANCE_CUSTOM.w;
	v_dry = smoothstep(0.30, 0.60, INSTANCE_CUSTOM.y);

	float height_factor = 1.0 - UV.y;
	float hash0 = hash12(root.xz);
	float hash1 = hash12(-root.zx);
	float clump0 = texture(clump_noise, root.zx * 0.075).x;
	float clump1 = texture(clump_noise, root.xz * 0.5).x;
	float clump2 = texture(clump_noise, -root.zx * 0.035).x;

	// --- GRASS BLADE HEIGHT/WIDTH ---
	vec3 camera_offset = root - CAMERA_POSITION_WORLD;
	float camera_distance = length(camera_offset);
	float height_offset = mix(height_range.x, height_range.y, mix(hash0, clump0, 0.8));
	height_offset *= mix(0.6, 1.35, tall) * mix(0.85, 1.0, coverage);

	VERTEX.x *= mix(0.6, 1.0, hash1);
	// The further the distance from the camera, the thicker the grass blade will
	// appear to account for decreasing density with distance (the blade layers thin out)
	VERTEX.x *= 1.0 + min(pow(widen_scale * camera_distance, widen_power), widen_max);
	VERTEX.y *= height_offset;
	vec3 vertex_model = VERTEX; // Vertex in model space before any rotations are applied

	// --- WIND ---
	// Wind fade (see header): 1 near the camera, 0 far away -- far blades hold still.
	float wind_fade = 1.0 - smoothstep(wind_fade_start, wind_fade_end, camera_distance);
	vec2 to_player = player_position.xz - root.xz;
	float player_distance = length(to_player) / crush_radius * 0.9;
	float crushed_factor = min(player_distance * player_distance * 1.2, 1.0);
	crushed_factor = mix(1.0, crushed_factor, 1.0 - smoothstep(crush_height * 0.6, crush_height, abs(player_position.y - root.y)));

	float turn_angle_base = (mix(-0.15, 0.15, hash0) + clump2 * clumping_factor) * TAU;
	float wind_direction = texture(wind_noise, root.zx * 0.005 / wind_speed + TIME * 0.005 * wind_speed).x * TAU;
	float wind_strength = mix(0.25, 1.0, texture(wind_noise, root.xz * 0.025 / wind_speed + TIME * 0.05).x) * crushed_factor;
	wind_strength *= wind_strength;
	wind_strength *= mix(0.6, 0.7, hash1) * wind_speed * wind_fade;
	mat3 grass_rotate = rotate_y(mix(turn_angle_base, wind_direction, wind_strength));

	float bend_angle_base = mix(0.12, 0.25, hash1 + height_offset * 0.1) * PI * height_factor;
	// We sample wind noise identically to strength, but with a time offset based on
	// the height to simulate the turbulence as the grass blade shakes from the wind.
	float wind_strength_turbulence = mix(0.25, 1.0, texture(wind_noise, root.xz * 0.025 / wind_speed + (TIME + height_factor * height_factor * 0.25) * 0.05).x);
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
	// Blend grass normal with terrain normal based on distance (assumes up is 0,1,0!)
	NORMAL = mix(vec3(0, 1, 0), NORMAL, fog_factor);

	vec3 b = mix(base_color, dry_base_color, v_dry);
	vec3 t = mix(tip_color, dry_tip_color, v_dry);
	float height_factor = 1.0 - uv.y;
	ALBEDO = mix(b, t, ease_in_quartic(height_factor));
	ALBEDO *= mix(0.1, 1.0, height_factor * height_factor); // AO
	// Color becomes more uniform as distance increases
	ALBEDO = mix(mix(b, t, 0.5) * 0.5, ALBEDO, fog_factor);

	ROUGHNESS = mix(1.0, 0.4, ease_out_quartic(height_factor));
	ANISOTROPY = 0.85;
}

void light() {
	float diffuse_factor = pow(4.0, dot(NORMAL, LIGHT)) / 4.0; // Diffuse never drops to 0 to simulate ambient bounces
	float sss_factor = max(-dot(VIEW, LIGHT), 0.0) * 0.5;
	DIFFUSE_LIGHT += (diffuse_factor + sss_factor * subsurface_scattering_color) * ATTENUATION * LIGHT_COLOR;
	SPECULAR_LIGHT *= diffuse_factor;
}
