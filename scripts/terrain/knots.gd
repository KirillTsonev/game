## Verticality knots (2026-09-28): deliberate points of interest where several cliff levels are
## packed into one spot. Modelled on an accidental formation Kirill liked on seed 4176228882
## (left wall, around world (-220, 170)): a shelf jutting out of the valley wall higher than the
## ground behind it, a dip between it and the mountain, and a lower ledge in front.
##
## Round 3 (Kirill: "a lot of the meshes' edges stick out, I assume we just stick the meshes into
## the hill we have, can we instead drive the knots naturally with the meshes and their own
## terrain generation (slopes to the sides/behind) instead? like the unique random one we found"):
## rounds 1-2 shaped the ground as noise-warped ellipse tiers and then pressed straight cliff
## meshes into the curved edges, so mesh ends poked out. The reference formation was built the
## other way round -- meshes FIRST, terrain from them -- by the regular cliff-dressing passes:
##   CliffDressing.flatten_terrain_for_cliff_dressing  levels each mesh's footprint to its foot
##   CliffDressing.raise_terrain_behind_cliff_dressing plateau behind each mesh at its REAL top
##       profile, bridged between side-by-side neighbours, faded back to natural ground behind
##       and to the sides (slope-limited)
## So a knot is now a small ARRANGEMENT OF STRAIGHT MESH ROWS, and its terrain is produced by
## those same two passes, one row at a time (each row reads the ground the earlier rows left, so
## a row placed on another row's plateau stacks on it):
##   WALL:  a low "bench" row facing the valley, then a big "shelf" row further back FACING THE
##          MOUNTAIN, its foot set a couple of metres below the ground there -- flatten carves that
##          into a dip, raise builds the shelf toward the valley, higher than the ground behind it
##          (exactly how @10 + @8/@9 formed the reference).
##   FLOOR: a low back row and a front row facing opposite ways (a mesa with sloped sides), then an
##          upper row on the front half -> stacked double cliff in front, the rise from the back
##          shelf to the top is a natural walkable slope.
##
## Pipeline position (2026-09-29, moved -- see "Knots-first pipeline" below): right AFTER cliff
## features + post-feature erosion, BEFORE cliff dressing, outcrops, the landmark stamp and road
## routing (TerrainHeightmap.build_heightmap). At that point only the landmark circle, other knots
## and the map ends are off-limits; dressing / outcrops then skip knot circles and the knot ground
## is restored after them. Heights outside the knot circles are never touched by build_knots
## (self-checked: "outside" count in the log must be 0). Every row plateau is verified walkable from outside (flood
## fill, KNOT_WALK_STEP) with a carved fallback ramp if not. The meshes are appended to the regular
## dressing plan, so instancing, collision, keep-outs and ground painting pick them up unchanged;
## the road avoids knots via cliff_obstacle_mask.
##
## Side effect to know about: raise_terrain_behind_cliff_dressing resets CliffDressing's static
## _raise_debug_* buffers on every call, so with RAISE_DEBUG_SHOW_SURFACE on, the overlay would
## only show the last knot row's raise, not the main dressing pass.
##
## Static-only module, same conventions as the other scripts/terrain modules.
class_name TerrainKnots
extends RefCounted

enum KnotType { WALL_LEFT, WALL_RIGHT, FLOOR }
const KNOT_TYPE_NAMES := ["wall_left", "wall_right", "floor"]

## Which knots a map gets. 2026-09-29 v1 (Kirill: "2 center, 2 right, and 1 left, so 1 of each per
## 256 of map length") split the map into fixed 256 m segments; v2 (Kirill: "how to do it without
## hardcoding them like X per Y m ... it's not guaranteed that the map length will be evenly
## divisible by 256") uses a SPACING instead: each type gets count = max(1, round(length /
## KNOT_SPACING)) slots spread evenly over the map's actual length (slot i at (i + 0.5) * length /
## count, jittered by KNOT_SLOT_JITTER x that slot spacing), so any length works (512 m -> 2 each,
## 640 m -> 3 each 213 m apart, 700 m -> 3 each 233 m apart). The fixed landmark (landmarks.gd) IS a
## left-wall knot, so the WALL_LEFT slot nearest to it is dropped. Current 512 m map: 2 floor +
## 2 right + 1 left (+ the landmark) -- same as v1.
const KNOT_SPACING := 256.0 ## ~metres of map length per knot of each type
## Also the PLACEMENT order: all walls first, floors last -- wall knots only fit a narrow band along
## their wall, floor knots can shift across the valley; placing a floor knot first let it sit
## against the right wall and push that area's right knot out (seen 2026-09-29).
const KNOT_TYPES := [KnotType.WALL_RIGHT, KnotType.WALL_LEFT, KnotType.FLOOR]
const KNOT_SLOT_JITTER := 0.2 ## +/- this fraction of the slot spacing (0.2 x 256 = +/-51 m on the current map)
const KNOT_END_CLEARANCE := 60.0 ## no knot circle within this many pixels of spawn (south) / exit (north)
const KNOT_CANDIDATES := 48 ## placement candidates per knot; best-scoring valid one wins
const KNOT_TEST_STRIDE := 3 ## pixel stride of the circle-vs-occupancy test (speed)

## Footprint circles (pixels = metres), centred on each template's centre_u. Sized to contain
## every row's flatten zone + raise plateau/fade/side slopes (raise can reach ~35 m).
const KNOT_WALL_RADIUS := 40.0
const KNOT_FLOOR_RADIUS := 42.0

## Occupancy: pixels cliff dressing / outcrop fitting moved by more than this are "taken".
const KNOT_OCCUPIED_DIFF := 0.25
const KNOT_OCCUPIED_MARGIN := 4.0 ## keep this gap from anything taken (and between knots)

## Rows.
const KNOT_ROW_GAP := 1.5 ## metres between meshes in a row -- far under CLIFF_DRESSING_RAISE_JOIN_THRESHOLD, so their plateaus bridge into one
const KNOT_ROW_YAW_JITTER := 0.2 ## radians a whole row may turn off the knot's axis
const KNOT_MESH_YAW_JITTER := 0.08 ## per-mesh extra yaw so a row isn't perfectly planar
const CLIFF_SMALL := "namaqualand_cliff_01"
const CLIFF_BIG := "namaqualand_cliff_02"

## Walkability check: a 1-pixel (1 m) step may climb at most this much (tan 40 deg -- margin
## under CharacterBody3D's default 45-degree floor_max_angle).
## Round 3c (Kirill: "can't reach upper layer" though the check said ALL reachable): 0.84
## (40 deg) passed routes that stop the player in-game once collision-triangle bumps are
## added, and the fill also walked straight through cliff meshes (their footprint is flattened,
## so the heightmap looks walkable where the rock's collision actually sits). Now 35 deg, and
## mesh footprints are blocked (KNOT_MESH_BLOCK_PAD).
const KNOT_WALK_STEP := 0.70
const KNOT_MESH_BLOCK_PAD := 1.5 ## metres around each knot mesh's footprint the flood fill / ramps treat as solid rock
const KNOT_RAMP_PAIR_SLOPE := 0.5 ## steepest fallback ramp bed we'll carve (26.6 deg) -- leaves margin under KNOT_WALK_STEP for noise + the bed's own smoothing
const KNOT_RAMP_TOP_SEARCH := 16 ## pixels around a level's centre searched for flat spots a ramp may end on
## Round 3d (Kirill: "the newly created inlet ramp caused an angular terrain"): the old fixed-width
## blend (6 m, flat 2.1 m core) turned deep cuts through a bulge into steep planar walls with hard
## creases. Now the bed is flat across KNOT_RAMP_BED_HALF, and beside it the ground is only clamped
## into a cone of KNOT_RAMP_SIDE_SLOPE around the bed (cut or fill) -- a deep cut simply gets a
## longer gentle side slope -- then the carved area is box-smoothed to round every crease.
const KNOT_RAMP_BED_HALF := 2.5 ## metres either side of the centre line that are exactly the ramp bed
const KNOT_RAMP_SIDE_SLOPE := 0.55 ## max rise per metre of the cut/fill banks beside the bed (~29 deg)
const KNOT_RAMP_SIDE_REACH := 16.0 ## how far from the centre line the banks may extend (outer 4 m fade back to natural ground)
const KNOT_RAMP_SMOOTH_PASSES := 3 ## 3x3 box-smoothing passes over the carved area
const KNOT_RAMP_ROCK_CLEAR := 3.5 ## metres beyond the bed edge that must be free of knot rock (on top of KNOT_MESH_BLOCK_PAD)
const KNOT_RAMP_ROCK_FADE := 4 ## pixels: ramp reshaping fades to nothing over this distance approaching a rock
const KNOT_LEVEL_PROBE := 9.0 ## a row's plateau is checked this far behind the row's centre line

## Entry point, called from TerrainHeightmap.build_heightmap. Mutates `heights` (inside knot
## circles only) and `obstacle_mask`. Returns {"knots": Array[Dictionary], "mesh_plan":
## Array[Dictionary]} -- mesh_plan entries use the exact cliff-dressing plan format (plus "knot"
## and "knot_row") so the caller can append them to cliff_dressing_plan.
static func build_knots(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, pre_dressing_heights: PackedFloat32Array, cliff_features: Array[Dictionary], cliff_plan: Array[Dictionary], outcrop_plan: Array[Dictionary], obstacle_mask: PackedByteArray, top_profiles: Dictionary) -> Dictionary:
	var t_start := Time.get_ticks_msec()
	var prof := {} # TEMP 2026-09-29 knot profiling (Kirill: "look into ramps and optimization") -- remove after
	var tt := Time.get_ticks_usec()
	var occupied := _build_occupancy(heights, pre_dressing_heights, width, length, cliff_plan, outcrop_plan)
	tt = _prof(prof, "occupancy", tt)
	var pre_knot := heights.duplicate()
	var footprint := PackedByteArray()
	footprint.resize(width * length)

	# Plan (see KNOT_SPACING): per type, max(1, round(length / KNOT_SPACING)) evenly spread slots;
	# the landmark takes the WALL_LEFT slot nearest to it. Type-major, so every wall slot is placed
	# before any floor knot. Deterministic per map size + landmark.
	var plan: Array[Dictionary] = []
	var count := maxi(1, int(round(float(length) / KNOT_SPACING)))
	var spacing := float(length) / float(count)
	for t in KNOT_TYPES:
		var slots: Array[float] = []
		for i in count:
			slots.append((float(i) + 0.5) * spacing)
		if t == KnotType.WALL_LEFT and TerrainLandmarks.is_active():
			var nearest := 0
			for i in slots.size():
				if absf(slots[i] - TerrainLandmarks.CENTER_PX.y) < absf(slots[nearest] - TerrainLandmarks.CENTER_PX.y):
					nearest = i
			slots.remove_at(nearest) # the fixed landmark is this slot's left-wall knot
		for pz in slots:
			plan.append({"type": t, "pz": pz, "jitter": KNOT_SLOT_JITTER * spacing, "slot_half": 0.5 * spacing})

	var knots: Array[Dictionary] = []
	var mesh_plan: Array[Dictionary] = []
	for p in plan:
		var type: int = p.type
		var slot_pz: float = p.pz
		tt = Time.get_ticks_usec()
		var knot := _place_knot(type, slot_pz, float(p.jitter), width, length, rng, occupied, cliff_features)
		if knot.is_empty():
			# 2026-09-29: widen to the whole slot (+/- half the slot spacing) before giving up on it -- a
			# straight whole-map retry let one slot's knot take another slot's spot (both right knots
			# ended up in the same half).
			print("TERRAIN_GEN: KNOT %s -- no free spot near pz %.0f, retrying across its slot" % [KNOT_TYPE_NAMES[type], slot_pz])
			knot = _place_knot(type, slot_pz, float(p.slot_half), width, length, rng, occupied, cliff_features)
		if knot.is_empty():
			print("TERRAIN_GEN: KNOT %s -- no free spot in its slot (pz %.0f), retrying along the whole map" % [KNOT_TYPE_NAMES[type], slot_pz])
			knot = _place_knot(type, slot_pz, float(p.jitter), width, length, rng, occupied, cliff_features, true)
		if knot.is_empty():
			print("TERRAIN_GEN: KNOT %s skipped -- no free spot anywhere (never forced onto existing formations)" % KNOT_TYPE_NAMES[type])
			continue
		tt = _prof(prof, "place", tt)
		var knot_index := knots.size()
		knot["index"] = knot_index
		var before := heights.duplicate()
		var entries := _build_rows(knot, heights, width, length, rng, top_profiles, knot_index)
		tt = _prof(prof, "rows", tt)
		_clip_to_circle(knot, heights, before, width, length)
		_mark_knot(knot, heights, before, width, length, footprint, occupied, obstacle_mask, entries)
		tt = _prof(prof, "clip+mark", tt)
		var mesh_block := _mesh_block_mask(entries, width, length)
		_collect_levels(knot, heights, width, length, mesh_block) # 2026-09-29: needs the rock mask (skips rock / covered tops)
		tt = _prof(prof, "levels+mesh_block", tt)
		_ensure_reachable(knot, heights, width, length, footprint, obstacle_mask, mesh_block)
		tt = _prof(prof, "reach+ramps", tt)
		mesh_plan.append_array(entries)
		knot["mesh_count"] = entries.size()
		knots.append(knot)
		_print_knot(knot)

	# Self-check: nothing outside the knot circles may have changed.
	tt = Time.get_ticks_usec()
	var outside := 0
	for pz in length:
		for px in width:
			var i := pz * width + px
			if heights[i] == pre_knot[i]:
				continue
			var inside := false
			for k in knots:
				if Vector2(px, pz).distance_to(Vector2(float(k.cx), float(k.cz))) <= float(k.reach) + 1.0:
					inside = true
					break
			if not inside:
				outside += 1
	tt = _prof(prof, "self-check", tt)
	var prof_parts: Array[String] = [] # TEMP profiling
	for k in prof:
		prof_parts.append("%s %.0f ms" % [k, float(prof[k]) / 1000.0])
	print("TERRAIN_GEN: KNOT_PROFILE " + ", ".join(prof_parts))
	# TEMP 2026-09-29: the editor Output panel stopped receiving game prints mid-session, so the
	# knot summary + ramp diagnostics also go to a file (overwritten every run).
	var diag := PackedStringArray()
	diag.append("KNOT_PROFILE " + ", ".join(prof_parts) + " -- total %.2fs" % ((Time.get_ticks_msec() - t_start) / 1000.0))
	for k in knots:
		diag.append("KNOT #%d %s at px (%.0f, %.0f): levels %s -- unreached %s -- ramps %s -- drops %s -- covered %s" % [int(k.index), KNOT_TYPE_NAMES[int(k.type)], float(k.cx), float(k.cz),
			", ".join((k.levels as Array).map(func(l): return "%s %.1f" % [l.name, float(l.h)])), str(k.unreached), str(k.ramps), str(k.get("drops", [])), str(k.get("covered", []))])
		for line in k.get("ramp_why", []):
			diag.append("    RAMP_DIAG " + String(line))
	var fa := FileAccess.open("res://godot_notes/knot_diag.txt", FileAccess.WRITE)
	if fa:
		fa.store_string("\n".join(diag))
		fa.close()
	print("TERRAIN_GEN: knots -- %d/%d placed, %d cliff mesh(es), %d changed pixel(s) OUTSIDE knot circles (must be 0) (%.2fs)" % [knots.size(), plan.size(), mesh_plan.size(), outside, (Time.get_ticks_msec() - t_start) / 1000.0])
	return {"knots": knots, "mesh_plan": mesh_plan}

## TEMP 2026-09-29 knot profiling helper: adds (now - t0) usec to prof[key], returns now.
static func _prof(prof: Dictionary, key: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	prof[key] = int(prof.get(key, 0)) + (now - t0)
	return now

# ---------------------------------------------------------------------------------------------
# Occupancy
# ---------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------
# Knots-first pipeline (2026-09-29, Kirill: "the random knots find space during generation very
# rarely, could we place them earlier instead of last?"). Knots used to run LAST among the
# terrain shapers and only in untouched ground, but cliff dressing lines almost every cliff feature
# and its raise-behind plateaus reach ~35 m, so a free 40 m circle was rare. Now build_knots runs
# right after the post-feature erosion (TerrainHeightmap.build_heightmap), when only the landmark
# circle and the map ends are off-limits, and the later layers make room for the knots instead:
#   filter_cliff_plan   planned cliff meshes reaching into a knot circle (+ margin) are dropped
#   filter_outcrops     same for outcrops
#   restore_knot_ground after dressing + outcrops shaped the terrain, each knot circle is put back
#                       to the knot's own ground (feathered at the rim), so a nearby mesh's raise-
#                       behind plateau can't spill in and break the verified reachability/ramps.
# Knot meshes still join cliff_dressing_plan only AFTER the main flatten/raise (knots shape their
# own ground; running them through the main passes again would double-apply).
# ---------------------------------------------------------------------------------------------
const KNOT_CLEAR_MARGIN := 8.0 ## metres beyond a knot circle a planned cliff mesh's body must stay clear of
const KNOT_PROTECT_FEATHER := 6.0 ## rim band over which restored knot ground blends into its surroundings

static func _knot_near(knots: Array, p: Vector2, extra: float) -> bool:
	for k in knots:
		if p.distance_to(Vector2(float(k.cx), float(k.cz))) < float(k.reach) + extra:
			return true
	return false

## Drops planned cliff-dressing meshes whose body reaches into a knot circle (+ KNOT_CLEAR_MARGIN).
static func filter_cliff_plan(plan: Array[Dictionary], knots: Array) -> int:
	if knots.is_empty():
		return 0
	var sizes: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		sizes[def.name] = def.real_size
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var e: Dictionary = plan[i]
		var half: float = float(sizes.get(e.def_name, 10.0)) * 0.5 * float(e.get("scale_jitter", 1.0))
		if _knot_near(knots, Vector2(float(e.px), float(e.pz)), half + KNOT_CLEAR_MARGIN):
			plan.remove_at(i)
			removed += 1
	return removed

## Drops planned outcrops reaching into a knot circle.
static func filter_outcrops(plan: Array, knots: Array) -> int:
	if knots.is_empty():
		return 0
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var o: Dictionary = plan[i]
		if _knot_near(knots, Vector2(float(o.px), float(o.pz)), float(o.radius) + 2.0):
			plan.remove_at(i)
			removed += 1
	return removed

## Puts each knot circle back to `snapshot` (heights right after build_knots): exact inside
## reach - KNOT_PROTECT_FEATHER, blended to the current terrain at the rim. Returns pixels restored.
static func restore_knot_ground(knots: Array, heights: PackedFloat32Array, snapshot: PackedFloat32Array, width: int, length: int) -> int:
	var restored := 0
	for k in knots:
		var cx: float = float(k.cx)
		var cz: float = float(k.cz)
		var r: float = float(k.reach)
		var x0 := clampi(int(floor(cx - r)), 0, width - 1)
		var x1 := clampi(int(ceil(cx + r)), 0, width - 1)
		var z0 := clampi(int(floor(cz - r)), 0, length - 1)
		var z1 := clampi(int(ceil(cz + r)), 0, length - 1)
		for pz in range(z0, z1 + 1):
			for px in range(x0, x1 + 1):
				var d := Vector2(px, pz).distance_to(Vector2(cx, cz))
				if d > r:
					continue
				var i := pz * width + px
				if heights[i] == snapshot[i]:
					continue
				var w := 1.0 - smoothstep(r - KNOT_PROTECT_FEATHER, r, d)
				heights[i] = lerpf(heights[i], snapshot[i], w)
				restored += 1
	return restored

## 1 = already taken by cliff dressing (flatten/raise), outcrop fitting, a cliff mesh or an
## outcrop, dilated by KNOT_OCCUPIED_MARGIN. Generic cliff features are deliberately NOT here
## (they're scored instead, see _feature_overlap).
static func _build_occupancy(heights: PackedFloat32Array, pre: PackedFloat32Array, width: int, length: int, cliff_plan: Array[Dictionary], outcrop_plan: Array[Dictionary]) -> PackedByteArray:
	var occ := PackedByteArray()
	occ.resize(width * length)
	for i in heights.size():
		if absf(heights[i] - pre[i]) > KNOT_OCCUPIED_DIFF:
			occ[i] = 1
	var sizes: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		sizes[def.name] = def.real_size
	for e in cliff_plan:
		var r: float = float(sizes.get(e.def_name, 10.0)) * 0.5 * float(e.scale_jitter) + 2.0
		_fill_circle(occ, width, length, float(e.px), float(e.pz), r)
	for o in outcrop_plan:
		_fill_circle(occ, width, length, float(o.px), float(o.pz), float(o.radius) + 2.0)
	# 2026-09-29: the fixed landmark's whole disk (landmarks.gd) is taken.
	if TerrainLandmarks.is_active():
		_fill_circle(occ, width, length, TerrainLandmarks.CENTER_PX.x, TerrainLandmarks.CENTER_PX.y, TerrainLandmarks.RADIUS)
	return _dilate(occ, width, length, int(KNOT_OCCUPIED_MARGIN))

static func _fill_circle(grid: PackedByteArray, width: int, length: int, cx: float, cz: float, r: float) -> void:
	var x0 := clampi(int(floor(cx - r)), 0, width - 1)
	var x1 := clampi(int(ceil(cx + r)), 0, width - 1)
	var z0 := clampi(int(floor(cz - r)), 0, length - 1)
	var z1 := clampi(int(ceil(cz + r)), 0, length - 1)
	var r2 := r * r
	for pz in range(z0, z1 + 1):
		for px in range(x0, x1 + 1):
			var dx := px - cx
			var dz := pz - cz
			if dx * dx + dz * dz <= r2:
				grid[pz * width + px] = 1

## Square dilation by r pixels, separable sliding-window count (O(1) per pixel per pass).
static func _dilate(src: PackedByteArray, width: int, length: int, r: int) -> PackedByteArray:
	var tmp := PackedByteArray()
	tmp.resize(src.size())
	for pz in length:
		var base := pz * width
		var count := 0
		for dx in range(-r, r + 1):
			if dx >= 0 and dx < width:
				count += src[base + dx]
		tmp[base] = 1 if count > 0 else 0
		for px in range(1, width):
			var entering := px + r
			var leaving := px - 1 - r
			if entering < width:
				count += src[base + entering]
			if leaving >= 0:
				count -= src[base + leaving]
			tmp[base + px] = 1 if count > 0 else 0
	var out := PackedByteArray()
	out.resize(src.size())
	var col := PackedInt32Array()
	col.resize(width)
	for dz in range(-r, r + 1):
		if dz >= 0 and dz < length:
			for px in width:
				col[px] += tmp[dz * width + px]
	for px in width:
		out[px] = 1 if col[px] > 0 else 0
	for pz in range(1, length):
		var entering_z := pz + r
		var leaving_z := pz - 1 - r
		for px in width:
			if entering_z < length:
				col[px] += tmp[entering_z * width + px]
			if leaving_z >= 0:
				col[px] -= tmp[leaving_z * width + px]
			out[pz * width + px] = 1 if col[px] > 0 else 0
	return out

# ---------------------------------------------------------------------------------------------
# Templates + frame
# ---------------------------------------------------------------------------------------------

## Rows in the knot's own frame, in BUILD ORDER. u = the knot's main axis (wall knots: from the
## wall toward the valley; floor knot: along the valley), v = sideways. facing = +1 faces +u,
## -1 faces -u. models = meshes laid side by side along the row. foot_drop = metres the row's
## foot is set BELOW the ground in front of it (flatten carves that into a dip).
static func _make_template(type: int, rng: RandomNumberGenerator) -> Dictionary:
	var s := 1.0 if rng.randf() < 0.5 else -1.0
	var rows: Array[Dictionary] = []
	var centre_u := 0.0
	var radius := 0.0
	if type == KnotType.FLOOR:
		# Back row first (low cliff facing -u), then the front row facing +u -- their plateaus
		# meet into one mesa with sloped sides -- then the upper row on the front half.
		rows.append(_row(rng, "back", -26.0, s * rng.randf_range(-3.0, 3.0), -1.0, [CLIFF_BIG], 1.2, 1.3, 0.0))
		var front_models: Array = [CLIFF_BIG, CLIFF_SMALL] if rng.randf() < 0.5 else [CLIFF_SMALL, CLIFF_BIG]
		rows.append(_row(rng, "front", 16.0, s * rng.randf_range(-2.0, 2.0), 1.0, front_models, 1.2, 1.3, 0.0))
		# u=0, not 5 (round 3b): at 5 the upper row's own flatten zone (up to 10 m in front of it)
		# reached back over the front row's rim and cut its plateau 1-3 m below the rock top
		# (Kirill's screenshot, transect 13.6 -> 12.5 m right behind @22). Now its foot sample
		# (CLIFF_DRESSING_FOOT_SAMPLE_OFFSET = 8 m ahead) lands on the front row's flat plateau.
		rows.append(_row(rng, "upper", 0.0, s * rng.randf_range(-2.0, 2.0), 1.0, [CLIFF_BIG], 1.25, 1.35, 0.0))
		centre_u = -5.0
		radius = KNOT_FLOOR_RADIUS
	else:
		# Bench first (low, facing the valley), then the shelf row facing the mountain with its
		# foot dropped into a dip -- its raise builds the shelf out over the slope toward the bench.
		var bench_models: Array = [CLIFF_SMALL, CLIFF_SMALL] if rng.randf() < 0.5 else [CLIFF_BIG]
		rows.append(_row(rng, "bench", 22.0, s * rng.randf_range(-3.0, 3.0), 1.0, bench_models, 1.0, 1.2, 0.0))
		rows.append(_row(rng, "shelf", -12.0, s * rng.randf_range(-2.0, 2.0), -1.0, [CLIFF_BIG, CLIFF_SMALL], 1.15, 1.3, rng.randf_range(2.0, 3.0)))
		centre_u = 4.0
		radius = KNOT_WALL_RADIUS
	return {"type": type, "side": s, "rows": rows, "centre_u": centre_u, "reach": radius}

static func _row(rng: RandomNumberGenerator, row_name: String, u: float, v: float, facing: float, models: Array, s_min: float, s_max: float, foot_drop: float) -> Dictionary:
	return {"name": row_name, "u": u, "v": v, "facing": facing, "models": models, "s_min": s_min, "s_max": s_max, "foot_drop": foot_drop, "yaw": rng.randf_range(-KNOT_ROW_YAW_JITTER, KNOT_ROW_YAW_JITTER)}

static func _set_frame(knot: Dictionary, ax: float, az: float, theta: float) -> void:
	knot["ax"] = ax
	knot["az"] = az
	knot["theta"] = theta
	knot["ux"] = cos(theta)
	knot["uz"] = sin(theta)
	knot["vx"] = -sin(theta)
	knot["vz"] = cos(theta)
	var c := _local_to_px(knot, float(knot.centre_u), 0.0)
	knot["cx"] = c.x
	knot["cz"] = c.y

static func _local_to_px(knot: Dictionary, u: float, v: float) -> Vector2:
	return Vector2(float(knot.ax) + float(knot.ux) * u + float(knot.vx) * v, float(knot.az) + float(knot.uz) * u + float(knot.vz) * v)

static func _px_to_local(knot: Dictionary, p: Vector2) -> Vector2:
	var d := p - Vector2(float(knot.ax), float(knot.az))
	return Vector2(d.x * float(knot.ux) + d.y * float(knot.uz), d.x * float(knot.vx) + d.y * float(knot.vz))

# ---------------------------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------------------------

## full_range: retry mode when the slot's neighbourhood had no free spot -- candidates anywhere
## along the map (still free space only; placed knots are already marked occupied), score still
## prefers spots near the slot.
static func _place_knot(type: int, slot_pz: float, jitter: float, width: int, length: int, rng: RandomNumberGenerator, occupied: PackedByteArray, cliff_features: Array[Dictionary], full_range: bool = false) -> Dictionary:
	var floor_half := TerrainConfig.VALLEY_FLOOR_WIDTH_FRACTION * 0.5
	var floor_lo := (0.5 - floor_half) * width
	var floor_hi := (0.5 + floor_half) * width
	var best: Dictionary = {}
	var best_score := INF
	for c in (KNOT_CANDIDATES * 2 if full_range else KNOT_CANDIDATES):
		var knot := _make_template(type, rng)
		var r: float = knot.reach
		# jitter = +/- metres around the slot (2026-09-29: per segment, was 10% of the whole map length)
		var az := rng.randf_range(0.0, float(length - 1)) if full_range else slot_pz + rng.randf_range(-1.0, 1.0) * jitter
		var ax := 0.0
		var theta := 0.0
		match type:
			KnotType.WALL_LEFT:
				# Anchor ~2/3 of the way from the map edge to the floor: the shelf lands mid-wall
				# (the reference formation's shelf sat at px ~34), the bench reaches the floor.
				theta = rng.randf_range(-0.2, 0.2)
				ax = floor_lo * 0.66 + rng.randf_range(-3.0, 3.0)
			KnotType.WALL_RIGHT:
				theta = PI + rng.randf_range(-0.2, 0.2)
				ax = floor_hi + (width - floor_hi) * 0.34 + rng.randf_range(-3.0, 3.0)
			_:
				# Axis runs along the valley; hug one side so the rest of the floor stays open.
				theta = (PI * 0.5 if rng.randf() < 0.5 else -PI * 0.5) + rng.randf_range(-0.25, 0.25)
				var hug_left := rng.randf() < 0.5
				ax = (floor_lo + r * 0.75 if hug_left else floor_hi - r * 0.75) + rng.randf_range(-4.0, 4.0)
		_set_frame(knot, ax, az, theta)
		var cz: float = knot.cz
		if cz - r < KNOT_END_CLEARANCE or cz + r > float(length - 1) - KNOT_END_CLEARANCE:
			continue
		if _circle_hits(float(knot.cx), cz, r, occupied, width, length):
			continue
		var score := _feature_overlap(knot, cliff_features) + 0.02 * absf(az - slot_pz)
		if score < best_score:
			best_score = score
			best = knot
	if not best.is_empty():
		best["feature_overlap"] = best_score
	return best

## True if any pixel of the circle (sampled at KNOT_TEST_STRIDE) is off-map or already taken.
static func _circle_hits(cx: float, cz: float, r: float, occupied: PackedByteArray, width: int, length: int) -> bool:
	var r2 := r * r
	for pz in range(int(floor(cz - r)), int(ceil(cz + r)) + 1, KNOT_TEST_STRIDE):
		for px in range(int(floor(cx - r)), int(ceil(cx + r)) + 1, KNOT_TEST_STRIDE):
			var dx := px - cx
			var dz := pz - cz
			if dx * dx + dz * dz > r2:
				continue
			if px < 0 or pz < 0 or px >= width or pz >= length:
				return true
			if occupied[pz * width + px] == 1:
				return true
	return false

static func _feature_overlap(knot: Dictionary, cliff_features: Array[Dictionary]) -> float:
	var c := Vector2(float(knot.cx), float(knot.cz))
	var r: float = float(knot.reach) * 0.6
	var total := 0.0
	for f in cliff_features:
		var fc: Vector2 = f.center
		total += maxf(0.0, r + float(f.reach) - c.distance_to(fc))
	return total

# ---------------------------------------------------------------------------------------------
# Rows -> meshes -> terrain
# ---------------------------------------------------------------------------------------------

static func _sample(heights: PackedFloat32Array, width: int, length: int, p: Vector2) -> float:
	return TerrainUtil.sample_height_bilinear(heights, width, length, clampf(p.x, 0.0, float(width - 1)), clampf(p.y, 0.0, float(length - 1)))

## Builds every row in order: lays its meshes side by side along the row, seats each on the ground
## in front of it (minus foot_drop), then runs the regular flatten + raise passes for just that
## row, so the NEXT row reads the ground this one left (that's how rows stack).
static func _build_rows(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, top_profiles: Dictionary, knot_index: int) -> Array[Dictionary]:
	var defs: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		defs[def.name] = def
	var axis_u := Vector2(float(knot.ux), float(knot.uz))
	var axis_v := Vector2(float(knot.vx), float(knot.vz))
	var plan: Array[Dictionary] = []
	# Round 3b lock: 0..1 per pixel -- how strongly already-built rows protect this ground from
	# later rows' flatten/raise (see _protect_entries).
	var protect := PackedFloat32Array()
	protect.resize(width * length)
	for row in knot.rows:
		var yaw: float = row.yaw
		var face := (axis_u * float(row.facing)).rotated(yaw)
		var along := axis_v.rotated(yaw)
		var models: Array = row.models
		var scales: Array[float] = []
		var total := KNOT_ROW_GAP * float(models.size() - 1)
		for m in models:
			var sc := rng.randf_range(float(row.s_min), float(row.s_max))
			scales.append(sc)
			total += float(defs[m].real_size) * sc
		var origin := _local_to_px(knot, float(row.u), float(row.v))
		var t := -total * 0.5
		var entries: Array[Dictionary] = []
		for i in models.size():
			var def: Dictionary = defs[models[i]]
			var sc: float = scales[i]
			var w: float = float(def.real_size) * sc
			var p := origin + along * (t + w * 0.5)
			var foot := _sample(heights, width, length, p + face * CliffDressing.CLIFF_DRESSING_FOOT_SAMPLE_OFFSET) - float(row.foot_drop)
			var f := face.rotated(rng.randf_range(-KNOT_MESH_YAW_JITTER, KNOT_MESH_YAW_JITTER))
			entries.append({
				"def_name": def.name,
				"px": clampf(p.x, 0.0, float(width - 1)),
				"pz": clampf(p.y, 0.0, float(length - 1)),
				"face_angle": atan2(f.x, f.y),
				"scale_jitter": sc,
				"face_dir_x": f.x,
				"face_dir_z": f.y,
				"height": foot,
				"knot": knot_index,
				"knot_row": row.name,
			})
			t += w + KNOT_ROW_GAP
		var prev := heights.duplicate()
		CliffDressing.flatten_terrain_for_cliff_dressing(entries, heights, width, length)
		CliffDressing.raise_terrain_behind_cliff_dressing(entries, heights, width, length, top_profiles, rng.randi())
		# Earlier rows' surroundings win over this row's flatten/raise: blend the old ground back
		# by their protection weight (scan covers this row's whole flatten + raise reach).
		var scan := total * 0.5 + 50.0
		for pz in range(clampi(int(floor(origin.y - scan)), 0, length - 1), clampi(int(ceil(origin.y + scan)), 0, length - 1) + 1):
			for px in range(clampi(int(floor(origin.x - scan)), 0, width - 1), clampi(int(ceil(origin.x + scan)), 0, width - 1) + 1):
				var i := pz * width + px
				if protect[i] > 0.0:
					heights[i] = lerpf(heights[i], prev[i], protect[i])
		_protect_entries(entries, protect, width, length, defs)
		row["origin"] = origin
		row["face"] = face
		plan.append_array(entries)
	return plan

## Round 3b (Kirill's screenshot: rock slab standing proud of the plateau behind it): a LATER
## row's flatten (which levels up to 10 m around its own footprint to its own foot) and raise
## (plateau + fade behind it) run over ground earlier rows already fitted to THEIR meshes, and
## can cut an earlier rim below its rock top or bury it. So once a row is built, the ground right
## around each of its meshes is locked: weight 1 inside the core box (footprint, KNOT_LOCK_BEHIND
## behind the rim, KNOT_LOCK_FRONT in front of the face), feathered to 0 over KNOT_LOCK_FEATHER so
## the lock boundary doesn't leave a step.
const KNOT_LOCK_BEHIND := 4.0
const KNOT_LOCK_FRONT := 1.0
const KNOT_LOCK_FEATHER := 5.0

static func _protect_entries(entries: Array[Dictionary], protect: PackedFloat32Array, width: int, length: int, defs: Dictionary) -> void:
	for e in entries:
		var def: Dictionary = defs[e.def_name]
		var sc: float = e.scale_jitter
		var half_x: float = float(def.real_size) * sc * 0.5
		var half_z: float = float(def.depth) * sc * 0.5
		var a: float = e.face_angle
		# Same local basis as CliffDressing's passes: +z = face direction (front), -z = behind.
		var axis_x := Vector2(cos(a), -sin(a))
		var axis_z := Vector2(sin(a), cos(a))
		var z_lo := -half_z - KNOT_LOCK_BEHIND
		var z_hi := half_z + KNOT_LOCK_FRONT
		var reach := Vector2(half_x, maxf(-z_lo, z_hi)).length() + KNOT_LOCK_FEATHER
		var cx: float = e.px
		var cz: float = e.pz
		for pz in range(clampi(int(floor(cz - reach)), 0, length - 1), clampi(int(ceil(cz + reach)), 0, length - 1) + 1):
			for px in range(clampi(int(floor(cx - reach)), 0, width - 1), clampi(int(ceil(cx + reach)), 0, width - 1) + 1):
				var d := Vector2(px - cx, pz - cz)
				var lx := d.dot(axis_x)
				var lz := d.dot(axis_z)
				var ox := maxf(0.0, absf(lx) - half_x)
				var oz := maxf(0.0, maxf(z_lo - lz, lz - z_hi))
				var w := 1.0 - smoothstep(0.0, KNOT_LOCK_FEATHER, Vector2(ox, oz).length())
				var i := pz * width + px
				protect[i] = maxf(protect[i], w)

## The raise pass's fade (plateau + fade + lateral slopes, warped by noise) can occasionally reach
## a few metres past the knot circle -- the only area checked free. Hard guarantee: knot changes
## fade out over the last KNOT_CLIP_BAND inside the circle and are discarded beyond it, so no
## neighbouring terrain is touched and there's no seam at the edge.
const KNOT_CLIP_BAND := 8.0
const KNOT_CLIP_SCAN := 45.0 ## how far past the circle to look for stray changes (> any raise reach)

static func _clip_to_circle(knot: Dictionary, heights: PackedFloat32Array, before: PackedFloat32Array, width: int, length: int) -> void:
	var cx: float = knot.cx
	var cz: float = knot.cz
	var r: float = knot.reach
	var scan := r + KNOT_CLIP_SCAN
	for pz in range(clampi(int(floor(cz - scan)), 0, length - 1), clampi(int(ceil(cz + scan)), 0, length - 1) + 1):
		for px in range(clampi(int(floor(cx - scan)), 0, width - 1), clampi(int(ceil(cx + scan)), 0, width - 1) + 1):
			var i := pz * width + px
			if heights[i] == before[i]:
				continue
			var d := Vector2(px, pz).distance_to(Vector2(cx, cz))
			if d <= r - KNOT_CLIP_BAND:
				continue
			var keep := 1.0 - smoothstep(r - KNOT_CLIP_BAND, r, d)
			heights[i] = lerpf(before[i], heights[i], keep)

## Footprint (changed pixels), occupancy for later knots (whole circle + margin) and the road
## obstacle mask (changed pixels + each mesh's own obstacle rectangle).
static func _mark_knot(knot: Dictionary, heights: PackedFloat32Array, before: PackedFloat32Array, width: int, length: int, footprint: PackedByteArray, occupied: PackedByteArray, obstacle_mask: PackedByteArray, entries: Array[Dictionary]) -> void:
	var cx: float = knot.cx
	var cz: float = knot.cz
	var r: float = knot.reach
	for pz in range(clampi(int(floor(cz - r)), 0, length - 1), clampi(int(ceil(cz + r)), 0, length - 1) + 1):
		for px in range(clampi(int(floor(cx - r)), 0, width - 1), clampi(int(ceil(cx + r)), 0, width - 1) + 1):
			var i := pz * width + px
			if absf(heights[i] - before[i]) > KNOT_OCCUPIED_DIFF:
				footprint[i] = 1
				obstacle_mask[i] = 1
	_fill_circle(occupied, width, length, cx, cz, r + KNOT_OCCUPIED_MARGIN)
	var mesh_mask := CliffDressing.build_cliff_dressing_obstacle_mask(entries, width, length)
	for i in mesh_mask.size():
		if mesh_mask[i] == 1:
			obstacle_mask[i] = 1

# ---------------------------------------------------------------------------------------------
# Reachability
# ---------------------------------------------------------------------------------------------

## One "level" per row: its plateau, KNOT_LEVEL_PROBE behind the row's centre line (after every
## row is built, so a buried lower plateau reads its real final height).
## 2026-09-29: the probe skips rock (mesh_block), and a row's top only counts as a level if the
## standable area walkably connected to its probe point (_level_top) is at least
## KNOT_LEVEL_MIN_AREA px. On floor knots the upper row stands right behind the front row, so the
## "front top" probe used to land inside the upper row's rock pad -- a spot no flood or ramp can ever
## reach -- and every floor knot reported "FAILED front top". Such covered tops are now listed in
## knot["covered"] (logged) instead of being counted as unreachable levels.
const KNOT_LEVEL_MIN_AREA := 16
static func _collect_levels(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int, mesh_block: PackedByteArray) -> void:
	var levels: Array[Dictionary] = []
	var covered: Array[String] = []
	for row in knot.rows:
		var origin: Vector2 = row.origin
		var face: Vector2 = row.face
		# Round 3c: the FLATTEST pixel in a window behind the row, not one fixed point -- the
		# fixed point 9 m back could land on a later row's slope, which then never passes the
		# walkability check however it's ramped.
		var along := Vector2(-face.y, face.x)
		var p := Vector2(-1, -1)
		var best_g := INF
		for db in range(5, 15):
			for dl in range(-8, 9, 2):
				var q := origin - face * float(db) + along * float(dl)
				var qx := clampi(int(round(q.x)), 0, width - 1)
				var qz := clampi(int(round(q.y)), 0, length - 1)
				if mesh_block[qz * width + qx] == 1:
					continue # rock (a later row's footprint + pad) is never a level
				var g := _grad_mag(heights, width, length, qx, qz)
				if g < best_g:
					best_g = g
					p = Vector2(qx, qz)
		if p.x < 0.0:
			covered.append(String(row.name) + " top")
			continue
		var local := _px_to_local(knot, p)
		var lvl := {"name": String(row.name) + " top", "is_level": true, "u": local.x, "v": local.y, "ru": 4.0, "rv": 4.0,
			"h": _sample(heights, width, length, p), "px": p.x, "pz": p.y}
		# Standable = flat (<= 0.35 rise/m) pixels of the connected top that don't touch rock. Counting
		# every connected pixel (slopes included) let 6 m2 slivers wedged between two rock rows count as
		# levels (seed 12345: floor front top, 6 usable px) -- unreachable by any ramp, and every retry
		# cost ~0.5 s. A level needs KNOT_LEVEL_MIN_AREA m2 of real standing room.
		var standable := 0
		for q in _level_top(knot, lvl, heights, width, length, mesh_block):
			var sx := int(q.x)
			var sz := int(q.y)
			if _grad_mag(heights, width, length, sx, sz) > 0.35:
				continue
			if mesh_block[sz * width + sx - 1] == 1 or mesh_block[sz * width + sx + 1] == 1 or mesh_block[(sz - 1) * width + sx] == 1 or mesh_block[(sz + 1) * width + sx] == 1:
				continue
			standable += 1
		if standable < KNOT_LEVEL_MIN_AREA:
			covered.append("%s (%d m2 standable)" % [String(lvl.name), standable])
			continue
		levels.append(lvl)
	knot["levels"] = levels
	knot["covered"] = covered

## 1 = solid rock for walkability purposes: each knot mesh's footprint rectangle (in its own
## rotated frame) plus KNOT_MESH_BLOCK_PAD.
static func _mesh_block_mask(entries: Array[Dictionary], width: int, length: int) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(width * length)
	var defs: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		defs[def.name] = def
	for e in entries:
		var def: Dictionary = defs[e.def_name]
		var sc: float = e.scale_jitter
		var half_x: float = float(def.real_size) * sc * 0.5 + KNOT_MESH_BLOCK_PAD
		var half_z: float = float(def.depth) * sc * 0.5 + KNOT_MESH_BLOCK_PAD
		var a: float = e.face_angle
		var axis_x := Vector2(cos(a), -sin(a))
		var axis_z := Vector2(sin(a), cos(a))
		var reach := Vector2(half_x, half_z).length()
		var cx: float = e.px
		var cz: float = e.pz
		for pz in range(clampi(int(floor(cz - reach)), 0, length - 1), clampi(int(ceil(cz + reach)), 0, length - 1) + 1):
			for px in range(clampi(int(floor(cx - reach)), 0, width - 1), clampi(int(ceil(cx + reach)), 0, width - 1) + 1):
				var d := Vector2(px - cx, pz - cz)
				if absf(d.dot(axis_x)) <= half_x and absf(d.dot(axis_z)) <= half_z:
					mask[pz * width + px] = 1
	return mask

## Flood fill over the knot's circle bbox from its border, 4-neighbour steps climbing at most
## KNOT_WALK_STEP, never through a knot mesh (mesh_block). Returns {visited, x0, z0, w, h}.
static func _flood(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int, mesh_block: PackedByteArray) -> Dictionary:
	var r: float = float(knot.reach) + 2.0
	var x0 := clampi(int(floor(float(knot.cx) - r)), 0, width - 1)
	var x1 := clampi(int(ceil(float(knot.cx) + r)), 0, width - 1)
	var z0 := clampi(int(floor(float(knot.cz) - r)), 0, length - 1)
	var z1 := clampi(int(ceil(float(knot.cz) + r)), 0, length - 1)
	var bw := x1 - x0 + 1
	var bh := z1 - z0 + 1
	var visited := PackedByteArray()
	visited.resize(bw * bh)
	# 2026-09-29 speed: slope per pixel computed ONCE per flood (inline central differences, same
	# result as _grad_mag) instead of per neighbour test -- the flood now runs once per ramp attempt.
	var grad := PackedFloat32Array()
	grad.resize(bw * bh)
	for lz in bh:
		var pz := z0 + lz
		var zl := maxi(pz - 1, 0)
		var zr := mini(pz + 1, length - 1)
		var dz_div := float(maxi(zr - zl, 1))
		for lx in bw:
			var px := x0 + lx
			var xl := maxi(px - 1, 0)
			var xr := mini(px + 1, width - 1)
			var gx := (heights[pz * width + xr] - heights[pz * width + xl]) / float(maxi(xr - xl, 1))
			var gz := (heights[zr * width + px] - heights[zl * width + px]) / dz_div
			grad[lz * bw + lx] = sqrt(gx * gx + gz * gz)
	var queue := PackedInt32Array()
	for lz in bh:
		for lx in bw:
			if lx == 0 or lz == 0 or lx == bw - 1 or lz == bh - 1:
				if mesh_block[(z0 + lz) * width + x0 + lx] == 1:
					continue
				visited[lz * bw + lx] = 1
				queue.append(lz * bw + lx)
	var head := 0
	var offsets := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < queue.size():
		var cur := queue[head]
		head += 1
		var cx := cur % bw
		var cz := floori(float(cur) / float(bw))
		var ch := heights[(z0 + cz) * width + x0 + cx]
		for o in offsets:
			var nx: int = cx + o.x
			var nz: int = cz + o.y
			if nx < 0 or nz < 0 or nx >= bw or nz >= bh:
				continue
			var ni := nz * bw + nx
			if visited[ni] == 1:
				continue
			if mesh_block[(z0 + nz) * width + x0 + nx] == 1:
				continue
			# Round 3c: the TRUE slope at the pixel (central-difference gradient magnitude), not just
			# the rise along this one axis -- a diagonal slope passes both per-axis checks at 0.70
			# while really being up to ~45 deg, which is what the player's floor check sees.
			if grad[ni] > KNOT_WALK_STEP:
				continue
			if absf(heights[(z0 + nz) * width + x0 + nx] - ch) > KNOT_WALK_STEP:
				continue
			visited[ni] = 1
			queue.append(ni)
	return {"visited": visited, "x0": x0, "z0": z0, "w": bw, "h": bh}

## Rise per metre of steepest ascent at a pixel (central differences, clamped at the map edge).
static func _grad_mag(heights: PackedFloat32Array, width: int, length: int, px: int, pz: int) -> float:
	var xl := maxi(px - 1, 0)
	var xr := mini(px + 1, width - 1)
	var zl := maxi(pz - 1, 0)
	var zr := mini(pz + 1, length - 1)
	var gx := (heights[pz * width + xr] - heights[pz * width + xl]) / float(maxi(xr - xl, 1))
	var gz := (heights[zr * width + px] - heights[zl * width + px]) / float(maxi(zr - zl, 1))
	return sqrt(gx * gx + gz * gz)

## Names of levels reached in `before` but not in `after` (a carve that cut them off).
static func _lost_levels(knot: Dictionary, before: Dictionary, after: Dictionary) -> Array[String]:
	var lost: Array[String] = []
	for l in knot.levels:
		if _level_reached(knot, l, before) and not _level_reached(knot, l, after):
			lost.append(String(l.name))
	return lost

static func _level_reached(knot: Dictionary, b: Dictionary, flood: Dictionary) -> bool:
	var c := _local_to_px(knot, float(b.u), float(b.v))
	var bw: int = flood.w
	var bh: int = flood.h
	var visited: PackedByteArray = flood.visited
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var lx := int(round(c.x)) + dx - int(flood.x0)
			var lz := int(round(c.y)) + dz - int(flood.z0)
			if lx >= 0 and lz >= 0 and lx < bw and lz < bh and visited[lz * bw + lx] == 1:
				return true
	return false

## Round 4 (2026-09-29, Kirill: "look into ramps and optimization"). Fallback ramps used to be ONE
## unverified attempt per unreached level, aimed at ANY flat spot within KNOT_RAMP_TOP_SEARCH of the
## level's centre -- sometimes a patch the rest of the level can't be walked to from (ramp carved,
## level still FAILED) -- and faded to nothing within KNOT_RAMP_ROCK_FADE of a rock, so on a shelf
## edged by rock the ramp's top end could fade out and leave a step. Now:
##   - ramp tops only on the level's TOP REGION (_level_top: walkably connected to the level centre,
##     same step rule as the flood), more than KNOT_RAMP_TOP_ROCK_MIN from any rock; the part of a
##     ramp lying ON that top only needs its centre line off rock (_segment_clear_top), so narrow
##     ledges between two rock rows can be reached at all;
##   - every carve is re-flooded; if the level still isn't reached it is UNDONE exactly and the next
##     best ramp (excluding that top) is tried, up to KNOT_RAMP_ATTEMPTS per level;
##   - levels are handled lowest first, over KNOT_RAMP_ROUNDS rounds, so an upper level can start
##     its ramp from a lower knot level once that one is reachable.
## Speed: the per-pixel 9x9 rock scan in the carve (~120k steps per ramp) is a lookup into a
## rock-distance grid built once per knot (_rock_distance).
## KNOT_RAMP_ROUNDS: levels go lowest first and ramps only climb from LOWER reached ground, so a
## level that failed can't gain a new ramp base from anything reached later in the same round (all
## higher). A second round only repeated the failed attempts (~half the ramp time on a failing knot,
## measured 2026-09-29) -- kept as a knob, set to 1.
const KNOT_RAMP_ROUNDS := 1
const KNOT_RAMP_ATTEMPTS := 3
const KNOT_RAMP_TOP_TOL := 1.5 ## level-top region: pixels within this many metres of the level height
const KNOT_RAMP_TRIED_EXCLUDE := 4.0 ## after a failed ramp, tops within this many px of its end aren't retried
const KNOT_RAMP_TOP_ROCK_MIN := 1.0 ## a ramp top must be more than this many metres from any knot rock (was 1.5: 2-px ledges had no candidates)
const KNOT_RAMP_SMALL_TOP := 80 ## top regions smaller than this (px) use every pixel as a ramp-top candidate, not a 2 px grid

## Checks every row plateau; carves verified fallback ramps (Round 4 note above) and records one-way
## drops. Results go into knot["ramps"/"drops"/"unreached"/"ramp_paths"].
## 2026-09-29 DROPS (Kirill: "can't we just drop to the front ledge from higher up?"): a lower level
## counts as reachable if a reachable HIGHER level sits right above it -- a point on each top within
## KNOT_DROP_MAX_RUN of each other, the higher one KNOT_DROP_MIN..KNOT_DROP_MAX above, and nothing on
## the way rising above the jumping-off height (the player walks off the edge / over the rock top and
## falls onto the lower top). Floor knots' front ledge sits under the upper row's cliff face, so the
## upper top drops onto it; ramps to such ledges (wedged between two rock rows) mostly failed and
## cost ~0.5 s per failed try. Order: (1) ramps for levels with NO possible drop source, (2) drops,
## (3) ramps for levels that had a source which turned out unreachable, (4) drops again.
const KNOT_DROP_MIN := 1.0 ## m -- smaller height differences are a step, not a drop
const KNOT_DROP_MAX := 12.0 ## m -- no fall damage today; keep drops to a sane height anyway
const KNOT_DROP_MAX_RUN := 12.0 ## m -- horizontal distance between the two tops (edge + rock depth)
static func _ensure_reachable(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int, footprint: PackedByteArray, obstacle_mask: PackedByteArray, mesh_block: PackedByteArray) -> void:
	var rd := _rock_distance(knot, mesh_block, width, length)
	var flood := _flood(knot, heights, width, length, mesh_block)
	var ramps: Array[String] = []
	var drops: Array[String] = []
	var dropped := {} # level name -> true when reached by a drop
	var tops := {}
	for l in knot.levels:
		tops[l.name] = _level_top(knot, l, heights, width, length, mesh_block)
	var order: Array = (knot.levels as Array).duplicate()
	order.sort_custom(func(a, b): return float(a.h) < float(b.h))
	# (1) ramps only where no higher level could drop onto this one
	var deferred: Array = []
	for b in order:
		if _level_reached(knot, b, flood):
			continue
		if _has_drop_source(b, order, tops, heights, width):
			deferred.append(b)
			continue
		flood = _ramp_level(knot, b, heights, width, length, footprint, obstacle_mask, mesh_block, rd, flood, ramps)
	# (2) drops, (3) ramps for deferred levels still unreached, (4) drops again
	_apply_drops(knot, order, flood, tops, dropped, drops, heights, width)
	for b in deferred:
		if _level_reached(knot, b, flood) or dropped.has(b.name):
			continue
		flood = _ramp_level(knot, b, heights, width, length, footprint, obstacle_mask, mesh_block, rd, flood, ramps)
	_apply_drops(knot, order, flood, tops, dropped, drops, heights, width)
	var unreached: Array[String] = []
	for b in knot.levels:
		if not _level_reached(knot, b, flood) and not dropped.has(b.name):
			unreached.append(String(b.name))
	knot["ramps"] = ramps
	knot["drops"] = drops
	knot["unreached"] = unreached

## Up to KNOT_RAMP_ATTEMPTS verified ramps to level b (carve, re-flood, keep only if b is reached and
## no previously reached level was cut off, else undo and exclude that top). Returns the flood.
static func _ramp_level(knot: Dictionary, b: Dictionary, heights: PackedFloat32Array, width: int, length: int, footprint: PackedByteArray, obstacle_mask: PackedByteArray, mesh_block: PackedByteArray, rd: Dictionary, flood: Dictionary, ramps: Array[String]) -> Dictionary:
	var tried: Array[Vector2] = []
	for attempt in KNOT_RAMP_ATTEMPTS:
		var r := _carve_ramp(knot, b, heights, width, length, flood, mesh_block, rd, tried)
		if r.is_empty():
			break # no candidate ramp left for this level
		var new_flood := _flood(knot, heights, width, length, mesh_block)
		var changed: PackedInt32Array = r.changed
		# 2026-09-29: a ramp must not cut off a level that was already reachable (seed 12345: the
		# shelf-top ramp was carved through the bench top and left the bench unreachable).
		var broke := _lost_levels(knot, flood, new_flood)
		if _level_reached(knot, b, new_flood) and broke.is_empty():
			for idx in changed:
				footprint[idx] = 1
				obstacle_mask[idx] = 1
			var ramp_list: Array = knot.get("ramp_paths", [])
			ramp_list.append({"level": b.name, "from": r.from, "to": r.to, "from_h": r.from_h, "to_h": r.to_h})
			knot["ramp_paths"] = ramp_list
			ramps.append("%s %.0f deg%s" % [b.name, float(r.slope), "" if attempt == 0 else " (try %d)" % (attempt + 1)])
			return new_flood
		# Didn't connect: undo exactly (flood is still valid for the restored heights), exclude that top.
		_ramp_why(knot, b, ("carved %.0f deg ramp but level still not reached -- undone" % float(r.slope)) if broke.is_empty() else ("carved %.0f deg ramp but it cut off %s -- undone" % [float(r.slope), ", ".join(broke)])) # TEMP ramp diag
		var old: PackedFloat32Array = r.old
		for i in changed.size():
			heights[changed[i]] = old[i]
		tried.append(r.to)
	return flood

## True if some level in `order` could drop onto b (geometry only, reachability not checked).
static func _has_drop_source(b: Dictionary, order: Array, tops: Dictionary, heights: PackedFloat32Array, width: int) -> bool:
	for hi in order:
		var dh := float(hi.h) - float(b.h)
		if dh >= KNOT_DROP_MIN and dh <= KNOT_DROP_MAX and _drop_link(tops[hi.name], tops[b.name], float(hi.h), heights, width):
			return true
	return false

## Marks levels reachable by a drop from a reachable higher level (repeats so drops can chain).
static func _apply_drops(knot: Dictionary, order: Array, flood: Dictionary, tops: Dictionary, dropped: Dictionary, drops: Array[String], heights: PackedFloat32Array, width: int) -> void:
	var changed := true
	while changed:
		changed = false
		for lo in order:
			if _level_reached(knot, lo, flood) or dropped.has(lo.name):
				continue
			for hi in order:
				var dh := float(hi.h) - float(lo.h)
				if dh < KNOT_DROP_MIN or dh > KNOT_DROP_MAX:
					continue
				if not (_level_reached(knot, hi, flood) or dropped.has(hi.name)):
					continue
				if _drop_link(tops[hi.name], tops[lo.name], float(hi.h), heights, width):
					dropped[lo.name] = true
					drops.append("%s <- %s (%.1f m drop)" % [lo.name, hi.name, dh])
					changed = true
					break

## A point on the high top and one on the low top within KNOT_DROP_MAX_RUN, with the ground between
## them never rising above the jumping-off height (+0.5 m). Tops are sampled every 3rd pixel.
static func _drop_link(hi_pts: PackedVector2Array, lo_pts: PackedVector2Array, hi_h: float, heights: PackedFloat32Array, width: int) -> bool:
	if hi_pts.is_empty() or lo_pts.is_empty():
		return false
	for i in range(0, hi_pts.size(), 3):
		var a := hi_pts[i]
		for j in range(0, lo_pts.size(), 3):
			var b := lo_pts[j]
			var run := a.distance_to(b)
			if run > KNOT_DROP_MAX_RUN:
				continue
			var n := maxi(1, int(ceil(run)))
			var clear := true
			for k in range(1, n):
				var p := a.lerp(b, float(k) / float(n))
				if heights[int(round(p.y)) * width + int(round(p.x))] > hi_h + 0.5:
					clear = false
					break
			if clear:
				return true
	return false

## Distance (metres, chamfer approximation) from each pixel of the knot's area to the nearest knot
## rock (mesh_block), built once per knot. Returns {d, x0, z0, w, h}; see _rd_at.
static func _rock_distance(knot: Dictionary, mesh_block: PackedByteArray, width: int, length: int) -> Dictionary:
	var r: float = float(knot.reach) + float(KNOT_RAMP_ROCK_FADE) + 2.0
	var x0 := clampi(int(floor(float(knot.cx) - r)), 0, width - 1)
	var x1 := clampi(int(ceil(float(knot.cx) + r)), 0, width - 1)
	var z0 := clampi(int(floor(float(knot.cz) - r)), 0, length - 1)
	var z1 := clampi(int(ceil(float(knot.cz) + r)), 0, length - 1)
	var bw := x1 - x0 + 1
	var bh := z1 - z0 + 1
	var d := PackedFloat32Array()
	d.resize(bw * bh)
	d.fill(99.0)
	for lz in bh:
		for lx in bw:
			if mesh_block[(z0 + lz) * width + x0 + lx] == 1:
				d[lz * bw + lx] = 0.0
	const DIAG := 1.4142
	for lz in bh: # forward pass
		for lx in bw:
			var i := lz * bw + lx
			var v := d[i]
			if lx > 0:
				v = minf(v, d[i - 1] + 1.0)
			if lz > 0:
				v = minf(v, d[i - bw] + 1.0)
				if lx > 0:
					v = minf(v, d[i - bw - 1] + DIAG)
				if lx < bw - 1:
					v = minf(v, d[i - bw + 1] + DIAG)
			d[i] = v
	for lz in range(bh - 1, -1, -1): # backward pass
		for lx in range(bw - 1, -1, -1):
			var i := lz * bw + lx
			var v := d[i]
			if lx < bw - 1:
				v = minf(v, d[i + 1] + 1.0)
			if lz < bh - 1:
				v = minf(v, d[i + bw] + 1.0)
				if lx < bw - 1:
					v = minf(v, d[i + bw + 1] + DIAG)
				if lx > 0:
					v = minf(v, d[i + bw - 1] + DIAG)
			d[i] = v
	return {"d": d, "x0": x0, "z0": z0, "w": bw, "h": bh}

static func _rd_at(rd: Dictionary, px: int, pz: int) -> float:
	var lx := px - int(rd.x0)
	var lz := pz - int(rd.z0)
	if lx < 0 or lz < 0 or lx >= int(rd.w) or lz >= int(rd.h):
		return 99.0
	var d: PackedFloat32Array = rd.d
	return d[lz * int(rd.w) + lx]

## The level's top region: pixels within KNOT_RAMP_TOP_TOL of its height that are walkably connected
## (same step rule as _flood) to a seed within 2 px of the level centre -- the area _level_reached
## checks -- so a ramp ending anywhere in it reaches the level. Empty if no seed stands there.
static func _level_top(knot: Dictionary, b: Dictionary, heights: PackedFloat32Array, width: int, length: int, mesh_block: PackedByteArray) -> PackedVector2Array:
	var out := PackedVector2Array()
	var target: float = b.h
	var c := _local_to_px(knot, float(b.u), float(b.v))
	var ci := Vector2i(int(round(c.x)), int(round(c.y)))
	var seed := Vector2i(-1, -1)
	var best := INF
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var sx := clampi(ci.x + dx, 1, width - 2)
			var sz := clampi(ci.y + dz, 1, length - 2)
			if mesh_block[sz * width + sx] == 1:
				continue
			var e := absf(heights[sz * width + sx] - target)
			if e < best and e <= KNOT_RAMP_TOP_TOL:
				best = e
				seed = Vector2i(sx, sz)
	if seed.x < 0:
		return out
	var R := KNOT_RAMP_TOP_SEARCH + 4
	var x0 := clampi(ci.x - R, 1, width - 2)
	var z0 := clampi(ci.y - R, 1, length - 2)
	var bw := clampi(ci.x + R, 1, width - 2) - x0 + 1
	var bh := clampi(ci.y + R, 1, length - 2) - z0 + 1
	var seen := PackedByteArray()
	seen.resize(bw * bh)
	var queue := PackedInt32Array()
	var s0 := (seed.y - z0) * bw + (seed.x - x0)
	seen[s0] = 1
	queue.append(s0)
	var head := 0
	while head < queue.size():
		var cur := queue[head]
		head += 1
		var lx := cur % bw
		var lz := floori(float(cur) / float(bw))
		var px := x0 + lx
		var pz := z0 + lz
		out.append(Vector2(px, pz))
		var ch := heights[pz * width + px]
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = lx + o.x
			var nz: int = lz + o.y
			if nx < 0 or nz < 0 or nx >= bw or nz >= bh:
				continue
			var ni := nz * bw + nx
			if seen[ni] == 1:
				continue
			var gi := (z0 + nz) * width + x0 + nx
			if mesh_block[gi] == 1:
				continue
			var nh := heights[gi]
			if absf(nh - target) > KNOT_RAMP_TOP_TOL or absf(nh - ch) > KNOT_WALK_STEP:
				continue
			if _grad_mag(heights, width, length, x0 + nx, z0 + nz) > KNOT_WALK_STEP:
				continue
			seen[ni] = 1
			queue.append(ni)
	return out

## Carves the best remaining fallback ramp to level b WITHOUT committing it: returns {changed
## (PackedInt32Array of pixel indices), old (their previous heights), from, to, from_h, to_h, slope}
## so _ensure_reachable can verify it and undo it, or {} if no valid ramp exists (tops in `tried`
## excluded).
static func _carve_ramp(knot: Dictionary, b: Dictionary, heights: PackedFloat32Array, width: int, length: int, flood: Dictionary, mesh_block: PackedByteArray, rd: Dictionary, tried: Array[Vector2]) -> Dictionary:
	var bw: int = flood.w
	var bh: int = flood.h
	var x0: int = flood.x0
	var z0: int = flood.z0
	var visited: PackedByteArray = flood.visited
	# Ramp tops: on the level's connected top region, flat, well clear of rock, not tried before.
	var highs: Array[Vector2] = []
	var high_h := PackedFloat32Array()
	var top := _level_top(knot, b, heights, width, length, mesh_block)
	var top_idx := {} # pixel index -> true, for _segment_clear_top
	for q in top:
		top_idx[int(q.y) * width + int(q.x)] = true
	var fine := top.size() < KNOT_RAMP_SMALL_TOP # 2026-09-29: small ledges get every pixel as a candidate
	for q in top:
		var hx := int(q.x)
		var hz := int(q.y)
		if not fine and (hx % 2 != 0 or hz % 2 != 0):
			continue # 2 px grid on normal-size tops, same density as before
		# Not hard against a rock. (First try required > KNOT_RAMP_ROCK_FADE + 1 = 5 m -- no pixel of a
		# narrow ledge between two rock rows passes that, so those levels never got a ramp at all.)
		if _rd_at(rd, hx, hz) <= KNOT_RAMP_TOP_ROCK_MIN:
			continue
		if _grad_mag(heights, width, length, hx, hz) > 0.35:
			continue
		var near_tried := false
		for t in tried:
			if q.distance_to(t) < KNOT_RAMP_TRIED_EXCLUDE:
				near_tried = true
				break
		if near_tried:
			continue
		highs.append(q)
		high_h.append(heights[hz * width + hx])
	if highs.is_empty():
		_ramp_why(knot, b, "no top" if top.is_empty() else "no usable top px (%d top px)" % top.size()) # TEMP ramp diag
		return {}
	var min_high := INF
	for hh in high_h:
		min_high = minf(min_high, hh)
	# Shortest straight ramp from reached lower ground to any top that stays <= KNOT_RAMP_PAIR_SLOPE
	# and clears every rock (Round 3c pair search, unchanged).
	var best_len := INF
	var p0 := Vector2(-1, -1)
	var p1 := Vector2(-1, -1)
	var h0 := 0.0
	var target_h := 0.0
	var n_lows := 0 # TEMP ramp diag
	var n_steep := 0
	var n_rock := 0
	var min_slope := INF
	for lz in range(0, bh, 2):
		for lx in range(0, bw, 2):
			if visited[lz * bw + lx] == 0:
				continue
			var lh := heights[(z0 + lz) * width + x0 + lx]
			if lh >= min_high - 1.0:
				continue
			n_lows += 1
			var lp := Vector2(x0 + lx, z0 + lz)
			for k in highs.size():
				if high_h[k] - lh < 1.0:
					continue
				var hp: Vector2 = highs[k]
				var run := lp.distance_to(hp)
				if run >= best_len:
					continue
				var pair_slope := (high_h[k] - lh) / maxf(run, 1.0)
				if pair_slope > KNOT_RAMP_PAIR_SLOPE:
					n_steep += 1
					min_slope = minf(min_slope, pair_slope)
					continue
				if not _segment_clear_top(lp, hp, mesh_block, width, length, top_idx):
					n_rock += 1
					continue
				best_len = run
				p0 = lp
				p1 = hp
				h0 = lh
				target_h = high_h[k]
	if p0.x < 0.0:
		_ramp_why(knot, b, "no ramp line: %d top px, %d reached low px, %d too steep (best %.2f > %.2f), %d blocked by rock" % [highs.size(), n_lows, n_steep, min_slope, KNOT_RAMP_PAIR_SLOPE, n_rock]) # TEMP ramp diag
		return {}
	var seg := p1 - p0
	var seg_len := maxf(seg.length(), 0.001)
	var reach := KNOT_RAMP_SIDE_REACH
	var rx0 := clampi(int(floor(minf(p0.x, p1.x) - reach)), 1, width - 2)
	var rx1 := clampi(int(ceil(maxf(p0.x, p1.x) + reach)), 1, width - 2)
	var rz0 := clampi(int(floor(minf(p0.y, p1.y) - reach)), 1, length - 2)
	var rz1 := clampi(int(ceil(maxf(p0.y, p1.y) + reach)), 1, length - 2)
	var orig := heights.duplicate()
	var kc := Vector2(float(knot.cx), float(knot.cz))
	var kr: float = knot.reach
	for pz in range(rz0, rz1 + 1):
		for px in range(rx0, rx1 + 1):
			var idx := pz * width + px
			if mesh_block[idx] == 1:
				continue # never reshape the ground a rock stands on
			var q := Vector2(px, pz)
			var t := clampf((q - p0).dot(seg) / (seg_len * seg_len), 0.0, 1.0)
			var d := q.distance_to(p0 + seg * t)
			if d >= reach:
				continue
			var bed := lerpf(h0, target_h, t)
			# Bed exactly inside BED_HALF; beyond it the ground may sit at most SIDE_SLOPE per metre
			# above/below the bed (cut bank / fill embankment), otherwise stays natural.
			var slack := maxf(0.0, d - KNOT_RAMP_BED_HALF) * KNOT_RAMP_SIDE_SLOPE
			var shaped := clampf(orig[idx], bed - slack, bed + slack)
			var fade := 1.0 - smoothstep(reach - 4.0, reach, d)
			fade *= 1.0 - smoothstep(kr - KNOT_CLIP_BAND, kr, q.distance_to(kc)) # never past the knot circle
			# Taper to nothing approaching a rock, so no cut step is left against it (rock-distance grid).
			fade *= smoothstep(0.0, float(KNOT_RAMP_ROCK_FADE), _rd_at(rd, px, pz))
			var nh := lerpf(orig[idx], shaped, fade)
			if absf(nh - orig[idx]) < 0.001:
				continue
			heights[idx] = nh
	# Round every crease (bed edge, bank top/bottom, ramp ends): box-smooth the carved area plus a
	# 2 px rim. Rock footprints and the circle's outer metre stay untouched.
	var zone := PackedByteArray()
	zone.resize(width * length)
	for pz in range(rz0, rz1 + 1):
		for px in range(rx0, rx1 + 1):
			if absf(heights[pz * width + px] - orig[pz * width + px]) < 0.001:
				continue
			for dz in range(-2, 3):
				for dx in range(-2, 3):
					var zx := clampi(px + dx, 1, width - 2)
					var zz := clampi(pz + dz, 1, length - 2)
					var zi := zz * width + zx
					if mesh_block[zi] == 0 and Vector2(zx, zz).distance_to(kc) <= kr - 1.0:
						zone[zi] = 1
	var sx0 := maxi(rx0 - 2, 1)
	var sx1 := mini(rx1 + 2, width - 2)
	var sz0 := maxi(rz0 - 2, 1)
	var sz1 := mini(rz1 + 2, length - 2)
	for pass_i in KNOT_RAMP_SMOOTH_PASSES:
		var prev := heights.duplicate()
		for pz in range(sz0, sz1 + 1):
			for px in range(sx0, sx1 + 1):
				var idx := pz * width + px
				if zone[idx] == 0:
					continue
				var sum := 0.0
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						sum += prev[(pz + dz) * width + px + dx]
				heights[idx] = sum / 9.0
	# Report (don't commit) what changed -- _ensure_reachable marks footprint/obstacle on success
	# and restores `old` on failure.
	var changed := PackedInt32Array()
	var old := PackedFloat32Array()
	for pz in range(sz0, sz1 + 1):
		for px in range(sx0, sx1 + 1):
			var idx := pz * width + px
			if absf(heights[idx] - orig[idx]) > 0.001:
				changed.append(idx)
				old.append(orig[idx])
	return {"changed": changed, "old": old, "from": p0, "to": p1, "from_h": h0, "to_h": target_h, "slope": rad_to_deg(atan2(absf(target_h - h0), seg_len))}

## Like _segment_clear, but sample points lying ON the target level's top region (top_idx) only need
## their centre off rock. A ramp's last metres run along the level itself, and narrow ledges are
## edged by rock by design -- the full side clearance (BED_HALF + ROCK_CLEAR = 6 m each side) ruled
## out every ledge narrower than ~12 m (e.g. every floor knot's front ledge, wall knots' benches),
## so those levels never got a ramp. The climbing part (off the top) keeps the full clearance.
static func _segment_clear_top(a: Vector2, b: Vector2, mesh_block: PackedByteArray, width: int, length: int, top_idx: Dictionary) -> bool:
	var seg := b - a
	var n := int(ceil(seg.length() / 0.7))
	if n <= 0:
		return true
	var nrm := Vector2(-seg.y, seg.x).normalized()
	var side_a := nrm * KNOT_RAMP_BED_HALF
	var side_b := nrm * (KNOT_RAMP_BED_HALF + KNOT_RAMP_ROCK_CLEAR)
	for k in range(n + 1):
		var p := a + seg * (float(k) / float(n))
		var px := clampi(int(round(p.x)), 0, width - 1)
		var pz := clampi(int(round(p.y)), 0, length - 1)
		if mesh_block[pz * width + px] == 1:
			return false
		if top_idx.has(pz * width + px):
			continue # on the ledge itself: centre line clear is enough
		for q in [p + side_a, p - side_a, p + side_b, p - side_b]:
			var qx := clampi(int(round(q.x)), 0, width - 1)
			var qz := clampi(int(round(q.y)), 0, length - 1)
			if mesh_block[qz * width + qx] == 1:
				return false
	return true

## True if a ramp from a to b (its centre line and both sides, ~1.5 m out) crosses no rock.
static func _segment_clear(a: Vector2, b: Vector2, mesh_block: PackedByteArray, width: int, length: int) -> bool:
	var seg := b - a
	var n := int(ceil(seg.length() / 0.7))
	if n <= 0:
		return true
	# Round 3d: clear the bed AND a margin beside it (bed edge + KNOT_RAMP_ROCK_CLEAR) -- a ramp hugging
	# a rock left a cut step against it that smoothing then tilted the bed into.
	var nrm := Vector2(-seg.y, seg.x).normalized()
	var side_a := nrm * KNOT_RAMP_BED_HALF
	var side_b := nrm * (KNOT_RAMP_BED_HALF + KNOT_RAMP_ROCK_CLEAR)
	for k in range(n + 1):
		var p := a + seg * (float(k) / float(n))
		for q in [p, p + side_a, p - side_a, p + side_b, p - side_b]:
			var qx := clampi(int(round(q.x)), 0, width - 1)
			var qz := clampi(int(round(q.y)), 0, length - 1)
			if mesh_block[qz * width + qx] == 1:
				return false
	return true

# ---------------------------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------------------------

static func _print_knot(knot: Dictionary) -> void:
	var parts: Array[String] = []
	for lvl in knot.levels:
		parts.append("%s %.1f m" % [lvl.name, float(lvl.h)])
	var rows_desc: Array[String] = []
	for row in knot.rows:
		var model_names := ""
		for m in row.models:
			model_names += ("+" if model_names != "" else "") + String(m).replace("namaqualand_", "")
		rows_desc.append("%s(%s, facing %s)" % [row.name, model_names, "+u" if float(row.facing) > 0.0 else "-u"])
	var unreached: Array[String] = knot.unreached
	var ramps: Array[String] = knot.ramps
	print("TERRAIN_GEN: KNOT #%d %s at px (%.0f, %.0f) theta %.2f -- rows %s -- %s -- reachable: %s -- fallback ramps: %s -- %d cliff mesh(es) -- feature overlap %.1f" % [
		int(knot.index), KNOT_TYPE_NAMES[int(knot.type)], float(knot.cx), float(knot.cz), float(knot.theta),
		", ".join(rows_desc), ", ".join(parts),
		"ALL levels" if unreached.is_empty() else "FAILED " + ", ".join(unreached),
		"none" if ramps.is_empty() else ", ".join(ramps),
		int(knot.mesh_count), float(knot.get("feature_overlap", 0.0)),
	])
	var covered: Array = knot.get("covered", [])
	var knot_drops: Array = knot.get("drops", [])
	if not knot_drops.is_empty():
		print("TERRAIN_GEN:   KNOT #%d reached by one-way drops: %s" % [int(knot.index), ", ".join(knot_drops)])
	if not covered.is_empty():
		print("TERRAIN_GEN:   KNOT #%d not counted as levels (no standable area -- covered by the next row / rock): %s" % [int(knot.index), ", ".join(covered)])
	for line in knot.get("ramp_why", []): # TEMP ramp diag
		print("TERRAIN_GEN:   KNOT #%d RAMP_DIAG %s" % [int(knot.index), line])

## TEMP 2026-09-29 ramp diagnostics: why a fallback ramp for level b wasn't made / didn't connect.
static func _ramp_why(knot: Dictionary, b: Dictionary, why: String) -> void:
	var lines: Array = knot.get("ramp_why", [])
	lines.append("%s (%.1f m): %s" % [String(b.name), float(b.h), why])
	knot["ramp_why"] = lines
