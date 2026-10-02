// Boulder / scree material with a HIGHLIGHT CAP (2026-10-02).
//
// Kirill: with the lantern and the post effects on, some rocks glowed -- the pale sets from every
// side, others where lantern and moon overlap. Measured (tools/assign_flat_textures.gd
// diag_rock_averages): not gloss (roughness 0.66-0.92 everywhere); the albedo textures have pale,
// chalky parts that land above UnrealBloom's threshold once lit. Darkening whole rocks changes
// their colour; this darkens only the pale PARTS: albedo luminance above cap_knee is compressed
// toward cap_limit (soft, exponential shoulder, hue kept). Darker texels are untouched.
//
// Otherwise this is StandardMaterial3D as the rock materials use it (albedo x colour, normal map,
// roughness texture in R, optional AO texture in R, Burley diffuse + GGX specular), so the
// lighting matches the saved .tres materials. tools/setup_rock_assets.gd setup_highlight_cap()
// builds one <name>_capped_material.tres per standard rock / scree material and makes it the
// Terrain3DMeshAsset override, with cap_knee / cap_limit from its HIGHLIGHT_CAP_* constants (tune
// there and re-run). For scale (linear luminance): ordinary boulders average 0.10-0.14, Ground 0.13.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;
uniform sampler2D texture_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform sampler2D texture_ao : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float ao_light_affect : hint_range(0.0, 1.0) = 0.0;

// Linear albedo luminance. Below cap_knee: unchanged. Above: approaches cap_limit, never passes it.
uniform float cap_knee : hint_range(0.0, 1.0) = 0.15;
uniform float cap_limit : hint_range(0.0, 1.0) = 0.24;

void fragment() {
	vec3 c = albedo.rgb * texture(texture_albedo, UV).rgb;
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	float room = max(cap_limit - cap_knee, 0.0001);
	float capped = luma < cap_knee ? luma : cap_knee + room * (1.0 - exp(-(luma - cap_knee) / room));
	ALBEDO = c * (capped / max(luma, 0.0001));

	METALLIC = 0.0;
	SPECULAR = specular;
	ROUGHNESS = texture(texture_roughness, UV).r * roughness;
	NORMAL_MAP = texture(texture_normal, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	AO = texture(texture_ao, UV).r;
	AO_LIGHT_AFFECT = ao_light_affect;
}
