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
class_name FireflyScatter
extends RefCounted

## -- How many and where --
const CANDIDATE_STEP := 8.0 ## m, jittered candidate grid
const SWARM_P := 0.05 ## chance per candidate at full darkness (before the spacing test)
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

static func scatter_fireflies(heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array) -> void:
	var t0 := Time.get_ticks_msec()
	swarms = []
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
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
			centres.append(Vector2(px, pz))
			swarms.append(_make_swarm(heights, width, length, import_position, rng, px, pz))

	var fireflies := 0
	var checksum := 0 # the same seed must print the same number on every run
	for s in swarms:
		fireflies += (s.homes as PackedVector3Array).size()
		checksum = hash([checksum, s.homes, s.colour])
	print("TERRAIN_GEN: fireflies -- %d swarm(s), %d firefl%s from %d candidate spots; checksum %d; %d ms" % [
		swarms.size(), fireflies, "y" if fireflies == 1 else "ies", candidates, checksum, Time.get_ticks_msec() - t0])

static func _near_deadfall(cells: Dictionary, px: float, pz: float) -> bool:
	var cx := floori(px / DEADFALL_REACH)
	var cz := floori(pz / DEADFALL_REACH)
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if cells.has(Vector2i(cx + dx, cz + dz)):
				return true
	return false

static func _make_swarm(heights: PackedFloat32Array, width: int, length: int, corner: Vector3, rng: RandomNumberGenerator, px: float, pz: float) -> Dictionary:
	var colour := _pick_colour(rng)
	var count := rng.randi_range(COUNT_MIN, COUNT_MAX)
	var homes := PackedVector3Array()
	var seeds := PackedFloat32Array()
	for i in count:
		var a := rng.randf() * TAU
		var r := SWARM_RADIUS * sqrt(rng.randf())
		var hx := clampf(px + cos(a) * r, 0.0, float(width - 1))
		var hz := clampf(pz + sin(a) * r, 0.0, float(length - 1))
		var h := TerrainUtil.sample_height_bilinear(heights, width, length, hx, hz)
		homes.append(Vector3(corner.x + hx, h + rng.randf_range(HEIGHT_MIN, HEIGHT_MAX), corner.z + hz))
		seeds.append(rng.randf())
	var ground := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
	return {"centre": Vector3(corner.x + px, ground + 0.5 * (HEIGHT_MIN + HEIGHT_MAX), corner.z + pz),
		"colour": colour, "homes": homes, "seeds": seeds}

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
