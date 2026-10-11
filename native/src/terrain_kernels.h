#pragma once

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

namespace godot {

// Native versions of terrain generation's hot loops. Each method repeats its GDScript original
// operation for operation, so a seed gives the same map with or without this library; the
// script versions stay as the fallback (see TerrainUtil.kernels() in scripts/terrain/).
class TerrainKernels : public RefCounted {
	GDCLASS(TerrainKernels, RefCounted)

protected:
	static void _bind_methods();

public:
	// Bumped whenever a kernel's behaviour or signature changes; the scripts check it.
	int get_version() const;

	// TerrainErosion.erode(). Returns the eroded heights (the array passed in is not changed).
	// params: MAX_DROPLET_LIFETIME, INERTIA, SEDIMENT_CAPACITY_FACTOR, MIN_SEDIMENT_CAPACITY,
	// ERODE_SPEED, DEPOSIT_SPEED, EVAPORATE_SPEED, GRAVITY, INITIAL_WATER_VOLUME, INITIAL_SPEED.
	PackedFloat32Array erode(PackedFloat32Array p_heights, int p_width, int p_length, const Ref<RandomNumberGenerator> &p_rng, int p_iterations, const PackedFloat64Array &p_params) const;

	// One pass of TerrainGroundPaint's majority filter (_mode_band over the whole map). Returns
	// the filtered texture map.
	PackedByteArray mode_filter(const PackedByteArray &p_src, int p_width, int p_length, int p_radius, int p_road_mark) const;

	// TerrainRoad._obstacle_distance() for a mask that is not empty: the two-pass chamfer distance
	// (m, capped) to the nearest marked pixel.
	PackedFloat32Array obstacle_distance(const PackedByteArray &p_mask, int p_width, int p_length, double p_cap) const;

	// The A* loop of TerrainRoad._find_road_path() over the node arrays the script prepares.
	// Returns the nodes from start to goal (row * cols + column), empty when there is no route.
	// offsets: the eight steps as dx, dy pairs; offset_side: each step's side vector as x, y.
	// params: ROAD_PATH_GRID_STEP, ROAD_SLOPE_HARD_LIMIT, ROAD_SLOPE_PENALTY, ROAD_HALF_WIDTH,
	// ROAD_CROSS_SLOPE_PENALTY, ROAD_OBSTACLE_SOFT_CLEARANCE, ROAD_OBSTACLE_PROXIMITY_PENALTY,
	// ROAD_MEANDER_COST_WEIGHT.
	PackedInt32Array road_search(const PackedFloat32Array &p_heights, int p_width, int p_length, int p_cols, int p_rows, int p_start_node, int p_goal_node, const PackedFloat32Array &p_node_h, const PackedByteArray &p_node_blocked, const PackedFloat32Array &p_node_od, const PackedFloat64Array &p_row_pref, const PackedInt32Array &p_offsets, const PackedFloat64Array &p_offset_dist, const PackedFloat64Array &p_offset_side, const PackedFloat64Array &p_params) const;

	// TerrainKnots._flood() inside the box the script works out: 1 = reached from the box's rim.
	PackedByteArray knot_flood(const PackedFloat32Array &p_heights, int p_width, int p_length, const PackedByteArray &p_mesh_block, int p_x0, int p_z0, int p_bw, int p_bh, double p_walk_step) const;

	// The pair loop of TerrainKnots._carve_ramp(): walks the sorted keys and tests each pair's
	// line against the rocks (_segment_clear_top). Returns [index of the first key that passes,
	// or -1; pairs refused before it].
	PackedInt32Array knot_first_clear_pair(const PackedInt64Array &p_keys, const PackedVector2Array &p_low_pts, const PackedVector2Array &p_highs, const PackedByteArray &p_mesh_block, const PackedByteArray &p_top_mask, int p_width, int p_length, double p_bed_half, double p_rock_clear) const;

	// TerrainKnots._dilate(): square dilation of a 0 / 1 mask by p_r pixels.
	PackedByteArray dilate(const PackedByteArray &p_src, int p_width, int p_length, int p_r) const;

	// 1 where two height maps differ by more than p_threshold (TerrainKnots._build_occupancy).
	PackedByteArray height_diff_mask(const PackedFloat32Array &p_a, const PackedFloat32Array &p_b, double p_threshold) const;

	// build_knots()'s self-check: pixels that differ between the two maps and lie in none of the
	// circles (cx, cz, radius triples; the radius already holds the margin).
	int count_changed_outside(const PackedFloat32Array &p_heights, const PackedFloat32Array &p_before, int p_width, int p_length, const PackedFloat64Array &p_circles) const;

	// The pixel loops of CliffDressing.raise_terrain_behind_cliff_dressing(): every entry's
	// accumulation, then the commit. The script works out each entry's values (CLIFF_RAISE_ENTRY
	// doubles per entry, the order is in the .cpp) and passes its top profile by index:
	// profile_heights[i] is a PackedFloat32Array, profile_ranges holds x_min, x_max per profile.
	// consts: CLIFF_DRESSING_RAISE_EDGE_WARP, _JOIN_BRIDGE_FULL, _JOIN_BLEND, _JOIN_RAMP_BACK,
	// _MAX_SLOPE, _PROXIMITY_FALLOFF, CLIFF_DRESSING_FLANK_BAND_FRACTION,
	// CLIFF_DRESSING_SEAM_MIN_COVERAGE, _SEAM_TOLERANCE, CLIFF_DRESSING_RAISE_BUMP_MAX, _BUMP_FRACTION.
	// Returns {"heights": PackedFloat32Array, "changed": int}.
	Dictionary cliff_raise(PackedFloat32Array p_heights, int p_width, int p_length, const PackedFloat64Array &p_entries, const Array &p_profile_heights, const PackedFloat64Array &p_profile_ranges, const Ref<FastNoiseLite> &p_warp_noise, const Ref<FastNoiseLite> &p_bump_noise, const PackedFloat64Array &p_consts, bool p_seam_only) const;

	// TerrainGroundPaint's main per-vertex pass (_paint_band over the whole map). ctx is the
	// dictionary the script's bands read; consts holds the module's constants by name (the list
	// is at the top of the function). Returns what one band returns, for the whole map, with
	// type_counts as a PackedInt32Array in the order of ROCK_TYPES.
	Dictionary paint_main(const Dictionary &p_ctx, const Dictionary &p_consts) const;

	// GrassScatter.stamp_circles(): the field with every circle (cx, cz, r triples) stamped in.
	PackedFloat32Array stamp_circles(PackedFloat32Array p_field, int p_width, int p_length, const PackedFloat64Array &p_circles, double p_cap) const;

	// The control map's road vertices as circles (px, pz, 0.0) for stamp_circles: base texture
	// = the road, or overlay = the road with a blend byte >= p_min_blend.
	PackedFloat64Array road_vertex_circles(const PackedByteArray &p_control, int p_width, int p_length, int p_road_id, int p_min_blend) const;

	// [lowest, highest] of a height map.
	PackedFloat64Array height_min_max(const PackedFloat32Array &p_heights) const;

	// GrassScatter's per-pixel combine (_bake_band over the whole map), from the bands' ctx and
	// the module's constants by name. Returns what one band returns, for the whole map.
	Dictionary grass_bake(const Dictionary &p_ctx, const Dictionary &p_consts) const;

	// TerrainHeightmap.smooth(): the map after `passes` box blurs of the given radius.
	PackedFloat32Array smooth(const PackedFloat32Array &p_heights, int p_width, int p_length, int p_passes, int p_radius) const;

	// TerrainRoad._raster_band over the whole map: {"weight", "blend"} (the consts are listed in the .cpp).
	Dictionary road_raster(const PackedVector2Array &p_path, int p_width, int p_length, const Ref<FastNoiseLite> &p_edge_noise, const PackedFloat64Array &p_consts) const;

	// TerrainRoad._grade_level_bed from the nearest-segment search to the crease smoothing:
	// {"heights", "max_cut", "max_fill", "zone"} (the consts are listed in the .cpp).
	Dictionary road_bed(PackedFloat32Array p_heights, const PackedFloat32Array &p_obst, const PackedVector2Array &p_line, const PackedFloat32Array &p_prof, int p_width, int p_length, const PackedFloat64Array &p_consts) const;

	// The mountain aprons' band loops over all their rows, each from the ctx its script bands read
	// and the constants by name (MountainWalls.kernel_consts()): MountainWalls._apron_height_band
	// and _apron_color_band, TerrainCastle._north_height_band and _north_color_band. Each returns
	// what one band returns, for the whole strip.
	Dictionary apron_heights(const Dictionary &p_ctx, const Dictionary &p_consts) const;
	Dictionary apron_colors(const Dictionary &p_ctx, const Dictionary &p_consts) const;
	Dictionary north_heights(const Dictionary &p_ctx, const Dictionary &p_consts) const;
	Dictionary north_colors(const Dictionary &p_ctx, const Dictionary &p_consts) const;

	// TerrainGroundPaint's border pass (_blend_band over the whole map). Returns
	// {"control": PackedInt32Array, "border": int, "third": int}.
	// params: BORDER_RADIUS, BORDER_FADE, THIRD_FADE, SPRAY_AMP, SPRAY_FLOOR, ROAD_MARK.
	Dictionary blend_borders(const PackedByteArray &p_dom, const PackedByteArray &p_spray, const PackedInt32Array &p_road_control, int p_width, int p_length, const PackedFloat64Array &p_params) const;
};

} // namespace godot
