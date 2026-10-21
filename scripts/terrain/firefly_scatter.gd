## Firefly swarms -- where they hover (2026-10-19, TRIAL).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## FireflyScatter.scatter_fireflies(...). Must run AFTER TreeScatter (the canopy grid) and
## DeadfallScatter (deadfall_keep_circles). Places nothing itself: it fills `swarms`, which
## FireflyField (scripts/terrain/firefly_field.gd) draws and animates.
##
## Design (Kirill: "fireflies here and there in the dark spots", rare for now, glow only, mixed
## colours): candidates on a jittered CANDIDATE_STEP grid; the chance grows with canopy cover and
## is raised near fallen logs and stumps. Never on the road, the mountain's rock or the castle
## (MountainWalls.on_mountain), and never nearer than MIN_SPACING to another swarm. Each swarm
## takes one colour from PALETTE; its fireflies vary it slightly.
## Swarms may sit by cliffs, outcrops and boulders (Kirill, 2026-10-20), but no firefly's home is
## inside one: a home in a keep-out (+ HOME_ROCK_CLEARANCE) is rolled again, up to HOME_TRIES
## times, then dropped; a swarm left with under MIN_HOMES_SHARE of its fireflies is not placed.
## That the player can climb such a rock and reach the fled swarm is FireflyField's business (it
## climbs above the player's head).
class_name FireflyScatter
extends RefCounted

## -- How many and where --
const CANDIDATE_STEP := 8.0 ## m, jittered candidate grid
const SWARM_P := 0.045 ## chance per candidate at full darkness (before the spacing test)
const CANOPY_LO := 0.35 ## canopy cover below this -> not dark enough
const CANOPY_HI := 0.8 ## cover above this -> full darkness
const LOG_BONUS := 0.5 ## added to the darkness next to a log / stump (inside DEADFALL_REACH)
const DEADFALL_REACH := 6.0 ## m
const MIN_SPACING := 40.0 ## m between swarm centres
const EDGE_MARGIN := 6.0 ## m kept off the map's border

## -- One swarm --
const COUNT_MIN := 42
const COUNT_MAX := 54
const SWARM_RADIUS := 5.0 ## m, homes are spread over a disc of this radius
const HEIGHT_MIN := 0.5 ## m above the ground
const HEIGHT_MAX := 4.0
const HOME_ROCK_CLEARANCE := 0.6 ## m kept off rock (the shader's hover_radius), on top of RockScatter.BOULDER_KEEPOUT_MARGIN
const HOME_TRIES := 6
const MIN_HOMES_SHARE := 0.5
## Swarm colours (HDR-free, the shader multiplies in the brightness): one per swarm, weighted.
## [colour, weight]
const PALETTE := [
	[Color(0.75, 1.0, 0.25), 0.45], # classic yellow-green
	[Color(1.0, 0.62, 0.18), 0.3], # warm amber
	[Color(0.45, 0.9, 1.0), 0.25], # pale cyan
	[Color(0.3, 1.0, 0.5), 0.15], # emerald green
	[Color(0.7, 0.45, 1.0), 0.1], # violet
]
const HUE_JITTER := 0.07 ## per firefly, in hue (0..1)

## This run's swarms: {centre: Vector3 (world), colour: Color, homes: PackedVector3Array (world),
## seeds: PackedFloat32Array (0..1, one per firefly)}. Read by FireflyField.
static var swarms: Array[Dictionary] = []

static func reset_run_state() -> void:
	swarms = []

static func scatter_fireflies(heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var t0 := Time.get_ticks_msec()
	swarms = []
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	keep_circles.append_array(RockScatter.rock_keep_circles)
	var keep_grid := RockScatter.build_keep_grid(UnderstoryScatter._build_keep_rects(cliff_plan, cliff_top_profiles), keep_circles, width, length)
	var homes_rerolled := 0
	var homes_dropped := 0
	var swarms_dropped := 0
	# Cells (DEADFALL_REACH m) holding a log or stump footprint: "near deadfall" = this cell or a
	# neighbour has one.
	var deadfall_cells := {}
	for c: Vector3 in DeadfallScatter.deadfall_keep_circles:
		deadfall_cells[Vector2i(floori(c.x / DEADFALL_REACH), floori(c.y / DEADFALL_REACH))] = true

	var steps_x := int((float(width) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	var steps_z := int((float(length) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	var centres := PackedVector2Array()
	var candidates := 0
	for iz in steps_z:
		for ix in steps_x:
			candidates += 1
			var px := EDGE_MARGIN + (float(ix) + rng.randf()) * CANDIDATE_STEP
			var pz := EDGE_MARGIN + (float(iz) + rng.randf()) * CANDIDATE_STEP
			var roll := rng.randf()
			var dark := smoothstep(CANOPY_LO, CANOPY_HI, UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz))
			if _near_deadfall(deadfall_cells, px, pz):
				dark += LOG_BONUS
			if roll >= SWARM_P * dark:
				continue
			if road_weight[clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)] > 0.0 \
					or MountainWalls.on_mountain(px, pz, SWARM_RADIUS):
				continue
			var crowded := false
			for c in centres:
				if c.distance_squared_to(Vector2(px, pz)) < MIN_SPACING * MIN_SPACING:
					crowded = true
					break
			if crowded:
				continue
			var swarm := _make_swarm(heights, width, length, import_position, rng, px, pz, keep_grid)
			homes_rerolled += int(swarm.rerolled)
			if swarm.homes.size() < int(ceil(MIN_HOMES_SHARE * float(swarm.count))):
				swarms_dropped += 1
				continue
			homes_dropped += int(swarm.count) - swarm.homes.size()
			swarm.erase("rerolled")
			swarm.erase("count")
			centres.append(Vector2(px, pz))
			swarms.append(swarm)

	var fireflies := 0
	var checksum := 0 # the same seed must print the same number on every run
	for s in swarms:
		fireflies += (s.homes as PackedVector3Array).size()
		checksum = hash([checksum, s.homes, s.colour])
	print("TERRAIN_GEN: fireflies -- %d swarm(s), %d firefl%s from %d candidate spots; off rock: %d home(s) rolled again, %d dropped, %d swarm(s) dropped; checksum %d; %d ms" % [
		swarms.size(), fireflies, "y" if fireflies == 1 else "ies", candidates, homes_rerolled, homes_dropped, swarms_dropped, checksum, Time.get_ticks_msec() - t0])

static func _near_deadfall(cells: Dictionary, px: float, pz: float) -> bool:
	var cx := floori(px / DEADFALL_REACH)
	var cz := floori(pz / DEADFALL_REACH)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if cells.has(Vector2i(cx + dx, cz + dz)):
				return true
	return false

## Also returns "count" (fireflies asked for) and "rerolled" (homes rolled again off rock), which
## the caller removes.
static func _make_swarm(heights: PackedFloat32Array, width: int, length: int, corner: Vector3, rng: RandomNumberGenerator, px: float, pz: float, keep_grid: Dictionary) -> Dictionary:
	var colour := _pick_colour(rng)
	var count := rng.randi_range(COUNT_MIN, COUNT_MAX)
	var homes := PackedVector3Array()
	var seeds := PackedFloat32Array()
	var rerolled := 0
	var keep_start: PackedInt32Array = keep_grid.start
	var keep_data: PackedFloat64Array = keep_grid.data
	for i in count:
		var hx := 0.0
		var hz := 0.0
		var clear := false
		for attempt in HOME_TRIES:
			var a := rng.randf() * TAU
			var r := SWARM_RADIUS * sqrt(rng.randf())
			hx = clampf(px + cos(a) * r, 0.0, float(width - 1))
			hz = clampf(pz + sin(a) * r, 0.0, float(length - 1))
			if not RockScatter.keep_grid_blocked(hx, hz, HOME_ROCK_CLEARANCE, keep_start, keep_data):
				clear = true
				break
			rerolled += 1
		if not clear:
			continue
		var h := TerrainUtil.sample_height_bilinear(heights, width, length, hx, hz)
		homes.append(Vector3(corner.x + hx, h + rng.randf_range(HEIGHT_MIN, HEIGHT_MAX), corner.z + hz))
		seeds.append(rng.randf())
	var ground := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
	return {"centre": Vector3(corner.x + px, ground + 0.5 * (HEIGHT_MIN + HEIGHT_MAX), corner.z + pz),
		"colour": colour, "homes": homes, "seeds": seeds, "count": count, "rerolled": rerolled}

static func _pick_colour(rng: RandomNumberGenerator) -> Color:
	var total := 0.0
	for row in PALETTE:
		total += float(row[1])
	var roll := rng.randf() * total
	for row in PALETTE:
		roll -= float(row[1])
		if roll <= 0.0:
			return row[0]
	return PALETTE[0][0]
