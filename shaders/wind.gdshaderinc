// The wind field (2026-10-06) -- one scrolling noise texture read at a world position, shared by
// the grass (shaders/grass/grass_blade.gdshader, where these formulas come from: GodotGrass) and
// the foliage (shaders/foliage/foliage_cutout.gdshaderinc), so a gust that flattens the grass
// reaches the plants standing in it at the same moment. Change a formula here and both follow.
// The texture is FoliageWind.noise_texture() (scripts/terrain/foliage_wind.gd); GrassField and
// FoliageWind hand it to their materials.

uniform float wind_speed : hint_range(0.0, 5.0) = 1.0;
uniform sampler2D wind_noise : repeat_enable, filter_linear;

// Direction the wind pushes toward at `xz`, as an angle: the push is (sin a, 0, cos a). Varies over
// ~200 m and drifts slowly.
float wind_direction(vec2 xz) {
	return texture(wind_noise, xz.yx * 0.005 / wind_speed + TIME * 0.005 * wind_speed).x * TAU;
}

// Unsquared gust strength at `xz`, 0.25 (calm) to 1 (gust), `time_lead` seconds ahead of now.
// Patches about 3 m wide travelling at about 2.8 m/s. Callers square it (after any factor of their
// own), which is what makes the wind mostly calm with short bursts.
float wind_gust_raw(vec2 xz, float time_lead) {
	return mix(0.25, 1.0, texture(wind_noise, xz * 0.025 / wind_speed + (TIME + time_lead) * 0.05).x);
}
