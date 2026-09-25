// Impostor BAKE only (tools/setup_understory_assets.gd bake_impostors, tools/setup_tree_assets.gd
// bake_tree_impostors): renders a plant's albedo x tint (x vertex colour if enabled) with a hard
// cutout at mip 0, unlit, onto a transparent background.
// normal_pass (trees, 2026-09-25): writes the surface normal instead -- object space (the mesh sits
// at the origin, so world = object), encoded n*0.5+0.5. NORMAL is already flipped for back faces
// here (cull_disabled side check), i.e. exactly the normal the real tree is lit with. Pre-linearised
// because the viewport converts linear -> sRGB on output; this way the PNG holds the raw encoding.
// opaque: no texture/cutout (bark surfaces in the normal pass).
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_linear;
uniform vec3 albedo_color : source_color = vec3(1.0);
uniform bool use_vertex_color = false;
uniform bool normal_pass = false;
uniform bool opaque = false;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void fragment() {
	vec4 t = opaque ? vec4(1.0) : textureLod(albedo_tex, UV, 0.0);
	if (use_vertex_color && !opaque) {
		t *= COLOR;
	}
	if (t.a < 0.5) {
		discard;
	}
	if (normal_pass) {
		vec3 n = normalize(mat3(INV_VIEW_MATRIX) * NORMAL);
		ALBEDO = srgb_to_linear(n * 0.5 + 0.5);
	} else {
		ALBEDO = t.rgb * albedo_color;
	}
}
