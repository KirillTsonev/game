// The valley's mountain walls (MountainWalls, scripts/terrain/mountain_walls.gd), 2026-10-08.
//
// The wall segments are coarse slices of a 8 km mountain: their own baked textures are about
// 0.6 m per pixel and stretched down the steep faces, far too soft up close. So the surface is a
// tiling rock texture projected from three sides (no stretching on any slope), and the baked maps
// only add what is larger than a tile: the baked colour as a brightness variation, the baked
// normal map as the big erosion shapes.
//
// Rows further back are hazed toward `haze_color` as a whole (`haze_amount`), and every row
// sinks into mist below `mist_clear_y` -- that is what separates one ridge line from the next.
shader_type spatial;
render_mode cull_back;

uniform sampler2D macro_albedo : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D macro_normal : hint_normal, filter_linear_mipmap, repeat_disable;
uniform float macro_normal_strength = 0.6;
/// How far the baked colour's brightness moves the rock colour (0 = not at all).
uniform float macro_shade = 0.6;
/// The baked colour map's average brightness: what counts as "no change".
uniform float macro_mean = 0.17;

uniform sampler2D detail_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
/// Size of one detail tile near the camera and far from it, m. Two sizes, cross-faded by distance,
/// so the tiling does not turn into a visible pattern on a distant face.
uniform float detail_size_near = 14.0;
uniform float detail_size_far = 60.0;
uniform float detail_far_start = 120.0;
uniform float detail_far_end = 400.0;
uniform float detail_normal_strength = 1.0;
uniform vec3 tint : source_color = vec3(0.55, 0.6, 0.7);

/// Ground gentle enough to carry forest is tinted toward `forest_color` (a stand-in for trees).
uniform vec3 forest_color : source_color = vec3(0.03, 0.06, 0.035);
uniform float forest_amount = 0.0;
uniform float forest_slope_none = 0.62; // normal.y at / below this: bare rock
uniform float forest_slope_full = 0.82;

/// Snow: from `snow_line_y` (world height), complete `snow_fade` m higher, on ground whose
/// normal.y is above the two slope limits. The line is moved up and down by the baked colour's
/// brightness, so it follows the mountain's own gullies and ribs.
uniform vec3 snow_color : source_color = vec3(0.72, 0.78, 0.9);
uniform float snow_line_y = 100000.0;
uniform float snow_fade = 140.0;
uniform float snow_slope_none = 0.45;
uniform float snow_slope_full = 0.72;
uniform float snow_line_wander = 90.0;
/// Faint rock layers: bands of this height (m), this strong, tilted and bent a little.
uniform float strata_period = 26.0;
uniform float strata_strength = 0.1;

uniform vec3 haze_color : source_color = vec3(0.2, 0.235, 0.31);
uniform vec3 mist_color : source_color = vec3(0.3, 0.35, 0.45);
uniform float haze_amount = 0.0;
/// World height at / below which the surface is fully in mist, and above which it is clear.
uniform float mist_full_y = -1000.0;
uniform float mist_clear_y = -999.0;
uniform float mist_amount = 0.0;
/// The veil (haze + mist) is air between the eye and the mountain, not paint on the rock: none
/// on a surface nearer than `veil_near` m, all of it from `veil_far` m.
uniform float veil_near = 120.0;
uniform float veil_far = 600.0;
/// A row that stands on the terrain (which has no veil of its own) starts clear where it meets
/// it and gains its veil over `veil_ramp` m going back from world x = `veil_ramp_x`, toward -X
/// (`veil_ramp_side` = 1) or +X (-1). 0 = no ramp.
uniform float veil_ramp = 0.0;
uniform float veil_ramp_x = 0.0;
uniform float veil_ramp_side = 1.0;

/// Clouds clinging to the slopes (2026-10-09): drifting patches of veil in a band of heights,
/// on top of the even mist below it. Paint on the surface, like the mist -- they cannot hang in
/// the gaps between peaks. `cloud_amount` 0 = off (and the default: the noise must be set first).
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform float cloud_amount = 0.0;
uniform vec3 cloud_color : source_color = vec3(0.38, 0.43, 0.54);
/// Size of one noise tile on the mountain, m, and the drift in m per second (world x / z).
uniform float cloud_scale = 1100.0;
uniform vec2 cloud_drift = vec2(-5.5, -5.5);
/// Share of the band the clouds cover, and how soft their edges are (in noise value).
uniform float cloud_coverage = 0.5;
uniform float cloud_softness = 0.2;
/// The band of world heights the clouds sit in; its limits wander by a quarter of its height.
uniform float cloud_bottom_y = 0.0;
uniform float cloud_top_y = 1.0;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec3 world_tangent;
varying vec3 world_binormal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
	world_tangent = normalize(mat3(MODEL_MATRIX) * TANGENT);
	world_binormal = normalize(mat3(MODEL_MATRIX) * BINORMAL);
}

// The x / y of a normal-map pixel, whichever way it was compressed (z is rebuilt by the caller).
vec2 normal_xy(sampler2D map, vec2 uv) {
	return texture(map, uv).rg * 2.0 - 1.0;
}

// Colour projected from the three axes, weighted by how much the surface faces each.
vec3 triplanar_colour(sampler2D map, vec3 p, vec3 weights) {
	return texture(map, p.zy).rgb * weights.x + texture(map, p.xz).rgb * weights.y + texture(map, p.xy).rgb * weights.z;
}

// A world-space normal from the detail normal map projected the same way ("whiteout" blend:
// each projection's bump is added onto the surface normal `n` in that projection's plane).
vec3 triplanar_normal(sampler2D map, vec3 p, vec3 weights, vec3 n, float strength) {
	vec2 x = normal_xy(map, p.zy) * strength;
	vec2 y = normal_xy(map, p.xz) * strength;
	vec2 z = normal_xy(map, p.xy) * strength;
	vec3 nx = vec3(x + n.zy, n.x);
	vec3 ny = vec3(y + n.xz, n.y);
	vec3 nz = vec3(z + n.xy, n.z);
	return normalize(nx.zyx * weights.x + ny.xzy * weights.y + nz.xyz * weights.z);
}

void fragment() {
	// The mesh normal bent by the baked (large-scale) normal map.
	vec3 n = normalize(world_normal);
	vec2 m = (texture(macro_normal, UV).rg * 2.0 - 1.0) * macro_normal_strength;
	vec3 big = normalize(normalize(world_tangent) * m.x + normalize(world_binormal) * m.y + n * sqrt(max(1.0 - dot(m, m), 0.05)));

	vec3 weights = pow(abs(big), vec3(4.0));
	weights /= weights.x + weights.y + weights.z;
	float far = smoothstep(detail_far_start, detail_far_end, distance(world_pos, CAMERA_POSITION_WORLD));
	vec3 p_near = world_pos / detail_size_near;
	vec3 p_far = world_pos / detail_size_far;
	vec3 rock = mix(triplanar_colour(detail_albedo, p_near, weights), triplanar_colour(detail_albedo, p_far, weights), far);
	vec3 fine = normalize(mix(
		triplanar_normal(detail_normal, p_near, weights, big, detail_normal_strength),
		triplanar_normal(detail_normal, p_far, weights, big, detail_normal_strength), far));

	vec3 baked = texture(macro_albedo, UV).rgb;
	float shade = mix(1.0, dot(baked, vec3(0.333)) / macro_mean, macro_shade);
	vec3 colour = rock * tint * shade;
	float layer_height = world_pos.y + 0.12 * world_pos.z + 14.0 * sin(world_pos.z * 0.011 + world_pos.x * 0.007);
	colour *= 1.0 + strata_strength * sin(layer_height * 6.2832 / strata_period) * sin(layer_height * 6.2832 / (strata_period * 3.7) + 1.3);
	float forest = smoothstep(forest_slope_none, forest_slope_full, big.y) * forest_amount;
	colour = mix(colour, forest_color * shade, forest);
	float snow_height = world_pos.y + (dot(baked, vec3(0.333)) / macro_mean - 1.0) * snow_line_wander * macro_shade;
	float snow = smoothstep(snow_line_y, snow_line_y + snow_fade, snow_height) * smoothstep(snow_slope_none, snow_slope_full, big.y);
	colour = mix(colour, snow_color, snow);
	fine = normalize(mix(fine, big, snow * 0.8)); // snow lies smooth over the rock's fine detail

	float mist = (1.0 - smoothstep(mist_full_y, mist_clear_y, world_pos.y)) * mist_amount;
	float cloud = 0.0;
	if (cloud_amount > 0.0) {
		// Read from above, sheared by height so a steep face does not show vertical streaks.
		vec2 cloud_uv = (world_pos.xz + world_pos.y * vec2(0.45, 0.3) + cloud_drift * TIME) / cloud_scale;
		float density = texture(cloud_noise, cloud_uv).r * 0.65 + texture(cloud_noise, cloud_uv * 2.3 + vec2(0.37, 0.11)).r * 0.35;
		float span = cloud_top_y - cloud_bottom_y;
		float height = world_pos.y + (texture(cloud_noise, cloud_uv * 0.31 + vec2(0.5)).r - 0.5) * 0.5 * span;
		float band = smoothstep(cloud_bottom_y - span * 0.15, cloud_bottom_y + span * 0.2, height) * (1.0 - smoothstep(cloud_top_y - span * 0.35, cloud_top_y, height));
		float edge = 1.0 - cloud_coverage;
		cloud = smoothstep(edge - cloud_softness, edge + cloud_softness, density) * band * cloud_amount;
	}
	float veil = 1.0 - (1.0 - haze_amount) * (1.0 - mist) * (1.0 - cloud);
	veil *= smoothstep(veil_near, veil_far, distance(world_pos, CAMERA_POSITION_WORLD));
	if (veil_ramp > 0.0) {
		veil *= smoothstep(0.0, veil_ramp, (veil_ramp_x - world_pos.x) * veil_ramp_side);
	}
	ALBEDO = colour * (1.0 - veil);
	EMISSION = mix(mix(haze_color, mist_color, mist), cloud_color, cloud) * veil;
	ROUGHNESS = mix(0.92, 0.6, snow);
	SPECULAR = 0.25 * (1.0 - veil);
	NORMAL = normalize((VIEW_MATRIX * vec4(mix(fine, n, veil), 0.0)).xyz);
}
