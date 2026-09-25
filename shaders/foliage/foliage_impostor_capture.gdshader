// Impostor BAKE only (tools/setup_understory_assets.gd bake_impostors): renders a plant's
// albedo x tint with a hard cutout at mip 0, unlit, onto a transparent background.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_linear;
uniform vec3 albedo_color : source_color = vec3(1.0);

void fragment() {
	vec4 t = textureLod(albedo_tex, UV, 0.0);
	if (t.a < 0.5) {
		discard;
	}
	ALBEDO = t.rgb * albedo_color;
}
