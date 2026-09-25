// Foliage cutout -- shared body for alpha-tested leaf cards (understory + tree leaf cards, 2026-09-25).
// Included by foliage_cutout_double.gdshader (cull_disabled, single-layer cards) and
// foliage_cutout_back.gdshader (cull_back, double-layered meshes like fern_02).
//
// Why a custom shader instead of StandardMaterial3D (see docs/shadows.md):
//  * Mip-scaled alpha (Ben Golus' CalcMipLevel trick): mipmaps AVERAGE alpha, so sparse leaves
//    fall below the cutoff at small mips and vanish. alpha *= 1 + mip * scale pushes the
//    averaged alpha back over the cutoff -- density is kept at distance, mip 0 is untouched.
//  * The shadow pass (IN_SHADOW_PASS) samples coarse shadow texels -> small mips; with its own,
//    stronger boost and lower cutoff, near shadows stay leafy and far (coarse-cascade) shadows
//    become soft solid-ish blobs instead of fading out ~20 m ahead of the player.
// Mipmaps must be ON for the leaf diffuse (they are: vram import with mips).

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 albedo_color : source_color = vec3(1.0);
// Multiply the texel (rgb AND alpha) by the vertex colour -- same as StandardMaterial3D's
// vertex_color_use_as_albedo. The Fab pack trees tint their leaf cards this way.
uniform bool use_vertex_color = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_scale = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform vec3 backlight_color : source_color = vec3(0.0);
uniform sampler2D backlight_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;

// Visible pass.
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform float mip_alpha_scale : hint_range(0.0, 1.0) = 0.25; // Golus: ~0.25 keeps coverage
// Shadow pass only.
uniform float shadow_alpha_cutoff : hint_range(0.0, 1.0) = 0.35;
uniform float shadow_mip_alpha_scale : hint_range(0.0, 2.0) = 0.6;

// Mip level the hardware picks for `uv` on a texture of `size` texels (from screen-space
// derivatives -- in the shadow pass these are shadow-map texels, i.e. the cascade's coarseness).
float foliage_mip_level(vec2 uv, vec2 size) {
	vec2 dx = dFdx(uv * size);
	vec2 dy = dFdy(uv * size);
	float d = max(dot(dx, dx), dot(dy, dy));
	return max(0.0, 0.5 * log2(max(d, 1e-8)));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	if (use_vertex_color) {
		tex *= COLOR;
	}
	ALBEDO = tex.rgb * albedo_color;
	float mip = foliage_mip_level(UV, vec2(textureSize(albedo_tex, 0)));
	float scale = IN_SHADOW_PASS ? shadow_mip_alpha_scale : mip_alpha_scale;
	ALPHA = tex.a * (1.0 + mip * scale);
	ALPHA_SCISSOR_THRESHOLD = IN_SHADOW_PASS ? shadow_alpha_cutoff : alpha_cutoff;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	ROUGHNESS = roughness;
	BACKLIGHT = backlight_color * texture(backlight_tex, UV).rgb;
}
