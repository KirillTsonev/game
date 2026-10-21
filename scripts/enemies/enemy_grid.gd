## The ground enemies walk on (2026-10-21, a first rudimentary enemy system): a 1 m grid over the
## generated map and the hub, one cell per heightmap pixel, searched with Godot's AStarGrid2D.
## No navigation mesh -- after a post by the maker of ALLFATHER (procedural levels, hordes): the
## enemies think on a grid every third of a second and slide from cell to cell in between
## (EnemyDirector, Enemy). Cell (x, z) is heightmap pixel (x, z); rows past the map's last one
## are the hub's (TerrainHub: hub row j = cell row AREA_LENGTH + j).
##
## A cell is blocked when the ground there is steeper than MAX_GRADE, on the mountain's rock
## (MountainWalls.mountain_depth), under the castle, or within BODY_RADIUS of an obstacle with
## collision: tree trunks, boulders, deadfall, outcrops, cliff meshes. The obstacles come from
## the scatter modules' keep-out lists, which stay filled until the next run's reset_run_state().
## Walkable cells are labelled by connected area (`component`): a path is only searched between
## cells of one area, so AStarGrid2D never floods the whole map looking for an unreachable goal.
##
## Built once, the first time an enemy is spawned (EnemyDirector.ensure), not at startup. Its cost
## is printed ("ENEMIES: grid built ...").
class_name EnemyGrid
extends RefCounted

const MAX_GRADE := 0.84 ## tan 40 deg: steeper ground is not walked on (the player's limit is 45)
const BODY_RADIUS := 0.4 ## m added to every obstacle's radius: how close an enemy's middle may come
const EDGE_MARGIN := 2 ## cells along the grid's edges kept blocked

var width := 0
var length := 0 ## the generated map's rows, then the hub's
var corner := Vector3.ZERO ## world position of cell (0, 0)
var heights := PackedFloat32Array()
var blocked := PackedByteArray() ## 1 = not walkable, per cell (row-major)
var component := PackedInt32Array() ## connected walkable area per cell, -1 = blocked
var astar := AStarGrid2D.new()

## The grid for the world WorldGenerator (`world`) built this run; null before it is built.
static func build(world: Node) -> EnemyGrid:
	var maps: Dictionary = world.get("world_maps") if world else {}
	if maps.is_empty():
		return null
	var t0 := Time.get_ticks_msec()
	var g := EnemyGrid.new()
	g.width = TerrainConfig.AREA_WIDTH
	var map_length := TerrainConfig.AREA_LENGTH
	g.heights = (maps.heights as PackedFloat32Array).duplicate()
	var hub: PackedFloat32Array = maps.get("hub_heights", PackedFloat32Array())
	if hub.size() == g.width * TerrainHub.STRIP_LENGTH:
		g.heights.append_array(hub)
	g.length = g.heights.size() / g.width
	g.corner = world.get("world_corner")
	g.blocked.resize(g.width * g.length)
	g.blocked.fill(0)
	g._block_ground(map_length)
	var t_ground := Time.get_ticks_msec()
	g._block_obstacles(maps)
	var t_obstacles := Time.get_ticks_msec()
	var areas := g._label_components()
	var t_areas := Time.get_ticks_msec()
	g._build_astar()
	var walkable := 0
	for i in g.blocked.size():
		walkable += 1 - g.blocked[i]
	print("ENEMIES: grid built -- %d x %d cells, %d walkable (%.0f %%) in %d area(s); ground %d ms, obstacles %d ms, areas %d ms, A* %d ms" % [
		g.width, g.length, walkable, 100.0 * walkable / float(g.blocked.size()), areas,
		t_ground - t0, t_obstacles - t_ground, t_areas - t_obstacles, Time.get_ticks_msec() - t_areas])
	return g

## Steep ground, the grid's edges, the mountain's rock and the castle.
func _block_ground(map_length: int) -> void:
	var max_grade_sq := MAX_GRADE * MAX_GRADE
	for z in length:
		var zm := maxi(z - 1, 0)
		var zp := mini(z + 1, length - 1)
		var row := z * width
		var edge_row := z < EDGE_MARGIN or z >= length - EDGE_MARGIN
		for x in width:
			if edge_row or x < EDGE_MARGIN or x >= width - EDGE_MARGIN:
				blocked[row + x] = 1
				continue
			var gx := (heights[row + x + 1] - heights[row + x - 1]) * 0.5
			var gz := (heights[zp * width + x] - heights[zm * width + x]) / float(zp - zm)
			if gx * gx + gz * gz > max_grade_sq:
				blocked[row + x] = 1
			elif z < map_length and (MountainWalls.mountain_depth(x, z) > 0.0 or TerrainCastle.covers(x, z, BODY_RADIUS)):
				blocked[row + x] = 1

## Everything with collision the scatter stages placed (their keep-out lists, in heightmap pixels).
func _block_obstacles(maps: Dictionary) -> void:
	for tp in TreeScatter.tree_points: # (px, pz, scale)
		_block_circle(tp.x, tp.y, TreeScatter.TREE_TRUNK_RADIUS * tp.z)
	for c in RockScatter.rock_keep_circles: # (px, pz, radius)
		_block_circle(c.x, c.y, c.z)
	for c in DeadfallScatter.deadfall_keep_circles:
		_block_circle(c.x, c.y, c.z)
	for oc in maps.get("outcrop_plan", []):
		_block_circle(float(oc.px), float(oc.pz), float(oc.radius))
	# Cliff meshes: their turned footprints, built as TreeScatter.scatter_trees builds its keep_rects.
	var defs: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		defs[def.name] = def
	var profiles: Dictionary = maps.get("cliff_dressing_top_profiles", {})
	for entry in maps.get("cliff_dressing_plan", []):
		var cdef = defs.get(entry.def_name)
		if cdef == null:
			continue
		var prof: Dictionary = profiles.get(entry.def_name, {})
		var sj: float = entry.scale_jitter
		var fa: float = entry.face_angle
		_block_rect(Vector2(entry.px, entry.pz), Vector2(cos(fa), -sin(fa)), Vector2(sin(fa), cos(fa)),
			float(prof.get("x_min", -cdef.real_size * 0.5)) * sj, float(prof.get("x_max", cdef.real_size * 0.5)) * sj,
			float(prof.get("z_min", -cdef.depth * 0.5)) * sj, float(prof.get("z_max", cdef.depth * 0.5)) * sj)

func _block_circle(px: float, pz: float, radius: float) -> void:
	var r := radius + BODY_RADIUS
	for z in range(maxi(ceili(pz - r), 0), mini(floori(pz + r), length - 1) + 1):
		for x in range(maxi(ceili(px - r), 0), mini(floori(px + r), width - 1) + 1):
			if (x - px) * (x - px) + (z - pz) * (z - pz) <= r * r:
				blocked[z * width + x] = 1

## A box turned on the ground: centre c, unit axes ax / az, extents along them x0..x1 / z0..z1.
func _block_rect(c: Vector2, ax: Vector2, az: Vector2, x0: float, x1: float, z0: float, z1: float) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for lx in [x0, x1]:
		for lz in [z0, z1]:
			var p: Vector2 = c + ax * lx + az * lz
			lo = lo.min(p)
			hi = hi.max(p)
	var pad := BODY_RADIUS
	for z in range(maxi(floori(lo.y - pad), 0), mini(ceili(hi.y + pad), length - 1) + 1):
		for x in range(maxi(floori(lo.x - pad), 0), mini(ceili(hi.x + pad), width - 1) + 1):
			var d := Vector2(x, z) - c
			var lx := d.dot(ax)
			var lz := d.dot(az)
			if lx >= x0 - pad and lx <= x1 + pad and lz >= z0 - pad and lz <= z1 + pad:
				blocked[z * width + x] = 1

## Flood-fills the walkable cells into areas joined side to side (a diagonal step is only taken
## when both side cells are free, so side-to-side is how enemies can actually move). Returns the count.
func _label_components() -> int:
	component.resize(width * length)
	component.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(width * length)
	var areas := 0
	for start in blocked.size():
		if blocked[start] != 0 or component[start] >= 0:
			continue
		component[start] = areas
		queue[0] = start
		var head := 0
		var tail := 1
		while head < tail:
			var i := queue[head]
			head += 1
			var x := i % width
			for n: int in [i - 1 if x > 0 else -1, i + 1 if x < width - 1 else -1, i - width, i + width]:
				if n >= 0 and n < blocked.size() and blocked[n] == 0 and component[n] < 0:
					component[n] = areas
					queue[tail] = n
					tail += 1
		areas += 1
	return areas

func _build_astar() -> void:
	astar.region = Rect2i(0, 0, width, length)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	# One call per run of blocked cells in a row, not per cell.
	for z in length:
		var row := z * width
		var x := 0
		while x < width:
			if blocked[row + x] == 0:
				x += 1
				continue
			var run_start := x
			while x < width and blocked[row + x] != 0:
				x += 1
			astar.fill_solid_region(Rect2i(run_start, z, x - run_start, 1), true)

func inside(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < width and cell.y < length

func walkable(cell: Vector2i) -> bool:
	return inside(cell) and blocked[cell.y * width + cell.x] == 0

## The connected area of `cell`, -1 if blocked or off the grid.
func area_of(cell: Vector2i) -> int:
	return component[cell.y * width + cell.x] if inside(cell) else -1

func cell_of(world_position: Vector3) -> Vector2i:
	return Vector2i(roundi(world_position.x - corner.x), roundi(world_position.z - corner.z))

## The ground under the middle of `cell`, in world space.
func world_of(cell: Vector2i) -> Vector3:
	return Vector3(corner.x + cell.x, ground_height(corner.x + cell.x, corner.z + cell.y), corner.z + cell.y)

## Ground height at world (x, z), between the heightmap's samples (the collision's ground).
func ground_height(world_x: float, world_z: float) -> float:
	return corner.y + TerrainUtil.sample_height_bilinear(heights, width, length, world_x - corner.x, world_z - corner.z)

## The walkable cell nearest `cell` within `reach` cells (in growing square rings), limited to
## area `area` unless it is -1; Vector2i(-1, -1) if there is none.
func nearest_walkable(cell: Vector2i, reach: int, area: int = -1) -> Vector2i:
	for r in reach + 1:
		var best := Vector2i(-1, -1)
		var best_d := INF
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dz)) != r:
					continue
				var c := cell + Vector2i(dx, dz)
				if walkable(c) and (area < 0 or area_of(c) == area):
					var d := float(dx * dx + dz * dz)
					if d < best_d:
						best_d = d
						best = c
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)

## Cells from `from` (left out) to `to`; empty when `to` is not in `from`'s area.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if not walkable(from) or area_of(from) != area_of(to):
		return path
	path = astar.get_id_path(from, to)
	if not path.is_empty() and path[0] == from:
		path.remove_at(0)
	return path
