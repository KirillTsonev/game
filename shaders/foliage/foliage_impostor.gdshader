// Far-distance impostor for understory plants (2026-09-25): two crossed quads (4 tris) textured
// with a baked front + side view (<dir>/<name>_impostor.png, see tools/setup_understory_assets.gd).
// Same leaf-alpha handling as foliage_cutout.gdshaderinc (mip-scaled alpha + shadow-pass cutoff,
// docs/shadows.md). The normal is forced to world UP so the flat cards light like the ground
// cover around them (a double-sided quad would otherwise flip dark on its back face).
// specular_disabled: with an UP normal, looking toward a low sun makes every impostor a mirror
// -> a band of white blobs on the horizon (seen in-game 2026-09-25). Far plants need no highlight.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 albedo_color : source_color = vec3(1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform vec3 backlight_color : source_color = vec3(0.0);
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform float mip_alpha_scale : hint_range(0.0, 1.0) = 0.25;
uniform float shadow_alpha_cutoff : hint_range(0.0, 1.0) = 0.35;
uniform float shadow_mip_alpha_scale : hint_range(0.0, 2.0) = 0.6;

float impostor_mip_level(vec2 uv, vec2 size) {
	vec2 dx = dFdx(uv * size);
	vec2 dy = dFdy(uv * size);
	float d = max(dot(dx, dx), dot(dy, dy));
	return max(0.0, 0.5 * log2(max(d, 1e-8)));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	ALBEDO = tex.rgb * albedo_color;
	float mip = impostor_mip_level(UV, vec2(textureSize(albedo_tex, 0)));
	ALPHA = tex.a * (1.0 + mip * (IN_SHADOW_PASS ? shadow_mip_alpha_scale : mip_alpha_scale));
	ALPHA_SCISSOR_THRESHOLD = IN_SHADOW_PASS ? shadow_alpha_cutoff : alpha_cutoff;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	ROUGHNESS = roughness;
	SPECULAR = 0.0;
	BACKLIGHT = backlight_color;
}
