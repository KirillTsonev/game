#include "terrain_kernels.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstdint>
#include <limits>
#include <mutex>
#include <thread>
#include <vector>

using namespace godot;

// GDScript's maxf() / minf() / mini(), as the engine defines them.
#define K_MAX(m_a, m_b) (((m_a) > (m_b)) ? (m_a) : (m_b))
#define K_MIN(m_a, m_b) (((m_a) < (m_b)) ? (m_a) : (m_b))

static const double K_TAU = 6.2831853071795864769252867666;

// GDScript's clampi().
static inline int64_t k_clampi(int64_t p_v, int64_t p_min, int64_t p_max) {
	return p_v < p_min ? p_min : (p_v > p_max ? p_max : p_v);
}

void TerrainKernels::_bind_methods() {
	ClassDB::bind_method(D_METHOD("get_version"), &TerrainKernels::get_version);
	ClassDB::bind_method(D_METHOD("erode", "heights", "width", "length", "rng", "iterations", "params"), &TerrainKernels::erode);
	ClassDB::bind_method(D_METHOD("mode_filter", "src", "width", "length", "radius", "road_mark"), &TerrainKernels::mode_filter);
	ClassDB::bind_method(D_METHOD("blend_borders", "dom", "spray", "road_control", "width", "length", "params"), &TerrainKernels::blend_borders);
	ClassDB::bind_method(D_METHOD("obstacle_distance", "mask", "width", "length", "cap"), &TerrainKernels::obstacle_distance);
	ClassDB::bind_method(D_METHOD("road_search", "heights", "width", "length", "cols", "rows", "start_node", "goal_node", "node_h", "node_blocked", "node_od", "row_pref", "offsets", "offset_dist", "offset_side", "params"), &TerrainKernels::road_search);
	ClassDB::bind_method(D_METHOD("knot_flood", "heights", "width", "length", "mesh_block", "x0", "z0", "bw", "bh", "walk_step"), &TerrainKernels::knot_flood);
	ClassDB::bind_method(D_METHOD("knot_first_clear_pair", "keys", "low_pts", "highs", "mesh_block", "top_mask", "width", "length", "bed_half", "rock_clear"), &TerrainKernels::knot_first_clear_pair);
	ClassDB::bind_method(D_METHOD("dilate", "src", "width", "length", "r"), &TerrainKernels::dilate);
	ClassDB::bind_method(D_METHOD("height_diff_mask", "a", "b", "threshold"), &TerrainKernels::height_diff_mask);
	ClassDB::bind_method(D_METHOD("count_changed_outside", "heights", "before", "width", "length", "circles"), &TerrainKernels::count_changed_outside);
	ClassDB::bind_method(D_METHOD("cliff_raise", "heights", "width", "length", "entries", "profile_heights", "profile_ranges", "warp_noise", "bump_noise", "consts", "seam_only"), &TerrainKernels::cliff_raise);
	ClassDB::bind_method(D_METHOD("paint_main", "ctx", "consts"), &TerrainKernels::paint_main);
	ClassDB::bind_method(D_METHOD("stamp_circles", "field", "width", "length", "circles", "cap"), &TerrainKernels::stamp_circles);
	ClassDB::bind_method(D_METHOD("road_vertex_circles", "control", "width", "length", "road_id", "min_blend"), &TerrainKernels::road_vertex_circles);
	ClassDB::bind_method(D_METHOD("height_min_max", "heights"), &TerrainKernels::height_min_max);
	ClassDB::bind_method(D_METHOD("grass_bake", "ctx", "consts"), &TerrainKernels::grass_bake);
	ClassDB::bind_method(D_METHOD("smooth", "heights", "width", "length", "passes", "radius"), &TerrainKernels::smooth);
	ClassDB::bind_method(D_METHOD("road_raster", "path", "width", "length", "edge_noise", "consts"), &TerrainKernels::road_raster);
	ClassDB::bind_method(D_METHOD("road_bed", "heights", "obst", "line", "prof", "width", "length", "consts"), &TerrainKernels::road_bed);
	ClassDB::bind_method(D_METHOD("apron_heights", "ctx", "consts"), &TerrainKernels::apron_heights);
	ClassDB::bind_method(D_METHOD("apron_colors", "ctx", "consts"), &TerrainKernels::apron_colors);
	ClassDB::bind_method(D_METHOD("north_heights", "ctx", "consts"), &TerrainKernels::north_heights);
	ClassDB::bind_method(D_METHOD("north_colors", "ctx", "consts"), &TerrainKernels::north_colors);
}

int TerrainKernels::get_version() const {
	return 9;
}

// GDScript's clampf() and lerpf().
static inline double k_clampf(double p_v, double p_min, double p_max) {
	return p_v < p_min ? p_min : (p_v > p_max ? p_max : p_v);
}
static inline double k_lerpf(double p_from, double p_to, double p_weight) {
	return p_from + (p_to - p_from) * p_weight;
}

// One cliff model's top profile, as CliffDressing's samplers read it.
struct KProfile {
	const float *heights = nullptr;
	int64_t n = 0;
	double x_min = 0.0;
	double x_max = 0.0;
};

// CliffDressing._sample_cliff_top_profile().
static double k_sample_profile(const KProfile &p_profile, double p_x) {
	const int64_t n = p_profile.n;
	if (n == 0) {
		return 0.0;
	}
	if (n == 1) {
		return p_profile.heights[0];
	}
	double t = 0.0;
	if (p_profile.x_max > p_profile.x_min) {
		t = k_clampf((p_x - p_profile.x_min) / (p_profile.x_max - p_profile.x_min), 0.0, 1.0);
	}
	const double f = t * double(n - 1);
	const int64_t i0 = k_clampi(int64_t(std::floor(f)), 0, n - 1);
	const int64_t i1 = k_clampi(i0 + 1, 0, n - 1);
	const double frac = f - double(i0);
	return k_lerpf(p_profile.heights[i0], p_profile.heights[i1], frac);
}

// CliffDressing._sample_cliff_top_profile_flanked().
static double k_sample_profile_flanked(const KProfile &p_profile, double p_x, double p_band_fraction) {
	const double base = k_sample_profile(p_profile, p_x);
	const int64_t n = p_profile.n;
	const double x_min = p_profile.x_min;
	const double x_max = p_profile.x_max;
	const double width = x_max - x_min;
	if (width <= 0.0 || n < 2) {
		return base;
	}
	const double band = p_band_fraction * width;
	const double step = width / double(n - 1);
	if (p_x <= x_min + band) {
		const double inner = x_min + band;
		double result = K_MAX(base, k_sample_profile(p_profile, inner));
		const double xc = K_MAX(p_x, x_min);
		result = K_MAX(result, k_sample_profile(p_profile, xc));
		for (int64_t i = 0; i < n; i++) {
			const double xi = x_min + step * double(i);
			if (xi >= xc && xi <= inner) {
				result = K_MAX(result, double(p_profile.heights[i]));
			}
		}
		return result;
	}
	if (p_x >= x_max - band) {
		const double inner = x_max - band;
		double result = K_MAX(base, k_sample_profile(p_profile, inner));
		const double xc = K_MIN(p_x, x_max);
		result = K_MAX(result, k_sample_profile(p_profile, xc));
		for (int64_t i = 0; i < n; i++) {
			const double xi = x_min + step * double(i);
			if (xi <= xc && xi >= inner) {
				result = K_MAX(result, double(p_profile.heights[i]));
			}
		}
		return result;
	}
	return base;
}

// What the script passes per entry of the plan, in this order.
enum {
	CR_PX,
	CR_PZ,
	CR_AXIS_X_X,
	CR_AXIS_X_Y,
	CR_AXIS_Z_X,
	CR_AXIS_Z_Y,
	CR_HALF_X,
	CR_HALF_Z,
	CR_PLATEAU_DEPTH,
	CR_FADE_DISTANCE,
	CR_INNER_RAMP,
	CR_JOINED_LEFT,
	CR_JOINED_RIGHT,
	CR_EDGE_LEFT,
	CR_EDGE_RIGHT,
	CR_SOFTNESS_LEFT,
	CR_SOFTNESS_RIGHT,
	CR_SCALE,
	CR_ORIGIN_Y,
	CR_TOP_LIFT,
	CR_JOIN_RISE_LEFT,
	CR_JOIN_RISE_RIGHT,
	CR_JOIN_RUN_LEFT,
	CR_JOIN_RUN_RIGHT,
	CR_GAP_LEFT,
	CR_GAP_RIGHT,
	CR_MIN_PX,
	CR_MAX_PX,
	CR_MIN_PZ,
	CR_MAX_PZ,
	CR_PROFILE,
	CLIFF_RAISE_ENTRY
};

// The two pixel loops of CliffDressing.raise_terrain_behind_cliff_dressing()
// (scripts/terrain/cliff_dressing.gd), operation for operation. The four sums are 32-bit floats
// as in the script, kept for the box round every entry's pixels only; a Vector2 dot product is
// 32-bit float arithmetic; the noise and smoothstep() are the engine's own.
Dictionary TerrainKernels::cliff_raise(PackedFloat32Array p_heights, int p_width, int p_length, const PackedFloat64Array &p_entries, const Array &p_profile_heights, const PackedFloat64Array &p_profile_ranges, const Ref<FastNoiseLite> &p_warp_noise, const Ref<FastNoiseLite> &p_bump_noise, const PackedFloat64Array &p_consts, bool p_seam_only) const {
	Dictionary result;
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_warp_noise.is_null() || p_bump_noise.is_null(), result);
	ERR_FAIL_COND_V(p_consts.size() != 11 || p_entries.size() % CLIFF_RAISE_ENTRY != 0, result);
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_heights.size() != width * length, result);
	ERR_FAIL_COND_V(p_profile_ranges.size() != p_profile_heights.size() * 2, result);

	const double edge_warp = p_consts[0];
	const double join_bridge_full = p_consts[1];
	const double join_blend = p_consts[2];
	const double join_ramp_back = p_consts[3];
	const double max_slope = p_consts[4];
	const double proximity_falloff = p_consts[5];
	const double flank_band_fraction = p_consts[6];
	const double seam_min_coverage = p_consts[7];
	const double seam_tolerance = p_consts[8];
	const double bump_max = p_consts[9];
	const double bump_fraction = p_consts[10];

	// The profiles: the arrays are held here so their pointers stay valid.
	std::vector<PackedFloat32Array> profile_arrays;
	std::vector<KProfile> profiles;
	for (int64_t i = 0; i < p_profile_heights.size(); i++) {
		profile_arrays.push_back(PackedFloat32Array(p_profile_heights[i]));
	}
	for (size_t i = 0; i < profile_arrays.size(); i++) {
		KProfile profile;
		profile.heights = profile_arrays[i].ptr();
		profile.n = profile_arrays[i].size();
		profile.x_min = p_profile_ranges[int64_t(i) * 2];
		profile.x_max = p_profile_ranges[int64_t(i) * 2 + 1];
		profiles.push_back(profile);
	}

	const int64_t entry_count = p_entries.size() / CLIFF_RAISE_ENTRY;
	const double *entries = p_entries.ptr();
	// The box every entry's pixels lie in.
	int64_t box_x0 = width;
	int64_t box_x1 = -1;
	int64_t box_z0 = length;
	int64_t box_z1 = -1;
	for (int64_t e = 0; e < entry_count; e++) {
		const double *v = entries + e * CLIFF_RAISE_ENTRY;
		ERR_FAIL_COND_V(v[CR_PROFILE] < 0 || int64_t(v[CR_PROFILE]) >= int64_t(profiles.size()), result);
		ERR_FAIL_COND_V(v[CR_MIN_PX] < 0 || v[CR_MAX_PX] >= width || v[CR_MIN_PZ] < 0 || v[CR_MAX_PZ] >= length, result);
		if (v[CR_MIN_PX] > v[CR_MAX_PX] || v[CR_MIN_PZ] > v[CR_MAX_PZ]) {
			continue;
		}
		box_x0 = K_MIN(box_x0, int64_t(v[CR_MIN_PX]));
		box_x1 = K_MAX(box_x1, int64_t(v[CR_MAX_PX]));
		box_z0 = K_MIN(box_z0, int64_t(v[CR_MIN_PZ]));
		box_z1 = K_MAX(box_z1, int64_t(v[CR_MAX_PZ]));
	}
	int64_t changed = 0;
	if (box_x1 < box_x0 || box_z1 < box_z0) {
		result["heights"] = p_heights;
		result["changed"] = changed;
		return result;
	}
	const int64_t bw = box_x1 - box_x0 + 1;
	const int64_t bh = box_z1 - box_z0 + 1;
	std::vector<float> w_sum(bw * bh, 0.0f);
	std::vector<float> wp_sum(bw * bh, 0.0f);
	std::vector<float> wl_sum(bw * bh, 0.0f);
	std::vector<float> keep(bw * bh, 1.0f);
	int64_t touched_x0 = width;
	int64_t touched_x1 = -1;
	int64_t touched_z0 = length;
	int64_t touched_z1 = -1;
	FastNoiseLite *warp_noise = p_warp_noise.ptr();
	FastNoiseLite *bump_noise = p_bump_noise.ptr();

	for (int64_t e = 0; e < entry_count; e++) {
		const double *v = entries + e * CLIFF_RAISE_ENTRY;
		const double px = v[CR_PX];
		const double pz = v[CR_PZ];
		const float axis_x_x = float(v[CR_AXIS_X_X]);
		const float axis_x_y = float(v[CR_AXIS_X_Y]);
		const float axis_z_x = float(v[CR_AXIS_Z_X]);
		const float axis_z_y = float(v[CR_AXIS_Z_Y]);
		const double half_x = v[CR_HALF_X];
		const double half_z = v[CR_HALF_Z];
		const double plateau_depth = v[CR_PLATEAU_DEPTH];
		const double fade_distance = v[CR_FADE_DISTANCE];
		const double inner_ramp = v[CR_INNER_RAMP];
		const bool joined_left = v[CR_JOINED_LEFT] != 0.0;
		const bool joined_right = v[CR_JOINED_RIGHT] != 0.0;
		const double effective_edge_left = v[CR_EDGE_LEFT];
		const double effective_edge_right = v[CR_EDGE_RIGHT];
		const double lateral_softness_left = v[CR_SOFTNESS_LEFT];
		const double lateral_softness_right = v[CR_SOFTNESS_RIGHT];
		const double scale_jitter = v[CR_SCALE];
		const double origin_y = v[CR_ORIGIN_Y];
		const double top_lift = v[CR_TOP_LIFT];
		const double join_rise_left = v[CR_JOIN_RISE_LEFT];
		const double join_rise_right = v[CR_JOIN_RISE_RIGHT];
		const double join_run_left = v[CR_JOIN_RUN_LEFT];
		const double join_run_right = v[CR_JOIN_RUN_RIGHT];
		const double nearest_gap_left = v[CR_GAP_LEFT];
		const double nearest_gap_right = v[CR_GAP_RIGHT];
		const int64_t min_px = int64_t(v[CR_MIN_PX]);
		const int64_t max_px = int64_t(v[CR_MAX_PX]);
		const int64_t min_pz = int64_t(v[CR_MIN_PZ]);
		const int64_t max_pz = int64_t(v[CR_MAX_PZ]);
		const KProfile &top_profile = profiles[int64_t(v[CR_PROFILE])];

		for (int64_t qz = min_pz; qz <= max_pz; qz++) {
			for (int64_t qx = min_px; qx <= max_px; qx++) {
				const float delta_x = float(double(qx) - px);
				const float delta_y = float(double(qz) - pz);
				const double local_x = delta_x * axis_x_x + delta_y * axis_x_y;
				const double local_z = delta_x * axis_z_x + delta_y * axis_z_y;
				const double d_behind = -local_z - half_z;
				double fade_warp = 1.0;
				if (d_behind > plateau_depth) {
					fade_warp = 1.0 + edge_warp * double(warp_noise->get_noise_2d(float(qx), float(qz)));
				}

				const bool side_joined = local_x < 0.0 ? joined_left : joined_right;
				double w_gated = 0.0;
				if (d_behind > -inner_ramp) {
					if (d_behind <= 0.0) {
						w_gated = UtilityFunctions::smoothstep(-inner_ramp, 0.0, d_behind);
					} else if (d_behind <= plateau_depth) {
						w_gated = 1.0;
					} else {
						w_gated = 1.0 - UtilityFunctions::smoothstep(0.0, fade_distance, (d_behind - plateau_depth) * fade_warp);
					}
				}
				double depth_weight = w_gated;
				if (side_joined) {
					const double depth_weight_gated = w_gated;
					depth_weight = 0.0;
					if (local_z >= 0.0) {
						depth_weight = 0.0;
					} else if (d_behind > plateau_depth) {
						depth_weight = 1.0 - UtilityFunctions::smoothstep(0.0, fade_distance, (d_behind - plateau_depth) * fade_warp);
					} else if (local_z <= -join_bridge_full * half_z) {
						depth_weight = 1.0;
					} else {
						depth_weight = 1.0 - UtilityFunctions::smoothstep(-join_bridge_full * half_z, 0.0, local_z);
					}
					const double join_t = UtilityFunctions::smoothstep(half_x - join_blend, half_x, std::fabs(local_x));
					depth_weight = k_lerpf(depth_weight_gated, depth_weight, join_t);
				}
				if (depth_weight <= 0.0) {
					continue;
				}

				const double side_effective_edge = local_x < 0.0 ? effective_edge_left : effective_edge_right;
				const double side_lateral_softness = local_x < 0.0 ? lateral_softness_left : lateral_softness_right;
				double lateral_outside = K_MAX(0.0, std::fabs(local_x) - side_effective_edge);
				if (lateral_outside > 0.0) {
					lateral_outside *= 1.0 + edge_warp * double(warp_noise->get_noise_2d(float(double(qx) + 5000.0), float(double(qz) - 5000.0)));
				}
				const double lateral_weight = 1.0 - UtilityFunctions::smoothstep(0.0, side_lateral_softness, lateral_outside);
				if (lateral_weight <= 0.0) {
					continue;
				}

				const double mesh_local_x = local_x / scale_jitter;
				const double top_local_y = k_sample_profile_flanked(top_profile, mesh_local_x, flank_band_fraction);
				double plateau_height = origin_y + top_local_y * scale_jitter + top_lift;
				if (d_behind > 0.0 && (join_rise_left > 0.0 || join_rise_right > 0.0)) {
					double join_lift = 0.0;
					if (join_rise_left > 0.0) {
						join_lift = join_rise_left * (1.0 - UtilityFunctions::smoothstep(0.0, join_run_left, K_MAX(local_x + half_x, 0.0)));
					}
					if (join_rise_right > 0.0) {
						join_lift = K_MAX(join_lift, join_rise_right * (1.0 - UtilityFunctions::smoothstep(0.0, join_run_right, K_MAX(half_x - local_x, 0.0))));
					}
					plateau_height += join_lift * UtilityFunctions::smoothstep(0.0, K_MAX(join_ramp_back, join_lift / (2.0 * max_slope)), d_behind);
				}

				const int64_t idx = (qz - box_z0) * bw + (qx - box_x0);
				const double raise_w = depth_weight * lateral_weight;
				const double prox_d = K_MAX(d_behind, 0.0) / proximity_falloff;
				const double avg_w = raise_w / (1.0 + prox_d * prox_d);
				w_sum[idx] = float(double(w_sum[idx]) + avg_w);
				wp_sum[idx] = float(double(wp_sum[idx]) + avg_w * plateau_height);
				wl_sum[idx] = float(double(wl_sum[idx]) + avg_w * top_lift);
				double cover_w = raise_w;
				if (side_joined) {
					const double side_gap = local_x < 0.0 ? nearest_gap_left : nearest_gap_right;
					const double cover_outside = K_MAX(0.0, std::fabs(local_x) - half_x - K_MAX(side_gap, 0.0));
					cover_w = depth_weight * K_MAX(lateral_weight, 1.0 - UtilityFunctions::smoothstep(0.0, 1.0, cover_outside));
				}
				keep[idx] = float(double(keep[idx]) * (1.0 - cover_w));
				touched_x0 = K_MIN(touched_x0, qx);
				touched_x1 = K_MAX(touched_x1, qx);
				touched_z0 = K_MIN(touched_z0, qz);
				touched_z1 = K_MAX(touched_z1, qz);
			}
		}
	}

	// Commit: one blend per touched pixel, after every entry has accumulated.
	float *heights = p_heights.ptrw();
	for (int64_t cz = touched_z0; cz <= touched_z1; cz++) {
		for (int64_t cx = touched_x0; cx <= touched_x1; cx++) {
			const int64_t i = cz * width + cx;
			const int64_t b = (cz - box_z0) * bw + (cx - box_x0);
			const double sum = w_sum[b];
			if (sum <= 0.0) {
				continue;
			}
			const double natural = heights[i];
			const double target = double(wp_sum[b]) / sum;
			const double coverage = 1.0 - double(keep[b]);
			if (p_seam_only) {
				const double shortfall = target - natural;
				if (shortfall <= 0.0 || coverage < seam_min_coverage) {
					continue;
				}
				const double seam_max = double(wl_sum[b]) / sum + seam_tolerance;
				const double seam_w = UtilityFunctions::smoothstep(seam_min_coverage, 1.0, coverage) * (1.0 - UtilityFunctions::smoothstep(seam_max - seam_tolerance * 0.5, seam_max, shortfall));
				if (seam_w <= 0.0) {
					continue;
				}
				heights[i] = float(natural + shortfall * seam_w);
				changed++;
				continue;
			}
			double blended_height = k_lerpf(natural, target, coverage);
			const double bump_amp = K_MIN(bump_max, std::fabs(target - natural) * bump_fraction);
			blended_height += double(bump_noise->get_noise_2d(float(cx), float(cz))) * bump_amp * 4.0 * coverage * (1.0 - coverage);
			heights[i] = float(blended_height);
			changed++;
		}
	}
	result["heights"] = p_heights;
	result["changed"] = changed;
	return result;
}

// TerrainKnots._flood() (scripts/terrain/knots.gd): the slope per pixel of the box (stored as a
// 32-bit float, as the script stores it), then the fill from the box's rim.
PackedByteArray TerrainKernels::knot_flood(const PackedFloat32Array &p_heights, int p_width, int p_length, const PackedByteArray &p_mesh_block, int p_x0, int p_z0, int p_bw, int p_bh, double p_walk_step) const {
	PackedByteArray visited_array;
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_heights.size() != width * length || p_mesh_block.size() != width * length, visited_array);
	ERR_FAIL_COND_V(p_bw < 1 || p_bh < 1 || p_x0 < 0 || p_z0 < 0 || p_x0 + p_bw > p_width || p_z0 + p_bh > p_length, visited_array);

	const int64_t x0 = p_x0;
	const int64_t z0 = p_z0;
	const int64_t bw = p_bw;
	const int64_t bh = p_bh;
	const float *heights = p_heights.ptr();
	const uint8_t *mesh_block = p_mesh_block.ptr();
	visited_array.resize(bw * bh);
	uint8_t *visited = visited_array.ptrw();
	for (int64_t i = 0; i < bw * bh; i++) {
		visited[i] = 0;
	}
	std::vector<float> grad(bw * bh);
	for (int64_t lz = 0; lz < bh; lz++) {
		const int64_t pz = z0 + lz;
		const int64_t zl = K_MAX(pz - 1, 0);
		const int64_t zr = K_MIN(pz + 1, length - 1);
		const double dz_div = double(K_MAX(zr - zl, 1));
		for (int64_t lx = 0; lx < bw; lx++) {
			const int64_t px = x0 + lx;
			const int64_t xl = K_MAX(px - 1, 0);
			const int64_t xr = K_MIN(px + 1, width - 1);
			const double gx = (double(heights[pz * width + xr]) - double(heights[pz * width + xl])) / double(K_MAX(xr - xl, 1));
			const double gz = (double(heights[zr * width + px]) - double(heights[zl * width + px])) / dz_div;
			grad[lz * bw + lx] = float(std::sqrt(gx * gx + gz * gz));
		}
	}
	std::vector<int32_t> queue;
	queue.reserve(bw * bh);
	for (int64_t lz = 0; lz < bh; lz++) {
		for (int64_t lx = 0; lx < bw; lx++) {
			if (lx == 0 || lz == 0 || lx == bw - 1 || lz == bh - 1) {
				if (mesh_block[(z0 + lz) * width + x0 + lx] == 1) {
					continue;
				}
				visited[lz * bw + lx] = 1;
				queue.push_back(int32_t(lz * bw + lx));
			}
		}
	}
	static const int64_t step_x[4] = { 1, -1, 0, 0 };
	static const int64_t step_z[4] = { 0, 0, 1, -1 };
	size_t head = 0;
	while (head < queue.size()) {
		const int64_t cur = queue[head];
		head++;
		const int64_t cx = cur % bw;
		const int64_t cz = cur / bw;
		const double ch = heights[(z0 + cz) * width + x0 + cx];
		for (int o = 0; o < 4; o++) {
			const int64_t nx = cx + step_x[o];
			const int64_t nz = cz + step_z[o];
			if (nx < 0 || nz < 0 || nx >= bw || nz >= bh) {
				continue;
			}
			const int64_t ni = nz * bw + nx;
			if (visited[ni] == 1) {
				continue;
			}
			if (mesh_block[(z0 + nz) * width + x0 + nx] == 1) {
				continue;
			}
			if (double(grad[ni]) > p_walk_step) {
				continue;
			}
			if (std::fabs(double(heights[(z0 + nz) * width + x0 + nx]) - ch) > p_walk_step) {
				continue;
			}
			visited[ni] = 1;
			queue.push_back(int32_t(ni));
		}
	}
	return visited_array;
}

// The engine's Vector2 arithmetic, which is 32-bit float: every operation below is the one the
// script's Vector2 expression performs, in its order.
struct KVec2 {
	float x;
	float y;
};

static inline bool k_blocked_at(const uint8_t *p_mask, float p_x, float p_y, int64_t p_width, int64_t p_x_max, int64_t p_z_max) {
	return p_mask[k_clampi(int64_t(std::round(double(p_y))), 0, p_z_max) * p_width + k_clampi(int64_t(std::round(double(p_x))), 0, p_x_max)] == 1;
}

// TerrainKnots._segment_clear_top().
static bool k_segment_clear_top(KVec2 p_a, KVec2 p_b, const uint8_t *p_mesh_block, int64_t p_width, int64_t p_length, const uint8_t *p_top_mask, float p_bed_half, float p_bed_and_clear) {
	const KVec2 seg = { p_b.x - p_a.x, p_b.y - p_a.y };
	const float seg_len = std::sqrt(seg.x * seg.x + seg.y * seg.y);
	const int64_t n = int64_t(std::ceil(double(seg_len) / 0.7));
	if (n <= 0) {
		return true;
	}
	KVec2 nrm = { -seg.y, seg.x };
	float l = nrm.x * nrm.x + nrm.y * nrm.y;
	if (l != 0) {
		l = std::sqrt(l);
		nrm.x /= l;
		nrm.y /= l;
	}
	const KVec2 side_a = { nrm.x * p_bed_half, nrm.y * p_bed_half };
	const KVec2 side_b = { nrm.x * p_bed_and_clear, nrm.y * p_bed_and_clear };
	const int64_t x_max = p_width - 1;
	const int64_t z_max = p_length - 1;
	for (int64_t k = 0; k <= n; k++) {
		const float tf = float(double(k) / double(n));
		const KVec2 p = { p_a.x + seg.x * tf, p_a.y + seg.y * tf };
		const int64_t i = k_clampi(int64_t(std::round(double(p.y))), 0, z_max) * p_width + k_clampi(int64_t(std::round(double(p.x))), 0, x_max);
		if (p_mesh_block[i] == 1) {
			return false;
		}
		if (p_top_mask[i] == 1) {
			continue; // on the ledge itself: centre line clear is enough
		}
		if (k_blocked_at(p_mesh_block, p.x + side_a.x, p.y + side_a.y, p_width, x_max, z_max)) {
			return false;
		}
		if (k_blocked_at(p_mesh_block, p.x - side_a.x, p.y - side_a.y, p_width, x_max, z_max)) {
			return false;
		}
		if (k_blocked_at(p_mesh_block, p.x + side_b.x, p.y + side_b.y, p_width, x_max, z_max)) {
			return false;
		}
		if (k_blocked_at(p_mesh_block, p.x - side_b.x, p.y - side_b.y, p_width, x_max, z_max)) {
			return false;
		}
	}
	return true;
}

// The pair loop of TerrainKnots._carve_ramp(): key = squared distance << 40 | low index << 16 | top index.
PackedInt32Array TerrainKernels::knot_first_clear_pair(const PackedInt64Array &p_keys, const PackedVector2Array &p_low_pts, const PackedVector2Array &p_highs, const PackedByteArray &p_mesh_block, const PackedByteArray &p_top_mask, int p_width, int p_length, double p_bed_half, double p_rock_clear) const {
	PackedInt32Array result;
	result.resize(2);
	result.set(0, -1);
	result.set(1, 0);
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_mesh_block.size() != width * length || p_top_mask.size() != width * length, result);

	const int64_t *keys = p_keys.ptr();
	const Vector2 *low_pts = p_low_pts.ptr();
	const Vector2 *highs = p_highs.ptr();
	const uint8_t *mesh_block = p_mesh_block.ptr();
	const uint8_t *top_mask = p_top_mask.ptr();
	const float bed_half = float(p_bed_half);
	const float bed_and_clear = float(p_bed_half + p_rock_clear);
	int64_t n_rock = 0;
	for (int64_t ki = 0; ki < p_keys.size(); ki++) {
		const int64_t key = keys[ki];
		const int64_t k = key & 0xFFFF;
		const int64_t low_seq = (key >> 16) & 0xFFFFFF;
		ERR_FAIL_COND_V(k >= p_highs.size() || low_seq >= p_low_pts.size(), result);
		const KVec2 lp = { float(low_pts[low_seq].x), float(low_pts[low_seq].y) };
		const KVec2 hp = { float(highs[k].x), float(highs[k].y) };
		if (!k_segment_clear_top(lp, hp, mesh_block, width, length, top_mask, bed_half, bed_and_clear)) {
			n_rock++;
			continue;
		}
		result.set(0, int32_t(ki));
		break;
	}
	result.set(1, int32_t(n_rock));
	return result;
}

// TerrainKnots._dilate(): the separable sliding-window count, rows then columns.
PackedByteArray TerrainKernels::dilate(const PackedByteArray &p_src, int p_width, int p_length, int p_r) const {
	PackedByteArray out_array;
	const int64_t width = p_width;
	const int64_t length = p_length;
	const int64_t r = p_r;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_r < 0 || p_src.size() != width * length, out_array);

	const uint8_t *src = p_src.ptr();
	std::vector<uint8_t> tmp(width * length);
	for (int64_t pz = 0; pz < length; pz++) {
		const int64_t base = pz * width;
		int64_t count = 0;
		for (int64_t dx = -r; dx <= r; dx++) {
			if (dx >= 0 && dx < width) {
				count += src[base + dx];
			}
		}
		tmp[base] = count > 0 ? 1 : 0;
		for (int64_t px = 1; px < width; px++) {
			const int64_t entering = px + r;
			const int64_t leaving = px - 1 - r;
			if (entering < width) {
				count += src[base + entering];
			}
			if (leaving >= 0) {
				count -= src[base + leaving];
			}
			tmp[base + px] = count > 0 ? 1 : 0;
		}
	}
	out_array.resize(width * length);
	uint8_t *out = out_array.ptrw();
	std::vector<int32_t> col(width, 0);
	for (int64_t dz = -r; dz <= r; dz++) {
		if (dz >= 0 && dz < length) {
			for (int64_t px = 0; px < width; px++) {
				col[px] += tmp[dz * width + px];
			}
		}
	}
	for (int64_t px = 0; px < width; px++) {
		out[px] = col[px] > 0 ? 1 : 0;
	}
	for (int64_t pz = 1; pz < length; pz++) {
		const int64_t entering_z = pz + r;
		const int64_t leaving_z = pz - 1 - r;
		for (int64_t px = 0; px < width; px++) {
			if (entering_z < length) {
				col[px] += tmp[entering_z * width + px];
			}
			if (leaving_z >= 0) {
				col[px] -= tmp[leaving_z * width + px];
			}
			out[pz * width + px] = col[px] > 0 ? 1 : 0;
		}
	}
	return out_array;
}

PackedByteArray TerrainKernels::height_diff_mask(const PackedFloat32Array &p_a, const PackedFloat32Array &p_b, double p_threshold) const {
	PackedByteArray mask_array;
	ERR_FAIL_COND_V(p_a.size() != p_b.size(), mask_array);
	const int64_t n = p_a.size();
	const float *a = p_a.ptr();
	const float *b = p_b.ptr();
	mask_array.resize(n);
	uint8_t *mask = mask_array.ptrw();
	for (int64_t i = 0; i < n; i++) {
		mask[i] = std::fabs(double(a[i]) - double(b[i])) > p_threshold ? 1 : 0;
	}
	return mask_array;
}

// The distance is Vector2(px, pz).distance_to(Vector2(cx, cz)): 32-bit float arithmetic.
int TerrainKernels::count_changed_outside(const PackedFloat32Array &p_heights, const PackedFloat32Array &p_before, int p_width, int p_length, const PackedFloat64Array &p_circles) const {
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_heights.size() != width * length || p_before.size() != width * length || p_circles.size() % 3 != 0, -1);

	const float *heights = p_heights.ptr();
	const float *before = p_before.ptr();
	const double *circles = p_circles.ptr();
	const int64_t circle_count = p_circles.size() / 3;
	int64_t outside = 0;
	for (int64_t pz = 0; pz < length; pz++) {
		for (int64_t px = 0; px < width; px++) {
			const int64_t i = pz * width + px;
			if (heights[i] == before[i]) {
				continue;
			}
			bool inside = false;
			for (int64_t c = 0; c < circle_count; c++) {
				const float dx = float(px) - float(circles[c * 3]);
				const float dz = float(pz) - float(circles[c * 3 + 1]);
				if (double(std::sqrt(dx * dx + dz * dz)) <= circles[c * 3 + 2]) {
					inside = true;
					break;
				}
			}
			if (!inside) {
				outside++;
			}
		}
	}
	return int(outside);
}

// TerrainRoad._obstacle_distance() (scripts/terrain/road.gd): a distance is read from and stored
// to a 32-bit float, the sums are doubles.
PackedFloat32Array TerrainKernels::obstacle_distance(const PackedByteArray &p_mask, int p_width, int p_length, double p_cap) const {
	PackedFloat32Array dist_array;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_mask.size() != int64_t(p_width) * p_length, dist_array);

	const int64_t width = p_width;
	const int64_t length = p_length;
	const uint8_t *mask = p_mask.ptr();
	dist_array.resize(width * length);
	float *dist = dist_array.ptrw();
	for (int64_t i = 0; i < width * length; i++) {
		dist[i] = float(mask[i] != 0 ? 0.0 : p_cap);
	}
	const double diag = 1.4142135;
	for (int64_t pz = 0; pz < length; pz++) {
		for (int64_t px = 0; px < width; px++) {
			const int64_t i = pz * width + px;
			double v = dist[i];
			if (v == 0.0) {
				continue;
			}
			if (px > 0) {
				v = K_MIN(v, dist[i - 1] + 1.0);
			}
			if (pz > 0) {
				v = K_MIN(v, dist[i - width] + 1.0);
				if (px > 0) {
					v = K_MIN(v, dist[i - width - 1] + diag);
				}
				if (px < width - 1) {
					v = K_MIN(v, dist[i - width + 1] + diag);
				}
			}
			dist[i] = float(v);
		}
	}
	for (int64_t pz = length - 1; pz >= 0; pz--) {
		for (int64_t px = width - 1; px >= 0; px--) {
			const int64_t i = pz * width + px;
			double v = dist[i];
			if (v == 0.0) {
				continue;
			}
			if (px < width - 1) {
				v = K_MIN(v, dist[i + 1] + 1.0);
			}
			if (pz < length - 1) {
				v = K_MIN(v, dist[i + width] + 1.0);
				if (px < width - 1) {
					v = K_MIN(v, dist[i + width + 1] + diag);
				}
				if (px > 0) {
					v = K_MIN(v, dist[i + width - 1] + diag);
				}
			}
			dist[i] = float(v);
		}
	}
	return dist_array;
}

// The search loop of TerrainRoad._find_road_path(): the same binary heap making the same
// comparisons on f in the same order, so it pops the same nodes. Vector2(nx, ny).distance_to(goal)
// is 32-bit float arithmetic in the script and here.
PackedInt32Array TerrainKernels::road_search(const PackedFloat32Array &p_heights, int p_width, int p_length, int p_cols, int p_rows, int p_start_node, int p_goal_node, const PackedFloat32Array &p_node_h, const PackedByteArray &p_node_blocked, const PackedFloat32Array &p_node_od, const PackedFloat64Array &p_row_pref, const PackedInt32Array &p_offsets, const PackedFloat64Array &p_offset_dist, const PackedFloat64Array &p_offset_side, const PackedFloat64Array &p_params) const {
	PackedInt32Array path;
	const int64_t node_count = int64_t(p_cols) * p_rows;
	ERR_FAIL_COND_V(p_params.size() != 8, path);
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_heights.size() != int64_t(p_width) * p_length, path);
	ERR_FAIL_COND_V(node_count < 1 || p_node_h.size() != node_count || p_node_blocked.size() != node_count || p_row_pref.size() != p_rows, path);
	ERR_FAIL_COND_V(!p_node_od.is_empty() && p_node_od.size() != node_count, path);
	ERR_FAIL_COND_V(p_offsets.size() != 16 || p_offset_dist.size() != 8 || p_offset_side.size() != 16, path);
	ERR_FAIL_COND_V(p_start_node < 0 || p_start_node >= node_count || p_goal_node < 0 || p_goal_node >= node_count, path);

	const double grid_step = p_params[0];
	const double slope_hard_limit = p_params[1];
	const double slope_penalty = p_params[2];
	const double half_width = p_params[3];
	const double cross_slope_penalty = p_params[4];
	const double soft_clearance = p_params[5];
	const double proximity_penalty = p_params[6];
	const double meander_cost_weight = p_params[7];

	const int64_t width = p_width;
	const int64_t length = p_length;
	const int64_t cols = p_cols;
	const int64_t rows = p_rows;
	const float *heights = p_heights.ptr();
	const float *node_h = p_node_h.ptr();
	const uint8_t *node_blocked = p_node_blocked.ptr();
	const bool has_od = !p_node_od.is_empty();
	const float *node_od = p_node_od.ptr();
	const double *row_pref = p_row_pref.ptr();
	const int32_t *offsets = p_offsets.ptr();
	const double *offset_dist = p_offset_dist.ptr();
	const double *offset_side = p_offset_side.ptr();

	// Binary min-heap as two parallel arrays (f, node); a node can be in it more than once.
	std::vector<double> heap_f;
	std::vector<int32_t> heap_n;
	std::vector<uint8_t> closed(node_count, 0);
	std::vector<int32_t> came_from(node_count, -1);
	std::vector<double> g_score(node_count, std::numeric_limits<double>::infinity());
	const float goal_x = float(p_goal_node % cols);
	const float goal_y = float(p_goal_node / cols);
	g_score[p_start_node] = 0.0;
	{
		const float sx = float(p_start_node % cols);
		const float sy = float(p_start_node / cols);
		heap_f.push_back(double(std::sqrt((sx - goal_x) * (sx - goal_x) + (sy - goal_y) * (sy - goal_y))) * grid_step);
		heap_n.push_back(p_start_node);
	}

	while (!heap_f.empty()) {
		// pop the smallest f
		int64_t current = heap_n[0];
		const int64_t last = int64_t(heap_f.size()) - 1;
		heap_f[0] = heap_f[last];
		heap_n[0] = heap_n[last];
		heap_f.pop_back();
		heap_n.pop_back();
		int64_t hi = 0;
		const int64_t hn = int64_t(heap_f.size());
		while (true) {
			const int64_t left = hi * 2 + 1;
			const int64_t right = hi * 2 + 2;
			int64_t smallest = hi;
			if (left < hn && heap_f[left] < heap_f[smallest]) {
				smallest = left;
			}
			if (right < hn && heap_f[right] < heap_f[smallest]) {
				smallest = right;
			}
			if (smallest == hi) {
				break;
			}
			const double tf = heap_f[hi];
			heap_f[hi] = heap_f[smallest];
			heap_f[smallest] = tf;
			const int32_t tn = heap_n[hi];
			heap_n[hi] = heap_n[smallest];
			heap_n[smallest] = tn;
			hi = smallest;
		}
		if (closed[current] == 1) {
			continue; // stale duplicate
		}
		closed[current] = 1;

		if (current == p_goal_node) {
			std::vector<int32_t> nodes;
			nodes.push_back(int32_t(current));
			while (came_from[current] >= 0) {
				current = came_from[current];
				nodes.push_back(int32_t(current));
			}
			path.resize(int64_t(nodes.size()));
			int32_t *out = path.ptrw();
			for (size_t k = 0; k < nodes.size(); k++) {
				out[k] = nodes[nodes.size() - 1 - k];
			}
			return path;
		}

		const int64_t current_x = current % cols;
		const int64_t current_y = current / cols;
		const double current_height = node_h[current];
		const double current_g = g_score[current];

		for (int oi = 0; oi < 8; oi++) {
			const int64_t nx = current_x + offsets[oi * 2];
			const int64_t ny = current_y + offsets[oi * 2 + 1];
			if (nx < 0 || nx >= cols || ny < 0 || ny >= rows) {
				continue;
			}
			const int64_t neighbor = ny * cols + nx;
			if (closed[neighbor] == 1) {
				continue;
			}
			if (node_blocked[neighbor] == 1) {
				continue;
			}

			const double height_delta = std::fabs(double(node_h[neighbor]) - current_height);
			if (height_delta > slope_hard_limit) {
				continue;
			}

			const double step_distance = offset_dist[oi];
			const double slope = height_delta / step_distance;
			double move_cost = step_distance * (1.0 + slope_penalty * slope * slope);
			// Sidehill cost: ground tilting across the step.
			const double side_x = offset_side[oi * 2];
			const double side_y = offset_side[oi * 2 + 1];
			const double npx = double(nx) * grid_step;
			const double npz = double(ny) * grid_step;
			const double h_left = heights[k_clampi(int64_t(std::round(npz + side_y)), 0, length - 1) * width + k_clampi(int64_t(std::round(npx + side_x)), 0, width - 1)];
			const double h_right = heights[k_clampi(int64_t(std::round(npz - side_y)), 0, length - 1) * width + k_clampi(int64_t(std::round(npx - side_x)), 0, width - 1)];
			const double cross = std::fabs(h_left - h_right) / (2.0 * half_width);
			move_cost += step_distance * cross_slope_penalty * cross * cross;
			// Keep clear of rocks.
			if (has_od) {
				const double od = node_od[neighbor];
				if (od < soft_clearance) {
					const double near = 1.0 - od / soft_clearance;
					move_cost += step_distance * proximity_penalty * near * near;
				}
			}
			// Meander pull toward the preferred column of this row.
			const double lateral_deviation = std::fabs(double(nx) - row_pref[ny]);
			move_cost += meander_cost_weight * lateral_deviation * step_distance;

			const double tentative_g = current_g + move_cost;
			if (tentative_g < g_score[neighbor]) {
				came_from[neighbor] = int32_t(current);
				g_score[neighbor] = tentative_g;
				// push
				const float fx = float(nx);
				const float fy = float(ny);
				heap_f.push_back(tentative_g + double(std::sqrt((fx - goal_x) * (fx - goal_x) + (fy - goal_y) * (fy - goal_y))) * grid_step);
				heap_n.push_back(int32_t(neighbor));
				int64_t ci = int64_t(heap_f.size()) - 1;
				while (ci > 0) {
					const int64_t parent = (ci - 1) / 2;
					if (heap_f[parent] <= heap_f[ci]) {
						break;
					}
					const double pf = heap_f[parent];
					heap_f[parent] = heap_f[ci];
					heap_f[ci] = pf;
					const int32_t pn = heap_n[parent];
					heap_n[parent] = heap_n[ci];
					heap_n[ci] = pn;
					ci = parent;
				}
			}
		}
	}
	return path;
}

// A line-for-line copy of TerrainErosion.erode() (scripts/terrain/erosion.gd): GDScript floats are
// doubles, a height is read from and stored to a 32-bit float, and the random numbers come from
// the same RandomNumberGenerator in the same order. cos() and sin() are the engine's own (asked
// through UtilityFunctions) so the last digit cannot differ from the script's.
PackedFloat32Array TerrainKernels::erode(PackedFloat32Array p_heights, int p_width, int p_length, const Ref<RandomNumberGenerator> &p_rng, int p_iterations, const PackedFloat64Array &p_params) const {
	ERR_FAIL_COND_V(p_rng.is_null(), p_heights);
	ERR_FAIL_COND_V(p_params.size() != 10, p_heights);
	ERR_FAIL_COND_V(p_width < 2 || p_length < 2 || p_heights.size() != int64_t(p_width) * p_length, p_heights);

	const int64_t max_lifetime = int64_t(p_params[0]);
	const double inertia = p_params[1];
	const double capacity_factor = p_params[2];
	const double min_capacity = p_params[3];
	const double erode_speed = p_params[4];
	const double deposit_speed = p_params[5];
	const double evaporate_speed = p_params[6];
	const double gravity = p_params[7];
	const double initial_water = p_params[8];
	const double initial_speed = p_params[9];

	const int64_t width = p_width;
	const int64_t length = p_length;
	float *heights = p_heights.ptrw();
	RandomNumberGenerator *rng = p_rng.ptr();

	for (int64_t iter = 0; iter < p_iterations; iter++) {
		double pos_x = rng->randf_range(0.0, width - 1.001);
		double pos_z = rng->randf_range(0.0, length - 1.001);
		double dir_x = 0.0;
		double dir_z = 0.0;
		double speed = initial_speed;
		double water = initial_water;
		double sediment = 0.0;

		for (int64_t step = 0; step < max_lifetime; step++) {
			const int64_t node_x = int64_t(pos_x);
			const int64_t node_z = int64_t(pos_z);
			const double cell_x = pos_x - node_x;
			const double cell_z = pos_z - node_z;
			const int64_t node_x1 = K_MIN(node_x + 1, width - 1);
			const int64_t node_z1 = K_MIN(node_z + 1, length - 1);

			const int64_t i_nw = node_z * width + node_x;
			const int64_t i_ne = node_z * width + node_x1;
			const int64_t i_sw = node_z1 * width + node_x;
			const int64_t i_se = node_z1 * width + node_x1;
			const double h_nw = heights[i_nw];
			const double h_ne = heights[i_ne];
			const double h_sw = heights[i_sw];
			const double h_se = heights[i_se];

			const double gradient_x = (h_ne - h_nw) * (1.0 - cell_z) + (h_se - h_sw) * cell_z;
			const double gradient_z = (h_sw - h_nw) * (1.0 - cell_x) + (h_se - h_ne) * cell_x;
			const double old_height = h_nw * (1 - cell_x) * (1 - cell_z) + h_ne * cell_x * (1 - cell_z) + h_sw * (1 - cell_x) * cell_z + h_se * cell_x * cell_z;

			dir_x = dir_x * inertia - gradient_x * (1.0 - inertia);
			dir_z = dir_z * inertia - gradient_z * (1.0 - inertia);
			double dir_len = std::sqrt(dir_x * dir_x + dir_z * dir_z);
			if (dir_len < 0.0001) {
				// Flat spot / directionless: a random escape direction.
				const double ang = rng->randf_range(0.0, K_TAU);
				dir_x = UtilityFunctions::cos(ang);
				dir_z = UtilityFunctions::sin(ang);
				dir_len = 1.0;
			}
			dir_x /= dir_len;
			dir_z /= dir_len;

			const double new_x = pos_x + dir_x;
			const double new_z = pos_z + dir_z;
			if (new_x < 0.0 || new_x >= width - 1 || new_z < 0.0 || new_z >= length - 1) {
				break;
			}

			const int64_t new_node_x = int64_t(new_x);
			const int64_t new_node_z = int64_t(new_z);
			const double new_cell_x = new_x - new_node_x;
			const double new_cell_z = new_z - new_node_z;
			const int64_t new_node_x1 = K_MIN(new_node_x + 1, width - 1);
			const int64_t new_node_z1 = K_MIN(new_node_z + 1, length - 1);
			const double n_h_nw = heights[new_node_z * width + new_node_x];
			const double n_h_ne = heights[new_node_z * width + new_node_x1];
			const double n_h_sw = heights[new_node_z1 * width + new_node_x];
			const double n_h_se = heights[new_node_z1 * width + new_node_x1];
			const double new_height = n_h_nw * (1 - new_cell_x) * (1 - new_cell_z) + n_h_ne * new_cell_x * (1 - new_cell_z) + n_h_sw * (1 - new_cell_x) * new_cell_z + n_h_se * new_cell_x * new_cell_z;

			const double height_diff = new_height - old_height;
			const double capacity = K_MAX(-height_diff, min_capacity) * speed * water * capacity_factor;

			if (sediment > capacity || height_diff > 0.0) {
				// Moving uphill, or carrying more than it can hold: drop sediment.
				const double deposit_amount = height_diff > 0.0 ? K_MIN(height_diff, sediment) : (sediment - capacity) * deposit_speed;
				sediment -= deposit_amount;
				heights[i_nw] = float(double(heights[i_nw]) + deposit_amount * (1 - cell_x) * (1 - cell_z));
				heights[i_ne] = float(double(heights[i_ne]) + deposit_amount * cell_x * (1 - cell_z));
				heights[i_sw] = float(double(heights[i_sw]) + deposit_amount * (1 - cell_x) * cell_z);
				heights[i_se] = float(double(heights[i_se]) + deposit_amount * cell_x * cell_z);
			} else {
				// Steep and fast: pick up sediment, capped by what is actually there.
				const double erode_amount = K_MIN((capacity - sediment) * erode_speed, -height_diff);
				sediment += erode_amount;
				heights[i_nw] = float(double(heights[i_nw]) - erode_amount * (1 - cell_x) * (1 - cell_z));
				heights[i_ne] = float(double(heights[i_ne]) - erode_amount * cell_x * (1 - cell_z));
				heights[i_sw] = float(double(heights[i_sw]) - erode_amount * (1 - cell_x) * cell_z);
				heights[i_se] = float(double(heights[i_se]) - erode_amount * cell_x * cell_z);
			}

			speed = std::sqrt(K_MAX(0.0, speed * speed + height_diff * -gravity));
			water *= (1.0 - evaporate_speed);
			pos_x = new_x;
			pos_z = new_z;
			if (water < 0.001) {
				break;
			}
		}
	}
	return p_heights;
}

// TerrainGroundPaint._mode_band() (scripts/terrain/ground_paint.gd) for every row: each vertex
// takes the most common texture within p_radius of it, read from the unfiltered map; its own wins
// a tie; road vertices are left alone and not counted. The script's block grid is only a shortcut
// past windows of one texture, which end the same way here ("already the majority").
PackedByteArray TerrainKernels::mode_filter(const PackedByteArray &p_src, int p_width, int p_length, int p_radius, int p_road_mark) const {
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_radius < 0 || p_src.size() != int64_t(p_width) * p_length, p_src);

	const int64_t width = p_width;
	const int64_t length = p_length;
	const int64_t radius = p_radius;
	const uint8_t *src = p_src.ptr();
	PackedByteArray out_array = p_src;
	uint8_t *out = out_array.ptrw();
	int32_t tally[256];

	for (int64_t pz = 0; pz < length; pz++) {
		const int64_t za = K_MAX(pz - radius, 0);
		const int64_t zb = K_MIN(pz + radius, length - 1);
		for (int64_t px = 0; px < width; px++) {
			const int64_t own = src[pz * width + px];
			if (own == p_road_mark) {
				continue;
			}
			const int64_t xa = K_MAX(px - radius, 0);
			const int64_t xb = K_MIN(px + radius, width - 1);
			int64_t same = 0;
			int64_t cells = 0;
			for (int64_t zz = za; zz <= zb; zz++) {
				for (int64_t xx = xa; xx <= xb; xx++) {
					const int64_t v = src[zz * width + xx];
					if (v == p_road_mark) {
						continue;
					}
					cells++;
					if (v == own) {
						same++;
					}
				}
			}
			if (same * 2 > cells) {
				continue; // already the majority
			}
			for (int k = 0; k < 256; k++) {
				tally[k] = 0;
			}
			int64_t best_id = own;
			int64_t best_n = same;
			for (int64_t zz = za; zz <= zb; zz++) {
				for (int64_t xx = xa; xx <= xb; xx++) {
					const int64_t v = src[zz * width + xx];
					if (v == p_road_mark) {
						continue;
					}
					tally[v]++;
					if (tally[v] > best_n) {
						best_n = tally[v];
						best_id = v;
					}
				}
			}
			out[pz * width + px] = uint8_t(best_id);
		}
	}
	return out_array;
}

// TerrainGroundPaint._pack(): base << 27, overlay << 22, blend byte << 14, kept as 32 bits.
static inline int32_t k_pack(int64_t p_base, int64_t p_overlay, double p_blend) {
	const double clamped = p_blend < 0.0 ? 0.0 : (p_blend > 1.0 ? 1.0 : p_blend);
	int64_t blend_byte = int64_t(std::round(clamped * 255.0));
	blend_byte = blend_byte < 0 ? 0 : (blend_byte > 255 ? 255 : blend_byte);
	return int32_t(uint32_t(((p_base & 0x1F) << 27) | ((p_overlay & 0x1F) << 22) | (blend_byte << 14)));
}

// TerrainGroundPaint._spray().
static inline double k_spray(double p_b, double p_s, double p_amp, double p_floor) {
	const double v = p_b + p_s * p_amp * (p_floor + 4.0 * p_b * (1.0 - p_b) * (1.0 - p_floor));
	return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

// TerrainGroundPaint._blend_band() for every row. smoothstep() is the engine's own.
Dictionary TerrainKernels::blend_borders(const PackedByteArray &p_dom, const PackedByteArray &p_spray, const PackedInt32Array &p_road_control, int p_width, int p_length, const PackedFloat64Array &p_params) const {
	Dictionary result;
	const int64_t n = int64_t(p_width) * p_length;
	ERR_FAIL_COND_V(p_params.size() != 6, result);
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_dom.size() != n || p_spray.size() != n || p_road_control.size() != n, result);

	const int64_t radius = int64_t(p_params[0]);
	const double border_fade = p_params[1];
	const double third_fade = p_params[2];
	const double spray_amp = p_params[3];
	const double spray_floor = p_params[4];
	const int64_t road_mark = int64_t(p_params[5]);

	const int64_t width = p_width;
	const int64_t length = p_length;
	const uint8_t *dom = p_dom.ptr();
	const uint8_t *spray_n = p_spray.ptr();
	const int32_t *road_control = p_road_control.ptr();
	PackedInt32Array control_array;
	control_array.resize(n);
	int32_t *control = control_array.ptrw();
	int64_t border = 0;
	int64_t third = 0;
	const int64_t far = (radius + 1) * (radius + 1) * 2;

	for (int64_t pz = 0; pz < length; pz++) {
		const int64_t za = K_MAX(pz - radius, 0);
		const int64_t zb = K_MIN(pz + radius, length - 1);
		for (int64_t px = 0; px < width; px++) {
			const int64_t i = pz * width + px;
			const int64_t a = dom[i];
			if (a == road_mark) {
				// What the road's edge fades into: the nearest vertex off the road within 2 m.
				int64_t beside = -1;
				int64_t beside_d = 99;
				const int64_t rz1 = K_MIN(pz + 2, length - 1);
				const int64_t rx1 = K_MIN(px + 2, width - 1);
				for (int64_t zz = K_MAX(pz - 2, 0); zz <= rz1; zz++) {
					for (int64_t xx = K_MAX(px - 2, 0); xx <= rx1; xx++) {
						const int64_t u = dom[zz * width + xx];
						const int64_t d = (zz - pz) * (zz - pz) + (xx - px) * (xx - px);
						if (u != road_mark && d < beside_d) {
							beside_d = d;
							beside = u;
						}
					}
				}
				const int64_t rc = road_control[i];
				control[i] = beside < 0 ? int32_t(rc) : int32_t(uint32_t((rc & 0x07FFFFFF) | ((beside & 0x1F) << 27)));
				continue;
			}
			// The two nearest other textures: e1 at d1 (squared), e2 at d2.
			int64_t e1 = -1;
			int64_t e2 = -1;
			int64_t d1 = far;
			int64_t d2 = far;
			const int64_t xa = K_MAX(px - radius, 0);
			const int64_t xb = K_MIN(px + radius, width - 1);
			for (int64_t zz = za; zz <= zb; zz++) {
				const int64_t row = zz * width;
				const int64_t dz2 = (zz - pz) * (zz - pz);
				for (int64_t xx = xa; xx <= xb; xx++) {
					const int64_t u = dom[row + xx];
					if (u == a || u == road_mark) {
						continue;
					}
					const int64_t d = dz2 + (xx - px) * (xx - px);
					if (u == e1) {
						if (d < d1) {
							d1 = d;
						}
					} else if (u == e2) {
						if (d < d2) {
							d2 = d;
							if (d2 < d1) {
								const int64_t sw_e = e1;
								const int64_t sw_d = d1;
								e1 = e2;
								d1 = d2;
								e2 = sw_e;
								d2 = sw_d;
							}
						}
					} else if (d < d1) {
						e2 = e1;
						d2 = d1;
						e1 = u;
						d1 = d;
					} else if (d < d2) {
						e2 = u;
						d2 = d;
					}
				}
			}
			if (e1 < 0) {
				control[i] = k_pack(a, a, 0.0);
				continue;
			}
			border++;
			// The border runs half a metre short of the nearest other vertex.
			double share = 0.5 * (1.0 - UtilityFunctions::smoothstep(0.0, border_fade, std::sqrt(double(d1)) - 0.5));
			if (e2 >= 0) {
				const double hold = UtilityFunctions::smoothstep(0.0, third_fade, std::sqrt(double(d2)) - 0.5);
				if (hold < 1.0) {
					third++;
					share *= hold;
				}
			}
			// Spray moves the share of the texture with the lower id.
			const double s = spray_n[i] / 255.0 - 0.5;
			if (share > 0.0) {
				if (a < e1) {
					share = 1.0 - k_spray(1.0 - share, s, spray_amp, spray_floor);
				} else {
					share = k_spray(share, s, spray_amp, spray_floor);
				}
			}
			control[i] = k_pack(a, e1, share);
		}
	}
	result["control"] = control_array;
	result["border"] = border;
	result["third"] = third;
	return result;
}

// A constant the script passes by name; a missing one stops the kernel (the script then falls back).
#define K_CONST(m_name) \
	ERR_FAIL_COND_V_MSG(!p_consts.has(#m_name), result, "TerrainKernels: constant " #m_name " not passed."); \
	const double m_name = double(p_consts[#m_name]);

// UnderstoryScatter._grid_sample().
static inline double k_grid_sample(const float *p_grid, int64_t p_gw, int64_t p_gl, double p_px, double p_pz, double p_cell) {
	const double fx = k_clampf(p_px / p_cell, 0.0, double(p_gw - 1));
	const double fz = k_clampf(p_pz / p_cell, 0.0, double(p_gl - 1));
	const int64_t x0 = int64_t(fx);
	const int64_t z0 = int64_t(fz);
	const int64_t x1 = K_MIN(x0 + 1, p_gw - 1);
	const int64_t z1 = K_MIN(z0 + 1, p_gl - 1);
	const double tx = fx - double(x0);
	const double tz = fz - double(z0);
	const double a = k_lerpf(p_grid[z0 * p_gw + x0], p_grid[z0 * p_gw + x1], tx);
	const double b = k_lerpf(p_grid[z1 * p_gw + x0], p_grid[z1 * p_gw + x1], tx);
	return k_lerpf(a, b, tz);
}

// TerrainGroundPaint._paint_band() (scripts/terrain/ground_paint.gd) for every row, from the same
// ctx dictionary the script's bands read. smoothstep() is Math::smoothstep, the engine's own
// definition compiled in (the loop calls it some twenty times per vertex). The two sums are added
// up per band of PAINT_BAND_ROWS rows and then band by band, as the script adds them.
Dictionary TerrainKernels::paint_main(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(GRASS_TEXTURE_GROW) K_CONST(PATCH_SHADE) K_CONST(GAP_SHADE) K_CONST(STEEP_NY_FULL) K_CONST(STEEP_NY_NONE)
	K_CONST(ROCK_WARP_AMP) K_CONST(CLIFF_REACH) K_CONST(BOULDER_REACH) K_CONST(BOULDER_STRENGTH) K_CONST(SCREE_REACH)
	K_CONST(ROCKY_LO) K_CONST(ROCKY_HI) K_CONST(ROCKY_BASE) K_CONST(ROCKY_BIG) K_CONST(ROCKY_SMALL) K_CONST(ROCKY_MIN)
	K_CONST(LITTER_TREE_FADE) K_CONST(LITTER_EDGE_NOISE) K_CONST(LITTER_SUPPLY_LO) K_CONST(LITTER_SUPPLY_HI)
	K_CONST(LITTER_UPHILL_STEP) K_CONST(LITTER_COLLAR_SIDE) K_CONST(LITTER_COLLAR_REACH) K_CONST(LITTER_CURV_LO) K_CONST(LITTER_CURV_HI)
	K_CONST(LITTER_DRIFT_LO) K_CONST(LITTER_DRIFT_HI) K_CONST(LITTER_DRIFT_SUPPLY_LO) K_CONST(LITTER_DRIFT_SUPPLY_HI)
	K_CONST(LITTER_ROAD_CLEAR) K_CONST(LITTER_ROAD_REACH) K_CONST(LITTER_NY_NONE) K_CONST(LITTER_NY_FULL)
	K_CONST(LITTER_CLIFF_CLEAR) K_CONST(LITTER_CLIFF_REACH) K_CONST(LITTER_FULL) K_CONST(LITTER_MIN)
	K_CONST(BARE_WORN_MAX) K_CONST(BARE_NY_FULL) K_CONST(BARE_NY_NONE) K_CONST(BARE_CLIFF_CLEAR) K_CONST(BARE_CLIFF_REACH)
	K_CONST(FLAT_NY) K_CONST(MOSS_SHADE_LO) K_CONST(MOSS_SHADE_HI)
	K_CONST(PATCH_RES) K_CONST(PATCH_EDGE) K_CONST(CURV_RADIUS) K_CONST(GRID_CELL) K_CONST(PAINT_BAND_ROWS)
	K_CONST(GROUND_ID) K_CONST(GRASS_ID) K_CONST(ROAD_ID) K_CONST(PINE_LITTER_ID) K_CONST(ROCK_FACE_ID) K_CONST(AERIAL_ROCKS_ID)
	K_CONST(ROCKY_TRAIL_ID) K_CONST(ROCKY_TERRAIN_ID) K_CONST(COAST_SAND_ROCKS_ID) K_CONST(ROAD_MARK)

	const int64_t width = int64_t(p_ctx["width"]);
	const int64_t length = int64_t(p_ctx["length"]);
	const int64_t n = width * length;
	const PackedFloat32Array heights_a = p_ctx["heights"];
	const PackedByteArray old_control_a = p_ctx["old_control"];
	const PackedByteArray coverage_a = p_ctx["coverage_bytes"];
	const PackedByteArray worn_a = p_ctx["worn_bytes"];
	const PackedByteArray verge_a = p_ctx["verge_bytes"];
	const PackedByteArray big_a = p_ctx["big_n"];
	const PackedByteArray small_a = p_ctx["small_n"];
	const PackedByteArray type_a_a = p_ctx["type_a"];
	const PackedByteArray type_b_a = p_ctx["type_b"];
	const PackedByteArray warp_x_a = p_ctx["warp_x"];
	const PackedByteArray warp_z_a = p_ctx["warp_z"];
	const PackedFloat32Array cliff_d_a = p_ctx["cliff_d"];
	const PackedFloat32Array boulder_d_a = p_ctx["boulder_d"];
	const PackedFloat32Array scree_d_a = p_ctx["scree_d"];
	const PackedFloat32Array road_d_a = p_ctx["road_d"];
	const PackedFloat32Array dead_d_a = p_ctx["dead_d"];
	const PackedFloat32Array tree_d_a = p_ctx["tree_d"];
	const PackedFloat32Array canopy_a = p_ctx["canopy"];
	const PackedFloat32Array cliff_shade_a = p_ctx["cliff_shade"];
	const int64_t gw = int64_t(p_ctx["gw"]);
	const int64_t gl = int64_t(p_ctx["gl"]);
	const bool litter_ok = bool(p_ctx["litter_ok"]);
	const PackedByteArray patch_a = p_ctx["patch_bytes"];
	const PackedFloat64Array patch_nv_a = p_ctx["patch_nv"];

	const int64_t patch_res = int64_t(PATCH_RES);
	const int64_t band_rows = int64_t(PAINT_BAND_ROWS);
	const int64_t curv_radius = int64_t(CURV_RADIUS);
	ERR_FAIL_COND_V(width < 2 || length < 2 || band_rows < 1 || patch_res != 2 || gw < 1 || gl < 1, result);
	ERR_FAIL_COND_V(heights_a.size() != n || old_control_a.size() != n * 4 || coverage_a.size() != n * 4, result);
	ERR_FAIL_COND_V(worn_a.size() != n || verge_a.size() != n || big_a.size() != n || small_a.size() != n || type_a_a.size() != n || type_b_a.size() != n || warp_x_a.size() != n || warp_z_a.size() != n, result);
	ERR_FAIL_COND_V(cliff_d_a.size() != n || boulder_d_a.size() != n || scree_d_a.size() != n || road_d_a.size() != n || dead_d_a.size() != n || tree_d_a.size() != n, result);
	ERR_FAIL_COND_V(canopy_a.size() != gw * gl || cliff_shade_a.size() != gw * gl || patch_a.size() != n * patch_res * patch_res || patch_nv_a.size() != 256, result);

	const float *heights = heights_a.ptr();
	const uint8_t *old_control = old_control_a.ptr();
	const uint8_t *coverage_bytes = coverage_a.ptr();
	const uint8_t *worn_bytes = worn_a.ptr();
	const uint8_t *verge_bytes = verge_a.ptr();
	const uint8_t *big_n = big_a.ptr();
	const uint8_t *small_n = small_a.ptr();
	const uint8_t *type_a = type_a_a.ptr();
	const uint8_t *type_b = type_b_a.ptr();
	const uint8_t *warp_x = warp_x_a.ptr();
	const uint8_t *warp_z = warp_z_a.ptr();
	const float *cliff_d = cliff_d_a.ptr();
	const float *boulder_d = boulder_d_a.ptr();
	const float *scree_d = scree_d_a.ptr();
	const float *road_d = road_d_a.ptr();
	const float *dead_d = dead_d_a.ptr();
	const float *tree_d = tree_d_a.ptr();
	const float *canopy = canopy_a.ptr();
	const float *cliff_shade = cliff_shade_a.ptr();
	const uint8_t *patch_bytes = patch_a.ptr();
	const double *patch_nv = patch_nv_a.ptr();

	const int64_t pw = width * patch_res;
	const int64_t pw1 = pw - 1;
	const int64_t pl1 = length * patch_res - 1;
	const double edge2 = 2.0 * PATCH_EDGE;
	const int64_t ground_id = int64_t(GROUND_ID);
	const int64_t grass_id = int64_t(GRASS_ID);
	const int64_t road_id = int64_t(ROAD_ID);
	const int64_t litter_id = int64_t(PINE_LITTER_ID);
	const int64_t rock_ids[5] = { int64_t(ROCK_FACE_ID), int64_t(AERIAL_ROCKS_ID), int64_t(ROCKY_TRAIL_ID), int64_t(ROCKY_TERRAIN_ID), int64_t(COAST_SAND_ROCKS_ID) };

	PackedInt32Array control_array;
	control_array.resize(n);
	int32_t *control = control_array.ptrw();
	PackedByteArray shade_array;
	shade_array.resize(n);
	uint8_t *patch_shade = shade_array.ptrw();
	PackedByteArray dom_array;
	dom_array.resize(n);
	uint8_t *dom = dom_array.ptrw();
	for (int64_t i = 0; i < n; i++) {
		control[i] = 0;
		patch_shade[i] = 255;
		dom[i] = 0;
	}
	int64_t n_road = 0;
	int64_t n_soil = 0;
	int64_t n_rock = 0;
	int64_t type_counts[5] = { 0, 0, 0, 0, 0 };
	double grass_total = 0.0;
	double bare_total = 0.0;
	int64_t litter_full = 0;
	int64_t litter_ramp = 0;

	const int64_t w1 = width - 1;
	const int64_t l1 = length - 1;
	for (int64_t z0 = 0; z0 < length; z0 += band_rows) {
		const int64_t z1 = K_MIN(z0 + band_rows, length);
		double grass_sum = 0.0;
		double bare_sum = 0.0;
		for (int64_t pz = z0; pz < z1; pz++) {
			const int64_t zm = K_MAX(pz - 1, 0);
			const int64_t zp = K_MIN(pz + 1, l1);
			for (int64_t px = 0; px < width; px++) {
				const int64_t i = pz * width + px;
				const int64_t old = int64_t(uint32_t(old_control[i * 4]) | (uint32_t(old_control[i * 4 + 1]) << 8) | (uint32_t(old_control[i * 4 + 2]) << 16) | (uint32_t(old_control[i * 4 + 3]) << 24));
				const double verge = verge_bytes[i] / 255.0;
				if (((old >> 27) & 0x1F) == road_id || ((old >> 22) & 0x1F) == road_id) {
					control[i] = k_pack(verge >= 0.5 ? ground_id : grass_id, road_id, ((old >> 14) & 0xFF) / 255.0);
					dom[i] = uint8_t(ROAD_MARK);
					n_road++;
					continue;
				}

				// Grass: the blades' own patch keep, softened over 5 taps.
				double cov = coverage_bytes[i * 4] / 255.0;
				cov += GRASS_TEXTURE_GROW * Math::smoothstep(0.0, 0.1, cov);
				double g = 0.0;
				if (cov > 0.0) {
					const int64_t tx = px * 2;
					const int64_t tz = pz * 2;
					const int64_t trow = tz * pw;
					double nv = patch_nv[patch_bytes[trow + tx]];
					g = 2.0 * Math::smoothstep(nv, nv + edge2, cov);
					nv = patch_nv[patch_bytes[trow + K_MAX(tx - 1, 0)]];
					g += Math::smoothstep(nv, nv + edge2, cov);
					nv = patch_nv[patch_bytes[trow + K_MIN(tx + 1, pw1)]];
					g += Math::smoothstep(nv, nv + edge2, cov);
					nv = patch_nv[patch_bytes[K_MAX(tz - 1, 0) * pw + tx]];
					g += Math::smoothstep(nv, nv + edge2, cov);
					nv = patch_nv[patch_bytes[K_MIN(tz + 1, pl1) * pw + tx]];
					g += Math::smoothstep(nv, nv + edge2, cov);
					g /= 6.0;
				}
				grass_sum += g;
				patch_shade[i] = uint8_t(int64_t(std::round(255.0 * (1.0 - PATCH_SHADE * g - GAP_SHADE * (1.0 - g) * Math::smoothstep(0.05, 0.25, cov)))));

				// Rockiness.
				const int64_t xm = K_MAX(px - 1, 0);
				const int64_t xp = K_MIN(px + 1, w1);
				const double dx = (double(heights[pz * width + xp]) - double(heights[pz * width + xm])) / double(xp - xm);
				const double dz = (double(heights[zp * width + px]) - double(heights[zm * width + px])) / double(zp - zm);
				const double ny = 1.0 / std::sqrt(1.0 + dx * dx + dz * dz);
				const double steep = 1.0 - Math::smoothstep(STEEP_NY_FULL, STEEP_NY_NONE, ny);
				const int64_t wpx = k_clampi(int64_t(std::round(double(px) + (warp_x[i] / 255.0 - 0.5) * 2.0 * ROCK_WARP_AMP)), 0, w1);
				const int64_t wpz = k_clampi(int64_t(std::round(double(pz) + (warp_z[i] / 255.0 - 0.5) * 2.0 * ROCK_WARP_AMP)), 0, l1);
				const int64_t j = wpz * width + wpx;
				const double p_cliff = 1.0 - Math::smoothstep(0.0, CLIFF_REACH, double(cliff_d[j]));
				const double p_boulder = (1.0 - Math::smoothstep(0.0, BOULDER_REACH, double(boulder_d[j]))) * BOULDER_STRENGTH;
				const double p_scree = 1.0 - Math::smoothstep(0.0, SCREE_REACH, double(scree_d[j]));
				const double prox = K_MAX(K_MAX(p_cliff, p_boulder), p_scree);
				const double nb = big_n[i] / 255.0;
				double rocky = 0.0;
				if (prox > 0.0) {
					rocky = Math::smoothstep(ROCKY_LO, ROCKY_HI, prox * (ROCKY_BASE + ROCKY_BIG * nb) + ROCKY_SMALL * (small_n[i] / 255.0 - 0.5));
				}
				rocky = K_MAX(rocky, steep * (0.6 + 0.4 * nb));

				const double canopy_c = k_grid_sample(canopy, gw, gl, double(px), double(pz), GRID_CELL);
				double lit = 0.0;
				if (litter_ok) {
					lit = 1.0 - Math::smoothstep(0.0, LITTER_TREE_FADE, double(tree_d[i]) + LITTER_EDGE_NOISE * (small_n[i] / 255.0 - 0.5));
					// Strays: only where nearby trees can supply them.
					const double supply = Math::smoothstep(LITTER_SUPPLY_LO, LITTER_SUPPLY_HI, canopy_c);
					if (supply > 0.0) {
						int64_t k = j;
						const double glen = std::sqrt(dx * dx + dz * dz);
						if (glen > 0.04) {
							k = k_clampi(int64_t(std::round(double(wpz) - dz / glen * LITTER_UPHILL_STEP)), 0, l1) * width + k_clampi(int64_t(std::round(double(wpx) - dx / glen * LITTER_UPHILL_STEP)), 0, w1);
						}
						const double collar = K_MAX(
								LITTER_COLLAR_SIDE * (1.0 - Math::smoothstep(0.0, LITTER_COLLAR_REACH, double(K_MIN(boulder_d[j], dead_d[j])))),
								1.0 - Math::smoothstep(0.0, LITTER_COLLAR_REACH, double(K_MIN(boulder_d[k], dead_d[k]))));
						const double curv = (double(heights[pz * width + K_MAX(px - curv_radius, 0)]) + double(heights[pz * width + K_MIN(px + curv_radius, w1)]) + double(heights[K_MAX(pz - curv_radius, 0) * width + px]) + double(heights[K_MIN(pz + curv_radius, l1) * width + px]) - 4.0 * double(heights[i])) / double(curv_radius * curv_radius);
						const double hollow = Math::smoothstep(LITTER_CURV_LO, LITTER_CURV_HI, curv);
						lit = K_MAX(lit, supply * K_MAX(collar, hollow));
					}
					// Wind drifts.
					const double drift = Math::smoothstep(LITTER_DRIFT_LO, LITTER_DRIFT_HI, 0.6 * nb + 0.4 * (small_n[i] / 255.0));
					lit = K_MAX(lit, drift * Math::smoothstep(LITTER_DRIFT_SUPPLY_LO, LITTER_DRIFT_SUPPLY_HI, canopy_c));
					lit *= Math::smoothstep(LITTER_ROAD_CLEAR, LITTER_ROAD_REACH, double(road_d[j]));
					lit *= Math::smoothstep(LITTER_NY_NONE, LITTER_NY_FULL, ny) * Math::smoothstep(LITTER_CLIFF_CLEAR, LITTER_CLIFF_REACH, double(cliff_d[j]));
				}

				// Bare soil: the road verge, worn patches, steep ground, cliffs.
				double bare = K_MAX(verge, BARE_WORN_MAX * double(worn_bytes[i]) / 255.0);
				bare = K_MAX(bare, K_MAX(1.0 - Math::smoothstep(BARE_NY_FULL, BARE_NY_NONE, ny), 1.0 - Math::smoothstep(BARE_CLIFF_CLEAR, BARE_CLIFF_REACH, double(cliff_d[j]))));

				if (rocky < ROCKY_MIN) {
					rocky = 0.0;
				}
				// The vertex takes the texture with the largest weight.
				const double lw = k_clampf(lit / LITTER_FULL, 0.0, 1.0);
				const double w_litter = lw * (1.0 - g * lw);
				const double w_ground = bare * (1.0 - lw);
				const double w_grass = K_MAX(1.0 - w_litter - w_ground, 0.0);
				bare_sum += w_ground;
				if (lw >= 1.0) {
					litter_full++;
				} else if (lit > LITTER_MIN) {
					litter_ramp++;
				}
				int64_t d_id = grass_id;
				double d_w = w_grass;
				if (w_litter > d_w) {
					d_w = w_litter;
					d_id = litter_id;
				}
				if (w_ground > d_w) {
					d_w = w_ground;
					d_id = ground_id;
				}
				if (rocky <= d_w * (1.0 - rocky)) {
					n_soil++;
					dom[i] = uint8_t(d_id);
					continue;
				}

				// Rock type: correlated weights + regional noise, highest wins.
				const double ta = type_a[i] / 255.0;
				const double tb = type_b[i] / 255.0;
				const double shade = K_MAX(canopy_c, k_grid_sample(cliff_shade, gw, gl, double(px), double(pz), GRID_CELL));
				const double flat = Math::smoothstep(STEEP_NY_NONE, FLAT_NY, ny);
				const double core = 1.0 - Math::smoothstep(0.0, 2.5, double(cliff_d[j]));
				const double w_face = 0.3 + 1.1 * core + 1.0 * steep + 0.5 * ta;
				const double w_moss = 1.7 * Math::smoothstep(MOSS_SHADE_LO, MOSS_SHADE_HI, shade + 0.25 * (tb - 0.5)) + 0.2 * tb;
				const double w_trail = 1.1 * p_scree + 0.8 * p_boulder / BOULDER_STRENGTH + 0.5 * (1.0 - ta);
				const double w_terr = 0.4 + 0.7 * g + 0.6 * tb;
				const double w_coast = flat * (0.5 + 1.2 * p_cliff * (1.0 - core)) + 0.5 * (1.0 - tb);
				int rock = 0;
				double best = w_face;
				if (w_moss > best) {
					best = w_moss;
					rock = 1;
				}
				if (w_trail > best) {
					best = w_trail;
					rock = 2;
				}
				if (w_terr > best) {
					best = w_terr;
					rock = 3;
				}
				if (w_coast > best) {
					rock = 4;
				}
				type_counts[rock]++;
				n_rock++;
				dom[i] = uint8_t(rock_ids[rock]);
			}
		}
		grass_total += grass_sum;
		bare_total += bare_sum;
	}

	PackedInt32Array type_array;
	for (int k = 0; k < 5; k++) {
		type_array.push_back(int32_t(type_counts[k]));
	}
	result["control"] = control_array;
	result["patch_shade"] = shade_array;
	result["dom"] = dom_array;
	result["road"] = n_road;
	result["soil"] = n_soil;
	result["rock"] = n_rock;
	result["type_counts"] = type_array;
	result["grass_sum"] = grass_total;
	result["bare_sum"] = bare_total;
	result["litter_full"] = litter_full;
	result["litter_ramp"] = litter_ramp;
	return result;
}

// GrassScatter.stamp_circles() (scripts/terrain/grass_scatter.gd): every circle's _stamp_circle
// on a copy of the field. A pixel ends with the smallest distance written to it whatever the order.
PackedFloat32Array TerrainKernels::stamp_circles(PackedFloat32Array p_field, int p_width, int p_length, const PackedFloat64Array &p_circles, double p_cap) const {
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_field.size() != width * length || p_circles.size() % 3 != 0, p_field);
	if (p_circles.is_empty()) {
		return p_field;
	}
	const double *circles = p_circles.ptr();
	const int64_t count = p_circles.size();
	float *field = p_field.ptrw();
	for (int64_t ci = 0; ci < count; ci += 3) {
		const double cx = circles[ci];
		const double cz = circles[ci + 1];
		const double r = circles[ci + 2];
		const double reach = r + p_cap;
		const int64_t x0 = K_MAX(0, int64_t(std::floor(cx - reach)));
		const int64_t x1 = K_MIN(width - 1, int64_t(std::ceil(cx + reach)));
		const int64_t z0 = K_MAX(0, int64_t(std::floor(cz - reach)));
		const int64_t z1 = K_MIN(length - 1, int64_t(std::ceil(cz + reach)));
		for (int64_t z = z0; z <= z1; z++) {
			const double fz = double(z) - cz;
			const int64_t row = z * width;
			for (int64_t x = x0; x <= x1; x++) {
				const double fx = double(x) - cx;
				const double d = K_MAX(std::sqrt(fx * fx + fz * fz) - r, 0.0);
				if (d < double(field[row + x])) {
					field[row + x] = float(d);
				}
			}
		}
	}
	return p_field;
}

// The road-vertex scans of GrassScatter.bake() and TerrainGroundPaint.paint(): px, pz, 0.0 for
// every control pixel (4 bytes, a little-endian uint32) whose base texture is the road, or whose
// overlay is the road with a blend byte of at least p_min_blend.
PackedFloat64Array TerrainKernels::road_vertex_circles(const PackedByteArray &p_control, int p_width, int p_length, int p_road_id, int p_min_blend) const {
	PackedFloat64Array circles;
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_control.size() != width * length * 4, circles);
	const uint8_t *control = p_control.ptr();
	std::vector<double> found;
	for (int64_t pz = 0; pz < length; pz++) {
		for (int64_t px = 0; px < width; px++) {
			const int64_t o = (pz * width + px) * 4;
			const int64_t c = int64_t(uint32_t(control[o]) | (uint32_t(control[o + 1]) << 8) | (uint32_t(control[o + 2]) << 16) | (uint32_t(control[o + 3]) << 24));
			if (((c >> 27) & 0x1F) == p_road_id || (((c >> 22) & 0x1F) == p_road_id && ((c >> 14) & 0xFF) >= p_min_blend)) {
				found.push_back(double(px));
				found.push_back(double(pz));
				found.push_back(0.0);
			}
		}
	}
	circles.resize(int64_t(found.size()));
	double *out = circles.ptrw();
	for (size_t k = 0; k < found.size(); k++) {
		out[k] = found[k];
	}
	return circles;
}

// The lowest and the highest of a height map, as minf() / maxf() over it find them.
PackedFloat64Array TerrainKernels::height_min_max(const PackedFloat32Array &p_heights) const {
	double lowest = std::numeric_limits<double>::infinity();
	double highest = -std::numeric_limits<double>::infinity();
	const float *heights = p_heights.ptr();
	for (int64_t i = 0; i < p_heights.size(); i++) {
		const double h = heights[i];
		lowest = K_MIN(lowest, h);
		highest = K_MAX(highest, h);
	}
	PackedFloat64Array range;
	range.push_back(lowest);
	range.push_back(highest);
	return range;
}

// GrassScatter._bake_band() for every row, from the ctx dictionary the script's bands read. The
// three sums are added up per band of BAKE_BAND_ROWS rows and then band by band, as in the script.
Dictionary TerrainKernels::grass_bake(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(CURV_RADIUS) K_CONST(CURV_FULL) K_CONST(SLOPE_BARE_NY) K_CONST(SLOPE_FULL_NY) K_CONST(ROCK_GAP) K_CONST(ROCK_FADE)
	K_CONST(VERGE_REACH_MAX) K_CONST(VERGE_NOISE_LO) K_CONST(VERGE_NOISE_HI) K_CONST(VERGE_GRASS_GAP) K_CONST(VERGE_GRASS_FADE)
	K_CONST(CANOPY_MIN_FACTOR) K_CONST(MEADOW_VAR_MIN) K_CONST(WORN_LO) K_CONST(WORN_HI) K_CONST(OPEN_COVERAGE)
	K_CONST(TUSSOCK_ROCK_CLEAR) K_CONST(TUSSOCK_SLOPE_BARE_NY) K_CONST(TUSSOCK_SLOPE_FULL_NY)
	K_CONST(DRY_BASE) K_CONST(DRY_NOISE_WEIGHT) K_CONST(DRY_CONVEX_WEIGHT) K_CONST(DRY_CONCAVE_WEIGHT) K_CONST(DRY_HEIGHT_WEIGHT)
	K_CONST(DRY_EDGE_WEIGHT) K_CONST(DRY_SHADE_WEIGHT)
	K_CONST(TALL_BASE) K_CONST(TALL_CONCAVE_WEIGHT) K_CONST(TALL_CONVEX_WEIGHT) K_CONST(TALL_CLUMP_WEIGHT) K_CONST(TALL_EDGE_MIN)
	K_CONST(BAKE_BAND_ROWS) K_CONST(GRID_CELL)

	const int64_t width = int64_t(p_ctx["width"]);
	const int64_t length = int64_t(p_ctx["length"]);
	const int64_t n = width * length;
	const PackedFloat32Array heights_a = p_ctx["heights"];
	const PackedFloat32Array rock_d_a = p_ctx["rock_d"];
	const PackedFloat32Array canopy_a = p_ctx["canopy_grid"];
	const int64_t gw = int64_t(p_ctx["gw"]);
	const int64_t gl = int64_t(p_ctx["gl"]);
	const PackedByteArray patch_a = p_ctx["patch_n"];
	const PackedByteArray clump_a = p_ctx["clump_n"];
	const PackedByteArray dry_a = p_ctx["dry_n"];
	const PackedByteArray worn_a_a = p_ctx["worn_a"];
	const PackedByteArray worn_b_a = p_ctx["worn_b"];
	const PackedFloat32Array paint_d_a = p_ctx["paint_d"];
	const PackedByteArray verge_a = p_ctx["verge_n"];
	const double h_min = double(p_ctx["height_min"]);
	const double hspan = double(p_ctx["hspan"]);
	const int64_t band_rows = int64_t(BAKE_BAND_ROWS);
	const int64_t curv_radius = int64_t(CURV_RADIUS);
	ERR_FAIL_COND_V(width < 2 || length < 2 || band_rows < 1 || curv_radius < 1 || gw < 1 || gl < 1, result);
	ERR_FAIL_COND_V(heights_a.size() != n || rock_d_a.size() != n || paint_d_a.size() != n || canopy_a.size() != gw * gl, result);
	ERR_FAIL_COND_V(patch_a.size() != n || clump_a.size() != n || dry_a.size() != n || worn_a_a.size() != n || worn_b_a.size() != n || verge_a.size() != n, result);

	const float *heights = heights_a.ptr();
	const float *rock_d = rock_d_a.ptr();
	const float *canopy_grid = canopy_a.ptr();
	const uint8_t *patch_n = patch_a.ptr();
	const uint8_t *clump_n = clump_a.ptr();
	const uint8_t *dry_n = dry_a.ptr();
	const uint8_t *worn_a = worn_a_a.ptr();
	const uint8_t *worn_b = worn_b_a.ptr();
	const float *paint_d = paint_d_a.ptr();
	const uint8_t *verge_n = verge_a.ptr();

	PackedByteArray bytes_array;
	bytes_array.resize(n * 4);
	uint8_t *bytes = bytes_array.ptrw();
	PackedByteArray worn_array;
	worn_array.resize(n);
	uint8_t *worn_out = worn_array.ptrw();
	PackedByteArray verge_array;
	verge_array.resize(n);
	uint8_t *verge_out = verge_array.ptrw();
	for (int64_t i = 0; i < n; i++) {
		verge_out[i] = 0;
	}
	std::vector<float> curv_samples;
	const int64_t w1 = width - 1;
	const int64_t l1 = length - 1;
	const double inv_r2 = 1.0 / double(curv_radius * curv_radius);
	double dens_total = 0.0;
	double dry_total = 0.0;
	double tall_total = 0.0;
	int64_t covered = 0;
	int64_t full = 0;

	for (int64_t z0 = 0; z0 < length; z0 += band_rows) {
		const int64_t z1 = K_MIN(z0 + band_rows, length);
		double dens_sum = 0.0;
		double dry_sum = 0.0;
		double tall_sum = 0.0;
		for (int64_t pz = z0; pz < z1; pz++) {
			const int64_t zm = K_MAX(pz - 1, 0);
			const int64_t zp = K_MIN(pz + 1, l1);
			const int64_t zcm = K_MAX(pz - curv_radius, 0);
			const int64_t zcp = K_MIN(pz + curv_radius, l1);
			const int64_t row = pz * width;
			for (int64_t px = 0; px < width; px++) {
				const int64_t i = row + px;
				const int64_t xm = K_MAX(px - 1, 0);
				const int64_t xp = K_MIN(px + 1, w1);
				const double h = heights[i];
				const double dx = (double(heights[row + xp]) - double(heights[row + xm])) / double(xp - xm);
				const double dz = (double(heights[zp * width + px]) - double(heights[zm * width + px])) / double(zp - zm);
				const double ny = 1.0 / std::sqrt(1.0 + dx * dx + dz * dz);
				const double curv = (double(heights[row + K_MAX(px - curv_radius, 0)]) + double(heights[row + K_MIN(px + curv_radius, w1)]) + double(heights[zcm * width + px]) + double(heights[zcp * width + px]) - 4.0 * h) * inv_r2;
				if ((i & 63) == 0) {
					curv_samples.push_back(float(curv));
				}
				const double cv = k_clampf(curv / CURV_FULL, -1.0, 1.0);
				const double hollow = K_MAX(cv, 0.0);
				const double ridge = K_MAX(-cv, 0.0);

				const double slope_f = Math::smoothstep(SLOPE_BARE_NY, SLOPE_FULL_NY, ny);
				const double rock_f = Math::smoothstep(ROCK_GAP, ROCK_FADE, double(rock_d[i]));
				// The road's verge: worn to soil within `reach` of the stones, grass beyond.
				const double reach = VERGE_REACH_MAX * Math::smoothstep(VERGE_NOISE_LO, VERGE_NOISE_HI, verge_n[i] / 255.0);
				const double pd = paint_d[i];
				if (reach > 0.3) {
					verge_out[i] = uint8_t(int64_t((1.0 - Math::smoothstep(reach * 0.5, reach, pd)) * 255.0 + 0.5));
				}
				const double road_f = Math::smoothstep(reach + VERGE_GRASS_GAP, reach + VERGE_GRASS_GAP + VERGE_GRASS_FADE, pd);
				const double canopy = k_grid_sample(canopy_grid, gw, gl, double(px), double(pz), GRID_CELL);
				const double canopy_f = k_lerpf(1.0, CANOPY_MIN_FACTOR, canopy);
				const double meadow_f = k_lerpf(MEADOW_VAR_MIN, 1.0, patch_n[i] / 255.0);
				const double clump = clump_n[i] / 255.0;
				const double worn_w = Math::smoothstep(WORN_LO, WORN_HI, (int64_t(worn_a[i]) + int64_t(worn_b[i])) / 510.0);
				worn_out[i] = uint8_t(int64_t(worn_w * 255.0 + 0.5));
				const double density = OPEN_COVERAGE * meadow_f * slope_f * rock_f * road_f * canopy_f * (1.0 - worn_w);
				const double tussock = road_f * Math::smoothstep(0.0, TUSSOCK_ROCK_CLEAR, double(rock_d[i])) * Math::smoothstep(TUSSOCK_SLOPE_BARE_NY, TUSSOCK_SLOPE_FULL_NY, ny);

				const double verge = rock_f * road_f; // 0 right at a rock / road edge, 1 in the open
				const double dry = k_clampf(DRY_BASE + DRY_NOISE_WEIGHT * (dry_n[i] / 127.5 - 1.0) + DRY_CONVEX_WEIGHT * ridge - DRY_CONCAVE_WEIGHT * hollow + DRY_HEIGHT_WEIGHT * (h - h_min) / hspan + DRY_EDGE_WEIGHT * (1.0 - verge) - DRY_SHADE_WEIGHT * canopy, 0.0, 1.0);
				const double tall = k_clampf((TALL_BASE + TALL_CONCAVE_WEIGHT * hollow - TALL_CONVEX_WEIGHT * ridge + TALL_CLUMP_WEIGHT * (clump * 2.0 - 1.0)) * k_lerpf(TALL_EDGE_MIN, 1.0, verge), 0.0, 1.0);

				const int64_t o = i * 4;
				bytes[o] = uint8_t(int64_t(density * 255.0 + 0.5));
				bytes[o + 1] = uint8_t(int64_t(dry * 255.0 + 0.5));
				bytes[o + 2] = uint8_t(int64_t(tall * 255.0 + 0.5));
				bytes[o + 3] = uint8_t(int64_t(tussock * 255.0 + 0.5));
				dens_sum += density;
				if (density > 0.15) {
					covered++;
					dry_sum += dry;
					tall_sum += tall;
				}
				if (density > 0.8) {
					full++;
				}
			}
		}
		dens_total += dens_sum;
		dry_total += dry_sum;
		tall_total += tall_sum;
	}

	PackedFloat32Array curv_array;
	curv_array.resize(int64_t(curv_samples.size()));
	float *curv_out = curv_array.ptrw();
	for (size_t k = 0; k < curv_samples.size(); k++) {
		curv_out[k] = curv_samples[k];
	}
	result["bytes"] = bytes_array;
	result["worn"] = worn_array;
	result["verge"] = verge_array;
	result["curv_samples"] = curv_array;
	result["dens_sum"] = dens_total;
	result["covered"] = covered;
	result["full"] = full;
	result["dry_sum"] = dry_total;
	result["tall_sum"] = tall_total;
	return result;
}

// TerrainHeightmap.smooth() (scripts/terrain/heightmap.gd): per pass a horizontal sliding-window
// sum (a double per row), then a vertical one (a 32-bit float per column, as the script keeps it).
PackedFloat32Array TerrainKernels::smooth(const PackedFloat32Array &p_heights, int p_width, int p_length, int p_passes, int p_radius) const {
	const int64_t width = p_width;
	const int64_t length = p_length;
	const int64_t radius = p_radius;
	ERR_FAIL_COND_V(p_width < 1 || p_length < 1 || p_radius < 0 || p_heights.size() != width * length, p_heights);
	if (p_passes <= 0) {
		return p_heights;
	}
	const int64_t window = 2 * radius + 1;
	std::vector<float> current(p_heights.ptr(), p_heights.ptr() + width * length);
	std::vector<float> rows(width * length);
	std::vector<float> col_sum(width);
	for (int pass = 0; pass < p_passes; pass++) {
		for (int64_t pz = 0; pz < length; pz++) {
			const int64_t row_start = pz * width;
			double sum = 0.0;
			for (int64_t dx = -radius; dx <= radius; dx++) {
				sum += double(current[row_start + k_clampi(dx, 0, width - 1)]);
			}
			rows[row_start] = float(sum / double(window));
			for (int64_t px = 1; px < width; px++) {
				const int64_t leaving = k_clampi(px - 1 - radius, 0, width - 1);
				const int64_t entering = k_clampi(px + radius, 0, width - 1);
				sum += double(current[row_start + entering]) - double(current[row_start + leaving]);
				rows[row_start + px] = float(sum / double(window));
			}
		}
		for (int64_t c = 0; c < width; c++) {
			col_sum[c] = 0.0f;
		}
		for (int64_t dz = -radius; dz <= radius; dz++) {
			const int64_t base = k_clampi(dz, 0, length - 1) * width;
			for (int64_t c = 0; c < width; c++) {
				col_sum[c] = float(double(col_sum[c]) + double(rows[base + c]));
			}
		}
		for (int64_t c = 0; c < width; c++) {
			current[c] = float(double(col_sum[c]) / double(window));
		}
		for (int64_t pz = 1; pz < length; pz++) {
			const int64_t leaving_base = k_clampi(pz - 1 - radius, 0, length - 1) * width;
			const int64_t entering_base = k_clampi(pz + radius, 0, length - 1) * width;
			const int64_t out_base = pz * width;
			for (int64_t c = 0; c < width; c++) {
				col_sum[c] = float(double(col_sum[c]) + (double(rows[entering_base + c]) - double(rows[leaving_base + c])));
				current[out_base + c] = float(double(col_sum[c]) / double(window));
			}
		}
	}
	PackedFloat32Array out_array;
	out_array.resize(width * length);
	float *out = out_array.ptrw();
	for (int64_t i = 0; i < width * length; i++) {
		out[i] = current[i];
	}
	return out_array;
}

// The nearest point of segment a-b to (px, pz), as the road's loops find it with Vector2
// arithmetic (32-bit float): sets r_t (a double, as the script's variable) and returns the distance.
static inline double k_segment_distance(KVec2 p_a, KVec2 p_seg, double p_len_sq, int64_t p_px, int64_t p_pz, double &r_t) {
	const KVec2 q = { float(p_px), float(p_pz) };
	double t = 0.0;
	if (p_len_sq > 0.00001) {
		const float dot = (q.x - p_a.x) * p_seg.x + (q.y - p_a.y) * p_seg.y;
		t = k_clampf(double(dot) / p_len_sq, 0.0, 1.0);
	}
	const float tf = float(t);
	const KVec2 closest = { p_a.x + p_seg.x * tf, p_a.y + p_seg.y * tf };
	r_t = t;
	return double(std::sqrt((q.x - closest.x) * (q.x - closest.x) + (q.y - closest.y) * (q.y - closest.y)));
}

// TerrainRoad._raster_band() (scripts/terrain/road.gd) for every row: the corridor weight and
// the paint blend, the strongest value per pixel over the segments in their order.
// consts: ROAD_HALF_WIDTH, ROAD_EDGE_SOFTNESS, ROAD_TEXTURE_HALF_WIDTH, ROAD_EDGE_NOISE_STRENGTH,
// ROAD_TEXTURE_BLEND_WIDTH.
Dictionary TerrainKernels::road_raster(const PackedVector2Array &p_path, int p_width, int p_length, const Ref<FastNoiseLite> &p_edge_noise, const PackedFloat64Array &p_consts) const {
	Dictionary result;
	const int64_t width = p_width;
	const int64_t length = p_length;
	ERR_FAIL_COND_V(p_edge_noise.is_null() || p_consts.size() != 5 || p_width < 1 || p_length < 1, result);
	const double half_width = p_consts[0];
	const double edge_softness = p_consts[1];
	const double texture_half_width = p_consts[2];
	const double edge_noise_strength = p_consts[3];
	const double texture_blend_width = p_consts[4];

	PackedFloat32Array weight_array;
	weight_array.resize(width * length);
	float *road_weight = weight_array.ptrw();
	PackedFloat32Array blend_array;
	blend_array.resize(width * length);
	float *road_blend = blend_array.ptrw();
	for (int64_t i = 0; i < width * length; i++) {
		road_weight[i] = 0.0f;
		road_blend[i] = 0.0f;
	}
	const Vector2 *path = p_path.ptr();
	FastNoiseLite *edge_noise = p_edge_noise.ptr();
	for (int64_t i = 0; i + 1 < p_path.size(); i++) {
		const KVec2 a = { float(path[i].x), float(path[i].y) };
		const KVec2 b = { float(path[i + 1].x), float(path[i + 1].y) };
		const int64_t min_pz = k_clampi(int64_t(std::floor(double(K_MIN(a.y, b.y)) - half_width)), 0, length - 1);
		const int64_t max_pz = k_clampi(int64_t(std::ceil(double(K_MAX(a.y, b.y)) + half_width)), 0, length - 1);
		if (min_pz > max_pz) {
			continue;
		}
		const KVec2 seg = { b.x - a.x, b.y - a.y };
		const double seg_len_sq = seg.x * seg.x + seg.y * seg.y;
		const int64_t min_px = k_clampi(int64_t(std::floor(double(K_MIN(a.x, b.x)) - half_width)), 0, width - 1);
		const int64_t max_px = k_clampi(int64_t(std::ceil(double(K_MAX(a.x, b.x)) + half_width)), 0, width - 1);
		for (int64_t pz = min_pz; pz <= max_pz; pz++) {
			for (int64_t px = min_px; px <= max_px; px++) {
				double t = 0.0;
				const double d = k_segment_distance(a, seg, seg_len_sq, px, pz, t);
				if (d > half_width) {
					continue;
				}
				const int64_t idx = pz * width + px;
				const double grade_weight = 1.0 - Math::smoothstep(half_width - edge_softness, half_width, d);
				if (grade_weight > double(road_weight[idx])) {
					road_weight[idx] = float(grade_weight);
				}
				const double painted_half_width = texture_half_width + double(edge_noise->get_noise_2d(float(px), float(pz))) * edge_noise_strength;
				const double blend_frac = 1.0 - Math::smoothstep(painted_half_width - texture_blend_width, painted_half_width, d);
				if (blend_frac > double(road_blend[idx])) {
					road_blend[idx] = float(blend_frac);
				}
			}
		}
	}
	result["weight"] = weight_array;
	result["blend"] = blend_array;
	return result;
}

// TerrainRoad._grade_level_bed() from the nearest-segment search (_bed_band) to the crease
// smoothing: the level bed and its banks. consts: ROAD_BANK_REACH, ROAD_BED_HALF_WIDTH,
// ROAD_BANK_SLOPE, ROAD_BANK_OBSTACLE_FADE, ROAD_BANK_SMOOTH_PASSES.
// Returns {"heights", "max_cut", "max_fill", "zone"} (zone = pixels in the smoothing zone).
Dictionary TerrainKernels::road_bed(PackedFloat32Array p_heights, const PackedFloat32Array &p_obst, const PackedVector2Array &p_line, const PackedFloat32Array &p_prof, int p_width, int p_length, const PackedFloat64Array &p_consts) const {
	Dictionary result;
	const int64_t width = p_width;
	const int64_t length = p_length;
	const int64_t total = width * length;
	ERR_FAIL_COND_V(p_consts.size() != 5 || p_width < 3 || p_length < 3 || p_heights.size() != total || p_obst.size() != total, result);
	ERR_FAIL_COND_V(p_line.size() < 2 || p_prof.size() != p_line.size(), result);
	const double reach = p_consts[0];
	const double bed_half_width = p_consts[1];
	const double bank_slope = p_consts[2];
	const double obstacle_fade = p_consts[3];
	const int64_t smooth_passes = int64_t(p_consts[4]);

	const Vector2 *line = p_line.ptr();
	const float *prof = p_prof.ptr();
	const float *obst = p_obst.ptr();
	const float inf = std::numeric_limits<float>::infinity();
	std::vector<float> best_d(total, inf);
	std::vector<float> bed_h(total, 0.0f);
	for (int64_t i = 0; i + 1 < p_line.size(); i++) {
		const KVec2 a = { float(line[i].x), float(line[i].y) };
		const KVec2 b = { float(line[i + 1].x), float(line[i + 1].y) };
		const int64_t z0 = k_clampi(int64_t(std::floor(double(K_MIN(a.y, b.y)) - reach)), 0, length - 1);
		const int64_t z1 = k_clampi(int64_t(std::ceil(double(K_MAX(a.y, b.y)) + reach)), 0, length - 1);
		if (z0 > z1) {
			continue;
		}
		const KVec2 seg = { b.x - a.x, b.y - a.y };
		const double sl2 = seg.x * seg.x + seg.y * seg.y;
		const int64_t x0 = k_clampi(int64_t(std::floor(double(K_MIN(a.x, b.x)) - reach)), 0, width - 1);
		const int64_t x1 = k_clampi(int64_t(std::ceil(double(K_MAX(a.x, b.x)) + reach)), 0, width - 1);
		for (int64_t pz = z0; pz <= z1; pz++) {
			for (int64_t px = x0; px <= x1; px++) {
				double t = 0.0;
				const double d = k_segment_distance(a, seg, sl2, px, pz, t);
				const int64_t idx = pz * width + px;
				if (d >= reach || d >= double(best_d[idx])) {
					continue;
				}
				best_d[idx] = float(d);
				bed_h[idx] = float(k_lerpf(prof[i], prof[i + 1], t));
			}
		}
	}

	float *heights = p_heights.ptrw();
	std::vector<float> orig(heights, heights + total);
	std::vector<int32_t> zone;
	std::vector<uint8_t> mark(total, 0);
	double max_cut = 0.0;
	double max_fill = 0.0;
	for (int64_t idx = 0; idx < total; idx++) {
		if (best_d[idx] == inf) {
			continue;
		}
		const double d = best_d[idx];
		const double bed = bed_h[idx];
		const double slack = K_MAX(0.0, d - bed_half_width) * bank_slope;
		const double shaped = k_clampf(double(orig[idx]), bed - slack, bed + slack);
		double fade = 1.0 - Math::smoothstep(reach - 4.0, reach, d);
		fade *= Math::smoothstep(0.0, obstacle_fade, double(obst[idx]));
		const double nh = k_lerpf(orig[idx], shaped, fade);
		if (std::fabs(nh - double(orig[idx])) < 0.001) {
			continue;
		}
		heights[idx] = float(nh);
		max_cut = K_MAX(max_cut, double(orig[idx]) - nh);
		max_fill = K_MAX(max_fill, nh - double(orig[idx]));
		// The smoothing zone: the changed pixel and a 1 px rim, away from obstacles.
		const int64_t cx = idx % width;
		const int64_t cz = idx / width;
		for (int64_t dz = -1; dz <= 1; dz++) {
			for (int64_t dx = -1; dx <= 1; dx++) {
				const int64_t zx = cx + dx;
				const int64_t zz = cz + dz;
				if (zx < 1 || zz < 1 || zx >= width - 1 || zz >= length - 1) {
					continue;
				}
				const int64_t zi = zz * width + zx;
				if (mark[zi] == 0 && double(obst[zi]) >= 2.0) {
					mark[zi] = 1;
					zone.push_back(int32_t(zi));
				}
			}
		}
	}
	// Round the bed-edge, bank-top and bank-toe creases.
	std::vector<float> prev(total);
	for (int64_t pass = 0; pass < smooth_passes; pass++) {
		for (int64_t i = 0; i < total; i++) {
			prev[i] = heights[i];
		}
		for (size_t k = 0; k < zone.size(); k++) {
			const int64_t zi = zone[k];
			double s = 0.0;
			for (int64_t dz = -1; dz <= 1; dz++) {
				for (int64_t dx = -1; dx <= 1; dx++) {
					s += double(prev[zi + dz * width + dx]);
				}
			}
			heights[zi] = float(s / 9.0);
		}
	}
	result["heights"] = p_heights;
	result["max_cut"] = max_cut;
	result["max_fill"] = max_fill;
	result["zone"] = int64_t(zone.size());
	return result;
}

// Runs p_fn(from, to) over [0, p_rows) in up to eight slices, each on a thread of its own, and
// waits for them. For loops whose rows are independent and whose cost is the engine's noise
// functions (asked through the bindings, which take no lock): the result is the single loop's.
template <typename F>
static void k_parallel_rows(int64_t p_rows, F p_fn) {
	int64_t slices = int64_t(std::thread::hardware_concurrency());
	slices = K_MIN(K_MIN(slices, int64_t(8)), p_rows / 16);
	if (slices <= 1) {
		p_fn(int64_t(0), p_rows);
		return;
	}
	const int64_t per_slice = (p_rows + slices - 1) / slices;
	std::vector<std::thread> threads;
	for (int64_t from = 0; from < p_rows; from += per_slice) {
		const int64_t to = K_MIN(from + per_slice, p_rows);
		threads.emplace_back([&p_fn, from, to]() { p_fn(from, to); });
	}
	for (std::thread &t : threads) {
		t.join();
	}
}

// The engine's Color arithmetic, which is 32-bit float.
struct KColor {
	float r;
	float g;
	float b;
};
// Color.lerp(): each channel from + (to - from) * weight, in 32-bit floats.
static inline KColor k_color_lerp(KColor p_from, KColor p_to, double p_weight) {
	const float w = float(p_weight);
	return { p_from.r + (p_to.r - p_from.r) * w, p_from.g + (p_to.g - p_from.g) * w, p_from.b + (p_to.b - p_from.b) * w };
}
// Color(r, g, b) from three script floats.
static inline KColor k_color(double p_r, double p_g, double p_b) {
	return { float(p_r), float(p_g), float(p_b) };
}

// MountainWalls._apron_height_band() (scripts/terrain/mountain_walls.gd) for every row, from the
// ctx the script's bands read (plus "section_noise", the noise of _ledge_share). The noises are
// asked from the objects passed in.
Dictionary TerrainKernels::apron_heights(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(APRON_WIDTH) K_CONST(APRON_PLAN_SHIFT) K_CONST(APRON_ENVELOPE_MIN) K_CONST(APRON_ENVELOPE_MAX)
	K_CONST(APRON_CONNECT_ENVELOPE_NONE) K_CONST(APRON_CONNECT_ENVELOPE_FULL) K_CONST(APRON_EDGE_BLEND) K_CONST(APRON_SPUR_HEIGHT)
	K_CONST(APRON_RELIEF_START) K_CONST(APRON_RELIEF_FULL) K_CONST(APRON_RELIEF) K_CONST(APRON_ENVELOPE_FLOOR)
	K_CONST(APRON_CONNECT_GRADE) K_CONST(APRON_CONNECT_START) K_CONST(APRON_TERRACE_WARP) K_CONST(APRON_TERRACE_HEIGHT)
	K_CONST(APRON_TERRACE_FACE) K_CONST(APRON_TERRACE_STRENGTH) K_CONST(APRON_TERRACE_TOP)

	const int64_t rows = int64_t(p_ctx["rows"]);
	const int64_t side = int64_t(p_ctx["side"]);
	const int64_t table_size = int64_t(p_ctx["table_size"]);
	const Dictionary ramp_tables = p_ctx["ramp_tables"];
	const PackedFloat32Array grades_a = p_ctx["grade"];
	const PackedFloat32Array edge_heights_a = p_ctx["edge_height"];
	const PackedFloat32Array edge_grades_a = p_ctx["edge_grade"];
	const PackedFloat32Array base_heights_a = p_ctx["base_height"];
	const Ref<FastNoiseLite> plan_noise = p_ctx["plan_noise"];
	const Ref<FastNoiseLite> envelope_noise = p_ctx["envelope_noise"];
	const Ref<FastNoiseLite> spur_noise = p_ctx["spur_noise"];
	const Ref<FastNoiseLite> relief_noise = p_ctx["relief_noise"];
	const Ref<FastNoiseLite> terrace_noise = p_ctx["terrace_noise"];
	const Ref<FastNoiseLite> section_noise = p_ctx["section_noise"];
	const int64_t apron_width = int64_t(APRON_WIDTH);
	ERR_FAIL_COND_V(rows < 1 || apron_width < 1 || table_size < 2, result);
	ERR_FAIL_COND_V(grades_a.size() < rows || edge_heights_a.size() < rows || edge_grades_a.size() < rows || base_heights_a.size() < rows, result);
	ERR_FAIL_COND_V(plan_noise.is_null() || envelope_noise.is_null() || spur_noise.is_null() || relief_noise.is_null() || terrace_noise.is_null() || section_noise.is_null(), result);

	PackedFloat32Array heights_array;
	heights_array.resize(apron_width * rows);
	float *heights = heights_array.ptrw();
	PackedFloat32Array envelopes_array;
	envelopes_array.resize(rows);
	float *envelopes = envelopes_array.ptrw();
	double crest_min = std::numeric_limits<double>::infinity();
	double crest_max = -std::numeric_limits<double>::infinity();
	// Each row's ramp table, looked up here: the dictionary is not read from the threads.
	std::vector<PackedFloat32Array> row_ramps;
	for (int64_t row = 0; row < rows; row++) {
		const int64_t grade_key = int64_t(std::round(double(grades_a[row]) * 100.0));
		ERR_FAIL_COND_V(!ramp_tables.has(grade_key), result);
		row_ramps.push_back(PackedFloat32Array(ramp_tables[grade_key]));
		ERR_FAIL_COND_V(row_ramps[row].size() < table_size, result);
	}
	const float *edge_heights = edge_heights_a.ptr();
	const float *edge_grades = edge_grades_a.ptr();
	const float *base_heights = base_heights_a.ptr();
	FastNoiseLite *plan_n = plan_noise.ptr();
	FastNoiseLite *envelope_n = envelope_noise.ptr();
	FastNoiseLite *spur_n = spur_noise.ptr();
	FastNoiseLite *relief_n = relief_noise.ptr();
	FastNoiseLite *terrace_n = terrace_noise.ptr();
	FastNoiseLite *section_n = section_noise.ptr();
	std::mutex merge;
	k_parallel_rows(rows, [&](int64_t p_from, int64_t p_to) {
	double slice_min = std::numeric_limits<double>::infinity();
	double slice_max = -std::numeric_limits<double>::infinity();
	for (int64_t row = p_from; row < p_to; row++) {
		const float *ramp = row_ramps[row].ptr();
		const double edge_height = edge_heights[row];
		const double edge_grade = edge_grades[row];
		const double base_height = base_heights[row];
		const double plan_shift = double(plan_n->get_noise_1d(float(row))) * APRON_PLAN_SHIFT;
		const double envelope = k_lerpf(APRON_ENVELOPE_MIN, APRON_ENVELOPE_MAX, Math::smoothstep(-0.4, 0.4, double(envelope_n->get_noise_1d(float(row)))));
		const double connect = Math::smoothstep(APRON_CONNECT_ENVELOPE_NONE, APRON_CONNECT_ENVELOPE_FULL, envelope);
		const double ledge_share = Math::smoothstep(-0.12, 0.12, double(section_n->get_noise_1d(float(row + side * 4096))));
		envelopes[row] = float((envelope - APRON_ENVELOPE_MIN) / (APRON_ENVELOPE_MAX - APRON_ENVELOPE_MIN));
		double crest = -std::numeric_limits<double>::infinity();
		for (int64_t a = 0; a < apron_width; a++) {
			const double out = double(side == 0 ? apron_width - a : a + 1); // m out from the map's edge
			const double shifted = K_MAX(out + plan_shift * Math::smoothstep(0.0, APRON_EDGE_BLEND, out), out * 0.35);
			const int64_t s0 = K_MIN(int64_t(shifted), table_size - 2);
			double rise = k_lerpf(ramp[s0], ramp[s0 + 1], shifted - double(s0));
			rise += Math::smoothstep(8.0, 50.0, shifted) * APRON_SPUR_HEIGHT * (0.5 + 0.5 * double(spur_n->get_noise_2d(float(out * 0.25), float(row))));
			rise += Math::smoothstep(APRON_RELIEF_START, APRON_RELIEF_FULL, shifted) * APRON_RELIEF * (0.5 + 0.5 * double(relief_n->get_noise_2d(float(out), float(row))));
			rise = K_MIN(rise, APRON_ENVELOPE_FLOOR) + envelope * K_MAX(rise - APRON_ENVELOPE_FLOOR, 0.0);
			rise += connect * APRON_CONNECT_GRADE * K_MAX(shifted - APRON_CONNECT_START, 0.0);
			// Faces and ledges, at the base only.
			const double shift = double(terrace_n->get_noise_2d(float(out), float(row))) * APRON_TERRACE_WARP;
			const double steps = (rise + shift) / APRON_TERRACE_HEIGHT;
			const double stepped = (std::floor(steps) + Math::smoothstep(0.0, APRON_TERRACE_FACE, steps - std::floor(steps))) * APRON_TERRACE_HEIGHT - shift;
			rise = k_lerpf(rise, stepped, APRON_TERRACE_STRENGTH * ledge_share * Math::smoothstep(4.0, 20.0, out) * (1.0 - Math::smoothstep(APRON_TERRACE_TOP * 0.4, APRON_TERRACE_TOP, rise)));
			const double body = base_height + rise;
			const double near = edge_height + edge_grade * out;
			const double h = k_lerpf(near, body, Math::smoothstep(0.0, APRON_EDGE_BLEND, out));
			heights[row * apron_width + a] = float(h);
			crest = K_MAX(crest, h - edge_height);
		}
		slice_min = K_MIN(slice_min, crest);
		slice_max = K_MAX(slice_max, crest);
	}
	std::lock_guard<std::mutex> lock(merge);
	crest_min = K_MIN(crest_min, slice_min);
	crest_max = K_MAX(crest_max, slice_max);
	});
	result["heights"] = heights_array;
	result["envelopes"] = envelopes_array;
	result["crest_min"] = crest_min;
	result["crest_max"] = crest_max;
	return result;
}

// The mountain's ground and colour at one pixel, shared by the side aprons and the north apron:
// what _apron_color_band and TerrainCastle._north_color_band work out from the slope, the height
// above the edge and the four neighbours. Writes the control pixel; returns the pixel's own colour.
struct KMountainShade {
	double turf_ny_none, turf_ny_full, turf_top, turf_fade, turf_amount;
	double snow_from, snow_full, snow_wander, snow_ny_none, snow_ny_full;
	double crease_shade, crease_min, crease_max, strata_shade, strata_period, shade_min;
	int64_t turf_id, snow_id, rock_id;
	KColor tint, turf_tint, snow_tint;
};

// The consts both colour kernels read into a KMountainShade.
#define K_MOUNTAIN_SHADE(m_shade) \
	K_CONST(APRON_TURF_NY_NONE) K_CONST(APRON_TURF_NY_FULL) K_CONST(APRON_TURF_TOP) K_CONST(APRON_TURF_FADE) K_CONST(APRON_TURF_AMOUNT) \
	K_CONST(APRON_TURF_ID) K_CONST(APRON_SNOW_ID) K_CONST(APRON_SNOW_FROM) K_CONST(APRON_SNOW_FULL) K_CONST(APRON_SNOW_WANDER) \
	K_CONST(APRON_SNOW_NY_NONE) K_CONST(APRON_SNOW_NY_FULL) K_CONST(APRON_CREASE_SHADE) K_CONST(APRON_CREASE_MIN) K_CONST(APRON_CREASE_MAX) \
	K_CONST(APRON_STRATA_SHADE) K_CONST(APRON_STRATA_PERIOD) K_CONST(APRON_SHADE_MIN) \
	K_CONST(TINT_R) K_CONST(TINT_G) K_CONST(TINT_B) K_CONST(TURF_TINT_R) K_CONST(TURF_TINT_G) K_CONST(TURF_TINT_B) \
	K_CONST(SNOW_TINT_R) K_CONST(SNOW_TINT_G) K_CONST(SNOW_TINT_B) \
	KMountainShade m_shade; \
	m_shade.turf_ny_none = APRON_TURF_NY_NONE; m_shade.turf_ny_full = APRON_TURF_NY_FULL; m_shade.turf_top = APRON_TURF_TOP; \
	m_shade.turf_fade = APRON_TURF_FADE; m_shade.turf_amount = APRON_TURF_AMOUNT; m_shade.snow_from = APRON_SNOW_FROM; \
	m_shade.snow_full = APRON_SNOW_FULL; m_shade.snow_wander = APRON_SNOW_WANDER; m_shade.snow_ny_none = APRON_SNOW_NY_NONE; \
	m_shade.snow_ny_full = APRON_SNOW_NY_FULL; m_shade.crease_shade = APRON_CREASE_SHADE; m_shade.crease_min = APRON_CREASE_MIN; \
	m_shade.crease_max = APRON_CREASE_MAX; m_shade.strata_shade = APRON_STRATA_SHADE; m_shade.strata_period = APRON_STRATA_PERIOD; \
	m_shade.shade_min = APRON_SHADE_MIN; m_shade.turf_id = int64_t(APRON_TURF_ID); m_shade.snow_id = int64_t(APRON_SNOW_ID); \
	m_shade.tint = k_color(TINT_R, TINT_G, TINT_B); m_shade.turf_tint = k_color(TURF_TINT_R, TURF_TINT_G, TURF_TINT_B); \
	m_shade.snow_tint = k_color(SNOW_TINT_R, SNOW_TINT_G, SNOW_TINT_B);

// p_x, p_z: the pixel's place in its strip (the noise is sampled there); p_above: its height
// above the edge. r_turf / r_snow: the weights, for the callers' counts.
static inline KColor k_mountain_shade(const KMountainShade &p_s, FastNoiseLite *p_noise, double p_x, double p_z, double p_h, double p_h_x0, double p_h_x1, double p_h_z0, double p_h_z1, double p_x_span, double p_z_span, double p_above, bool p_bare, int32_t &r_control, double &r_turf, double &r_snow) {
	const double dx = (p_h_x1 - p_h_x0) / p_x_span;
	const double dz = (p_h_z1 - p_h_z0) / p_z_span;
	const double ny = 1.0 / std::sqrt(1.0 + dx * dx + dz * dz);
	// Turf on ledges, low on the mountain only.
	double turf = Math::smoothstep(p_s.turf_ny_none, p_s.turf_ny_full, ny) * (1.0 - Math::smoothstep(p_s.turf_top - p_s.turf_fade, p_s.turf_top, p_above)) * p_s.turf_amount;
	// Snow on the tips.
	double snow = Math::smoothstep(p_s.snow_from, p_s.snow_full, p_above + p_s.snow_wander * double(p_noise->get_noise_2d(float(p_x * 2.0 + 50.0), float(p_z * 2.0)))) * Math::smoothstep(p_s.snow_ny_none, p_s.snow_ny_full, ny);
	if (p_bare) {
		turf = 0.0;
		snow = 0.0;
	}
	r_control = snow > 0.02 ? k_pack(p_s.rock_id, p_s.snow_id, snow) : k_pack(p_s.rock_id, p_s.turf_id, turf);
	// Brightness: creases darker, edges lighter; faint layers by height; a mild broad variation.
	const double curvature = p_h_x0 + p_h_x1 + p_h_z0 + p_h_z1 - 4.0 * p_h;
	double shade = k_clampf(1.0 - curvature * p_s.crease_shade, p_s.crease_min, p_s.crease_max) / p_s.crease_max;
	shade *= 1.0 - p_s.strata_shade * (0.5 + 0.5 * UtilityFunctions::sin((p_h + 4.0 * double(p_noise->get_noise_2d(float(p_x * 3.0), float(p_z * 3.0)))) * K_TAU / p_s.strata_period));
	shade *= k_lerpf(p_s.shade_min, 1.0, 0.5 + 0.5 * double(p_noise->get_noise_2d(float(p_x), float(p_z))));
	const KColor tint = k_color_lerp(k_color_lerp(p_s.tint, p_s.turf_tint, turf), p_s.snow_tint, snow);
	shade = k_lerpf(shade, 1.0, snow * 0.7); // snow fills creases and covers the rock's layers
	r_turf = turf;
	r_snow = snow;
	return k_color(shade * double(tint.r), shade * double(tint.g), shade * double(tint.b));
}

// MountainWalls._apron_color_band() for every row, from the ctx the script's bands read.
Dictionary TerrainKernels::apron_colors(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(APRON_WIDTH) K_CONST(APRON_COLOR_BLEND) K_CONST(MAP_WIDTH) K_CONST(MAP_LENGTH)
	K_MOUNTAIN_SHADE(ms)

	const int64_t rows = int64_t(p_ctx["rows"]);
	const int64_t side = int64_t(p_ctx["side"]);
	const PackedFloat32Array heights_a = p_ctx["heights"];
	const PackedFloat32Array edge_heights_a = p_ctx["edge_height"];
	const PackedByteArray on_shoulder_a = p_ctx["on_shoulder"];
	const PackedByteArray map_color_a = p_ctx["map_color"];
	const Ref<FastNoiseLite> shade_noise = p_ctx["shade_noise"];
	ms.rock_id = int64_t(p_ctx["rock_id"]);
	const int64_t apron_width = int64_t(APRON_WIDTH);
	const int64_t map_width = int64_t(MAP_WIDTH);
	const int64_t map_length = int64_t(MAP_LENGTH);
	ERR_FAIL_COND_V(rows < 1 || apron_width < 1 || shade_noise.is_null(), result);
	ERR_FAIL_COND_V(heights_a.size() != apron_width * rows || edge_heights_a.size() < rows, result);
	ERR_FAIL_COND_V(!on_shoulder_a.is_empty() && on_shoulder_a.size() != apron_width * rows, result);
	ERR_FAIL_COND_V(!map_color_a.is_empty() && map_color_a.size() < K_MIN(rows, map_length) * map_width * 4, result);

	const float *heights = heights_a.ptr();
	const uint8_t *on_shoulder = on_shoulder_a.ptr();
	const uint8_t *map_color = map_color_a.ptr();
	FastNoiseLite *noise = shade_noise.ptr();
	PackedInt32Array control_array;
	control_array.resize(apron_width * rows);
	int32_t *control = control_array.ptrw();
	PackedByteArray color_array;
	color_array.resize(apron_width * rows * 4);
	uint8_t *color = color_array.ptrw();
	int64_t turf_px = 0;
	int64_t snow_px = 0;
	const float *edge_heights = edge_heights_a.ptr();
	const bool has_shoulder = !on_shoulder_a.is_empty();
	const bool has_map_color = !map_color_a.is_empty();
	std::mutex merge;
	k_parallel_rows(rows, [&](int64_t p_from, int64_t p_to) {
	int64_t slice_turf = 0;
	int64_t slice_snow = 0;
	for (int64_t row = p_from; row < p_to; row++) {
		const int64_t r0 = K_MAX(row - 1, 0);
		const int64_t r1 = K_MIN(row + 1, rows - 1);
		const double edge_height = edge_heights[row];
		// What the map's ground is coloured right at the edge.
		KColor edge_color = ms.tint;
		if (row < map_length && has_map_color) {
			const int64_t e = (row * map_width + (side == 0 ? 0 : map_width - 1)) * 4;
			edge_color = k_color(map_color[e] / 255.0 * double(ms.tint.r), map_color[e + 1] / 255.0 * double(ms.tint.g), map_color[e + 2] / 255.0 * double(ms.tint.b));
		}
		for (int64_t a = 0; a < apron_width; a++) {
			const int64_t i = row * apron_width + a;
			const int64_t a0 = K_MAX(a - 1, 0);
			const int64_t a1 = K_MIN(a + 1, apron_width - 1);
			const double h = heights[i];
			const bool bare = has_shoulder && on_shoulder[i] == 1;
			double turf = 0.0;
			double snow = 0.0;
			const KColor own = k_mountain_shade(ms, noise, double(a), double(row), h, heights[row * apron_width + a0], heights[row * apron_width + a1], heights[r0 * apron_width + a], heights[r1 * apron_width + a], double(K_MAX(a1 - a0, 1)), double(K_MAX(r1 - r0, 1)), h - edge_height, bare, control[i], turf, snow);
			if (turf > 0.02) {
				slice_turf++;
			}
			if (snow > 0.02) {
				slice_snow++;
			}
			const KColor final_color = k_color_lerp(edge_color, own, Math::smoothstep(0.0, APRON_COLOR_BLEND, double(side == 0 ? apron_width - a : a + 1)));
			color[i * 4] = uint8_t(int64_t(255.0 * double(final_color.r)));
			color[i * 4 + 1] = uint8_t(int64_t(255.0 * double(final_color.g)));
			color[i * 4 + 2] = uint8_t(int64_t(255.0 * double(final_color.b)));
			color[i * 4 + 3] = 128; // roughness left as it is
		}
	}
	std::lock_guard<std::mutex> lock(merge);
	turf_px += slice_turf;
	snow_px += slice_snow;
	});
	result["control"] = control_array;
	result["color"] = color_array;
	result["turf_px"] = turf_px;
	result["snow_px"] = snow_px;
	return result;
}

// TerrainCastle._north_height_band() (scripts/terrain/castle.gd) for every row.
Dictionary TerrainKernels::north_heights(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(NORTH_LENGTH) K_CONST(WALL_RELIEF) K_CONST(NORTH_EDGE_BLEND) K_CONST(WALL_EDGE_GRADE)

	const int64_t width = int64_t(p_ctx["width"]);
	const PackedFloat32Array edge_row_a = p_ctx["edge_row"];
	const PackedFloat32Array base_a = p_ctx["base"];
	const PackedFloat32Array ramp_a = p_ctx["ramp"];
	const Ref<FastNoiseLite> relief_noise = p_ctx["relief_noise"];
	const int64_t length = int64_t(NORTH_LENGTH);
	ERR_FAIL_COND_V(width < 1 || length < 1 || relief_noise.is_null(), result);
	ERR_FAIL_COND_V(edge_row_a.size() < width || base_a.size() < width || ramp_a.size() < length + 1, result);

	const float *edge_row = edge_row_a.ptr();
	const float *base = base_a.ptr();
	const float *ramp = ramp_a.ptr();
	FastNoiseLite *noise = relief_noise.ptr();
	PackedFloat32Array heights_array;
	heights_array.resize(width * length);
	float *heights = heights_array.ptrw();
	double crest = -std::numeric_limits<double>::infinity();
	std::mutex merge;
	k_parallel_rows(length, [&](int64_t p_from, int64_t p_to) {
	double slice_crest = -std::numeric_limits<double>::infinity();
	for (int64_t j = p_from; j < p_to; j++) {
		const int64_t d = length - j; // m north of the map's edge
		const double relief = Math::smoothstep(10.0, 60.0, double(d)) * WALL_RELIEF;
		const double join = Math::smoothstep(0.0, NORTH_EDGE_BLEND, double(d));
		for (int64_t c = 0; c < width; c++) {
			const double body = double(base[c]) + double(ramp[d]) + relief * (0.5 + 0.5 * double(noise->get_noise_2d(float(c), float(d))));
			const double h = k_lerpf(double(edge_row[c]) + WALL_EDGE_GRADE * double(d), body, join);
			heights[j * width + c] = float(h);
			slice_crest = K_MAX(slice_crest, h - double(base[c]));
		}
	}
	std::lock_guard<std::mutex> lock(merge);
	crest = K_MAX(crest, slice_crest);
	});
	result["heights"] = heights_array;
	result["crest"] = crest;
	return result;
}

// TerrainCastle._north_color_band() for every row.
Dictionary TerrainKernels::north_colors(const Dictionary &p_ctx, const Dictionary &p_consts) const {
	Dictionary result;
	K_CONST(NORTH_LENGTH) K_CONST(NORTH_COLOR_BLEND) K_CONST(MAP_FROM) K_CONST(MAP_TO)
	K_MOUNTAIN_SHADE(ms)

	const int64_t width = int64_t(p_ctx["width"]);
	const PackedFloat32Array heights_a = p_ctx["heights"];
	const PackedFloat32Array base_a = p_ctx["base"];
	const PackedByteArray on_shoulder_a = p_ctx["on_shoulder"];
	const PackedByteArray edge_color_a = p_ctx["edge_color"];
	const Ref<FastNoiseLite> shade_noise = p_ctx["shade_noise"];
	ms.rock_id = int64_t(p_ctx["rock_id"]);
	const int64_t length = int64_t(NORTH_LENGTH);
	const int64_t map_from = int64_t(MAP_FROM);
	const int64_t map_to = int64_t(MAP_TO);
	ERR_FAIL_COND_V(width < 1 || length < 1 || shade_noise.is_null(), result);
	ERR_FAIL_COND_V(heights_a.size() != width * length || base_a.size() < width || on_shoulder_a.size() != width * length, result);

	const float *heights = heights_a.ptr();
	const float *base = base_a.ptr();
	const uint8_t *on_shoulder = on_shoulder_a.ptr();
	const uint8_t *edge_bytes = edge_color_a.ptr();
	const bool has_edge = edge_color_a.size() >= width * 4;
	FastNoiseLite *noise = shade_noise.ptr();
	PackedInt32Array control_array;
	control_array.resize(width * length);
	int32_t *control = control_array.ptrw();
	PackedByteArray color_array;
	color_array.resize(width * length * 4);
	uint8_t *color = color_array.ptrw();
	k_parallel_rows(length, [&](int64_t p_from, int64_t p_to) {
	for (int64_t j = p_from; j < p_to; j++) {
		const int64_t j0 = K_MAX(j - 1, 0);
		const int64_t j1 = K_MIN(j + 1, length - 1);
		const double own_share = Math::smoothstep(0.0, NORTH_COLOR_BLEND, double(length - j));
		for (int64_t c = 0; c < width; c++) {
			const int64_t cell = j * width + c;
			const int64_t c0 = K_MAX(c - 1, 0);
			const int64_t c1 = K_MIN(c + 1, width - 1);
			const double h = heights[cell];
			double turf = 0.0;
			double snow = 0.0;
			KColor final_color = k_mountain_shade(ms, noise, double(c), double(j), h, heights[j * width + c0], heights[j * width + c1], heights[j0 * width + c], heights[j1 * width + c], double(K_MAX(c1 - c0, 1)), double(K_MAX(j1 - j0, 1)), h - double(base[c]), on_shoulder[cell] == 1, control[cell], turf, snow);
			if (own_share < 1.0 && has_edge) {
				// What the row south of it is coloured: the side aprons' pixels as they are, the
				// map's with the mountain's tint the ground paint multiplies into them later.
				KColor edge = k_color(edge_bytes[c * 4] / 255.0, edge_bytes[c * 4 + 1] / 255.0, edge_bytes[c * 4 + 2] / 255.0);
				if (c >= map_from && c < map_to) {
					edge = k_color(double(edge.r) * double(ms.tint.r), double(edge.g) * double(ms.tint.g), double(edge.b) * double(ms.tint.b));
				}
				final_color = k_color_lerp(edge, final_color, own_share);
			}
			color[cell * 4] = uint8_t(int64_t(255.0 * double(final_color.r)));
			color[cell * 4 + 1] = uint8_t(int64_t(255.0 * double(final_color.g)));
			color[cell * 4 + 2] = uint8_t(int64_t(255.0 * double(final_color.b)));
			color[cell * 4 + 3] = 128; // roughness left as it is
		}
	}
	});
	result["control"] = control_array;
	result["color"] = color_array;
	return result;
}
