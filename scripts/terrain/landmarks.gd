## Fixed landmarks (2026-09-29): hand-picked formations captured ONCE from the seed they appeared
## on and stamped into every generated map at the same spot.
##
## Landmark #1 = the "verticality knot" Kirill found on seed 4176228882 (left valley wall, around
## world (-220, 160)): a shelf jutting out of the wall higher than the ground behind it, a dip,
## and a lower ledge -- formed by cliff meshes @8/@9/@10 and their raise-behind plateaus (see
## knots.gd's header). Kirill (2026-09-29): "can we somehow copy that random knot we discovered
## wholesale and turn it into a fixed landmark that appears in every seed?" -- same spot every seed.
##
## Data file (DATA_PATH, written by capture() from the reference run): the heights inside a disk of
## RADIUS around CENTER_PX (absolute metres, null off-map) + every cliff-dressing entry whose
## centre is inside it (position relative to the centre, foot height absolute).
##
## Pipeline (TerrainHeightmap.build_heightmap), only when the data file exists:
##   1. filter_cliff_plan() right after plan_cliff_dressing, BEFORE flatten/raise: planned meshes
##      in the disk are dropped (so nothing gets built there only to be overwritten).
##   2. filter_outcrops() right after plan_outcrops, before they're fitted.
##   3. stamp() after outcrops, before knots + road: fits a plane (offset + tilt) between this
##      map's terrain and the captured heights on the outer FEATHER ring, writes captured heights
##      + plane inside, feathered over the ring; appends the captured meshes (heights shifted by
##      the same plane); marks the inner disk in the road obstacle mask. Knots then see the area as
##      taken (height diff + mesh circles in their occupancy).
## On the reference seed itself the stamp must be ~a no-op (stamp() prints the max change).
##
## Copy SHAPE (2026-09-29): the circle turned out to copy too much, so the copy area is now a
## polygon Kirill picked in-game with the beacon tool (scripts/debug/landmark_beacon_tool.gd),
## saved as "polygon" in the data file (points relative to the centre). When it's present:
##   - inside the polygon  = captured heights copied 1:1 (+ fitted plane), road-blocked
##   - FEATHER m OUTSIDE it = blend back to this map's terrain (the plane is fitted on this band)
##   - captured meshes / cliff features are only stamped if their centre is inside the polygon
##   - this map's own dressing / outcrops / features are cleared from polygon + FEATHER
## Without "polygon" everything falls back to the old circle (CENTER_PX / RADIUS / FEATHER ring).
## The captured heights cover a (size x size) square, so polygon + FEATHER must stay inside it.
## To re-pick the shape: re-enable the debug call in terrain_gen.gd (see spawn_debug_overlay).
## To go back to the circle: delete the "polygon" key from the data file.
##
## Static-only module, same conventions as the other scripts/terrain modules.
class_name TerrainLandmarks
extends RefCounted

const DATA_PATH := "res://terrain_data/landmarks/verticality_knot_01.json"
## Disk (heightmap pixels = metres). CENTER_PX/RADIUS chosen from debug_list() so every one of the
## formation's meshes AND its raised plateaus sit inside the disk (see capture's report).
## Reference layout (seed 4176228882): mesh @9 cliff_01 px(42.1, 440.8), @8 cliff_01 px(51.6, 451.6),
## @10 cliff_02 px(22.5, 404.6) (half-width 11.3, faces the mountain, its shelf built toward the
## valley), plus two cliff features (5 m steps) at px(48.7, 448.4) and (22.8, 408.4). At r 45 @10's
## body and the plateau behind @8/@9 (~38 m out) reached the feather ring -> r 55, centre (35, 430):
## everything sits inside the fully-copied inner 45 m.
const CENTER_PX := Vector2(35.0, 430.0)
const RADIUS := 55.0
const FEATHER := 10.0 ## outer ring: blend captured -> this map's terrain, and where the plane is fitted
const ENABLED := true

static var _cache: Dictionary = {}

static func _load() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	if not FileAccess.file_exists(DATA_PATH):
		return {}
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("LANDMARK: %s is not valid JSON -- landmark skipped" % DATA_PATH)
		return {}
	_cache = parsed
	return _cache

static func is_active() -> bool:
	return ENABLED and not _load().is_empty()

static func _center() -> Vector2:
	var d := _load()
	if d.has("center"):
		return Vector2(float(d.center[0]), float(d.center[1]))
	return CENTER_PX

static func _radius() -> float:
	return float(_load().get("radius", RADIUS))

## Half the widest extent of a cliff-dressing entry's model (for "does it reach into the disk").
static func _entry_half_size(e: Dictionary) -> float:
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		if def.name == e.def_name:
			return float(def.real_size) * float(e.get("scale_jitter", 1.0)) * 0.5
	return 5.0

## 1. Drop planned cliff meshes that would stand in / reach into the landmark area.
static func filter_cliff_plan(plan: Array[Dictionary]) -> int:
	if not is_active():
		return 0
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var e: Dictionary = plan[i]
		if _reaches(Vector2(float(e.px), float(e.pz)), _entry_half_size(e)):
			plan.remove_at(i)
			removed += 1
	return removed

## 2. Drop outcrops in / reaching into the landmark area.
static func filter_outcrops(plan: Array) -> int:
	if not is_active():
		return 0
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var o: Dictionary = plan[i]
		if _reaches(Vector2(float(o.px), float(o.pz)), float(o.radius)):
			plan.remove_at(i)
			removed += 1
	return removed

# ---------------------------------------------------------------------------------------------
# Copy shape (2026-09-29, Kirill: pick the copy area in-game with beacons, blend OUTWARD).
# If the data file has "polygon" (>= 3 points, pixels relative to the landmark centre, saved by
# the beacon tool), that shape replaces the circle: inside it = captured heights 1:1 (+ plane),
# then a FEATHER-wide band OUTSIDE it blends back to this map. Captured meshes / features are only
# taken if their centre is inside the shape. Without a polygon the old circle behaviour applies.
# Captured heights cover the full (size x size) square around the centre, so the shape + FEATHER
# must stay inside that square (the beacon tool flags beacons that don't).
# ---------------------------------------------------------------------------------------------

## Saved copy shape (relative pixels), empty if none.
static func polygon() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in _load().get("polygon", []):
		out.append(Vector2(float(p[0]), float(p[1])))
	return out if out.size() >= 3 else PackedVector2Array()

## Half-size of the captured square (pixels), for the beacon tool's limit check.
static func capture_half() -> int:
	return int(_load().get("size", RADIUS * 2.0 + 1.0)) / 2

## (copy weight 0..1, 1.0 if in the fully-copied core else 0.0) for a pixel RELATIVE to the centre.
## poly empty -> circle mode.
static func _zone(rel: Vector2, poly: PackedVector2Array) -> Vector2:
	if poly.size() >= 3:
		if Geometry2D.is_point_in_polygon(rel, poly):
			return Vector2(1.0, 1.0)
		var d := dist_to_polygon(rel, poly)
		return Vector2(1.0 - smoothstep(0.0, FEATHER, d) if d < FEATHER else 0.0, 0.0)
	var r := _radius()
	var dist := rel.length()
	if dist <= r - FEATHER:
		return Vector2(1.0, 1.0)
	return Vector2(1.0 - smoothstep(r - FEATHER, r, dist) if dist < r else 0.0, 0.0)

## Public copy weight for any shape (the beacon tool previews unsaved shapes with this).
static func zone_for(rel: Vector2, poly: PackedVector2Array) -> Vector2:
	return _zone(rel, poly)

static func dist_to_polygon(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best

## Does something centred at `p_abs` (absolute pixels) with half-size `extra` reach the area this
## map's own dressing must clear (core + feather)?
static func _reaches(p_abs: Vector2, extra: float) -> bool:
	var rel := p_abs - _center()
	var poly := polygon()
	if poly.size() >= 3:
		return Geometry2D.is_point_in_polygon(rel, poly) or dist_to_polygon(rel, poly) < FEATHER + extra
	return rel.length() < _radius() + extra

## Writes the shape into the landmark data file (keeps everything else). Takes effect next run.
static func save_polygon(points: Array[Vector2]) -> String:
	if points.size() < 3:
		return "LANDMARK shape NOT saved -- need at least 3 beacons (have %d)" % points.size()
	if not FileAccess.file_exists(DATA_PATH):
		return "LANDMARK shape NOT saved -- %s missing" % DATA_PATH
	var data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return "LANDMARK shape NOT saved -- %s is not valid JSON" % DATA_PATH
	var arr: Array = []
	for p in points:
		arr.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01)])
	data["polygon"] = arr
	var fa := FileAccess.open(DATA_PATH, FileAccess.WRITE)
	if fa == null:
		return "LANDMARK shape NOT saved -- can't write %s (err %d)" % [DATA_PATH, FileAccess.get_open_error()]
	fa.store_string(JSON.stringify(data))
	fa.close()
	_cache = {}
	return "LANDMARK shape saved: %d points %s -- restart the scene to stamp with it" % [arr.size(), str(arr)]

## 3. Stamp heights + meshes, reserve the area. Returns stats.
static func stamp(heights: PackedFloat32Array, width: int, length: int, cliff_plan: Array[Dictionary], obstacle_mask: PackedByteArray, cliff_features: Array, top_profiles: Dictionary) -> Dictionary:
	if not is_active():
		return {}
	var d := _load()
	var c := _center()
	var r := _radius()
	var n: int = int(d.size)
	var half := n / 2
	var patch: Array = d.heights
	var poly := polygon() # empty -> circle mode
	# Plane fit on the blend band (circle: the outer FEATHER ring; polygon: the band outside the shape).
	var s := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0] # sums: 1, x, z, xx, xz, zz, f, xf, zf
	var ring_px := 0
	for lz in n:
		for lx in n:
			var dx := float(lx - half)
			var dz := float(lz - half)
			var zr := _zone(Vector2(dx, dz), poly)
			if zr.y > 0.5 or zr.x <= 0.0:
				continue
			var v = patch[lz * n + lx]
			if v == null:
				continue
			var px := int(c.x) + lx - half
			var pz := int(c.y) + lz - half
			if px < 0 or pz < 0 or px >= width or pz >= length:
				continue
			var f: float = heights[pz * width + px] - float(v)
			s[0] += 1.0; s[1] += dx; s[2] += dz; s[3] += dx * dx; s[4] += dx * dz; s[5] += dz * dz
			s[6] += f; s[7] += dx * f; s[8] += dz * f
			ring_px += 1
	var plane := _solve3(s)
	var pa: float = plane.x
	var pb: float = plane.y
	var pc: float = plane.z
	# Heights: captured + plane inside, feathered to this map's terrain across the ring.
	var max_change := 0.0
	var changed := 0
	for lz in n:
		for lx in n:
			var v = patch[lz * n + lx]
			if v == null:
				continue
			var dx := float(lx - half)
			var dz := float(lz - half)
			var zw := _zone(Vector2(dx, dz), poly)
			if zw.x <= 0.0:
				continue
			var px := int(c.x) + lx - half
			var pz := int(c.y) + lz - half
			if px < 0 or pz < 0 or px >= width or pz >= length:
				continue
			var idx := pz * width + px
			var w: float = zw.x
			var target := float(v) + pa + pb * dx + pc * dz
			var nh := lerpf(heights[idx], target, w)
			max_change = maxf(max_change, absf(nh - heights[idx]))
			if absf(nh - heights[idx]) > 0.001:
				changed += 1
			heights[idx] = nh
			if zw.y > 0.5 and not obstacle_mask.is_empty():
				obstacle_mask[idx] = 1
	# Meshes.
	var added: Array[Dictionary] = []
	for m in d.meshes:
		var e: Dictionary = (m as Dictionary).duplicate(true)
		var mdx: float = float(e.dx)
		var mdz: float = float(e.dz)
		if poly.size() >= 3 and not Geometry2D.is_point_in_polygon(Vector2(mdx, mdz), poly):
			continue # polygon mode: only meshes whose centre is inside the picked shape
		e.erase("dx")
		e.erase("dz")
		e["px"] = c.x + mdx
		e["pz"] = c.y + mdz
		e["height"] = float(e.height) + pa + pb * mdx + pc * mdz
		e["landmark"] = "verticality_knot_01"
		added.append(e)
	cliff_plan.append_array(added)
	# 2026-09-30: the copied ground keeps the reference run's top lift, and the plane fit moves the
	# meshes rigidly vs the terrain per pixel -> top the ground behind them back up to mesh top +
	# each def's "top_lift" (top-up only -- see CLIFF_DRESSING_SEAM_MIN_COVERAGE).
	var seam_px := 0
	if not added.is_empty():
		seam_px = CliffDressing.raise_terrain_behind_cliff_dressing(added, heights, width, length, top_profiles, 0, true)
	if not obstacle_mask.is_empty():
		var mesh_mask := CliffDressing.build_cliff_dressing_obstacle_mask(added, width, length)
		for i in mesh_mask.size():
			if mesh_mask[i] == 1:
				obstacle_mask[i] = 1
	# Cliff features: this map's features centred in the disk go (their terrain was just replaced),
	# the captured ones come in -- boulders / scree / rock paint / moss shade follow features.
	var feat_removed := 0
	for i in range(cliff_features.size() - 1, -1, -1):
		var fc: Vector2 = cliff_features[i].center
		if _zone(fc - c, poly).x > 0.0:
			cliff_features.remove_at(i)
			feat_removed += 1
	var feat_added := 0
	for fd in d.get("features", []):
		var f: Dictionary = _decode(fd)
		if poly.size() >= 3 and not Geometry2D.is_point_in_polygon(f.center as Vector2, poly):
			continue # centre still relative here
		f["center"] = c + (f.center as Vector2)
		f["landmark"] = "verticality_knot_01"
		cliff_features.append(f)
		feat_added += 1
	var stats := {"plane": plane, "ring_px": ring_px, "changed": changed, "max_change": max_change, "meshes": added.size(), "seam_px": seam_px}
	print("TERRAIN_GEN: LANDMARK verticality_knot_01 stamped at px (%.0f, %.0f) r %.0f [%s] -- plane offset %.2f m, tilt (%.3f, %.3f) from %d ring px; %d px changed (max %.2f m); %d cliff mesh(es), %d px topped up to mesh top + per-def top_lift; cliff features -%d +%d" % [
		c.x, c.y, r, ("polygon %d pts" % poly.size()) if poly.size() >= 3 else "circle", pa, pb, pc, ring_px, changed, max_change, added.size(), seam_px, feat_removed, feat_added])
	return stats

# ---------------------------------------------------------------------------------------------
# 2026-09-29 DEBUG overlay (Kirill: "can you add some sort of visible highlight to see what gets
# copied?"). Draws what stamp() brought into THIS map, so we can decide what to trim:
#   CYAN   tint + wall  = inner disk (r - FEATHER): captured heights copied 1:1 (+ plane)
#   ORANGE tint + wall  = feather ring: blend captured -> this map (more opaque = more copy)
#   MAGENTA pole/ring/label = copied cliff mesh "LM mesh #k" (k = index in the JSON's meshes)
#   YELLOW  pole/label      = copied cliff feature "LM feature #j" (index in the JSON's features;
#                             boulders / scree / rock paint / moss follow these)
# Rebuilt every run under a "LandmarkDebugOverlay" node; purely visual, no collision.
#
# STATUS: DISABLED (2026-09-29, copy shape picked and saved). Nothing calls spawn_debug_overlay
# right now -- the call in terrain_gen.gd's _ready() is commented out; uncomment it to bring the
# overlay AND the beacon tool back. DEBUG_SHOW_OVERLAY is a second kill switch inside the function.
# In polygon mode (a saved shape exists) the circle tint/walls are skipped and the beacon tool
# draws the shape + its preview tint instead (it starts from the saved shape, so you can edit it).
# ---------------------------------------------------------------------------------------------
const DEBUG_SHOW_OVERLAY := true
const DEBUG_OVERLAY_LIFT := 0.15 ## metres the tint floats above the ground (avoids z-fighting)
const DEBUG_WALL_HEIGHT := 4.0 ## height of the boundary walls
const DEBUG_POLE_HEIGHT := 10.0
const DEBUG_COL_INNER := Color(0.1, 0.9, 1.0, 0.35)
const DEBUG_COL_FEATHER := Color(1.0, 0.55, 0.0, 0.55)
const DEBUG_COL_MESH := Color(1.0, 0.2, 0.9, 0.9)
const DEBUG_COL_FEATURE := Color(1.0, 0.95, 0.1, 0.9)

static func spawn_debug_overlay(parent: Node, heightmap_corner: Vector3, maps: Dictionary) -> void:
	var old := parent.get_node_or_null("LandmarkDebugOverlay")
	if old:
		old.queue_free()
	if not DEBUG_SHOW_OVERLAY or not is_active():
		return
	var heights: PackedFloat32Array = maps.heights
	var width := TerrainConfig.AREA_WIDTH
	var length := TerrainConfig.AREA_LENGTH
	var c := Vector2(floorf(_center().x), floorf(_center().y)) # stamp() uses int(c) as the pixel centre
	var r := _radius()
	var ring_lo := r - FEATHER

	# Built detached, added deferred (parent is still setting up its children during _ready --
	# same as CliffDressing.spawn_raise_debug_boxes). Root at the origin, so local = world.
	var root := Node3D.new()
	root.name = "LandmarkDebugOverlay"
	parent.add_child.call_deferred(root)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# 1. Tint draped over the stamped terrain (per-vertex colour by distance from the centre).
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0 := maxi(int(floor(c.x - r)), 0)
	var x1 := mini(int(ceil(c.x + r)), width - 2)
	var z0 := maxi(int(floor(c.y - r)), 0)
	var z1 := mini(int(ceil(c.y + r)), length - 2)
	var poly := polygon()
	var circle_mode := poly.size() < 3 # polygon mode: the beacon tool draws the shape + its tint
	var corners := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(0, 1)]
	if circle_mode:
		for qz in range(z0, z1 + 1):
			for qx in range(x0, x1 + 1):
				if Vector2(qx + 0.5, qz + 0.5).distance_to(c) > r:
					continue
				for k: Vector2i in corners:
					var px := qx + k.x
					var pz := qz + k.y
					st.set_color(_debug_zone_color(Vector2(px, pz).distance_to(c), ring_lo, r))
					st.add_vertex(heightmap_corner + Vector3(px, heights[pz * width + px] + DEBUG_OVERLAY_LIFT, pz))
		# 2. Boundary walls: inner (end of the 1:1 copy) and outer (end of any influence).
		_debug_add_wall(st, heights, width, length, heightmap_corner, c, ring_lo, DEBUG_WALL_HEIGHT, Color(DEBUG_COL_INNER, 0.6))
		_debug_add_wall(st, heights, width, length, heightmap_corner, c, r, DEBUG_WALL_HEIGHT, Color(DEBUG_COL_FEATHER, 0.6))
	# 3. Copied cliff meshes: footprint ring at the model's half-size.
	var mesh_k := 0
	var mesh_lines: Array[String] = []
	for e in maps.cliff_dressing_plan:
		if not e.has("landmark"):
			continue
		var p := Vector2(float(e.px), float(e.pz))
		_debug_add_wall(st, heights, width, length, heightmap_corner, p, _entry_half_size(e), 0.8, Color(DEBUG_COL_MESH, 0.5))
		var foot := heightmap_corner + Vector3(p.x, float(e.height), p.y)
		_debug_pole(root, foot, DEBUG_COL_MESH, "LM mesh #%d\n%s\n(dx %.1f, dz %.1f)" % [mesh_k, e.def_name, p.x - c.x, p.y - c.y])
		mesh_lines.append("#%d %s dx %.1f dz %.1f world (%.0f, %.1f, %.0f)" % [mesh_k, e.def_name, p.x - c.x, p.y - c.y, foot.x, foot.y, foot.z])
		mesh_k += 1
	if circle_mode or mesh_k > 0:
		var tint := MeshInstance3D.new()
		tint.name = "Tint"
		tint.mesh = st.commit()
		tint.material_override = mat
		tint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(tint)
	# 4. Copied cliff features.
	var feat_j := 0
	for f in maps.cliff_features:
		if not f.has("landmark"):
			continue
		var fc: Vector2 = f.center
		var fh := _debug_h(heights, width, length, fc.x, fc.y)
		_debug_pole(root, heightmap_corner + Vector3(fc.x, fh, fc.y), DEBUG_COL_FEATURE, "LM feature #%d\n%s step %.1f" % [feat_j, str(f.get("kind", f.get("type", "?"))), float(f.get("step_height", 0.0))])
		feat_j += 1
	var cw := heightmap_corner + Vector3(c.x, _debug_h(heights, width, length, c.x, c.y), c.y)
	print("TERRAIN_GEN_DEBUG: LANDMARK overlay -- centre world (%.0f, %.1f, %.0f), inner r %.0f, outer r %.0f; %d mesh(es), %d feature(s)" % [cw.x, cw.y, cw.z, ring_lo, r, mesh_k, feat_j])
	for line in mesh_lines:
		print("TERRAIN_GEN_DEBUG:   LM mesh " + line)
	# 5. Beacon tool (B place / X remove nearest / N save) for picking the copy shape in-game.
	# load() at runtime rather than preload, to avoid a class_name preload cycle.
	var tool: Node3D = load("res://scripts/debug/landmark_beacon_tool.gd").new()
	tool.name = "LandmarkBeaconTool"
	tool.setup(heightmap_corner, heights, c, poly, capture_half())
	root.add_child(tool)

static func _debug_zone_color(dist: float, ring_lo: float, r: float) -> Color:
	if dist <= ring_lo:
		return DEBUG_COL_INNER
	var w := 1.0 - smoothstep(ring_lo, r, dist) # same weight stamp() uses
	return Color(DEBUG_COL_FEATHER, 0.1 + DEBUG_COL_FEATHER.a * w)

static func _debug_h(heights: PackedFloat32Array, width: int, length: int, x: float, z: float) -> float:
	var px := clampi(int(round(x)), 0, width - 1)
	var pz := clampi(int(round(z)), 0, length - 1)
	return heights[pz * width + px]

## Vertical ribbon following the ground around a circle, fading out toward the top.
static func _debug_add_wall(st: SurfaceTool, heights: PackedFloat32Array, width: int, length: int, corner: Vector3, centre: Vector2, radius: float, tall: float, col: Color) -> void:
	var segs := maxi(24, int(radius * 4.0))
	var top_col := Color(col, 0.05)
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var p0 := centre + Vector2(cos(a0), sin(a0)) * radius
		var p1 := centre + Vector2(cos(a1), sin(a1)) * radius
		if p0.x < 0.0 or p0.y < 0.0 or p0.x > width - 1 or p0.y > length - 1:
			continue
		var b0 := corner + Vector3(p0.x, _debug_h(heights, width, length, p0.x, p0.y), p0.y)
		var b1 := corner + Vector3(p1.x, _debug_h(heights, width, length, p1.x, p1.y), p1.y)
		var t0 := b0 + Vector3(0.0, tall, 0.0)
		var t1 := b1 + Vector3(0.0, tall, 0.0)
		st.set_color(col); st.add_vertex(b0)
		st.set_color(col); st.add_vertex(b1)
		st.set_color(top_col); st.add_vertex(t1)
		st.set_color(col); st.add_vertex(b0)
		st.set_color(top_col); st.add_vertex(t1)
		st.set_color(top_col); st.add_vertex(t0)

## Thin coloured pole with a billboard label on top (label visible through terrain).
static func _debug_pole(root: Node3D, foot: Vector3, col: Color, text: String) -> void:
	var pole := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.25, DEBUG_POLE_HEIGHT, 0.25)
	pole.mesh = box
	var pm := StandardMaterial3D.new()
	pm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pm.albedo_color = col
	pole.material_override = pm
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pole.position = foot + Vector3(0.0, DEBUG_POLE_HEIGHT * 0.5, 0.0)
	root.add_child(pole)
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.font_size = 64
	label.pixel_size = 0.02
	label.outline_size = 14
	label.modulate = Color(col, 1.0)
	label.position = foot + Vector3(0.0, DEBUG_POLE_HEIGHT + 1.5, 0.0)
	root.add_child(label)

## Solves the 3x3 normal equations of a plane fit from the sums in s (see stamp()).
static func _solve3(s: Array) -> Vector3:
	if s[0] < 3.0:
		return Vector3.ZERO
	var m := Basis(Vector3(s[0], s[1], s[2]), Vector3(s[1], s[3], s[4]), Vector3(s[2], s[4], s[5]))
	if absf(m.determinant()) < 1e-6:
		return Vector3(s[6] / s[0], 0.0, 0.0)
	return m.inverse() * Vector3(s[6], s[7], s[8])

# ---------------------------------------------------------------------------------------------
# Capture + debug (called at runtime on the REFERENCE seed via WorldGenerator)
# ---------------------------------------------------------------------------------------------

## Lists cliff-dressing entries / outcrops / cliff features near `center` (pixels).
static func debug_list(maps: Dictionary, center: Vector2, reach: float) -> String:
	var lines: Array[String] = []
	var plan: Array = maps.cliff_dressing_plan
	for i in plan.size():
		var e: Dictionary = plan[i]
		var p := Vector2(float(e.px), float(e.pz))
		var dist := p.distance_to(center)
		if dist <= reach:
			lines.append("mesh @%d %s px(%.1f, %.1f) dist %.1f half %.1f face %.2f scale %.2f foot %.2f%s" % [i, e.def_name, p.x, p.y, dist, _entry_half_size(e), float(e.face_angle), float(e.scale_jitter), float(e.height), " knot" if e.has("knot") else ""])
	for o in maps.outcrop_plan:
		var p := Vector2(float(o.px), float(o.pz))
		if p.distance_to(center) <= reach:
			lines.append("outcrop px(%.1f, %.1f) dist %.1f radius %.1f" % [p.x, p.y, p.distance_to(center), float(o.radius)])
	for f in maps.cliff_features:
		var fc: Vector2 = f.center
		if fc.distance_to(center) <= reach + float(f.get("half_len", 0.0)):
			lines.append("feature %s centre px(%.1f, %.1f) dist %.1f half_len %.1f step %.1f" % [str(f.get("kind", f.get("type", "?"))), fc.x, fc.y, fc.distance_to(center), float(f.get("half_len", 0.0)), float(f.get("step_height", 0.0))])
	return "\n".join(lines)

## Captures the disk (CENTER_PX, RADIUS) from `maps` into DATA_PATH. Meshes = entries whose centre
## is inside the disk (the report lists any that STRADDLE the edge -- pick CENTER/RADIUS so none do).
static func capture(maps: Dictionary, source_seed: int) -> String:
	var heights: PackedFloat32Array = maps.heights
	var width := TerrainConfig.AREA_WIDTH
	var length := TerrainConfig.AREA_LENGTH
	var c := CENTER_PX
	var r := RADIUS
	var half := int(ceil(r))
	var n := half * 2 + 1
	var patch: Array = []
	patch.resize(n * n)
	for lz in n:
		for lx in n:
			var px := int(c.x) + lx - half
			var pz := int(c.y) + lz - half
			if px < 0 or pz < 0 or px >= width or pz >= length:
				patch[lz * n + lx] = null
			else:
				patch[lz * n + lx] = snappedf(heights[pz * width + px], 0.0001)
	var meshes: Array = []
	var straddle: Array[String] = []
	for e in maps.cliff_dressing_plan:
		var p := Vector2(float(e.px), float(e.pz))
		var dist := p.distance_to(c)
		var hs := _entry_half_size(e)
		if dist < r:
			if dist + hs > r - FEATHER:
				straddle.append("%s at dist %.1f (+%.1f) reaches the feather ring" % [e.def_name, dist, hs])
			var m: Dictionary = {}
			for k in e:
				if k in ["px", "pz", "knot", "knot_row", "landmark"]:
					continue
				m[k] = e[k]
			m["dx"] = p.x - c.x
			m["dz"] = p.y - c.y
			meshes.append(m)
		elif dist - hs < r:
			straddle.append("%s at dist %.1f (-%.1f) OUTSIDE but reaches in -- not captured" % [e.def_name, dist, hs])
	# Cliff features (escarpment steps etc.) whose centre is inside the disk: boulders, scree, rock
	# ground paint and moss shade are placed along features, so the knot's rockfall comes with them.
	var features: Array = []
	for f in maps.cliff_features:
		var fc: Vector2 = f.center
		if fc.distance_to(c) < r - FEATHER:
			var fd: Dictionary = _encode(f)
			fd["center"] = _encode(fc - c)
			features.append(fd)
	var data := {"name": "verticality_knot_01", "source_seed": source_seed, "center": [c.x, c.y], "radius": r, "size": n, "heights": patch, "meshes": meshes, "features": features}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DATA_PATH.get_base_dir()))
	var fa := FileAccess.open(DATA_PATH, FileAccess.WRITE)
	if fa == null:
		return "LANDMARK capture FAILED: can't write %s (err %d)" % [DATA_PATH, FileAccess.get_open_error()]
	fa.store_string(JSON.stringify(data))
	fa.close()
	_cache = {}
	return "LANDMARK captured %s: %dx%d heights, %d mesh(es), %d cliff feature(s), seed %d%s" % [DATA_PATH, n, n, meshes.size(), features.size(), source_seed, ("\n  edge warnings: " + "; ".join(straddle)) if not straddle.is_empty() else ""]

## JSON can't hold Vector2/Vector3 -- tagged arrays instead ({"v2": [x, y]}), recursively.
static func _encode(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2:
			return {"v2": [v.x, v.y]}
		TYPE_VECTOR3:
			return {"v3": [v.x, v.y, v.z]}
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[k] = _encode(v[k])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for x in v:
				arr.append(_encode(x))
			return arr
	return v

static func _decode(v: Variant) -> Variant:
	if typeof(v) == TYPE_DICTIONARY:
		if v.has("v2") and v.size() == 1:
			return Vector2(float(v.v2[0]), float(v.v2[1]))
		if v.has("v3") and v.size() == 1:
			return Vector3(float(v.v3[0]), float(v.v3[1]), float(v.v3[2]))
		var out := {}
		for k in v:
			out[k] = _decode(v[k])
		return out
	if typeof(v) == TYPE_ARRAY:
		var arr: Array = []
		for x in v:
			arr.append(_decode(x))
		return arr
	return v
