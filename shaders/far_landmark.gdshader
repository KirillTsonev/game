// A landmark far beyond the built valley (TerrainCastle, FAR_END; PROTOTYPE 2026-10-21).
//
// It stands where there is no terrain and must stay in view through the fog that closes a
// section, so the scene's fog is off for it and it carries its own air instead, like the
// mountain rows (mountain_wall.gdshader): veiled as a whole toward `haze_color` (`haze_amount`),
// and sunk in mist below `mist_clear_y`, so its foot fades out instead of ending on nothing.
// It is drawn in the transparent pass (ALPHA 1, fully opaque) so its render_priority decides
// whether it comes before the fog bank (fog_bank.gdshader, hidden by it) or after (always seen).
shader_type spatial;
render_mode cull_back, fog_disabled, depth_draw_always;

uniform vec3 albedo : source_color = vec3(0.12, 0.12, 0.14);
uniform float roughness = 0.9;
uniform vec3 haze_color : source_color = vec3(0.2, 0.235, 0.31);
uniform vec3 mist_color : source_color = vec3(0.3, 0.35, 0.45);
uniform float haze_amount = 0.45;
/// World height at / below which the surface is fully in mist, and above which it is clear.
uniform float mist_full_y = 0.0;
uniform float mist_clear_y = 200.0;
uniform float mist_amount = 1.0;
// Not drawn below the fog bank's top (bank_reveal), so the bank shows there instead.
#include "res://shaders/fog_bank_top.gdshaderinc"

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float mist = (1.0 - smoothstep(mist_full_y, mist_clear_y, world_pos.y)) * mist_amount;
	float veil = 1.0 - (1.0 - haze_amount) * (1.0 - mist);
	ALBEDO = albedo * (1.0 - veil);
	EMISSION = mix(haze_color, mist_color, mist) * veil;
	ROUGHNESS = roughness;
	SPECULAR = 0.5 * (1.0 - veil);
	ALPHA = bank_reveal(world_pos);
}
