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
// Colour strength of the texel around its own grey: 1 = as painted, above 1 = more vivid (the
// flowers, 2026-10-04: they got lost among the other foliage).
uniform float saturation : hint_range(0.0, 2.5) = 1.0;
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

// Wind sway (2026-10-06): the plant leans with the grass's own gust field (shaders/wind.gdshaderinc),
// read at the plant's root, so grass and plants move in the same gusts. All of it is set at run
// time by FoliageWind (scripts/terrain/foliage_wind.gd) for the understory and the flowers; a
// material nobody sets up keeps sway_amount 0 and stands still (the tree leaf cards, the editor).
#include "res://shaders/wind.gdshaderinc"
// m a point at sway_height moves in a full gust. 0 = no sway.
uniform float sway_amount = 0.0;
// m above the root (in the world, so after the plant's scale) where the sway reaches sway_amount.
// Lower points move in proportion; higher ones up to 1.5x.
uniform float sway_height = 1.0;
// Share of the sway a point on the plant's centre axis gets; points sway_height out to the side
// get all of it. 1 = the whole plant tilts from its root (flower stalks), lower = the middle of a
// bush holds still while its outer leaves move.
uniform float sway_core : hint_range(0.0, 1.0) = 1.0;
// Sideways wobble across the wind, as a share of the push along it.
uniform float sway_flutter : hint_range(0.0, 1.0) = 0.35;
// Speed of that wobble, rad/s (5 = about 0.8 Hz).
uniform float sway_speed = 5.0;
// Tree leaf / branch cards: each card sways about the point where it meets the bark, which stands
// still. Needs the per-card data build_pack_trees() bakes into UV2 (x = m from the attachment
// point, y = the card's phase); sway_height is then the card length that gets sway_amount, and
// sway_core is not used. The gust is read where the card is, not at the tree's root, so it
// travels through the crown as it does over the grass below.
uniform bool sway_cards = false;
// Same fade as the grass's (GrassField.wind_fade_*): full sway nearer than start, none past end.
uniform float wind_fade_start = 40.0;
uniform float wind_fade_end = 80.0;
// The view camera. Not CAMERA_POSITION_WORLD: in the shadow pass that is the light's camera, and
// the shadow would then sway differently from the plant casting it.
uniform vec3 sway_camera_position = vec3(0.0);

void vertex() {
	if (sway_amount > 0.0) {
		vec3 root = MODEL_MATRIX[3].xyz;
		float fade = 1.0 - smoothstep(wind_fade_start, wind_fade_end, distance(root, sway_camera_position));
		if (fade > 0.0) {
			// The scatter scales plants uniformly, so one basis column gives the scale.
			float scale_sq = dot(MODEL_MATRIX[0].xyz, MODEL_MATRIX[0].xyz);
			float scale = sqrt(scale_sq);
			// Each plant, and each part of it, wobbles out of step with its neighbours.
			float phase = fract(sin(dot(root.xz, vec2(12.9898, 78.233))) * 43758.5453) * TAU;
			vec2 at = root.xz;
			float weight;
			if (sway_cards) {
				at = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
				// sqrt(scale): a sapling (the same mesh at 0.13-0.3) bends more for its size than the tree.
				weight = min(UV2.x * sqrt(scale) / sway_height, 1.5);
				phase += UV2.y * TAU;
			} else {
				float height = min(max(VERTEX.y, 0.0) * scale / sway_height, 1.5);
				float reach = min(length(VERTEX.xz) * scale / sway_height, 1.0);
				weight = height * mix(sway_core, 1.0, reach);
				phase += (VERTEX.x + VERTEX.z) * scale * 4.0;
			}
			// Like a grass blade's tip, the far parts get the gust a moment early.
			float gust = wind_gust_raw(at, weight * weight * 0.25);
			gust *= gust;
			float angle = wind_direction(at);
			vec2 along = vec2(sin(angle), cos(angle));
			float strength = gust * sway_amount * weight * fade;
			vec2 push = (along + vec2(along.y, -along.x) * sin(TIME * sway_speed + phase) * sway_flutter) * strength;
			// A branch also bobs up and down.
			float bob = sway_cards ? sin(TIME * sway_speed * 0.8 + phase * 1.7) * sway_flutter * 0.5 * strength : 0.0;
			// World-space push -> model space (v * M = transpose(M) * v; / scale^2 makes it the inverse).
			VERTEX += (vec3(push.x, bob, push.y) * mat3(MODEL_MATRIX)) / scale_sq;
		}
	}
}

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
	vec3 c = max(mix(vec3(dot(tex.rgb, vec3(0.2126, 0.7152, 0.0722))), tex.rgb, saturation), vec3(0.0));
	ALBEDO = c * albedo_color;
	float mip = foliage_mip_level(UV, vec2(textureSize(albedo_tex, 0)));
	float scale = IN_SHADOW_PASS ? shadow_mip_alpha_scale : mip_alpha_scale;
	ALPHA = tex.a * (1.0 + mip * scale);
	ALPHA_SCISSOR_THRESHOLD = IN_SHADOW_PASS ? shadow_alpha_cutoff : alpha_cutoff;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	ROUGHNESS = roughness;
	BACKLIGHT = backlight_color * texture(backlight_tex, UV).rgb;
}
