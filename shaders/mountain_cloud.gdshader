// Cloud banks between the valley's mountain rows (MountainWalls._build_cloud_sheets), 2026-10-09.
//
// One large upright sheet per bank, standing along a row of mountains: see-through, cut from a
// drifting noise pattern in a band of heights, its ends and both edges of the band faded out.
// Where a mountain stands just behind the sheet the cloud thins out toward it (`proximity_fade`),
// so the sheet never shows as a hard line across a face; nearer mountains simply hide it. Unlike
// the clouds painted on the rows by mountain_wall.gdshader, these hang in the gaps between peaks
// and move against the mountains as the camera moves.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 cloud_color : source_color = vec3(0.38, 0.43, 0.54);
/// How much the thickest cloud hides of what is behind it.
uniform float cloud_amount = 0.7;
/// Share of the band under cloud, and how soft a cloud's edge is (in noise value).
uniform float cloud_coverage = 0.5;
uniform float cloud_softness = 0.22;
/// Size of one noise tile along the sheet, m; upward a tile is `tile_height` x that (below 1:
/// the patches come out wider than tall).
uniform float tile = 900.0;
uniform float tile_height = 0.6;
/// The world direction the sheet runs along, and the drift along it in m per second.
uniform vec3 along_axis = vec3(0.0, 0.0, 1.0);
uniform float drift = 5.0;
/// Where on the noise this sheet starts: different on every sheet.
uniform vec2 noise_offset = vec2(0.0);
/// The band of world heights the clouds sit in; its limits wander by a quarter of its height.
uniform float bottom_y = 0.0;
uniform float top_y = 100.0;
/// The sheet's two ends along `along_axis` (world coordinate) and the length they fade over, m.
uniform float end_low = -1000.0;
uniform float end_high = 1000.0;
uniform float end_fade = 250.0;
/// The cloud thins out over this many m in front of whatever stands behind it.
uniform float proximity_fade = 120.0;
/// None nearer to the camera than the first distance, all of it from the second, m.
uniform float near_fade_start = 150.0;
uniform float near_fade_end = 400.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float along = dot(world_pos, along_axis);
	vec2 uv = vec2(along + drift * TIME, world_pos.y / tile_height) / tile + noise_offset;
	float density = texture(cloud_noise, uv).r * 0.65 + texture(cloud_noise, uv * 2.3 + vec2(0.37, 0.11)).r * 0.35;
	float span = top_y - bottom_y;
	float height = world_pos.y + (texture(cloud_noise, uv * 0.31 + vec2(0.5)).r - 0.5) * 0.5 * span;
	float band = smoothstep(bottom_y, bottom_y + span * 0.3, height) * (1.0 - smoothstep(top_y - span * 0.45, top_y, height));
	float edge = 1.0 - cloud_coverage;
	float alpha = smoothstep(edge - cloud_softness, edge + cloud_softness, density) * band;
	alpha *= smoothstep(end_low, end_low + end_fade, along) * (1.0 - smoothstep(end_high - end_fade, end_high, along));

	// What is already drawn behind this pixel, in view space (z is negative in front of the camera).
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 behind = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	behind.xyz /= behind.w;
	alpha *= clamp(1.0 - smoothstep(behind.z + proximity_fade, behind.z, VERTEX.z), 0.0, 1.0);
	alpha *= smoothstep(near_fade_start, near_fade_end, distance(world_pos, CAMERA_POSITION_WORLD));

	ALBEDO = cloud_color * mix(0.8, 1.15, density);
	ALPHA = alpha * cloud_amount;
}
