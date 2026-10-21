## The valley's sections, in the order they are walked (PROTOTYPE 2026-10-21, the biome valley).
##
## The valley is a chain of sections of about 1 km, of which only the first -- the generated map --
## is built; the others are seen from it only in the distance, beyond the fog bank (FarEndView),
## and the castle stands in the last (Kirill). They are not in one straight line: each is shifted
## sideways from the one before and stands higher or lower (Kirill's diagram, 2026-10-21, read at
## one scale -- the map, 1024 m long, is 129 px of it: about 7.9 m a pixel, along, across and up).
## Everything placed out there reads its place from here: the castle (TerrainCastle.far_*) and
## the mountain rows behind it from its section; the far ranges along the sides (MountainWalls)
## and the fog bank (FarEndView) from the basin round all the sections (basin()).
##
## Positions along the valley are "along": m north of the generated map's north edge (world -Z),
## negative inside the map. Each section is level and straight; across the gap before it (the fog
## walk between two sections) the centre and the floor ease over from the section before.
class_name ValleyPath
extends RefCounted

## "gap": m between the end of the section before and this one's start; "length": m along;
## "shift": m its middle lies sideways from the map's middle (+ = +X, east: right as the valley
## is walked north); "floor": m its floor lies above the map's valley floor. The first is the
## map. TUNING -- the layout of the whole valley.
const SECTIONS: Array[Dictionary] = [
	{"gap": 0.0, "length": 1024.0, "shift": 0.0, "floor": 0.0}, # the map (green)
	{"gap": 270.0, "length": 1127.0, "shift": -365.0, "floor": -254.0}, # red
	{"gap": 167.0, "length": 1135.0, "shift": 40.0, "floor": 389.0}, # blue
	{"gap": 247.0, "length": 1231.0, "shift": 326.0, "floor": 873.0}, # cyan
	{"gap": 119.0, "length": 1056.0, "shift": 56.0, "floor": 1246.0}, # yellow
	{"gap": 103.0, "length": 1040.0, "shift": 71.0, "floor": 1627.0}, # purple: the castle's
]
## Where in the last section the castle stands, as a share of its length from its start.
const CASTLE_SHARE := 0.5

## -- The basin --
## The sections lie in one wide valley, not each in its own: the valley's walls are an envelope
## round all of them (Kirill, 2026-10-21, a second diagram: "I don't think we need to make the
## valley like the left on the schematic, but like the right" -- the fog bank and the far ranges
## followed each section's own line, which gave cut mountains at every bend and ridges across the
## cloud at every step in height). At each place its edges reach out to every section within
## BASIN_REACH m along, BASIN_MARGIN m past that section's middle, and are then rounded over
## BASIN_ROUND m; its floor is the sections' floors rounded over BASIN_FLOOR_ROUND m (a gentle
## rise, not steps). Kept as a table every BASIN_STEP m. TUNING.
const BASIN_MARGIN := 150.0
const BASIN_REACH := 1200.0
const BASIN_ROUND := 800.0
const BASIN_FLOOR_ROUND := 1000.0
const BASIN_STEP := 10.0
## How far past the last section's end the table runs.
const BASIN_BEYOND := 3000.0

static var _spans: Array[Vector2] = []

## Each section's start and end, along.
static func spans() -> Array[Vector2]:
	if _spans.is_empty():
		var start := -float(SECTIONS[0].length)
		for k in SECTIONS.size():
			if k > 0:
				start = _spans[k - 1].y + float(SECTIONS[k].gap)
			_spans.append(Vector2(start, start + float(SECTIONS[k].length)))
	return _spans

## The valley's middle (x: m sideways from the map's middle) and floor (y: m above the map's
## valley floor) at `along`. Past the last section: the last section's.
static func at(along: float) -> Vector2:
	var s := spans()
	for k in SECTIONS.size():
		if along <= s[k].y:
			var here := Vector2(float(SECTIONS[k].shift), float(SECTIONS[k].floor))
			if k == 0 or along >= s[k].x:
				return here
			var before := Vector2(float(SECTIONS[k - 1].shift), float(SECTIONS[k - 1].floor))
			return before.lerp(here, smoothstep(s[k - 1].y, s[k].x, along))
	var last: Dictionary = SECTIONS[SECTIONS.size() - 1]
	return Vector2(float(last.shift), float(last.floor))

## Where the castle stands, along.
static func castle_along() -> float:
	var s := spans()[SECTIONS.size() - 1]
	return lerpf(s.x, s.y, CASTLE_SHARE)

## The castle's section's middle and floor (as at()).
static func castle_place() -> Vector2:
	return at(castle_along())

static var _basin := PackedVector3Array()
static var _basin_from := 0.0

## The basin at `along`: x = its low-X edge, y = its high-X edge (m sideways from the map's
## middle), z = its floor (m above the map's valley floor).
static func basin(along: float) -> Vector3:
	if _basin.is_empty():
		_build_basin()
	var f := clampf((along - _basin_from) / BASIN_STEP, 0.0, float(_basin.size() - 1))
	var i := mini(int(f), _basin.size() - 2)
	return _basin[i].lerp(_basin[i + 1], f - float(i))

static func _build_basin() -> void:
	_basin_from = spans()[0].x
	var count := int((spans()[SECTIONS.size() - 1].y + BASIN_BEYOND - _basin_from) / BASIN_STEP) + 1
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	var floors := PackedFloat32Array()
	for i in count:
		var here := at(_basin_from + float(i) * BASIN_STEP)
		lo.append(here.x - BASIN_MARGIN)
		hi.append(here.x + BASIN_MARGIN)
		floors.append(here.y)
	var reach := int(BASIN_REACH / BASIN_STEP)
	var wide_lo := PackedFloat32Array()
	var wide_hi := PackedFloat32Array()
	for i in count:
		var a := INF
		var b := -INF
		for j in range(maxi(i - reach, 0), mini(i + reach, count - 1) + 1):
			a = minf(a, lo[j])
			b = maxf(b, hi[j])
		wide_lo.append(a)
		wide_hi.append(b)
	wide_lo = _rounded(wide_lo, int(BASIN_ROUND * 0.5 / BASIN_STEP))
	wide_hi = _rounded(wide_hi, int(BASIN_ROUND * 0.5 / BASIN_STEP))
	floors = _rounded(floors, int(BASIN_FLOOR_ROUND * 0.5 / BASIN_STEP))
	_basin.resize(count)
	for i in count:
		_basin[i] = Vector3(wide_lo[i], wide_hi[i], floors[i])

## `values` averaged over `radius` entries each way (the ends held).
static func _rounded(values: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())
	var last := values.size() - 1
	for i in values.size():
		var sum := 0.0
		for j in range(i - radius, i + radius + 1):
			sum += values[clampi(j, 0, last)]
		out[i] = sum / float(2 * radius + 1)
	return out
