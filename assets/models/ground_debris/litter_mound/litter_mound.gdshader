// Litter mounds: the Terrain3D PineLitter texture pair on a mesh, so a mound matches the litter
// painted on the ground under it.
// A custom shader, not StandardMaterial3D, on purpose: the normal sampler has NO hint_normal /
// roughness hint. Those hints make the editor "detect" the file as a normal map and reimport it
// as RG-only, which drops the packed roughness and breaks Terrain3D's same-format texture array.
shader_type spatial;

uniform sampler2D albedo_height : source_color, filter_linear_mipmap_anisotropic, repeat_enable; // A = height, unused
uniform sampler2D normal_roughness : filter_linear_mipmap_anisotropic, repeat_enable; // OpenGL normal + roughness in A
uniform vec3 tint : source_color = vec3(1.0);
uniform float normal_strength = 1.0;

void fragment() {
	ALBEDO = texture(albedo_height, UV).rgb * tint;
	vec4 nr = texture(normal_roughness, UV);
	NORMAL_MAP = nr.rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = nr.a;
}
