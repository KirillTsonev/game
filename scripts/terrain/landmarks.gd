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

## 1. Drop planned cliff meshes that would stand in / reach into the landmark disk.
static func filter_cliff_plan(plan: Array[Dictionary]) -> int:
	if not is_active():
		return 0
	var c := _center()
	var r := _radius()
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var e: Dictionary = plan[i]
		if Vector2(float(e.px), float(e.pz)).distance_to(c) < r + _entry_half_size(e):
			plan.remove_at(i)
			removed += 1
	return removed

## 2. Drop outcrops in / reaching into the disk.
static func filter_outcrops(plan: Array) -> int:
	if not is_active():
		return 0
	var c := _center()
	var r := _radius()
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var o: Dictionary = plan[i]
		if Vector2(float(o.px), float(o.pz)).distance_to(c) < r + float(o.radius):
			plan.remove_at(i)
			removed += 1
	return removed

## 3. Stamp heights + meshes, reserve the area. Returns stats.
static func stamp(heights: PackedFloat32Array, width: int, length: int, cliff_plan: Array[Dictionary], obstacle_mask: PackedByteArray, cliff_features: Array) -> Dictionary:
	if not is_active():
		return {}
	var d := _load()
	var c := _center()
	var r := _radius()
	var n: int = int(d.size)
	var half := n / 2
	var patch: Array = d.heights
	var ring_lo := r - FEATHER
	# Plane fit on the ring: diff = this map - captured, least squares a + b*dx + c*dz.
	var s := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0] # sums: 1, x, z, xx, xz, zz, f, xf, zf
	var ring_px := 0
	for lz in n:
		for lx in n:
			var dx := float(lx - half)
			var dz := float(lz - half)
			var dist := sqrt(dx * dx + dz * dz)
			if dist < ring_lo or dist > r:
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
			var dist := sqrt(dx * dx + dz * dz)
			if dist > r:
				continue
			var px := int(c.x) + lx - half
			var pz := int(c.y) + lz - half
			if px < 0 or pz < 0 or px >= width or pz >= length:
				continue
			var idx := pz * width + px
			var w := 1.0 - smoothstep(ring_lo, r, dist)
			var target := float(v) + pa + pb * dx + pc * dz
			var nh := lerpf(heights[idx], target, w)
			max_change = maxf(max_change, absf(nh - heights[idx]))
			if absf(nh - heights[idx]) > 0.001:
				changed += 1
			heights[idx] = nh
			if dist <= ring_lo and not obstacle_mask.is_empty():
				obstacle_mask[idx] = 1
	# Meshes.
	var added: Array[Dictionary] = []
	for m in d.meshes:
		var e: Dictionary = (m as Dictionary).duplicate(true)
		var mdx: float = float(e.dx)
		var mdz: float = float(e.dz)
		e.erase("dx")
		e.erase("dz")
		e["px"] = c.x + mdx
		e["pz"] = c.y + mdz
		e["height"] = float(e.height) + pa + pb * mdx + pc * mdz
		e["landmark"] = "verticality_knot_01"
		added.append(e)
	cliff_plan.append_array(added)
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
		if fc.distance_to(c) < r:
			cliff_features.remove_at(i)
			feat_removed += 1
	var feat_added := 0
	for fd in d.get("features", []):
		var f: Dictionary = _decode(fd)
		f["center"] = c + (f.center as Vector2)
		f["landmark"] = "verticality_knot_01"
		cliff_features.append(f)
		feat_added += 1
	var stats := {"plane": plane, "ring_px": ring_px, "changed": changed, "max_change": max_change, "meshes": added.size()}
	print("TERRAIN_GEN: LANDMARK verticality_knot_01 stamped at px (%.0f, %.0f) r %.0f -- plane offset %.2f m, tilt (%.3f, %.3f) from %d ring px; %d px changed (max %.2f m); %d cliff mesh(es); cliff features -%d +%d" % [
		c.x, c.y, r, pa, pb, pc, ring_px, changed, max_change, added.size(), feat_removed, feat_added])
	return stats

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
