// The sea of low cloud that closes a section of the valley (FarEndView; PROTOTYPE 2026-10-21).
//
// A box of cloud, drawn from its inside faces (so it also works with the camera in it): every
// pixel works out the stretch of its view ray inside the box -- cut short by whatever opaque
// surface the depth buffer has there -- and marches it front to back in a few steps. The cloud's
// top is a U across the valley (bank_top_at, fog_bank_top.gdshaderinc): low over the floor, high
// over the side ridges, and it curves up along the valley toward the castle, as if lying on
// rising ground. On that top lie a slow large swell (`top_wander`) and billows (`billow_*`); the
// cloud is eased in over `front_fade` m from its south face. Dense from any distance: the player
// sees a wall of cloud, not a view that fogs up as they walk closer (Kirill).
//
// Lit by the moon (unshaded, its own light): bright just under the top, most where a billow
// faces the moon (`moon_toward`), darkening to `fog_color` deeper in. (A flat fog of one colour
// until 2026-10-21; Kirill: "it could be haze, low clouds, anything that completely blocks the
// view".)
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_front, shadows_disabled, fog_disabled;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 box_min;
uniform vec3 box_max;
/// Deep in the cloud, its moonlit top, and its top's sides turned from the moon.
uniform vec3 fog_color : source_color = vec3(0.2, 0.235, 0.31);
uniform vec3 top_color : source_color = vec3(0.3, 0.35, 0.45);
uniform vec3 shade_color : source_color = vec3(0.24, 0.28, 0.37);
/// Direction TO the moon (world), and how far under the top its light reaches, m.
uniform vec3 moon_toward = vec3(0.0, 1.0, 0.0);
uniform float light_depth = 60.0;
/// Cloud per m of view ray where it is thickest.
uniform float density = 0.03;
/// World z of the bank's south face, and the m north of it over which the cloud thickens.
uniform float front_z = 0.0;
uniform float front_fade = 150.0;
/// The m under the top over which the cloud thins to nothing, and the swell of the top: how far
/// it wanders up and down, over what size, drifting how fast (m/s).
uniform float top_fade = 80.0;
uniform float top_wander = 30.0;
#include "res://shaders/fog_bank_top.gdshaderinc"
uniform float noise_scale = 600.0;
uniform vec2 drift = vec2(-4.0, -2.0);
/// The billows on the top: their height (m, up and down) and size (m).
uniform float billow_height = 35.0;
uniform float billow_scale = 180.0;
uniform vec2 billow_drift = vec2(-2.0, -1.0);
// 10 while the bank was about 1 km deep; it now reaches to the castle, about 4 km. The steps
// are offset per pixel, so their spacing shows as grain, not as bands.
const int STEPS = 32;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// The noise is one seamless tile: read at one size it repeats, and the billows came out as
// identical bands across the valley (Kirill, 2026-10-21). So three sizes that do not divide
// into each other, each turned its own way, their places pushed about by a slow broad noise,
// and their height varying from calm stretches to heaped ones.
const mat2 TURN_A = mat2(vec2(0.799, 0.602), vec2(-0.602, 0.799)); // 37 deg
const mat2 TURN_B = mat2(vec2(0.276, 0.961), vec2(-0.961, 0.276)); // 74 deg

// How far the top is raised at `xz` by the swell and the billows, m.
float top_bump(vec2 xz) {
	float swell = (texture(noise, (xz + drift * TIME) / noise_scale).r - 0.5) * 2.0 * top_wander;
	vec2 warp = vec2(texture(noise, xz / 950.0 + vec2(0.21, 0.63)).r, texture(noise, xz / 950.0 + vec2(0.78, 0.36)).r) - 0.5;
	vec2 q = xz + warp * 450.0 + billow_drift * TIME;
	float b = texture(noise, q / (billow_scale * 3.1)).r * 0.5
		+ texture(noise, TURN_A * q / (billow_scale * 1.27) + vec2(0.37, 0.11)).r * 0.32
		+ texture(noise, TURN_B * q / (billow_scale * 0.53) + vec2(0.59, 0.83)).r * 0.18;
	float puffs = smoothstep(0.25, 0.8, b); // rounded heads, flat between them
	float heap = mix(0.3, 1.4, smoothstep(0.3, 0.7, texture(noise, xz / 1700.0 + vec2(0.53, 0.17)).r));
	return swell + (puffs - 0.5) * 2.0 * billow_height * heap;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 dir = normalize(world_pos - cam);
	// Where the ray enters and leaves the box.
	vec3 inv = 1.0 / (dir + vec3(1e-6));
	vec3 t0 = (box_min - cam) * inv;
	vec3 t1 = (box_max - cam) * inv;
	vec3 t_near = min(t0, t1);
	vec3 t_far = max(t0, t1);
	float enter = max(max(max(t_near.x, t_near.y), t_near.z), 0.0);
	float leave = min(min(t_far.x, t_far.y), t_far.z);
	// ... and where it hits the opaque scene.
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	leave = min(leave, length(view.xyz / view.w));
	float span = leave - enter;
	if (span <= 0.0) {
		discard;
	}
	float step_length = span / float(STEPS);
	// Interleaved gradient noise: a different start within the first step for each pixel.
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float transmit = 1.0;
	vec3 colour = vec3(0.0);
	float facing = -1.0; // worked out once, where the ray first meets cloud
	for (int i = 0; i < STEPS; i++) {
		vec3 p = cam + dir * (enter + (float(i) + jitter) * step_length);
		float bump = top_bump(p.xz);
		float top = bank_top_at(p.xz) + bump;
		float under = top - p.y; // m under the cloud's top here
		float f = density * smoothstep(0.0, top_fade, under) * smoothstep(front_z, front_z - front_fade, p.z); // north is -Z
		if (f <= 0.0) {
			continue;
		}
		if (facing < 0.0) {
			// The top's slope here (the billows' and the swell's, not the U's): which way it faces.
			float e = billow_scale * 0.08;
			vec2 slope = vec2(top_bump(p.xz + vec2(e, 0.0)) - bump, top_bump(p.xz + vec2(0.0, e)) - bump) / e;
			facing = clamp(0.5 + 0.5 * dot(normalize(vec3(-slope.x, 1.0, -slope.y)), moon_toward), 0.0, 1.0);
		}
		float lit = exp(-max(under, 0.0) / light_depth);
		vec3 sample_colour = mix(fog_color, mix(shade_color, top_color, facing), lit);
		float absorbed = 1.0 - exp(-f * step_length);
		colour += transmit * absorbed * sample_colour;
		transmit *= 1.0 - absorbed;
		if (transmit < 0.01) {
			break;
		}
	}
	ALPHA = 1.0 - transmit;
	ALBEDO = ALPHA > 0.0 ? colour / ALPHA : fog_color;
}
