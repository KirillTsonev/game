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
uniform float saturation : hint_range(0.0, 1.5) = 1.0;
// Leaf-coverage boost applied here instead of in the bake (trees, 2026-09-25), so it can be tuned
// live (PerfDebug keys). The tree atlases store true coverage; the understory ones are baked with
// their alpha as-is and keep the default 1.0.
uniform float alpha_gain : hint_range(0.0, 4.0) = 1.0;
// Distance-dependent fullness (trees, 2026-09-25): further away the impostor samples coarser mips,
// which average thin needles into faint alpha, so one gain can't fit both ends of the cross-fade.
// alpha_gain applies at gain_near_dist, alpha_gain_far at gain_far_dist and beyond, smooth between.
// alpha_gain_far < 0 = off (understory keeps the single alpha_gain).
uniform float alpha_gain_far : hint_range(-1.0, 4.0) = -1.0;
uniform float gain_near_dist = 130.0;
uniform float gain_far_dist = 170.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.9;
uniform vec3 backlight_color : source_color = vec3(0.0);
uniform float alpha_cutoff : hint_range(0.0, 1.0) = 0.5;
uniform float mip_alpha_scale : hint_range(0.0, 1.0) = 0.25;
uniform float shadow_alpha_cutoff : hint_range(0.0, 1.0) = 0.35;
uniform float shadow_mip_alpha_scale : hint_range(0.0, 2.0) = 0.6;
uniform float view_normal_mix : hint_range(0.0, 1.0) = 0.0;
// Baked object-space normals (trees, 2026-09-25): each pixel is lit with the real tree's normal, so
// the impostor darkens/brightens like the crown it replaces for any sun direction. Raw data (no
// source_color), encoded n*0.5+0.5, same atlas layout as albedo_tex.
uniform bool use_normal_tex = false;
uniform int normal_views = 4;  // planes in the atlas, left to right (TREE_IMPOSTOR_VIEWS)
uniform sampler2D normal_tex : filter_linear_mipmap, repeat_disable;

// Object -> view rotation. Taken in vertex(): there MODELVIEW_MATRIX already includes the
// Terrain3D multimesh instance transform (random yaw + scale).
varying vec3 mv_x;
varying vec3 mv_y;
varying vec3 mv_z;

void vertex() {
	mv_x = MODELVIEW_MATRIX[0].xyz;
	mv_y = MODELVIEW_MATRIX[1].xyz;
	mv_z = MODELVIEW_MATRIX[2].xyz;
}

float impostor_mip_level(vec2 uv, vec2 size) {
	vec2 dx = dFdx(uv * size);
	vec2 dy = dFdy(uv * size);
	float d = max(dot(dx, dx), dot(dy, dy));
	return max(0.0, 0.5 * log2(max(d, 1e-8)));
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	// saturation < 1 pulls the baked colour toward its grey (trees 2026-09-25: the unlit bake came
	// out more saturated than the lit real crowns at the 150 m switch, 0.66 vs 0.58 measured).
	vec3 c = mix(vec3(dot(tex.rgb, vec3(0.2126, 0.7152, 0.0722))), tex.rgb, saturation);
	ALBEDO = c * albedo_color;
	float mip = impostor_mip_level(UV, vec2(textureSize(albedo_tex, 0)));
	float gain = alpha_gain;
	if (alpha_gain_far >= 0.0) {
		gain = mix(alpha_gain, alpha_gain_far, smoothstep(gain_near_dist, gain_far_dist, length(VERTEX)));
	}
	ALPHA = min(tex.a * gain, 1.0) * (1.0 + mip * (IN_SHADOW_PASS ? shadow_mip_alpha_scale : mip_alpha_scale));
	ALPHA_SCISSOR_THRESHOLD = IN_SHADOW_PASS ? shadow_alpha_cutoff : alpha_cutoff;
	// view_normal_mix > 0 tilts the normal toward the camera (view space +Z): looking into the sun
	// the card then darkens like a real crown's silhouette instead of glowing (trees, 2026-09-25).
	vec3 up_v = (VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	if (use_normal_tex) {
		vec3 n_obj = texture(normal_tex, UV).rgb * 2.0 - 1.0;
		mat3 mv = mat3(mv_x, mv_y, mv_z);
		vec3 n = normalize(mv * n_obj);
		// Each plane shows the same image from both sides, but its normals were baked facing the
		// capture camera (plane k faced (sin a, 0, cos a), a = PI*k/views). Seen from the back side
		// they'd all face away -> black silhouettes with the sun behind the player (seen in-game
		// 2026-09-25). Mirror through the plane, like Godot's side check flips a real double-sided
		// leaf toward the viewer.
		float k = floor(clamp(UV.x, 0.0, 0.9999) * float(normal_views));
		float a = PI * k / float(normal_views);
		vec3 axis = normalize(mv * vec3(sin(a), 0.0, cos(a)));
		if (dot(axis, VIEW) < 0.0) {
			n = reflect(n, axis);
		}
		NORMAL = n;
	} else {
		NORMAL = normalize(mix(up_v, vec3(0.0, 0.0, 1.0), view_normal_mix));
	}
	ROUGHNESS = roughness;
	SPECULAR = 0.0;
	BACKLIGHT = backlight_color;
}
