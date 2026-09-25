## Road: A* routing with meander pull, Catmull-Rom smoothing, grading into the heightmap,
## and the road ribbon mesh.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainRoad.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainRoad
extends RefCounted

const ROAD_MESH_NODE_NAME := "RoadMesh" ## sibling MeshInstance3D holding the flat road-depth overlay mesh (parallax-mapped via StandardMaterial3D heightmap_enabled, no vertex displacement -- see _build_road_mesh), rebuilt fresh every run
const ROAD_TEXTURE_ID := 1
const ROAD_EDGE_NOISE_STRENGTH := 0.6 ## world units (2026-09-16: 0.6 -> 1.8 -> 0.9 when the road was halved -> 1.7 here, since even 0.9 combined with a tight 6-unit wavelength still read as essentially straight. Needed ROAD_HALF_WIDTH widened alongside this -- see that constant's own note -- to keep painted_half_width's worst case safely inside the grading corridor without also widening the visible road surface itself (ROAD_TEXTURE_HALF_WIDTH is unchanged).

## -- Road --
## A single route from the center of the north edge to the center of the
## south edge -- the two SHORT edges (each AREA_WIDTH long), so the road
## travels the map's LONG axis (AREA_LENGTH) rather than cutting across its
## short one. Found with A* pathfinding over a coarse grid rather than a
## blind straight line: each grid step's cost is penalized by how steep the
## terrain is there (squared, so mild slopes barely matter but a cliff face
## is effectively a wall), which makes the path bend around cliffs/ridges
## instead of climbing straight through them. The resulting grid-resolution
## waypoints are then smoothed with Catmull-Rom interpolation so the route
## reads as a curved road rather than a jagged staircase of 45-degree turns.
## Heights inside ROAD_HALF_WIDTH of the smoothed path get pulled toward a
## heavily-blurred copy of the terrain, which grades the corridor (smooths
## it flat enough to walk/drive) while still following the underlying slope,
## rather than cutting a dead-flat shelf through a hillside. The control map
## gets painted with ROAD_TEXTURE_ID within the narrower
## ROAD_TEXTURE_HALF_WIDTH, so there's a ground shoulder between the visible
## road and the graded edge of the corridor.
const ROAD_HALF_WIDTH := 6.0 ## world units, half-width of the graded corridor (2026-09-16: 6.0 -> 3.0 when the road was halved, -> 4.0 here -- widened again, NOT to make the visible road wider (ROAD_TEXTURE_HALF_WIDTH stays 2.0), but to give ROAD_EDGE_NOISE_STRENGTH's bigger amplitude enough shoulder room that the jittered painted edge can't reach past the graded corridor and paint onto rough, ungraded terrain)
const ROAD_TEXTURE_HALF_WIDTH := 3.0 ## world units, half-width of the painted road surface -- kept at 2.0 even though ROAD_HALF_WIDTH grew, so the visible road itself stays the width it was set to when halved; only the ground shoulder around it got wider
const ROAD_TEXTURE_BLEND_WIDTH := 1.5 ## world units, width of the control-map cross-fade band just inside the (jittered) painted edge -- see _pack_control_blend()/_generate_road()'s road_blend array. Without this, every painted pixel used base==overlay (a no-op blend), so the road/ground boundary was a razor-sharp texture swap no matter how much the edge itself was jittered; this band is what actually softens it.
const ROAD_EDGE_SOFTNESS := 2.5 ## half-width, in units, of the grading blend at the corridor's edge
const ROAD_SMOOTH_PASSES := 4 ## extra box-blur passes (on a separate copy) used as the "graded" target the corridor blends toward
const ROAD_SMOOTH_RADIUS := 3

## -- Road pathfinding (A*) --
const ROAD_PATH_GRID_STEP := 4.0 ## world units between pathfinding grid nodes -- coarser than the 1-unit heightmap for speed, smoothed back out afterward
const ROAD_SLOPE_PENALTY := 7.2 ## how strongly a steep step is penalized vs. a flat one of the same length -- higher pushes the route further out of its way to avoid slopes (2026-09-16: +5%, per the road-snaking analysis -- makes existing modest terrain variation costly enough to detour around a bit more readily)
const ROAD_SLOPE_HARD_LIMIT := 2.0 ## height change per grid step (in world units) beyond which that step is forbidden outright, not just costly -- keeps the router from ever routing straight up a near-vertical cliff face even if it's the shortest path (2026-09-16: -5%, tightened alongside ROAD_SLOPE_PENALTY -- slightly more terrain now counts as "too steep" outright, forcing more genuine detours)
const ROAD_PATH_SUBDIVISIONS := 8 ## Catmull-Rom subdivisions per grid segment when smoothing the coarse A* path into a curve

## -- Road depth mesh (2026-09-16, third attempt) -- a FLAT overlay ribbon
## (no vertex displacement/bump noise, unlike the reverted second attempt)
## that follows the same centerline+graded terrain height, textured with a
## StandardMaterial3D using Godot's built-in heightmap_enabled parallax
## (Poly Haven concrete_rock_path maps) -- see CLAUDE.md for why this
## replaces both the fragment-shader-on-Terrain3D and displaced-geometry
## attempts.
const ROAD_MESH_COLUMNS := 7 ## vertices across the ribbon's width per row
const ROAD_MESH_SEGMENT_LENGTH := 1.0 ## target world-space spacing between resampled rows along the path
const ROAD_MESH_LIFT := 0.03 ## small lift above the sampled terrain height to avoid shadow-map z-fighting with the terrain surface directly underneath
const ROAD_TEXTURE_TILE_LENGTH := 4.0 ## world units one texture tile covers, both along and across the ribbon
const ROAD_BUMP_AMPLITUDE := 0.035 ## small real vertex-height variation (2026-09-17) -- parallax alone reads as flat from a near-overhead FPS angle (its apparent offset scales with view angle from the surface normal, which is small looking mostly straight down), so real geometry is what actually gives a visible silhouette. Kept small, and shadow casting is disabled on this mesh (see _build_road_mesh) specifically so this doesn't repeat the second attempt's harsh self-shadowing.
const ROAD_BUMP_FREQUENCY := 0.35

const ROAD_GOAL_BAND_FRACTION := 0.33 ## (2026-09-16) the road's start stays pinned to the exact center of the north edge, but the south-edge exit is no longer forced to that same X column -- pinning both ends to the same column makes a straight line the crow-flies shortest path, so A* had no reason to bend the route unless real terrain slope forced it, which rarely happened. The exit X is instead picked randomly within this fraction of AREA_WIDTH, centered on the map's midline (0.33 => the exit lands somewhere in the central 33% of the south edge). This forces genuine diagonal travel across the grid even on a flat map, which the Catmull-Rom smoothing then turns into a natural-looking curve rather than a jittered straight line.

## -- Road "meander" (cosmetic S-curve pull, 2026-09-16) --
## Even at aggressive ROAD_SLOPE_PENALTY/ROAD_SLOPE_HARD_LIMIT/FEATURE_DENSITY
## values (tested up to 2x), the road stayed close to straight -- the valley
## floor (VALLEY_FLOOR_WIDTH_FRACTION) the road actually travels through is
## deliberately flat, and ROAD_GOAL_BAND_FRACTION's diagonal offset alone
## isn't enough real slope to make the pathfinder detour meaningfully more
## than once. Cranking terrain roughness further to force more bends fights
## the valley's own design (flat, walkable floor) instead of fixing the
## actual problem: there just isn't enough genuine terrain reason to curve.
## So this fakes it instead of trying to manufacture more real slope: the
## pathfinder gets pulled toward a wandering sine-wave PREFERRED centerline
## (interpolated between the real, fixed start/goal columns) as an EXTRA
## soft cost term, on top of -- not instead of -- real slope avoidance. A
## genuine cliff still hard-blocks a step (ROAD_SLOPE_HARD_LIMIT) regardless
## of what the preferred centerline wants; this only shapes the pathfinder's
## preference among still-viable cells. See _find_road_path's `preferred_x`.
const ROAD_MEANDER_AMPLITUDE_FRACTION := 0.18 ## how far, as a fraction of AREA_WIDTH, the preferred centerline can wander from the straight line between the fixed start/exit columns. Purely cosmetic -- real terrain can still push the actual route further than this.
const ROAD_MEANDER_CYCLES := 2.2 ## how many full left-right wander cycles the preferred centerline completes over the road's full north-to-south length. Fractional on purpose, so the wander pattern doesn't land symmetrically with the map's own north/south layout.
const ROAD_MEANDER_COST_WEIGHT := 0.35 ## how strongly the pathfinder is pulled toward the wandering preferred centerline, relative to the distance-based cost each grid step already has. Too high overrides genuine slope avoidance (defeats ROAD_SLOPE_PENALTY entirely); too low and flat terrain wins again, which is the whole problem this exists to work around.

## Resamples a polyline at uniform world-space arc-length spacing, regardless
## of how unevenly its source points (Catmull-Rom subdivisions bunch up on
## tight curves) are distributed. Used by _build_road_mesh so mesh rows land
## at consistent intervals along the road no matter how the path curves.
static func _resample_path(path: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if path.size() < 2:
		return result
	result.append(path[0])
	var carry := 0.0
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len <= 0.00001:
			continue
		var dist_along := spacing - carry
		while dist_along < seg_len:
			result.append(a.lerp(b, dist_along / seg_len))
			dist_along += spacing
		carry = dist_along - seg_len
	var last: Vector2 = path[path.size() - 1]
	if result[result.size() - 1].distance_to(last) > 0.001:
		result.append(last)
	return result

## Smooths a resampled path laterally (simple windowed moving average, several
## passes) purely for mesh-building purposes -- does NOT touch the original
## `path`/texture-painting data. Needed because a tight bend in the raw
## Catmull-Rom path can have a local curve radius smaller than
## ROAD_TEXTURE_HALF_WIDTH; offsetting by a fixed half-width on the inside of
## such a bend overshoots past the curve's own radius and folds the ribbon
## over itself (self-intersecting/degenerate quads), which shows up as dark
## slit artifacts right where the road turns. Flattening the curvature here
## first keeps every local bend's radius comfortably above the offset amount.
static func _smooth_path_for_mesh(path: PackedVector2Array, passes: int, window: int) -> PackedVector2Array:
	var result := path.duplicate()
	for _p in passes:
		var smoothed := result.duplicate()
		for i in range(result.size()):
			var lo := maxi(i - window, 0)
			var hi := mini(i + window, result.size() - 1)
			var sum := Vector2.ZERO
			var count := 0
			for j in range(lo, hi + 1):
				sum += result[j]
				count += 1
			smoothed[i] = sum / count
		result = smoothed
	return result

## Builds a FLAT overlay ribbon mesh along the road centerline -- no vertex
## displacement/bump noise (see the reverted second attempt in CLAUDE.md for
## why that caused harsh self-shadowing at grazing sun angles). Each row's
## height comes straight from the same (already road-graded) `heights` data
## the terrain itself uses, lifted by ROAD_MESH_LIFT to avoid z-fighting, so
## the mesh reads as "the same ground, just with a proper depth-mapped
## material" rather than a separate raised surface. Depth comes entirely
## from the material's built-in heightmap parallax (see the StandardMaterial3D
## setup below), not from geometry.
static func build_road_mesh(parent_node: Node, heights: PackedFloat32Array, width: int, length: int, path: PackedVector2Array, heightmap_corner: Vector3, seed_value: int) -> void:
	if path.size() < 2:
		print("TERRAIN_GEN: _build_road_mesh -- no road path, skipping")
		return
	var bump_noise := FastNoiseLite.new()
	bump_noise.seed = seed_value ^ 0x524F4144 # 'ROAD' salt
	bump_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	bump_noise.frequency = ROAD_BUMP_FREQUENCY
	var resampled := _resample_path(path, ROAD_MESH_SEGMENT_LENGTH)
	if resampled.size() < 2:
		print("TERRAIN_GEN: _build_road_mesh -- resampled path too short, skipping")
		return
	# See _smooth_path_for_mesh's comment -- prevents self-intersecting
	# geometry on tight bends without affecting the actual gameplay path.
	resampled = _smooth_path_for_mesh(resampled, 3, 4)

	var half_columns := (ROAD_MESH_COLUMNS - 1) / 2.0
	# One row of world-space positions per resampled path point, spanning
	# ROAD_MESH_COLUMNS samples across ROAD_TEXTURE_HALF_WIDTH*2.
	var rows: Array[PackedVector3Array] = []
	var row_uvs: Array[PackedVector2Array] = []
	var accumulated_length := 0.0
	for i in resampled.size():
		var point: Vector2 = resampled[i]
		var prev: Vector2 = resampled[maxi(i - 1, 0)]
		var next: Vector2 = resampled[mini(i + 1, resampled.size() - 1)]
		var tangent := (next - prev)
		if tangent.length_squared() < 0.00001:
			tangent = Vector2(0, 1)
		tangent = tangent.normalized()
		var perp := Vector2(-tangent.y, tangent.x)

		if i > 0:
			accumulated_length += point.distance_to(resampled[i - 1])

		var row_positions := PackedVector3Array()
		var row_uv := PackedVector2Array()
		for c in ROAD_MESH_COLUMNS:
			var offset := (c - half_columns) / half_columns * ROAD_TEXTURE_HALF_WIDTH
			var sample_px: float = point.x + perp.x * offset
			var sample_pz: float = point.y + perp.y * offset
			sample_px = clampf(sample_px, 0.0, float(width - 1))
			sample_pz = clampf(sample_pz, 0.0, float(length - 1))
			var h := TerrainUtil.sample_height_bilinear(heights, width, length, sample_px, sample_pz)
			var world_x := heightmap_corner.x + sample_px
			var world_z := heightmap_corner.z + sample_pz
			var bump := bump_noise.get_noise_2d(world_x, world_z) * ROAD_BUMP_AMPLITUDE
			row_positions.append(Vector3(world_x, h + ROAD_MESH_LIFT + bump, world_z))
			row_uv.append(Vector2(offset / ROAD_TEXTURE_TILE_LENGTH, accumulated_length / ROAD_TEXTURE_TILE_LENGTH))
		rows.append(row_positions)
		row_uvs.append(row_uv)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Accumulate smooth per-vertex normals from adjacent quad faces before
	# committing -- SurfaceTool's own generate_normals() would work off the
	# per-triangle set only after add_vertex, so this hand-rolled pass mirrors
	# the same approach validated in the (reverted) second attempt: normals
	# via cross products of quad edge vectors, which analytically always face
	# +Y for this ribbon's winding.
	var vertex_count := resampled.size() * ROAD_MESH_COLUMNS
	var normals := PackedVector3Array()
	normals.resize(vertex_count)
	for i in vertex_count:
		normals[i] = Vector3.ZERO

	for r in range(rows.size() - 1):
		for c in range(ROAD_MESH_COLUMNS - 1):
			var i00 := r * ROAD_MESH_COLUMNS + c
			var i10 := r * ROAD_MESH_COLUMNS + c + 1
			var i01 := (r + 1) * ROAD_MESH_COLUMNS + c
			var i11 := (r + 1) * ROAD_MESH_COLUMNS + c + 1
			var p00: Vector3 = rows[r][c]
			var p10: Vector3 = rows[r][c + 1]
			var p01: Vector3 = rows[r + 1][c]
			var p11: Vector3 = rows[r + 1][c + 1]
			var n1 := (p10 - p00).cross(p01 - p00).normalized()
			var n2 := (p11 - p10).cross(p01 - p10).normalized()
			normals[i00] += n1
			normals[i10] += n1 + n2
			normals[i01] += n1 + n2
			normals[i11] += n2
	for i in vertex_count:
		if normals[i].length_squared() > 0.00001:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	for r in range(rows.size() - 1):
		for c in range(ROAD_MESH_COLUMNS - 1):
			var i00 := r * ROAD_MESH_COLUMNS + c
			var i10 := r * ROAD_MESH_COLUMNS + c + 1
			var i01 := (r + 1) * ROAD_MESH_COLUMNS + c
			var i11 := (r + 1) * ROAD_MESH_COLUMNS + c + 1
			var a: Vector3 = rows[r][c]
			var b: Vector3 = rows[r][c + 1]
			var cc: Vector3 = rows[r + 1][c]
			var d: Vector3 = rows[r + 1][c + 1]
			var uv_a: Vector2 = row_uvs[r][c]
			var uv_b: Vector2 = row_uvs[r][c + 1]
			var uv_c: Vector2 = row_uvs[r + 1][c]
			var uv_d: Vector2 = row_uvs[r + 1][c + 1]
			st.set_normal(normals[i00]); st.set_uv(uv_a); st.add_vertex(a)
			st.set_normal(normals[i10]); st.set_uv(uv_b); st.add_vertex(b)
			st.set_normal(normals[i01]); st.set_uv(uv_c); st.add_vertex(cc)
			st.set_normal(normals[i10]); st.set_uv(uv_b); st.add_vertex(b)
			st.set_normal(normals[i11]); st.set_uv(uv_d); st.add_vertex(d)
			st.set_normal(normals[i01]); st.set_uv(uv_c); st.add_vertex(cc)

	# Required for correct normal-mapped/parallax lighting -- omitting this
	# was the root cause of the garbage tangent-space lighting artifact hit
	# in the second attempt.
	st.generate_tangents()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/source/road_px_diff_1k.png")
	mat.normal_enabled = true
	mat.normal_texture = load("res://textures/source/road_px_nor_gl_1k.png")
	var arm: Texture2D = load("res://textures/source/road_px_arm_1k.png")
	mat.ao_enabled = true
	mat.ao_texture = arm
	mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.roughness_texture = arm
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	# Concrete/rock isn't metallic -- leaving this at 0 (rather than driving it
	# from the arm map's blue channel) plus a lower non-metal specular
	# reflectance avoids a bright specular hotspot where the moon light
	# catches a low-roughness patch of the source texture at a sharp angle
	# (seen as a gray/white streak crossing the road at a slope break).
	mat.metallic = 0.0
	mat.metallic_specular = 0.3
	# Godot's built-in parallax occlusion mapping -- fakes depth via a
	# view-dependent UV offset from the height map, entirely in the shader.
	# No vertices move, so unlike the second attempt there is no extra
	# geometric relief for directional light to self-shadow harshly at
	# grazing angles. 0.04 (simple, non-deep parallax) read as basically flat
	# from typical FPS camera angles looking down at the ground -- bumped the
	# scale and switched to deep (layered/raymarched) parallax for a much
	# more convincing occlusion silhouette at the stone-block edges; this is
	# still a pure shader-space offset with no extra geometry, so it doesn't
	# reintroduce the self-shadowing problem from the second attempt.
	mat.heightmap_enabled = true
	mat.heightmap_texture = load("res://textures/source/road_px_disp_1k.png")
	mat.heightmap_scale = 0.15
	mat.heightmap_deep_parallax = true
	mat.heightmap_min_layers = 8
	mat.heightmap_max_layers = 32
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = ROAD_MESH_NODE_NAME
	mesh_instance.mesh = mesh
	mesh_instance.material_override = mat
	# The small ROAD_BUMP_AMPLITUDE relief above is enough to break the
	# top-down silhouette flatness, but letting it cast shadows is exactly
	# what made the second (reverted) attempt look awful -- small bumps under
	# a low/grazing light cast disproportionately long, hard-edged shadows on
	# themselves. Disabling shadow casting keeps the real depth cue without
	# reintroducing that problem.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var parent := parent_node
	var old_mesh := parent.get_node_or_null(ROAD_MESH_NODE_NAME)
	if old_mesh:
		old_mesh.queue_free()
	parent.add_child.call_deferred(mesh_instance)
	print("TERRAIN_GEN: _build_road_mesh -- %d rows x %d columns" % [rows.size(), ROAD_MESH_COLUMNS])

## Road: a route from the center of the north edge to the center of the
## south edge -- the two SHORT edges (each AREA_WIDTH long), so the road
## travels the map's LONG axis (AREA_LENGTH) rather than cutting across its
## short one. Found via _find_road_path (A* over a coarse grid, penalized by
## terrain steepness so it bends around cliffs/ridges) and smoothed into a
## curve by _catmull_rom_smooth. Grades the corridor by blending each pixel
## toward a heavily-blurred copy of the terrain (weighted by distance from
## the path, so it fades smoothly rather than cutting a flat shelf), and
## paints the control map with ROAD_TEXTURE_ID within a narrower band so
## there's a ground shoulder between the visible road surface and the edge
## of the graded corridor.
##
## Rasterized segment-by-segment (each segment only touches the small
## rectangle of pixels around it) rather than pixel-by-pixel scanning every
## segment -- with a winding multi-segment path that's the difference
## between roughly width*length work and roughly path_length*corridor_width
## work, which matters a lot once the path isn't just one straight line.
## Returns the per-pixel road grading weight (0 = untouched terrain, up to 1
## at the corridor's center) -- callers that need to avoid the road (e.g.
## _scatter_boulders, so rocks don't get placed in/right next to the road)
## use this instead of re-deriving the path themselves. Always sized
## width*length, including the early-return "no path found" case below, so
## callers never need to special-case a missing road.
static func generate_road(heights: PackedFloat32Array, control: PackedInt32Array, width: int, length: int, rng: RandomNumberGenerator, edge_noise: FastNoiseLite, cliff_obstacle_mask: PackedByteArray) -> Dictionary:
	# The south edge (pz = length-1) is where the player actually spawns --
	# see the spawn_world comment below -- so it stays pinned dead-center.
	# The north edge (the far exit) is randomized instead, within the
	# central ROAD_GOAL_BAND_FRACTION (see that constant's comment).
	# randf_range(-0.5, 0.5) * band_width spans the full band symmetrically
	# around the midline.
	var t_road_stage := Time.get_ticks_msec() ## fine-grained sub-timing (2026-09-16) -- see _build_heightmap's coarser per-stage prints
	var start_x := width * 0.5 + rng.randf_range(-0.5, 0.5) * (width * ROAD_GOAL_BAND_FRACTION)
	# Per-seed phase for the cosmetic meander wave (see ROAD_MEANDER_* above) --
	# without this, every playthrough's S-curve would wander through the exact
	# same left-right pattern, just with a different start_x.
	var meander_phase := rng.randf_range(0.0, TAU)
	var raw_path := _find_road_path(heights, width, length, start_x, meander_phase, cliff_obstacle_mask)
	print("TERRAIN_GEN:   pathfinding (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()
	if raw_path.size() < 2:
		print("TERRAIN_GEN: road pathfinding produced no usable path, skipping road")
		var empty_weight := PackedFloat32Array()
		empty_weight.resize(width * length)
		# Spawn/exit still need SOMETHING valid even with no road -- fall back
		# to dead-center-to-dead-center (the pre-goal-band-decoupling shape)
		# rather than leaving the caller (which repositions the Player) with
		# nothing to work with.
		var fallback_spawn_height: float = heights[(length - 1) * width + int(width * 0.5)]
		var fallback_exit_height: float = heights[0 * width + int(width * 0.5)]
		return {
			"weight": empty_weight,
			"spawn_pixel": Vector3(width * 0.5, fallback_spawn_height, length - 1),
			"exit_pixel": Vector3(width * 0.5, fallback_exit_height, 0),
			"path": PackedVector2Array(),
		}

	# Force the endpoints to the exact intended X -- the A* grid resolution
	# (ROAD_PATH_GRID_STEP) can land a node a couple of units off from the
	# true target column, and the route itself should start/end exactly there
	# regardless. The exit (north) uses the same start_x that drove the
	# pathfinding above; the spawn (south) is always dead-center.
	raw_path[0] = Vector2(start_x, 0.0)
	raw_path[raw_path.size() - 1] = Vector2(width * 0.5, length - 1.0)

	var path := _catmull_rom_smooth(raw_path, ROAD_PATH_SUBDIVISIONS)
	print("TERRAIN_GEN:   catmull-rom smoothing (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	# Lightweight permanent meander sanity check (2026-09-16, replaces a
	# heavier temporary reversal-counting diagnostic used to verify the
	# ROAD_MEANDER_* feature -- see that constant's comment and the
	# centripetal-vs-uniform Catmull-Rom comment above _catmull_rom_smooth
	# for what that investigation found): just the path's lateral span, as a
	# quick "did the road actually wander this run" signal without needing a
	# screenshot.
	var min_x := path[0].x
	var max_x := path[0].x
	for point in path:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
	print("TERRAIN_GEN:   path lateral span=%.1f (x_range=[%.1f, %.1f])" % [max_x - min_x, min_x, max_x])

	# The "graded" target the corridor blends toward -- a separate heavily-
	# blurred COPY of heights, so the road follows the terrain's overall
	# slope instead of becoming a dead-flat plane cutting through it.
	var blurred := heights.duplicate()
	TerrainHeightmap.smooth(blurred, width, length, ROAD_SMOOTH_PASSES, ROAD_SMOOTH_RADIUS)
	print("TERRAIN_GEN:   graded-target blur (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	# Highest grading weight seen so far per pixel (multiple nearby segments
	# can overlap the same pixel on a tight curve -- take the strongest
	# effect rather than letting a later segment weaken an earlier one), and
	# the strongest road TEXTURE blend fraction seen (0.0 = pure ground,
	# 1.0 = pure road) -- see _pack_control_blend()'s own comment for why
	# this replaced a binary "painted or not" flag.
	var road_weight := PackedFloat32Array()
	road_weight.resize(width * length)
	var road_blend := PackedFloat32Array()
	road_blend.resize(width * length)

	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg := b - a
		var seg_len_sq := seg.length_squared()

		var min_px := clampi(int(floor(minf(a.x, b.x) - ROAD_HALF_WIDTH)), 0, width - 1)
		var max_px := clampi(int(ceil(maxf(a.x, b.x) + ROAD_HALF_WIDTH)), 0, width - 1)
		var min_pz := clampi(int(floor(minf(a.y, b.y) - ROAD_HALF_WIDTH)), 0, length - 1)
		var max_pz := clampi(int(ceil(maxf(a.y, b.y) + ROAD_HALF_WIDTH)), 0, length - 1)

		for pz in range(min_pz, max_pz + 1):
			for px in range(min_px, max_px + 1):
				var point := Vector2(px, pz)
				var t := 0.0
				if seg_len_sq > 0.00001:
					t = clampf((point - a).dot(seg) / seg_len_sq, 0.0, 1.0)
				var closest := a + seg * t
				var d := point.distance_to(closest)
				if d > ROAD_HALF_WIDTH:
					continue

				var idx := pz * width + px
				var grade_weight := 1.0 - smoothstep(ROAD_HALF_WIDTH - ROAD_EDGE_SOFTNESS, ROAD_HALF_WIDTH, d)
				if grade_weight > road_weight[idx]:
					road_weight[idx] = grade_weight
				# Jitter only the painted-texture edge, not the graded corridor
				# width above -- the corridor shape is what actually governs
				# walkability/grading, and keeping it a clean offset from the
				# smoothed path avoids any risk of an ungraded bump right at the
				# road's own edge. The paint edge is purely cosmetic, so it can
				# wobble freely to break up the razor-straight shoulder line.
				var painted_half_width := ROAD_TEXTURE_HALF_WIDTH + edge_noise.get_noise_2d(px, pz) * ROAD_EDGE_NOISE_STRENGTH
				# Cross-fade band: 1.0 (pure road) once d is ROAD_TEXTURE_BLEND_WIDTH
				# or more inside the jittered edge, ramping smoothly down to 0.0
				# (pure ground) exactly at the edge itself and beyond -- see
				# ROAD_TEXTURE_BLEND_WIDTH's own comment. smoothstep's built-in
				# clamping means no extra "if d > painted_half_width" guard is
				# needed here the way the old binary flag required.
				var blend_frac := 1.0 - smoothstep(painted_half_width - ROAD_TEXTURE_BLEND_WIDTH, painted_half_width, d)
				if blend_frac > road_blend[idx]:
					road_blend[idx] = blend_frac
	print("TERRAIN_GEN:   segment rasterization (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	for idx in road_weight.size():
		if road_weight[idx] > 0.0:
			heights[idx] = lerpf(heights[idx], blurred[idx], road_weight[idx])
		if road_blend[idx] > 0.0:
			control[idx] = TerrainHeightmap.pack_control_blend(TerrainConfig.GROUND_TEXTURE_ID, ROAD_TEXTURE_ID, road_blend[idx])
	print("TERRAIN_GEN:   apply grading+control (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))

	# The player spawns on the SOUTH edge (heightmap pixel (width/2, length-1),
	# forced above), which is always dead-center regardless of seed -- only
	# the north-edge exit (start_x) moves.
	#
	# IMPORTANT: this only hands back PIXEL coordinates (+ height), not world
	# positions -- converting to world space requires heightmap_corner, which
	# isn't knowable until AFTER Terrain3DData.import_images() actually places
	# the region(s) in _ready() (see that function's heightmap_corner comment:
	# turns out Terrain3D doesn't symmetrically center a multi-region import
	# the way a naive position-minus-half-size formula assumes -- it anchors
	# via floor(position/region_size) per axis and extends toward +X/+Z from
	# there, so a length that spans more than one REGION_SIZE tile can leave
	# the corner somewhere other than -length. Building a world Vector3 HERE,
	# before import has even happened, produced exactly that silent "spawns
	# in the middle of the map" bug once AREA_LENGTH grew past REGION_SIZE.
	var spawn_px := int(width * 0.5)
	var spawn_height: float = heights[(length - 1) * width + spawn_px]
	var spawn_pixel := Vector3(spawn_px, spawn_height, length - 1)

	# The exit (north edge, pz = 0) moves per-seed within ROAD_GOAL_BAND_FRACTION.
	var exit_px := clampi(int(round(start_x)), 0, width - 1)
	var exit_height: float = heights[0 * width + exit_px]
	var exit_pixel := Vector3(exit_px, exit_height, 0)
	# `path` (the smoothed centerline, pixel/heightmap-space XZ) is handed
	# back so _build_road_mesh can walk the exact same curve the texture
	# painting above rasterized -- see that function's own comment for why a
	# separate flat overlay mesh (not the painted texture itself) is what
	# carries the parallax material.
	return {"weight": road_weight, "spawn_pixel": spawn_pixel, "exit_pixel": exit_pixel, "path": path}

## Finds a route from the center of the north edge to the center of the south
## edge using A* over a coarse grid (spacing ROAD_PATH_GRID_STEP), where the
## cost of a step is its distance scaled up by how steep the terrain is
## there (squared, so mild slopes barely matter but steep ones are strongly
## avoided) and any step steeper than ROAD_SLOPE_HARD_LIMIT per grid step is
## forbidden outright -- that's what makes the route bend around a cliff
## instead of climbing straight through it, without needing to know
## anything about where the cliff features specifically were placed (their
## own steepness is enough). Returns grid-resolution waypoints in heightmap
## pixel coordinates; _catmull_rom_smooth turns those into an actual curve.
static func _find_road_path(heights: PackedFloat32Array, width: int, length: int, start_x: float, meander_phase: float, cliff_obstacle_mask: PackedByteArray) -> PackedVector2Array:
	var cols := int(ceil(width / ROAD_PATH_GRID_STEP)) + 1
	var rows := int(ceil(length / ROAD_PATH_GRID_STEP)) + 1

	var sample_height := func(gx: int, gz: int) -> float:
		var px := clampi(int(round(gx * ROAD_PATH_GRID_STEP)), 0, width - 1)
		var pz := clampi(int(round(gz * ROAD_PATH_GRID_STEP)), 0, length - 1)
		return heights[pz * width + px]

	# 2026-09-17 reorder: cliff-dressing footprints are now planned/flattened into `heights`
	# BEFORE road routing runs, so they no longer show up as a slope discontinuity
	# ROAD_SLOPE_HARD_LIMIT would catch on its own (the flatten blend smooths right over that
	# edge). This explicit obstacle check is what makes A* actually route around them instead
	# of happily paving straight across a flattened cliff-mesh footprint.
	var is_obstructed := func(gx: int, gz: int) -> bool:
		if cliff_obstacle_mask.is_empty():
			return false
		var px := clampi(int(round(gx * ROAD_PATH_GRID_STEP)), 0, width - 1)
		var pz := clampi(int(round(gz * ROAD_PATH_GRID_STEP)), 0, length - 1)
		return cliff_obstacle_mask[pz * width + px] != 0

	# North/south edges (the SHORT ones, each AREA_WIDTH long) are what the
	# road connects -- it travels the LONG axis (AREA_LENGTH, north to south)
	# rather than cutting across the short one. Swapping this would connect
	# the two long west/east edges instead, which is backwards.
	# The goal (south edge, where the player spawns -- see _generate_road's
	# spawn_world comment) stays pinned to the map's center column, but the
	# start (north edge) column comes from start_x (see ROAD_GOAL_BAND_FRACTION)
	# so the two ends don't share a column -- that's what actually forces the
	# route to travel diagonally instead of straight down the map.
	var mid_col := int(round((cols - 1) * 0.5))
	var start_col := clampi(int(round(start_x / ROAD_PATH_GRID_STEP)), 0, cols - 1)
	var start := Vector2i(start_col, 0)
	var goal := Vector2i(mid_col, rows - 1)

	# Cosmetic meander (see ROAD_MEANDER_* consts' comment): a wandering
	# PREFERRED column per row, tapered to exactly 0 deviation at gz=0 and
	# gz=rows-1 (`envelope`, a half-sine hump) so it never fights the hard-
	# forced start/goal columns above. `preferred_col` blends linearly between
	# those two real columns, then adds the sine wander on top, scaled by
	# ROAD_MEANDER_AMPLITUDE_FRACTION*cols so it stays proportional to the
	# grid regardless of map size.
	var preferred_col := func(gz: int) -> float:
		var t := float(gz) / float(maxi(rows - 1, 1))
		var baseline := lerpf(float(start_col), float(mid_col), t)
		var envelope := sin(PI * t) # 0 at t=0 and t=1, peaks at the midpoint
		var wander := ROAD_MEANDER_AMPLITUDE_FRACTION * cols * envelope * sin(t * TAU * ROAD_MEANDER_CYCLES + meander_phase)
		return baseline + wander

	var neighbor_offsets := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]

	# Binary min-heap of [f_score, Vector2i] open-set entries, ordered by
	# f_score (2026-09-16, replaced the old "linear-scan the whole open set
	# for the lowest f" approach). That old approach was O(V) PER POP and
	# therefore O(V^2) overall for V = cols*rows grid nodes -- fine at small
	# map sizes, but V scales with AREA_WIDTH*AREA_LENGTH, so the old cost
	# scaled with the SQUARE of map area. Per-stage timing (_build_heightmap)
	# confirmed this was the dominant remaining cost in road routing once the
	# _smooth() blur elsewhere was fixed to be separable (see that function's
	# comment) -- this is the other half of that fix.
	#
	# No decrease-key support: a node can be pushed more than once (once per
	# g_score improvement, same as the old open_set could hold a node whose
	# f_score had since improved elsewhere -- except the old code kept only
	# one entry per node via `in_open` and mutated its f_score in place).
	# Here, `closed` makes re-popping a stale, already-finalized duplicate a
	# cheap early-exit instead of reprocessing it -- standard technique for
	# an array-backed binary heap without an efficient decrease-key.
	var heap: Array = []
	var closed := {}
	var came_from := {}
	var g_score := {start: 0.0}

	var heap_push := func(f: float, node: Vector2i) -> void:
		heap.append([f, node])
		var i := heap.size() - 1
		while i > 0:
			var parent := (i - 1) / 2
			if heap[parent][0] <= heap[i][0]:
				break
			var tmp = heap[parent]
			heap[parent] = heap[i]
			heap[i] = tmp
			i = parent

	var heap_pop_min := func() -> Array:
		var top = heap[0]
		var last := heap.size() - 1
		heap[0] = heap[last]
		heap.remove_at(last)
		var i := 0
		var n := heap.size()
		while true:
			var left := i * 2 + 1
			var right := i * 2 + 2
			var smallest := i
			if left < n and heap[left][0] < heap[smallest][0]:
				smallest = left
			if right < n and heap[right][0] < heap[smallest][0]:
				smallest = right
			if smallest == i:
				break
			var tmp2 = heap[i]
			heap[i] = heap[smallest]
			heap[smallest] = tmp2
			i = smallest
		return top

	heap_push.call(Vector2(start).distance_to(Vector2(goal)) * ROAD_PATH_GRID_STEP, start)

	while not heap.is_empty():
		var top: Array = heap_pop_min.call()
		var current: Vector2i = top[1]
		if closed.has(current):
			continue # stale duplicate -- a better route to this node was already finalized
		closed[current] = true

		if current == goal:
			var path_nodes: Array[Vector2i] = [current]
			while came_from.has(current):
				current = came_from[current]
				path_nodes.push_front(current)
			var path := PackedVector2Array()
			for node in path_nodes:
				path.append(Vector2(node.x * ROAD_PATH_GRID_STEP, node.y * ROAD_PATH_GRID_STEP))
			return path

		var current_height: float = sample_height.call(current.x, current.y)

		for offset in neighbor_offsets:
			var neighbor: Vector2i = current + offset
			if neighbor.x < 0 or neighbor.x >= cols or neighbor.y < 0 or neighbor.y >= rows:
				continue
			if closed.has(neighbor):
				continue

			if is_obstructed.call(neighbor.x, neighbor.y):
				continue # planted cliff-dressing footprint -- solid terrain, never route through it

			var neighbor_height: float = sample_height.call(neighbor.x, neighbor.y)
			var height_delta := absf(neighbor_height - current_height)
			if height_delta > ROAD_SLOPE_HARD_LIMIT:
				continue # too steep to ever route through, no matter the cost

			var step_distance: float = ROAD_PATH_GRID_STEP * Vector2(offset).length()
			var slope := height_delta / step_distance
			var move_cost := step_distance * (1.0 + ROAD_SLOPE_PENALTY * slope * slope)

			# Cosmetic meander pull (see ROAD_MEANDER_* consts): an EXTRA soft
			# cost for straying from the wandering preferred column at this row,
			# on top of the real slope cost above -- never overrides the hard
			# slope-limit `continue` above, only shapes preference among cells
			# that were already going to be considered.
			var lateral_deviation := absf(float(neighbor.x) - preferred_col.call(neighbor.y))
			move_cost += ROAD_MEANDER_COST_WEIGHT * lateral_deviation * step_distance

			var tentative_g: float = g_score.get(current, INF) + move_cost
			if tentative_g < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				var f := tentative_g + Vector2(neighbor).distance_to(Vector2(goal)) * ROAD_PATH_GRID_STEP
				heap_push.call(f, neighbor)

	# No route found at all (e.g. a wall of ROAD_SLOPE_HARD_LIMIT-steep terrain
	# spans the whole map) -- fall back to a straight line rather than no road.
	push_warning("TERRAIN_GEN: road pathfinding found no route from north to south edge -- falling back to a straight line")
	var fallback := PackedVector2Array()
	fallback.append(Vector2(start_col * ROAD_PATH_GRID_STEP, 0.0))
	fallback.append(Vector2(mid_col * ROAD_PATH_GRID_STEP, (rows - 1) * ROAD_PATH_GRID_STEP))
	return fallback

## CENTRIPETAL Catmull-Rom spline through `points` (2026-09-16, replaced a
## UNIFORM-parameterization version), resampled at `subdivisions` steps per
## input segment. Turns the blocky grid-resolution A* waypoints (which only
## ever step in 8 fixed directions) into a road that actually curves.
##
## Uniform Catmull-Rom (parameter t running 0..1 per segment regardless of
## how far apart the actual points are) is well known to overshoot/ring when
## the control polygon has real curvature with UNEVENLY spaced points --
## exactly what the road-meander feature (see ROAD_MEANDER_* above)
## introduced. Confirmed via a temporary diagnostic: the raw A* path (before
## this function) had only 6 direction reversals for a deliberate ~2.2-cycle
## S-curve, but the OLD uniform-parameterized smoothed output had 55 --
## i.e. this function was manufacturing ~50 spurious wiggles the pathfinder
## never asked for, on top of the intended curve. Before the meander
## feature, the raw path was close enough to a straight line that this
## defect had nothing to amplify and went unnoticed.
##
## Centripetal parameterization (alpha=0.5, the Barry-Goldman formulation)
## spaces each segment's local parameter by the SQUARE ROOT of the actual
## distance between points instead of a fixed 1.0 per segment -- this is
## the standard, well-documented fix for uniform Catmull-Rom's overshoot/
## self-intersection on non-uniformly-spaced control points. `epsilon`
## guards the (rare) case of two coincident points, which would otherwise
## divide by zero.
static func _catmull_rom_smooth(points: PackedVector2Array, subdivisions: int) -> PackedVector2Array:
	var n := points.size()
	if n < 2:
		return points
	var alpha := 0.5
	var epsilon := 0.0001
	var result := PackedVector2Array()
	for i in range(n - 1):
		var p0: Vector2 = points[maxi(i - 1, 0)]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[mini(i + 2, n - 1)]

		var t0 := 0.0
		var t1 := t0 + pow(maxf(p1.distance_to(p0), epsilon), alpha)
		var t2 := t1 + pow(maxf(p2.distance_to(p1), epsilon), alpha)
		var t3 := t2 + pow(maxf(p3.distance_to(p2), epsilon), alpha)

		for s in subdivisions:
			var t := lerpf(t1, t2, float(s) / float(subdivisions))
			var a1 := p0 * (t1 - t) / (t1 - t0) + p1 * (t - t0) / (t1 - t0)
			var a2 := p1 * (t2 - t) / (t2 - t1) + p2 * (t - t1) / (t2 - t1)
			var a3 := p2 * (t3 - t) / (t3 - t2) + p3 * (t - t2) / (t3 - t2)
			var b1 := a1 * (t2 - t) / (t2 - t0) + a2 * (t - t0) / (t2 - t0)
			var b2 := a2 * (t3 - t) / (t3 - t1) + a3 * (t - t1) / (t3 - t1)
			var point := b1 * (t2 - t) / (t2 - t1) + b2 * (t - t1) / (t2 - t1)
			result.append(point)
	result.append(points[n - 1])
	return result
