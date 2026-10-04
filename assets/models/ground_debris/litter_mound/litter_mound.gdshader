// Litter mounds: the Terrain3D PineLitter texture pair on a mesh, so a mound matches the litter
// painted on the ground under it.
// A custom shader, not StandardMaterial3D, on purpose: the normal sampler has NO hint_normal /
// roughness hint. Those hints make the editor "detect" the file as a normal map and reimport it
// as RG-only, which drops the packed roughness and breaks Terrain3D's same-format texture array.
//
// 2026-10-04 (Kirill: "the deadfall mounds are shiny and reflective"): sampling the same textures
// was not enough -- the terrain shader (scenes/main.tscn, end of fragment()) also derives specular
// and AO from them and halves the normal map, and the mounds did none of that:
//   SPECULAR  terrain = 1 - roughness (~0.12 for this texture, mean roughness 0.88); here it was
//             Godot's default 0.5, about four times the highlight.
//   normal    terrain uses the texture asset's normal_depth (0.5 for PineLitter); here it was 1.0.
//   AO        terrain darkens the low parts of the height map and dims direct light there; here none.
// These now copy the terrain's formulas. Keep them in step with that shader and with PineLitter's
// normal_depth / ao_strength (tools/assign_flat_textures.gd diag_uv_scale() prints both).
// Not copied: the terrain's colour map (macro tint x the shade under tree patches), so a mound can
// still read a little brighter than shaded ground around it.
shader_type spatial;

uniform sampler2D albedo_height : source_color, filter_linear_mipmap_anisotropic, repeat_enable; // A = height
uniform sampler2D normal_roughness : filter_linear_mipmap_anisotropic, repeat_enable; // OpenGL normal + roughness in A
uniform vec3 tint : source_color = vec3(1.0);
uniform float normal_depth = 0.5; // = PineLitter's Terrain3D normal_depth (was "normal_strength" = 1.0)
uniform float ao_strength = 0.5; // = PineLitter's Terrain3D ao_strength

void fragment() {
	vec4 ah = texture(albedo_height, UV);
	vec4 nr = texture(normal_roughness, UV);
	ALBEDO = ah.rgb * tint;
	NORMAL_MAP = nr.rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	ROUGHNESS = nr.a;
	SPECULAR = 1.0 - nr.a;
	// Terrain: higher and/or facing up = less occluded. `up` is its unpacked normal's up component.
	float up = nr.b * 2.0 - 1.0;
	float ao = (1.0 - (ah.a * log(2.1 - ao_strength))) * (1.0 - up);
	AO = clamp(1.0 - ao * ao_strength, ah.a, 1.0);
	AO_LIGHT_AFFECT = (1.0 - ah.a) * clamp(up, 0.0, 1.0);
}
