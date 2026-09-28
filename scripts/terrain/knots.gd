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
## Pipeline position: AFTER cliff features, cliff dressing and outcrop fitting, BEFORE road routing
## (TerrainHeightmap.build_heightmap). Knots only go where none of those already changed the
## terrain (occupancy grid from the height diff since just before cliff dressing + every placed
## mesh / outcrop), inside a circle of KNOT_*_RADIUS; heights outside the circles are never touched
## (self-checked: "outside" count in the log must be 0), so existing formations -- the reference
## one included -- stay as they were. Every row plateau is verified walkable from outside (flood
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

## Which knots a map gets (Kirill 2026-09-28: "2 wall knots and 1 floor knot for current size").
const KNOTS_PER_MAP := [KnotType.WALL_LEFT, KnotType.WALL_RIGHT, KnotType.FLOOR]
## One knot per third of the map length; which type lands in which third is shuffled per seed.
const KNOT_SLOT_FRACTIONS := [0.25, 0.5, 0.75]
const KNOT_SLOT_JITTER_FRACTION := 0.1 ## +/- this fraction of the map length around the slot
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
	var occupied := _build_occupancy(heights, pre_dressing_heights, width, length, cliff_plan, outcrop_plan)
	var pre_knot := heights.duplicate()
	var footprint := PackedByteArray()
	footprint.resize(width * length)

	# Shuffle which knot type goes into which third of the map (deterministic per seed).
	var order: Array = KNOTS_PER_MAP.duplicate()
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp

	var knots: Array[Dictionary] = []
	var mesh_plan: Array[Dictionary] = []
	for slot in order.size():
		var type: int = order[slot]
		var slot_pz: float = float(KNOT_SLOT_FRACTIONS[slot]) * float(length)
		var knot := _place_knot(type, slot_pz, width, length, rng, occupied, cliff_features)
		if knot.is_empty():
			print("TERRAIN_GEN: KNOT %s -- no free spot near pz %.0f, retrying along the whole map" % [KNOT_TYPE_NAMES[type], slot_pz])
			knot = _place_knot(type, slot_pz, width, length, rng, occupied, cliff_features, true)
		if knot.is_empty():
			print("TERRAIN_GEN: KNOT %s skipped -- no free spot anywhere (never forced onto existing formations)" % KNOT_TYPE_NAMES[type])
			continue
		var knot_index := knots.size()
		knot["index"] = knot_index
		var before := heights.duplicate()
		var entries := _build_rows(knot, heights, width, length, rng, top_profiles, knot_index)
		_clip_to_circle(knot, heights, before, width, length)
		_mark_knot(knot, heights, before, width, length, footprint, occupied, obstacle_mask, entries)
		_collect_levels(knot, heights, width, length)
		var mesh_block := _mesh_block_mask(entries, width, length)
		_ensure_reachable(knot, heights, width, length, footprint, obstacle_mask, mesh_block)
		mesh_plan.append_array(entries)
		knot["mesh_count"] = entries.size()
		knots.append(knot)
		_print_knot(knot)

	# Self-check: nothing outside the knot circles may have changed.
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
	print("TERRAIN_GEN: knots -- %d/%d placed, %d cliff mesh(es), %d changed pixel(s) OUTSIDE knot circles (must be 0) (%.2fs)" % [knots.size(), order.size(), mesh_plan.size(), outside, (Time.get_ticks_msec() - t_start) / 1000.0])
	return {"knots": knots, "mesh_plan": mesh_plan}

# ---------------------------------------------------------------------------------------------
# Occupancy
# ---------------------------------------------------------------------------------------------

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
static func _place_knot(type: int, slot_pz: float, width: int, length: int, rng: RandomNumberGenerator, occupied: PackedByteArray, cliff_features: Array[Dictionary], full_range: bool = false) -> Dictionary:
	var floor_half := TerrainConfig.VALLEY_FLOOR_WIDTH_FRACTION * 0.5
	var floor_lo := (0.5 - floor_half) * width
	var floor_hi := (0.5 + floor_half) * width
	var best: Dictionary = {}
	var best_score := INF
	for c in (KNOT_CANDIDATES * 2 if full_range else KNOT_CANDIDATES):
		var knot := _make_template(type, rng)
		var r: float = knot.reach
		var az := rng.randf_range(0.0, float(length - 1)) if full_range else slot_pz + rng.randf_range(-1.0, 1.0) * KNOT_SLOT_JITTER_FRACTION * length
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
static func _collect_levels(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int) -> void:
	var levels: Array[Dictionary] = []
	for row in knot.rows:
		var origin: Vector2 = row.origin
		var face: Vector2 = row.face
		# Round 3c: the FLATTEST pixel in a window behind the row, not one fixed point -- the
		# fixed point 9 m back could land on a later row's slope, which then never passes the
		# walkability check however it's ramped.
		var along := Vector2(-face.y, face.x)
		var p := origin - face * KNOT_LEVEL_PROBE
		var best_g := INF
		for db in range(5, 15):
			for dl in range(-8, 9, 2):
				var q := origin - face * float(db) + along * float(dl)
				var qx := clampi(int(round(q.x)), 0, width - 1)
				var qz := clampi(int(round(q.y)), 0, length - 1)
				var g := _grad_mag(heights, width, length, qx, qz)
				if g < best_g:
					best_g = g
					p = Vector2(qx, qz)
		var local := _px_to_local(knot, p)
		levels.append({"name": String(row.name) + " top", "is_level": true, "u": local.x, "v": local.y, "ru": 4.0, "rv": 4.0,
			"h": _sample(heights, width, length, p), "px": p.x, "pz": p.y})
	knot["levels"] = levels

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
			if _grad_mag(heights, width, length, x0 + nx, z0 + nz) > KNOT_WALK_STEP:
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

## Checks every row plateau; carves a straight fallback ramp to any unreached one from the nearest
## reached lower ground, then re-checks. Results go into knot["ramps"/"unreached"].
static func _ensure_reachable(knot: Dictionary, heights: PackedFloat32Array, width: int, length: int, footprint: PackedByteArray, obstacle_mask: PackedByteArray, mesh_block: PackedByteArray) -> void:
	var flood := _flood(knot, heights, width, length, mesh_block)
	var ramps: Array[String] = []
	for b in knot.levels:
		if _level_reached(knot, b, flood):
			continue
		var slope := _carve_ramp(knot, b, heights, width, length, flood, footprint, obstacle_mask, mesh_block)
		if slope >= 0.0:
			ramps.append("%s %.0f deg" % [b.name, slope])
			flood = _flood(knot, heights, width, length, mesh_block)
	var unreached: Array[String] = []
	for b in knot.levels:
		if not _level_reached(knot, b, flood):
			unreached.append(String(b.name))
	knot["ramps"] = ramps
	knot["unreached"] = unreached

## Returns the ramp's slope in degrees, or -1 if no reached lower pixel was found.
static func _carve_ramp(knot: Dictionary, b: Dictionary, heights: PackedFloat32Array, width: int, length: int, flood: Dictionary, footprint: PackedByteArray, obstacle_mask: PackedByteArray, mesh_block: PackedByteArray) -> float:
	var target_h: float = b.h
	var c := _local_to_px(knot, float(b.u), float(b.v))
	var bw: int = flood.w
	var bh: int = flood.h
	var x0: int = flood.x0
	var z0: int = flood.z0
	var visited: PackedByteArray = flood.visited
	# Round 3c: search PAIRS -- any reached lower spot x any flat spot on the level's own top --
	# for the SHORTEST straight ramp that stays <= KNOT_RAMP_PAIR_SLOPE and clears every rock.
	# Aiming at one fixed level point forced ramps through the level's own cliff (or from the
	# valley floor 27 m away, cutting an 8.8 m trench through a plateau side). No valid pair =
	# report FAILED rather than carve something ugly.
	var highs: Array[Vector2] = []
	var high_h := PackedFloat32Array()
	var ci := Vector2i(int(round(c.x)), int(round(c.y)))
	for dz in range(-KNOT_RAMP_TOP_SEARCH, KNOT_RAMP_TOP_SEARCH + 1, 2):
		for dx in range(-KNOT_RAMP_TOP_SEARCH, KNOT_RAMP_TOP_SEARCH + 1, 2):
			var hx := clampi(ci.x + dx, 1, width - 2)
			var hz := clampi(ci.y + dz, 1, length - 2)
			var hh := heights[hz * width + hx]
			if absf(hh - target_h) > 0.75 or mesh_block[hz * width + hx] == 1:
				continue
			if _grad_mag(heights, width, length, hx, hz) > 0.35:
				continue
			highs.append(Vector2(hx, hz))
			high_h.append(hh)
	if highs.is_empty():
		return -1.0
	var best_len := INF
	var p0 := Vector2(-1, -1)
	var p1 := Vector2(-1, -1)
	var h0 := 0.0
	for lz in range(0, bh, 2):
		for lx in range(0, bw, 2):
			if visited[lz * bw + lx] == 0:
				continue
			var lp := Vector2(x0 + lx, z0 + lz)
			var lh := heights[(z0 + lz) * width + x0 + lx]
			if lh >= target_h - 1.0:
				continue
			for k in highs.size():
				var hp: Vector2 = highs[k]
				var run := lp.distance_to(hp)
				if run >= best_len:
					continue
				if (high_h[k] - lh) / maxf(run, 1.0) > KNOT_RAMP_PAIR_SLOPE:
					continue
				if not _segment_clear(lp, hp, mesh_block, width, length):
					continue
				best_len = run
				p0 = lp
				p1 = hp
				h0 = lh
				target_h = high_h[k]
	if p0.x < 0.0:
		return -1.0
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
			# Taper to nothing approaching a rock, so no cut step is left against it.
			var rock_d := float(KNOT_RAMP_ROCK_FADE) + 1.0
			for dz in range(-KNOT_RAMP_ROCK_FADE, KNOT_RAMP_ROCK_FADE + 1):
				for dx in range(-KNOT_RAMP_ROCK_FADE, KNOT_RAMP_ROCK_FADE + 1):
					var bx := clampi(px + dx, 0, width - 1)
					var bz := clampi(pz + dz, 0, length - 1)
					if mesh_block[bz * width + bx] == 1:
						rock_d = minf(rock_d, sqrt(float(dx * dx + dz * dz)))
			fade *= smoothstep(0.0, float(KNOT_RAMP_ROCK_FADE), rock_d)
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
	for pz in range(sz0, sz1 + 1):
		for px in range(sx0, sx1 + 1):
			var idx := pz * width + px
			if absf(heights[idx] - orig[idx]) > 0.001:
				footprint[idx] = 1
				obstacle_mask[idx] = 1
	# Remember where it is so the log can point the player at it (terrain_gen prints world coords).
	var ramp_list: Array = knot.get("ramp_paths", [])
	ramp_list.append({"level": b.name, "from": p0, "to": p1, "from_h": h0, "to_h": target_h})
	knot["ramp_paths"] = ramp_list
	return rad_to_deg(atan2(absf(target_h - h0), seg_len))

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
