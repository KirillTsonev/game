// The sea of low cloud that closes a section of the valley (FarEndView; PROTOTYPE 2026-10-21).
//
// A box of cloud, drawn from its inside faces (so it also works with the camera in it): every
// pixel works out the stretch of its view ray inside the box -- cut short by whatever opaque
// surface the depth buffer has there -- and marches it front to back in a few steps. The cloud's
// top is a U across the valley (bank_top_at, fog_bank_top.gdshaderinc): low over the floor, high
// over the side ridges, its middle and height following the valley's sections (ValleyPath:
// shifted sideways, higher or lower), as if lying in the valley it hides. On that top lie a slow large swell (`top_wander`) and billows (`billow_*`); the
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
/// The front's bulges (front_bulge): the top's billows' and swell's height, times this, in m toward
/// the valley; worked out only within front_reach m north of front_z (past its fade). The box
/// reaches that far south of front_z too (FarEndView.BANK_FRONT_BULGE).
uniform float front_bulge_scale = 1.0;
uniform float front_reach = 150.0;/// The m under the top over which the cloud thins to nothing, and the swell of the top: how far
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
/// Glows in the cloud, lighting it from inside (FarEndView.LAVA_GLOWS / ICE_GLOWS /
/// FURNACE_GLOWS, 2026-10-21): up to 12. Each: `glow_points` = where (xyz) and how far its light
/// spreads (w, m); `glow_looks` = its colour (rgb, linear) and strength (a); `glow_times` = how it
/// behaves: x 0 = flashes (the lava zone's volcanoes, "like lightning shows through storm clouds"
/// -- Kirill: a dull steady glow, glow_steady of a flash, plus flashes at its own irregular
/// times), 1 = breathes (the ice zone: swells and fades over y s, z = its place in that cycle,
/// 0..1, never below breathe_low), 2 = beats (the farmland's furnaces: swells and sinks like slow
/// bellows every y s from z on, never below 0.3); w = how far it wanders (m), slowly.
uniform vec4 glow_points[12];
uniform vec4 glow_looks[12];
uniform vec4 glow_times[12];
uniform int glow_count = 0;
uniform float glow_steady = 0.08;
uniform float breathe_low = 0.15;
/// A breathing glow's light on slopes of the top turned away from the moon, as a share of its light
/// on those facing it.
uniform float breathe_shape_low = 0.25;
/// Flashes: one chance per this many s for each glow, taken this often (0..1), dying away at
/// this rate (1/s); some come twice.
uniform float flash_period = 2.5;
uniform float flash_chance = 0.45;
uniform float flash_decay = 6.0;
/// The delta's glowing water under the cloud (FarEndView.DELTA_*, 2026-10-21: the flooded zone, its
/// light moving where the lava's flashes and the ice's breathes): blue-green streaks stretched
/// along the valley (`delta_scale` m across, 3.5 x that along), meandering, drifting toward +Z at
/// `delta_flow` m/s, brighter deeper in and in the hollows between the puffs -- light from below.
/// Within a box round `delta_centre` (world xz) of half size `delta_half` (m), softened over
/// `delta_soft` m. 0 strength = none.
uniform vec3 delta_color : source_color = vec3(0.2, 0.85, 0.7);
uniform float delta_strength = 0.0;
uniform vec2 delta_centre = vec2(0.0);
uniform vec2 delta_half = vec2(500.0);
uniform float delta_soft = 300.0;
uniform float delta_scale = 220.0;
uniform float delta_flow = 6.0;
/// The farmland's lights under the cloud (FarEndView.FARM_*, 2026-10-21): lamplit farmsteads
/// seen through the mist -- in a grid of `farm_cell` m cells, a share `farm_chance` of them holds
/// a warm light `farm_radius` m across at a random spot in it, flickering gently and now and then
/// out for a while. Worked out once per pixel where its ray crosses the top (per step, lights this
/// small sparkled with the steps), shining from below. Within a box round `farm_centre` (world xz)
/// of half size `farm_half` (m), softened over `farm_soft` m. 0 strength = none.
uniform vec3 farm_color : source_color = vec3(1.0, 0.62, 0.28);
uniform float farm_strength = 0.0;
uniform vec2 farm_centre = vec2(0.0);
uniform vec2 farm_half = vec2(500.0);
uniform float farm_soft = 300.0;
uniform float farm_cell = 150.0;
uniform float farm_radius = 45.0;
uniform float farm_chance = 0.45;
/// The dead land before the castle (FarEndView.DEAD_*, 2026-10-21): no light of its own -- the
/// cloud there is darker and colder, `dead_amount` (0..1) of its colour gone and the rest tinted
/// `dead_tint`, so the castle's own light is the only one left (Kirill: "if there will be any glow
/// it will come from the castle itself"). Within a box round `dead_centre` (world xz) of half size
/// `dead_half` (m), softened over `dead_soft` m. 0 amount = none.
uniform vec3 dead_tint : source_color = vec3(0.75, 0.8, 0.9);
uniform float dead_amount = 0.0;
uniform vec2 dead_centre = vec2(0.0);
uniform vec2 dead_half = vec2(1000.0);
uniform float dead_soft = 500.0;
// 10 while the bank was about 1 km deep; it now reaches to the castle, about 4 km. The steps
// are offset per pixel, so their spacing shows as grain, not as bands.
const int STEPS = 32;
// Halvings to find where a ray crosses the cloud's top (for its slope), once per pixel.
const int REFINE_STEPS = 5;

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

// The front's bulges toward the valley at (x, y) of its face, m (+ = south): the top's billows
// and swell, read across the upright face instead (so the front is cloud, not a flat wall).
float front_bulge(vec2 xy) {
	return top_bump(xy * vec2(1.0, 1.4) + vec2(3100.0, 7300.0)) * front_bulge_scale;
}

// Where the front's skin is at p (world z): front_z moved by its bulges, near the front only.
float front_skin(vec3 p) {
	return p.z > front_z - front_fade - front_reach ? front_z + front_bulge(p.xy) : front_z;
}

float glow_hash(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

float cell_hash(vec2 c) {
	return fract(sin(dot(c, vec2(127.1, 311.7))) * 43758.5453);
}

// The farm lights' light at xz (the nearest cells' lights: its own and the eight round it).
vec3 farm_light_at(vec2 xz) {
	if (farm_strength <= 0.0) {
		return vec3(0.0);
	}
	vec2 off = abs(xz - farm_centre) - farm_half;
	float inside = 1.0 - smoothstep(-farm_soft, farm_soft, max(off.x, off.y));
	if (inside <= 0.0) {
		return vec3(0.0);
	}
	vec2 home = floor(xz / farm_cell);
	float sum = 0.0;
	for (int dz = -1; dz <= 1; dz++) {
		for (int dx = -1; dx <= 1; dx++) {
			vec2 c = home + vec2(float(dx), float(dz));
			float h = cell_hash(c);
			if (h > farm_chance) {
				continue;
			}
			vec2 spot = (c + 0.2 + 0.6 * vec2(cell_hash(c + 17.3), cell_hash(c + 41.7))) * farm_cell;
			vec2 d = xz - spot;
			// Out about a sixth of the time, at its own moments, fading over a few seconds.
			float cycle = fract(TIME / (25.0 + h * 60.0) + h * 7.0);
			float on = smoothstep(0.0, 0.04, cycle) * (1.0 - smoothstep(0.82, 0.86, cycle));
			float flicker = 0.85 + 0.15 * sin(TIME * (2.0 + h * 5.0) + h * 40.0) * sin(TIME * (3.1 + h * 2.0) + h * 9.0);
			sum += exp(-dot(d, d) / (farm_radius * farm_radius)) * on * flicker * (0.6 + 0.4 * cell_hash(c + 5.1));
		}
	}
	return farm_color * farm_strength * inside * sum;
}

// How bright glow `seed`'s flash is at time t (0 between flashes): in each flash_period one may
// start, at a random moment, die away fast, and now and then strike again a moment later.
float flash(float t, float seed) {
	float cycles = t / flash_period + seed;
	float cell = floor(cycles);
	float h = glow_hash(cell + seed * 37.0);
	if (h > flash_chance) {
		return 0.0;
	}
	float local = (cycles - cell) * flash_period - glow_hash(cell * 1.7 + seed) * (flash_period - 0.6);
	if (local < 0.0) {
		return 0.0;
	}
	float brightness = 0.6 + 0.4 * glow_hash(cell + 0.5);
	float strike = exp(-local * flash_decay);
	float again = h < flash_chance * 0.35 ? step(0.15, local) * exp(-(local - 0.15) * flash_decay * 1.4) * 0.8 : 0.0;
	return (strike + again) * brightness;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	// Each glow's light this frame (its colour x strength x how bright it is now) and where it is
	// now, once per pixel.
	vec3 glow_now[12];
	vec3 glow_at[12];
	for (int k = 0; k < 12; k++) {
		glow_now[k] = vec3(0.0);
		glow_at[k] = glow_points[k].xyz;
		if (k >= glow_count) {
			continue;
		}
		vec4 times = glow_times[k];
		float bright;
		if (times.x < 0.5) {
			bright = glow_steady + flash(TIME, float(k) * 1.731 + 0.37);
		} else if (times.x < 1.5) {
			float breath = 0.5 - 0.5 * cos(6.2832 * (TIME / times.y + times.z));
			bright = mix(breathe_low, 1.0, breath * breath);
		} else {
			// Swells over a third of its cycle and sinks over the rest: slow bellows. (A quick double
			// pulse at first, read as flashes -- Kirill: "slower and softer".)
			float beat_phase = fract(TIME / times.y + times.z);
			float beat = beat_phase < 0.35 ? smoothstep(0.0, 0.35, beat_phase) : 1.0 - smoothstep(0.35, 1.0, beat_phase);
			bright = 0.3 + 0.7 * beat;
		}
		glow_now[k] = glow_looks[k].rgb * glow_looks[k].a * bright;
		// A slow wander: loops of a minute and more, each glow its own.
		float t = TIME * 0.09 + times.z * 6.2832 + float(k);
		glow_at[k] += times.w * vec3(sin(t), 0.15 * sin(t * 1.7), cos(t * 0.63));
	}
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
	float outside_t = enter; // the last place along the ray found outside the cloud
	float through_front = 0.0; // 1 = the ray came into the cloud through its front, 0 = through its top
	vec3 farm_light = vec3(0.0); // the farm lights under where the ray meets the cloud
	for (int i = 0; i < STEPS; i++) {
		float t = enter + (float(i) + jitter) * step_length;
		vec3 p = cam + dir * t;
		float bump = top_bump(p.xz);
		float top = bank_top_at(p.xz) + bump;
		float under = top - p.y; // m under the cloud's top here
		float skin = front_skin(p);
		float f = density * smoothstep(0.0, top_fade, under) * smoothstep(skin, skin - front_fade, p.z); // north is -Z
		if (f <= 0.0) {
			outside_t = t;
			continue;
		}
		if (facing < 0.0) {
			// Where the ray actually crossed the top, between the last step outside and this one:
			// halved a few times. Measured at the step itself, the slope (and the ice glows' shaping
			// by it) jumped from pixel to pixel with the steps' per-pixel offset -- grain (Kirill).
			float lo = outside_t;
			float hi = t;
			for (int r = 0; r < REFINE_STEPS; r++) {
				float mid = (lo + hi) * 0.5;
				vec3 q = cam + dir * mid;
				if (bank_top_at(q.xz) + top_bump(q.xz) - q.y > 0.0 && q.z < front_skin(q)) {
					hi = mid;
				} else {
					lo = mid;
				}
			}
			vec3 s = cam + dir * hi;
			float s_bump = top_bump(s.xz);
			// The top's slope there (the billows' and the swell's, not the U's): which way it faces.
			float e = billow_scale * 0.08;
			vec2 slope = vec2(top_bump(s.xz + vec2(e, 0.0)) - s_bump, top_bump(s.xz + vec2(0.0, e)) - s_bump) / e;
			float top_facing = clamp(0.5 + 0.5 * dot(normalize(vec3(-slope.x, 1.0, -slope.y)), moon_toward), 0.0, 1.0);
			// ... unless the ray came in through the bank's front: that face looks south, and the
			// top's slope above it, the same all the way down, drew upright streaks (Kirill). Which
			// face it was: just before the crossing the ray was above the top (came in through the
			// top) or under it (through the front). (Judged by depth under the top at first: over the
			// floor the whole front is only about 160 m tall, and most of it still took the top's.)
			vec3 before = cam + dir * lo;
			float before_under = bank_top_at(before.xz) + top_bump(before.xz) - before.y;
			// The front's own bulges (front_skin): its slope there, the face looking south.
			float s_skin = front_bulge(s.xy);
			vec2 front_slope = vec2(front_bulge(s.xy + vec2(e, 0.0)) - s_skin, front_bulge(s.xy + vec2(0.0, e)) - s_skin) / e;
			float front_facing = clamp(0.5 + 0.5 * dot(normalize(vec3(-front_slope.x, -front_slope.y, 1.0)), moon_toward), 0.0, 1.0);
			through_front = smoothstep(0.0, 30.0, before_under);
			farm_light = farm_light_at(s.xz);
			facing = mix(top_facing, front_facing, through_front);
		}
		// Seen through the front, the light under the top and the cloud's thinning toward it follow
		// the top without its puffs: with them, the puffs' pattern ran straight down the front too.
		float under_seen = under - bump * through_front;
		f = density * smoothstep(0.0, top_fade, under_seen) * smoothstep(skin, skin - front_fade, p.z);
		if (f <= 0.0) {
			continue;
		}
		// Lit just under the surface it came in through: the top, or (through the front) the front's
		// skin -- deeper in, the cloud's own colour (through the front, only the light under the top
		// at first: the whole front came out one flat grey -- Kirill).
		float lit_top = exp(-max(under_seen, 0.0) / light_depth);
		float lit_front = exp(-max(skin - p.z, 0.0) / light_depth);
		float lit = mix(lit_top, max(lit_top, lit_front), through_front);
		vec3 sample_colour = mix(fog_color, mix(shade_color, top_color, facing), lit);
		if (dead_amount > 0.0) {
			vec2 dead_off = abs(p.xz - dead_centre) - dead_half;
			float dead = 1.0 - smoothstep(-dead_soft, dead_soft, max(dead_off.x, dead_off.y));
			sample_colour = mix(sample_colour, sample_colour * dead_tint * (1.0 - dead_amount), dead);
		}
		for (int k = 0; k < glow_count; k++) {
			vec3 d = p - glow_at[k];
			// A breathing glow is shaded by the top's slope (`facing`), so the puffs' contours show
			// through its light (added flat, it washed them out to one bright spot -- Kirill).
			float shaped = abs(glow_times[k].x - 1.0) < 0.5 ? breathe_shape_low + (1.0 - breathe_shape_low) * facing : 1.0;
			sample_colour += glow_now[k] * shaped * exp(-dot(d, d) / (glow_points[k].w * glow_points[k].w));
		}
		sample_colour += farm_light * (0.3 + 0.7 * smoothstep(0.0, 120.0, under_seen)) * (1.0 - 0.5 * facing);
		if (delta_strength > 0.0) {
			vec2 off = abs(p.xz - delta_centre) - delta_half;
			float inside = 1.0 - smoothstep(-delta_soft, delta_soft, max(off.x, off.y));
			if (inside > 0.0) {
				vec2 q = vec2(p.x, p.z - delta_flow * TIME);
				float warp = texture(noise, q / (delta_scale * 6.0)).r - 0.5;
				vec2 uv = vec2((q.x + warp * delta_scale * 2.0) / delta_scale, q.y / (delta_scale * 3.5));
				float n = texture(noise, uv * 0.25).r * 0.6 + texture(noise, uv * 0.6 + vec2(0.3, 0.7)).r * 0.4;
				float streak = smoothstep(0.5, 0.75, n);
				float pulse = 0.75 + 0.25 * sin(TIME * 0.5 + q.y * 0.004);
				float from_below = 0.3 + 0.7 * smoothstep(0.0, 120.0, under_seen);
				float hollow = 1.0 - 0.6 * facing;
				sample_colour += delta_color * delta_strength * inside * streak * pulse * from_below * hollow;
			}
		}
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
