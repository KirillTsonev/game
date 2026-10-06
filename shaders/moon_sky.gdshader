// Sky for main.tscn: the same gradient and light glow as Godot's ProceduralSkyMaterial (same
// maths, same defaults), plus a moon texture drawn where the DirectionalLight3D points.
// The light itself is not changed by anything here.
shader_type sky;
render_mode use_debanding;

uniform vec3 sky_top_color : source_color = vec3(0.385, 0.454, 0.55);
uniform vec3 sky_horizon_color : source_color = vec3(0.6463, 0.6558, 0.6708);
uniform float sky_curve : hint_range(0.0, 1.0) = 0.15;
uniform float sky_energy_multiplier = 1.0;

uniform vec3 ground_bottom_color : source_color = vec3(0.2, 0.169, 0.133);
uniform vec3 ground_horizon_color : source_color = vec3(0.6463, 0.6558, 0.6708);
uniform float ground_curve : hint_range(0.0, 1.0) = 0.02;
uniform float ground_energy_multiplier = 1.0;

// The glow around the light: how far it reaches (degrees) and how fast it fades.
uniform float sun_angle_max : hint_range(0.0, 360.0, 0.01) = 30.0;
uniform float sun_curve : hint_range(0.0, 1.0) = 0.15;
// Brightness of the glow at the moon's edge, as a share of the light's colour x energy.
uniform float glow_strength : hint_range(0.0, 4.0, 0.01) = 0.5;

// Square image of the moon on a transparent background.
uniform sampler2D moon_texture : source_color, filter_linear, repeat_disable;
// Angular width of the whole image, in degrees (the real moon is 0.5).
uniform float moon_size : hint_range(0.5, 45.0, 0.1) = 8.0;
// Multiplies the image, which is then tinted by the light's colour.
uniform float moon_brightness : hint_range(0.0, 32.0, 0.05) = 12.0;
uniform float moon_rotation : hint_range(-180.0, 180.0, 0.5) = 0.0;

// Stars: the sky is cut into cells (star_cells x star_cells on each of the six faces of a cube
// around the viewer), and each cell holds one possible star with its own fixed place, brightness,
// colour and rank. A star shows once star_amount has passed its rank, so raising star_amount adds
// stars and never moves or removes the ones already there. Drawn under the moon's glow, the moon
// and the clouds.
uniform float star_amount : hint_range(0.0, 1.0, 0.005) = 0.3;
uniform float star_cells : hint_range(4.0, 96.0, 1.0) = 28.0;
// Radius of the brightest stars, in degrees.
uniform float star_size : hint_range(0.02, 1.0, 0.01) = 0.16;
uniform float star_brightness : hint_range(0.0, 32.0, 0.05) = 4.0;
// The dimmest stars, as a share of the brightest ones' radius and brightness. The painterly
// effect removes dots smaller than its brush whatever their brightness, so the size floor is the
// one that keeps the dim stars on screen.
uniform float star_min_size : hint_range(0.1, 1.0, 0.01) = 0.85;
uniform float star_min_brightness : hint_range(0.0, 1.0, 0.01) = 0.5;
// Higher = fewer bright stars among the dim ones.
uniform float star_dim_bias : hint_range(1.0, 12.0, 0.1) = 5.0;
// 0 = all white, 1 = from blue-white to warm.
uniform float star_color_variety : hint_range(0.0, 1.0, 0.01) = 0.6;
// Share of a star's brightness that flickers, and how fast (rad/s).
uniform float star_twinkle : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float star_twinkle_speed : hint_range(0.0, 20.0, 0.1) = 3.0;
// Stars fade out below this height above the horizon (EYEDIR.y).
uniform float star_horizon_fade : hint_range(0.01, 0.5, 0.01) = 0.15;

// Four random numbers in 0..1 for a cell (Dave Hoskins' hash43).
vec4 star_hash(vec3 p) {
	vec4 p4 = fract(p.xyzx * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p4 += dot(p4, p4.wzxy + 33.33);
	return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

// The light of the star whose cell the direction `dir` falls in.
vec3 star_light(vec3 dir) {
	// The cube face `dir` points at: `major` is its axis, `side_u` / `side_v` span the face.
	vec3 a = abs(dir);
	vec3 major;
	vec3 side_u;
	vec3 side_v;
	if (a.x >= a.y && a.x >= a.z) {
		major = vec3(sign(dir.x), 0.0, 0.0);
		side_u = vec3(0.0, 1.0, 0.0);
		side_v = vec3(0.0, 0.0, 1.0);
	} else if (a.y >= a.z) {
		major = vec3(0.0, sign(dir.y), 0.0);
		side_u = vec3(1.0, 0.0, 0.0);
		side_v = vec3(0.0, 0.0, 1.0);
	} else {
		major = vec3(0.0, 0.0, sign(dir.z));
		side_u = vec3(1.0, 0.0, 0.0);
		side_v = vec3(0.0, 1.0, 0.0);
	}
	// Position on the face by angle (-1..1), so cells near the face's corners are not much smaller.
	vec2 face_pos = atan(vec2(dot(dir, side_u), dot(dir, side_v)) / dot(dir, major)) * (4.0 / PI);
	vec2 cell = floor((face_pos * 0.5 + 0.5) * star_cells);
	vec4 rnd = star_hash(vec3(cell, dot(major, vec3(1.0, 2.0, 3.0)) + 4.0));
	float rnd_a = fract(rnd.w * 17.3);
	float rnd_b = fract(rnd.w * 91.7);

	float rank = pow(rnd.w, star_dim_bias);
	float bright = mix(star_min_brightness, 1.0, rank);
	float radius = radians(star_size) * mix(star_min_size, 1.0, rank);
	// The star keeps its whole disc inside its cell, so no neighbouring cell has to be checked.
	float margin = min(radians(star_size) / (PI * 0.5 / star_cells), 0.45);
	vec2 star_pos = (cell + margin + rnd.xy * (1.0 - 2.0 * margin)) / star_cells * 2.0 - 1.0;
	vec2 t = tan(star_pos * (PI / 4.0));
	vec3 star_dir = normalize(major + side_u * t.x + side_v * t.y);

	float falloff = clamp(1.0 - length(dir - star_dir) / radius, 0.0, 1.0);
	float shown = clamp((star_amount - rnd.z) / 0.03, 0.0, 1.0);
	float twinkle = 1.0 + star_twinkle * sin(TIME * star_twinkle_speed * (0.6 + 0.8 * rnd_a) + rnd_b * TAU);
	vec3 tint = mix(vec3(1.0), mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.85, 0.7), rnd_a), star_color_variety);
	return tint * (star_brightness * bright * falloff * falloff * shown * twinkle);
}

// Clouds: two layers of one noise texture drifting across a flattened dome, drawn over the sky,
// the glow and the moon. scripts/cloud_sky.gd supplies the texture and the drift and switches them
// on (cloud_amount), and repeats cloud_density() on the CPU to dim the moonlight when a cloud is
// in front of the moon -- change the maths in both places.
uniform float cloud_amount : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform vec2 cloud_offset = vec2(0.0);
// Share of the sky the clouds fill, and how wide their edges are (in noise value).
uniform float cloud_coverage : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float cloud_softness : hint_range(0.01, 0.5, 0.01) = 0.18;
// Bigger = smaller clouds.
uniform float cloud_scale : hint_range(0.05, 2.0, 0.01) = 0.45;
// How much the thickest cloud hides what is behind it.
uniform float cloud_opacity : hint_range(0.0, 1.0, 0.01) = 0.85;
// Lower = the dome is flatter: clouds near the horizon look further away.
uniform float cloud_flatten : hint_range(0.02, 1.0, 0.01) = 0.15;
// Clouds fade out below this height above the horizon (EYEDIR.y).
uniform float cloud_horizon_fade : hint_range(0.01, 0.5, 0.01) = 0.12;
// Colour of a cloud away from the moon.
uniform vec3 cloud_color : source_color = vec3(0.07, 0.09, 0.15);
// Moonlight in the clouds around the moon: strength (x the light's colour) and the angle from
// the moon, in degrees, at which it has dropped to about a third. Thin edges catch the most.
uniform float cloud_moon_glow : hint_range(0.0, 8.0, 0.01) = 1.2;
uniform float cloud_moon_glow_angle : hint_range(1.0, 90.0, 0.5) = 14.0;

// 0 = clear sky, 1 = thick cloud, in the direction `dir` (above the horizon only).
float cloud_density(vec3 dir) {
	vec2 uv = dir.xz / (dir.y + cloud_flatten) * cloud_scale + cloud_offset;
	float n = texture(cloud_noise, uv).r * 0.65 + texture(cloud_noise, uv * 2.3 + cloud_offset * 0.6).r * 0.35;
	float edge = 1.0 - cloud_coverage;
	return smoothstep(edge - cloud_softness, edge + cloud_softness, n) * smoothstep(0.0, cloud_horizon_fade, dir.y);
}

void sky() {
	float v_angle = acos(clamp(EYEDIR.y, -1.0, 1.0));
	float c = 1.0 - v_angle / (PI * 0.5);
	vec3 sky = mix(sky_horizon_color, sky_top_color, clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0));
	sky *= sky_energy_multiplier;

	// Not in the sky's reflection map: points this small only add noise to it.
	if (star_amount > 0.0 && EYEDIR.y > 0.0 && !AT_CUBEMAP_PASS) {
		sky += star_light(EYEDIR) * smoothstep(0.0, star_horizon_fade, EYEDIR.y);
	}

	if (LIGHT0_ENABLED) {
		float facing = dot(LIGHT0_DIRECTION, EYEDIR);
		float sun_angle = acos(clamp(facing, -1.0, 1.0));
		float glow_max = radians(sun_angle_max);
		// The glow starts at the moon's edge (the disc fills 95 % of the image) and fades outward,
		// so it reads as light coming off the moon and not as a brighter spot behind it.
		float glow_start = max(LIGHT0_SIZE, radians(moon_size) * 0.5 * 0.95);
		if (sun_angle < glow_max) {
			float c2 = clamp((sun_angle - glow_start) / max(glow_max - glow_start, 0.0001), 0.0, 1.0);
			sky = mix(LIGHT0_COLOR * LIGHT0_ENERGY * glow_strength, sky, clamp(1.0 - pow(1.0 - c2, 1.0 / sun_curve), 0.0, 1.0));
		}

		// Moon: project the view direction onto the plane facing the light, so the image stays
		// upright and undistorted wherever the light is in the sky.
		vec3 world_up = abs(LIGHT0_DIRECTION.y) > 0.999 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
		vec3 moon_right = normalize(cross(world_up, LIGHT0_DIRECTION));
		vec3 moon_up = cross(LIGHT0_DIRECTION, moon_right);
		vec2 p = vec2(dot(EYEDIR, moon_right), dot(EYEDIR, moon_up)) / max(facing, 0.0001);
		p /= tan(radians(moon_size) * 0.5);
		float rot = radians(moon_rotation);
		p = mat2(vec2(cos(rot), sin(rot)), vec2(-sin(rot), cos(rot))) * p;
		vec2 moon_uv = vec2(p.x, -p.y) * 0.5 + 0.5;
		vec4 moon = texture(moon_texture, moon_uv);
		float inside = step(0.0, facing) * step(abs(p.x), 1.0) * step(abs(p.y), 1.0);
		sky = mix(sky, moon.rgb * LIGHT0_COLOR * moon_brightness, moon.a * inside);
	}

	if (cloud_amount > 0.0 && EYEDIR.y > 0.0) {
		float density = cloud_density(EYEDIR);
		vec3 cloud = cloud_color;
		if (LIGHT0_ENABLED) {
			float moon_angle = acos(clamp(dot(LIGHT0_DIRECTION, EYEDIR), -1.0, 1.0));
			cloud += LIGHT0_COLOR * cloud_moon_glow * exp(-moon_angle / radians(cloud_moon_glow_angle)) * mix(1.0, 0.3, density);
		}
		sky = mix(sky, cloud, density * cloud_opacity * cloud_amount);
	}

	c = (v_angle - (PI * 0.5)) / (PI * 0.5);
	vec3 ground = mix(ground_horizon_color, ground_bottom_color, clamp(1.0 - pow(1.0 - c, 1.0 / ground_curve), 0.0, 1.0));
	ground *= ground_energy_multiplier;

	COLOR = mix(ground, sky, step(0.0, EYEDIR.y));
}
