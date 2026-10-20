// Fireflies (2026-10-19, TRIAL): one glowing dot per MultiMesh instance, drawn by FireflyField
// (scripts/terrain/firefly_field.gd). The dots light nothing, the bloom gives the halo; the light
// on the ground comes from FireflyField's OmniLight3Ds.
// Per instance: the transform's origin = the firefly's home, COLOR = its colour,
// INSTANCE_CUSTOM.x = its swarm's row in swarm_state, .y = a random 0..1 seed.
// swarm_state (one column per swarm, written by FireflyField): row 0 r = scatter 0..1 (linear in
// time; the easing and stagger are worked out here per firefly), g / b = the world x / z where the
// player was when the swarm took off; row 1 r = the nearest a home can be from that point, g = how
// much farther the farthest can be, b = how high the swarm climbs (m). The take-offs run outward
// from that point as a wave (Kirill, 2026-10-20: "the ones closest to the player rise first"). The
// whole swarm climbs by one height (Kirill, 2026-10-20), each firefly drifting sideways away from
// the player as it goes (flee_side_*, same day): its own 3-4 m (flee_up_*, picked per swarm by FireflyField), or more, set by
// FireflyField, when the player stands high beside it (on a cliff or outcrop).
// Everything else -- hover, blink, flight, distance fade -- happens here, with no script work.
// FireflyField repeats the motion and the blink in script for the few fireflies it gives a light
// (2026-10-20), so the two must stay the same: the random numbers are an integer hash of
// INSTANCE_ID (a fract(sin()) hash differs between the GPU's 32-bit floats and GDScript), the
// time is `clock`, set by the script each frame (shaders' TIME cannot be read in script), and any
// change to the motion below must be made in FireflyField._position / _flash as well.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D swarm_state : filter_nearest;
uniform float clock = 0.0; // s, set by FireflyField every frame
uniform float energy = 6.0; // brightness at a flash's peak (the bloom threshold is 0.6)
uniform float size = 0.1; // m, half the dot's width up close
uniform float min_angle = 0.0025; // rad, the dot is never narrower than this (no sub-pixel shimmer); its brightness falls instead
uniform float hover_radius = 0.6; // m, how far a firefly wanders from its home
uniform float hover_speed = 0.35;
uniform float blink_floor = 0.15; // glow between flashes, share of the peak
uniform float blink_rate = 0.3; // flashes per second (each firefly a bit faster or slower)
uniform float blink_width = 7.0; // larger = shorter flashes
uniform float flee_up_min = 3.0; // m, straight up (one value per swarm, between these; FireflyField picks it and may raise it)
uniform float flee_up_max = 4.0;
uniform float flee_jitter = 0.3; // m, how much one firefly's climb differs from its swarm's
// While climbing, each firefly also drifts sideways AWAY from where the player stood at take-off
// (Kirill, 2026-10-20), by this much at the top (one value per firefly, between these).
uniform float flee_side_min = 2.0; // m
uniform float flee_side_max = 4.0;
uniform float flee_side_spread = 35.0; // deg, each firefly's direction turned off the away-line by up to this either side
uniform float flee_stagger = 0.5; // share of the flight over which the fireflies' take-offs are spread (0 = all at once); each flies the rest, 1 - this
uniform float flee_wave_noise = 0.15; // share of a take-off's moment that is random instead of by distance from the player (0 = a clean ring)
uniform float flee_wobble = 0.12; // m, a quick flutter mid-flight, gone again at either end
uniform float flee_wobble_speed = 3.0; // flutters a second
// A fleeing firefly fades out as it climbs, gone at the top, and back in on the way down (Kirill,
// 2026-10-20). The share of its climb before the fade starts (0 = from take-off).
uniform float flee_fade_start = 0.0;
uniform float fade_start = 60.0; // m from the camera
uniform float fade_end = 80.0;

varying vec3 v_colour;
varying float v_glow;

// Integer hash (lowbias32); FireflyField._hash32 is the same in script.
uint hash32(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

// 0..1 for an id and a salt (one salt per kind of number); exact in 32-bit floats too.
float rand01(uint id, uint salt) {
	return float(hash32(hash32(id) ^ salt) >> 8u) / 16777216.0;
}

// Slow out of 0, fastest at 0.5, slow into 1 (gentler at both ends than smoothstep).
float smootherstep01(float x) {
	x = clamp(x, 0.0, 1.0);
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

void vertex() {
	vec3 home = MODEL_MATRIX[3].xyz;
	float seed = INSTANCE_CUSTOM.y;
	uint id = uint(INSTANCE_ID);
	vec3 h = vec3(rand01(id, 1u), rand01(id, 2u), rand01(id, 3u));
	vec3 g = vec3(rand01(id, 4u), rand01(id, 5u), rand01(id, 6u)) * TAU;

	float t = clock * hover_speed;
	vec3 drift = vec3(
		sin(t * (0.7 + 0.6 * h.x) + g.x) + 0.5 * sin(t * (1.9 + h.y) + g.y),
		0.5 * sin(t * (0.5 + 0.5 * h.z) + g.z) + 0.25 * sin(t * (1.3 + h.x) + g.x),
		sin(t * (0.8 + 0.5 * h.y) + g.y) + 0.5 * sin(t * (1.7 + h.z) + g.z)) * (hover_radius / 1.5);

	vec4 state = texelFetch(swarm_state, ivec2(int(INSTANCE_CUSTOM.x + 0.5), 0), 0);
	// This firefly's own part of the swarm's flight: it takes off later than the swarm's start
	// (up to flee_stagger) and every firefly flies for the same share (1 - flee_stagger), so all
	// climb at one speed and the late ones arrive last (Kirill, 2026-10-20: flying the rest faster
	// "yanked" the late ones up). Up, and sideways only away from the player (first straight up,
	// "only up, not spread, not bunch up"; then "scatter to the side as they rise", both 2026-10-20).
	int swarm = int(INSTANCE_CUSTOM.x + 0.5);
	vec4 wave = texelFetch(swarm_state, ivec2(swarm, 1), 0);
	float order = clamp((distance(home.xz, state.gb) - wave.r) / max(wave.g, 0.001), 0.0, 1.0);
	float start = mix(order, rand01(id, 7u), flee_wave_noise) * flee_stagger;
	float own = clamp((state.r - start) / (1.0 - flee_stagger), 0.0, 1.0);
	float climb = smootherstep01(own);
	float swarm_up = wave.b; // the same for every firefly of the swarm
	float own_jitter = (rand01(id, 8u) - 0.5) * 2.0 * flee_jitter;
	vec2 away = home.xz - state.gb;
	float side_rand = rand01(id, 10u);
	away = dot(away, away) > 0.0001 ? normalize(away) : vec2(cos(side_rand * TAU), sin(side_rand * TAU));
	float turn = (rand01(id, 11u) - 0.5) * 2.0 * radians(flee_side_spread);
	away = vec2(away.x * cos(turn) - away.y * sin(turn), away.x * sin(turn) + away.y * cos(turn));
	vec2 side = away * mix(flee_side_min, flee_side_max, side_rand) * climb;
	vec3 flee = vec3(side.x, (swarm_up + own_jitter) * climb, side.y);
	// The hover keeps its size; the flight only adds a quick flutter, largest mid-flight.
	float ft = clock * flee_wobble_speed;
	vec3 flutter = vec3(sin(ft * (1.0 + h.x) + g.z), sin(ft * (1.3 + h.y) + g.x), sin(ft * (0.9 + h.z) + g.y))
		* flee_wobble * 4.0 * own * (1.0 - own);
	vec3 world = home + drift + flutter + flee;

	float dist = distance(world, CAMERA_POSITION_WORLD);
	float fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	float r = max(size, dist * min_angle);
	float shrink = size / r;
	float phase = fract(clock * blink_rate * (0.7 + 0.6 * h.z) + seed * 7.0);
	float flash = exp(-pow((phase - 0.5) * blink_width, 2.0));
	float shown = 1.0 - clamp((climb - flee_fade_start) / max(1.0 - flee_fade_start, 0.001), 0.0, 1.0);
	fade *= shown;
	v_glow = (blink_floor + (1.0 - blink_floor) * flash) * shrink * shrink * fade * energy;
	v_colour = COLOR.rgb;

	vec4 view = VIEW_MATRIX * vec4(world, 1.0);
	view.xy += VERTEX.xy * 2.0 * r * step(0.0001, fade); // a 1 x 1 quad; a faded-out one collapses to a point
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d2 = dot(p, p);
	float glow = (exp(-d2 * 10.0) + 0.2 * exp(-d2 * 3.0)) * clamp(1.0 - d2, 0.0, 1.0);
	ALBEDO = v_colour * v_glow;
	ALPHA = glow;
}
