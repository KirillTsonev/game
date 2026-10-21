// The top of the fog bank that closes a section (FarEndView; PROTOTYPE 2026-10-21), shared by
// the bank (fog_bank.gdshader) and by what is drawn after it and seen through it: the castle
// (far_landmark.gdshader) and the mountain rows behind it (mountain_wall.gdshader, through
// MountainWalls._far_drawn). FarEndView.set_bank_shape sets every uniform here.
//
// The top is a U across the valley -- bank_floor_top_y over the valley's floor, rising to
// bank_top_y over bank_side_rise m past its edges -- that follows the basin round all the
// valley's sections (ValleyPath.basin): at each place along the valley its floor's two edges and
// height are read from `bank_path` (R / G = low / high edge, m sideways from bank_middle_x, B =
// floor, m; texels from bank_path_from to bank_path_to m north of the map's north edge,
// bank_map_north_z).
uniform float bank_top_y = 140.0;
uniform float bank_floor_top_y = 140.0;
uniform float bank_middle_x = 0.0;
uniform float bank_side_rise = 200.0;
uniform float bank_map_north_z = 0.0;
uniform sampler2D bank_path : filter_linear, repeat_disable;
uniform float bank_path_from = 0.0;
uniform float bank_path_to = 1.0;
/// What is seen through the bank is not drawn below its top (it would be painted over the fog,
/// Kirill: the gap between the section's end and the castle showed): hidden from bank_reveal_below
/// m under the top, fully shown from bank_reveal_above m over it.
uniform float bank_reveal_below = 100.0;
uniform float bank_reveal_above = 40.0;

// The valley's floor at world z: its low and high edge (x, y; from bank_middle_x) and height (z).
vec3 bank_path_at(float z) {
	float u = clamp((bank_map_north_z - z - bank_path_from) / (bank_path_to - bank_path_from), 0.0, 1.0);
	return textureLod(bank_path, vec2(u, 0.5), 0.0).rgb;
}

float bank_top_at(vec2 xz) {
	vec3 path = bank_path_at(xz.y);
	float dx = xz.x - bank_middle_x;
	float outside = max(max(path.x - dx, dx - path.y), 0.0);
	return mix(bank_floor_top_y, bank_top_y, smoothstep(0.0, bank_side_rise, outside)) + path.z;
}

// 0 = under the bank (not drawn), 1 = clear above it.
float bank_reveal(vec3 p) {
	float top = bank_top_at(p.xz);
	return smoothstep(top - bank_reveal_below, top + bank_reveal_above, p.y);
}
