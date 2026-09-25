## Shared helpers: heightmap sampling (height/normal), zone pixel ranges, and mesh
## vertex/normal collection used by several placement modules.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainUtil.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainUtil
extends RefCounted

const VERTEX_SPACING := 1.0

## wall_t (0 = floor, 1 = rim -- see _valley_profile) boundary between the
## steep "wall" zone and the "transition" zone near the rim, for feature
## placement purposes only (a separate concern from the macro shape itself).
const ZONE_TRANSITION_WALL_T := 0.7

## Recursively gathers every MeshInstance3D's vertices under `node`, transformed into `node`'s
## own root local space (2026-09-17, "match the elevation line"): each node's own `transform`
## (local to ITS parent) is folded into `parent_transform` on the way down, so a multi-part
## model (mountainside is 5 separate MeshInstance3D nodes -- see _add_cliff_collision_recursive's
## comment) still comes back as one consistent set of vertices in the top-level root's space,
## the same space _dress_cliff_faces places mesh_root's scale/rotation/position onto.
static func collect_mesh_vertices_recursive(node: Node, parent_transform: Transform3D, out_vertices: PackedVector3Array) -> void:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		if mesh_inst.mesh:
			for surface_idx in mesh_inst.mesh.get_surface_count():
				var arrays := mesh_inst.mesh.surface_get_arrays(surface_idx)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts:
					out_vertices.append(local_transform * v)
	for child in node.get_children():
		collect_mesh_vertices_recursive(child, local_transform, out_vertices)

## Pixel-space X range a candidate feature center can be drawn from for the
## given valley zone ("floor", "wall", "transition") -- derived from the
## same VALLEY_FLOOR_WIDTH_FRACTION/ZONE_TRANSITION_WALL_T boundaries
## _valley_profile uses, so feature placement and the macro shape always
## agree on where the floor/wall/rim actually are. "wall" and "transition"
## each straddle both sides of the (asymmetric) valley -- this picks one
## side at random per call, so left/right get roughly equal shares of
## wall/transition features over many calls despite the height asymmetry.
static func zone_pixel_range(zone: String, width: int, rng: RandomNumberGenerator) -> Vector2:
	var w := float(width)
	var floor_half := TerrainConfig.VALLEY_FLOOR_WIDTH_FRACTION * 0.5
	var floor_lo := (0.5 - floor_half) * w
	var floor_hi := (0.5 + floor_half) * w
	var edge_margin := 4.0 ## keep clear of the absolute map edge
	var left_wall_lo := floor_lo * (1.0 - ZONE_TRANSITION_WALL_T)
	var right_wall_hi := floor_hi + ZONE_TRANSITION_WALL_T * (w - floor_hi)
	match zone:
		"wall":
			if rng.randf() < 0.5:
				return Vector2(maxf(left_wall_lo, edge_margin), floor_lo)
			else:
				return Vector2(floor_hi, minf(right_wall_hi, w - 1.0 - edge_margin))
		"transition":
			if rng.randf() < 0.5:
				return Vector2(edge_margin, maxf(left_wall_lo, edge_margin + 1.0))
			else:
				return Vector2(minf(right_wall_hi, w - 1.0 - edge_margin - 1.0), w - 1.0 - edge_margin)
		_: # "floor"
			return Vector2(floor_lo, floor_hi)

## Pulls a candidate range [lo,hi] inward by `reach` on each side so that a
## center drawn from the result can never place a feature's footprint past
## [0, max_index] -- without this, a zone-restricted range (see
## _zone_pixel_range) can sit close enough to the map edge that a large
## feature's footprint gets clipped by the heightmap boundary instead of
## blending into unmodified terrain the way it does everywhere else. If the
## zone's own band is narrower than the feature needs (a big feature in a
## tight wall/transition band), this collapses to the one point that's
## still fully contained rather than letting it clip.
static func clamp_range_for_reach(lo: float, hi: float, reach: float, max_index: float) -> Vector2:
	var safe_lo := maxf(lo, reach)
	var safe_hi := minf(hi, max_index - reach)
	if safe_lo > safe_hi:
		var mid := clampf((lo + hi) * 0.5, reach, max_index - reach)
		return Vector2(mid, mid)
	return Vector2(safe_lo, safe_hi)

## Bilinear height sample directly from the flat heights array -- used by
## _scatter_boulders so boulder placement matches the exact same data that
## became the height image, with no round-trip through Terrain3DData.
static func sample_height_bilinear(heights: PackedFloat32Array, width: int, length: int, px: float, pz: float) -> float:
	var x0 := clampi(int(floor(px)), 0, width - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var z0 := clampi(int(floor(pz)), 0, length - 1)
	var z1 := clampi(z0 + 1, 0, length - 1)
	var fx := clampf(px - x0, 0.0, 1.0)
	var fz := clampf(pz - z0, 0.0, 1.0)
	var h00 := heights[z0 * width + x0]
	var h10 := heights[z0 * width + x1]
	var h01 := heights[z1 * width + x0]
	var h11 := heights[z1 * width + x1]
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fz)

## Surface normal via central differences -- same rise/run formula
## _paint_slope_rock uses for its slope check, just turned into a full
## normal vector instead of a scalar slope, so scattered boulders rest
## tilted to match the ground they're placed on.
static func sample_normal(heights: PackedFloat32Array, width: int, length: int, px: float, pz: float) -> Vector3:
	var cx := clampi(int(round(px)), 0, width - 1)
	var cz := clampi(int(round(pz)), 0, length - 1)
	var x0 := maxi(cx - 1, 0)
	var x1 := mini(cx + 1, width - 1)
	var z0 := maxi(cz - 1, 0)
	var z1 := mini(cz + 1, length - 1)
	var dx := (heights[cz * width + x1] - heights[cz * width + x0]) / float(maxi(x1 - x0, 1)) / VERTEX_SPACING
	var dz := (heights[z1 * width + cx] - heights[z0 * width + cx]) / float(maxi(z1 - z0, 1)) / VERTEX_SPACING
	return Vector3(-dx, 1.0, -dz).normalized()

## Sums every vertex normal under `node` (same transform folding as
## _collect_mesh_vertices_recursive) -- a scanned rock shell's summed normal points out of its
## textured face, which is how _scatter_outcrops knows which side to lay facing up.
static func sum_mesh_normals_recursive(node: Node, parent_transform: Transform3D) -> Vector3:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	var total := Vector3.ZERO
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		if mesh_inst.mesh:
			for surface_idx in mesh_inst.mesh.get_surface_count():
				var arrays := mesh_inst.mesh.surface_get_arrays(surface_idx)
				var normals = arrays[Mesh.ARRAY_NORMAL]
				if normals is PackedVector3Array:
					for n in normals:
						total += local_transform.basis * n
	for child in node.get_children():
		total += sum_mesh_normals_recursive(child, local_transform)
	return total
