extends Node3D
## 2026-09-29 DEBUG -- landmark copy-shape picker. Kirill: "walk around the landmark, press a
## button, a debug beacon appears, the beacons connect automatically, a button to remove a beacon,
## then when we have the shape you read it and implement that shape as the copy area".
##
##   B  place a beacon where you stand (camera XZ, dropped to the ground)
##   X  remove the beacon nearest to you
##   N  save the shape into the landmark data file (TerrainLandmarks.save_polygon). The stamp uses
##      it from the NEXT scene run: inside = copied 1:1, blend goes OUTWARD, FEATHER metres wide.
##
## Beacons connect one by one in the order they're placed (Kirill 2026-09-29: the earlier
## cheapest-insertion ordering "doesn't work well"): B0 -> B1 -> B2 ... in white, plus a dim yellow
## line from the last beacon back to B0 that closes the shape. X removes a beacon and its
## neighbours reconnect to each other.
## Starts from the saved shape, if there is one. Preview tint uses the exact stamp weights
## (TerrainLandmarks.zone_for): cyan = copied 1:1, orange = blend band (opacity = how much of the
## copy shows). RED beacon = the shape + its blend would leave the captured height square there.
## Spawned by TerrainLandmarks.spawn_debug_overlay; purely visual, no collision.
##
## STATUS: DISABLED (2026-09-29) -- the copy shape was picked and saved. To use it again, uncomment
## the TerrainLandmarks.spawn_debug_overlay(...) call in terrain_gen.gd's _ready(). Recipe:
##   1. run the scene, walk to the landmark (left valley wall, world ~(-217, 174), same every seed)
##   2. the saved beacons load back in order; X near a beacon removes it, B appends new ones
##   3. N saves, then restart the scene -- stamp() logs "[polygon N pts]" when it uses the shape
##   4. comment the call out again when done

const KEY_PLACE := KEY_B
const KEY_REMOVE := KEY_X
const KEY_SAVE := KEY_N
const EDGE_WALL_HEIGHT := 3.0
const TINT_LIFT := 0.2
const COL_BEACON_OK := Color(0.2, 1.0, 0.35, 0.95)
const COL_BEACON_BAD := Color(1.0, 0.15, 0.15, 0.95)
const COL_EDGE := Color(1.0, 1.0, 1.0, 0.75)
const COL_CLOSE := Color(1.0, 0.9, 0.3, 0.35) ## auto-closing last->first line

var _corner := Vector3.ZERO
var _heights := PackedFloat32Array()
var _centre := Vector2.ZERO ## landmark centre, absolute pixels
var _cap_half := 55 ## half-size of the captured height square (pixels)
var _limit := 45.0 ## |dx| / |dz| a beacon may reach so shape + blend stay inside the square
var _points: Array[Vector2] = [] ## relative pixels, loop order
var _vis: Node3D
var _mat: StandardMaterial3D
var _unsaved := false

func setup(corner: Vector3, heights: PackedFloat32Array, centre: Vector2, saved: PackedVector2Array, capture_half: int) -> void:
	_corner = corner
	_heights = heights
	_centre = centre
	_cap_half = capture_half
	_limit = float(capture_half) - TerrainLandmarks.FEATHER
	for p in saved:
		_points.append(p)

func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rebuild()
	print("TERRAIN_GEN_DEBUG: BEACONS ready -- B place, X remove nearest, N save shape (%d loaded from the data file)" % _points.size())

func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.physical_keycode:
		KEY_PLACE:
			_place()
		KEY_REMOVE:
			_remove_nearest()
		KEY_SAVE:
			_save()
		_:
			return
	get_viewport().set_input_as_handled()

func _player_rel() -> Vector2:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return Vector2.INF
	var p := cam.global_position
	return Vector2(p.x - _corner.x, p.z - _corner.z) - _centre

func _ok(p: Vector2) -> bool:
	return absf(p.x) <= _limit and absf(p.y) <= _limit

func _place() -> void:
	var p := _player_rel()
	if p == Vector2.INF:
		push_warning("BEACONS: no active camera -- beacon not placed")
		return
	var at := _points.size() # always appended: beacons connect one by one in placement order
	_points.insert(at, p)
	_unsaved = true
	print("TERRAIN_GEN_DEBUG: BEACON placed as #%d at rel (%.1f, %.1f)%s -- %d beacon(s), unsaved" % [at, p.x, p.y, "" if _ok(p) else " OUTSIDE the capture limit (+-%.0f)" % _limit, _points.size()])
	_rebuild()

func _remove_nearest() -> void:
	if _points.is_empty():
		print("TERRAIN_GEN_DEBUG: BEACON remove -- no beacons")
		return
	var p := _player_rel()
	var best := 0
	for i in _points.size():
		if _points[i].distance_to(p) < _points[best].distance_to(p):
			best = i
	var q := _points[best]
	_points.remove_at(best)
	_unsaved = true
	print("TERRAIN_GEN_DEBUG: BEACON #%d removed (rel %.1f, %.1f, %.1f m from you) -- %d beacon(s) left, unsaved" % [best, q.x, q.y, q.distance_to(p), _points.size()])
	_rebuild()

func _save() -> void:
	var bad := 0
	for p in _points:
		if not _ok(p):
			bad += 1
	var msg := TerrainLandmarks.save_polygon(_points)
	if msg.begins_with("LANDMARK shape saved"):
		_unsaved = false
	print("TERRAIN_GEN_DEBUG: " + msg + ("" if bad == 0 else "  WARNING: %d beacon(s) outside the capture limit -- the blend gets cut there" % bad))

func _h(ax: float, az: float) -> float:
	return TerrainLandmarks._debug_h(_heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, ax, az)

func _rebuild() -> void:
	if _vis:
		remove_child(_vis) # detach first so the new node keeps the "BeaconVisuals" name
		_vis.queue_free()
	_vis = Node3D.new()
	_vis.name = "BeaconVisuals"
	add_child(_vis)
	var n := _points.size()
	# Beacons.
	for i in n:
		var p := _points[i]
		var a := _centre + p
		var foot := _corner + Vector3(a.x, _h(a.x, a.y), a.y)
		var ok := _ok(p)
		TerrainLandmarks._debug_pole(_vis, foot, COL_BEACON_OK if ok else COL_BEACON_BAD, "B%d%s" % [i, "" if ok else "\nOUTSIDE"])
	if n < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Edges: B0->B1->...->Bn-1 in placement order (white), plus the auto-closing Bn-1->B0 line
	# (dim yellow) once there are 3+ beacons, since the copy area has to be a closed shape.
	for i in n - 1:
		_edge_wall(st, _points[i], _points[i + 1], COL_EDGE)
	if n >= 3:
		_edge_wall(st, _points[n - 1], _points[0], COL_CLOSE)
	# Preview tint of the resulting copy area (same weights as the stamp).
	if n >= 3:
		_preview_tint(st, PackedVector2Array(_points))
	var mi := MeshInstance3D.new()
	mi.name = "ShapePreview"
	mi.mesh = st.commit()
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vis.add_child(mi)

func _vertex(st: SurfaceTool, rel: Vector2, lift: float, col: Color) -> void:
	var a := _centre + rel
	st.set_color(col)
	st.add_vertex(_corner + Vector3(a.x, _h(a.x, a.y) + lift, a.y))

## Ground-following vertical ribbon from a to b (relative pixels), fading toward the top.
func _edge_wall(st: SurfaceTool, a: Vector2, b: Vector2, col: Color) -> void:
	var steps := maxi(1, int(ceil(a.distance_to(b))))
	var top := Color(col, 0.05)
	for j in steps:
		var p0 := a.lerp(b, float(j) / steps)
		var p1 := a.lerp(b, float(j + 1) / steps)
		_vertex(st, p0, 0.05, col)
		_vertex(st, p1, 0.05, col)
		_vertex(st, p1, EDGE_WALL_HEIGHT, top)
		_vertex(st, p0, 0.05, col)
		_vertex(st, p1, EDGE_WALL_HEIGHT, top)
		_vertex(st, p0, EDGE_WALL_HEIGHT, top)

func _zone_color(rel: Vector2, poly: PackedVector2Array) -> Color:
	var z := TerrainLandmarks.zone_for(rel, poly)
	if z.y > 0.5:
		return TerrainLandmarks.DEBUG_COL_INNER
	if z.x <= 0.0:
		return Color(TerrainLandmarks.DEBUG_COL_FEATHER, 0.0)
	return Color(TerrainLandmarks.DEBUG_COL_FEATHER, 0.1 + TerrainLandmarks.DEBUG_COL_FEATHER.a * z.x)

func _preview_tint(st: SurfaceTool, poly: PackedVector2Array) -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p in poly:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var f := TerrainLandmarks.FEATHER
	var x0 := maxi(int(floor(lo.x - f)), -_cap_half)
	var x1 := mini(int(ceil(hi.x + f)), _cap_half - 1)
	var z0 := maxi(int(floor(lo.y - f)), -_cap_half)
	var z1 := mini(int(ceil(hi.y + f)), _cap_half - 1)
	var w := TerrainConfig.AREA_WIDTH
	var l := TerrainConfig.AREA_LENGTH
	for qz in range(z0, z1 + 1):
		for qx in range(x0, x1 + 1):
			var ax := _centre.x + qx
			var az := _centre.y + qz
			if ax < 0.0 or az < 0.0 or ax > w - 2 or az > l - 2:
				continue
			var r00 := Vector2(qx, qz)
			var r10 := Vector2(qx + 1, qz)
			var r11 := Vector2(qx + 1, qz + 1)
			var r01 := Vector2(qx, qz + 1)
			var c00 := _zone_color(r00, poly)
			var c10 := _zone_color(r10, poly)
			var c11 := _zone_color(r11, poly)
			var c01 := _zone_color(r01, poly)
			if c00.a <= 0.0 and c10.a <= 0.0 and c11.a <= 0.0 and c01.a <= 0.0:
				continue
			_vertex(st, r00, TINT_LIFT, c00)
			_vertex(st, r10, TINT_LIFT, c10)
			_vertex(st, r11, TINT_LIFT, c11)
			_vertex(st, r00, TINT_LIFT, c00)
			_vertex(st, r11, TINT_LIFT, c11)
			_vertex(st, r01, TINT_LIFT, c01)
