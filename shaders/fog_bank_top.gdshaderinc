// The top of the fog bank that closes a section (FarEndView; PROTOTYPE 2026-10-21), shared by
// the bank (fog_bank.gdshader) and by what is drawn after it and seen through it: the castle
// (far_landmark.gdshader) and the mountain rows behind it (mountain_wall.gdshader, through
// MountainWalls._far_drawn). FarEndView.set_bank_shape sets every uniform here.
//
// The top is a U across the valley: bank_floor_top_y between the floor's two edges (world x),
// rising to bank_top_y over bank_side_rise m outward from each; and all of it curves up along
// the valley by bank_curve_rise m from bank_curve_start_z to bank_curve_end_z (north = -Z), as
// pow(share of the way, bank_curve_power) -- level near, steepening toward the far end.
uniform float bank_top_y = 140.0;
uniform float bank_floor_top_y = 140.0;
uniform float bank_floor_x_low = 0.0;
uniform float bank_floor_x_high = 0.0;
uniform float bank_side_rise = 200.0;
uniform float bank_curve_start_z = 0.0;
uniform float bank_curve_end_z = -4000.0;
uniform float bank_curve_rise = 0.0;
uniform float bank_curve_power = 2.0;
/// What is seen through the bank is not drawn below its top (it would be painted over the fog,
/// Kirill: the gap between the section's end and the castle showed): hidden from bank_reveal_below
/// m under the top, fully shown from bank_reveal_above m over it.
uniform float bank_reveal_below = 100.0;
uniform float bank_reveal_above = 40.0;

float bank_top_at(vec2 xz) {
	float outside = max(max(bank_floor_x_low - xz.x, xz.x - bank_floor_x_high), 0.0);
	float along = clamp((bank_curve_start_z - xz.y) / (bank_curve_start_z - bank_curve_end_z), 0.0, 1.0);
	return mix(bank_floor_top_y, bank_top_y, smoothstep(0.0, bank_side_rise, outside)) + bank_curve_rise * pow(along, bank_curve_power);
}

// 0 = under the bank (not drawn), 1 = clear above it.
float bank_reveal(vec3 p) {
	float top = bank_top_at(p.xz);
	return smoothstep(top - bank_reveal_below, top + bank_reveal_above, p.y);
}
