## The castle (2026-10-09): a fixed landmark at the north end of the generated map, and the strip
## of mountain terrain beyond that end.
##
## The valley's north end is part of the generated map since the same day (its first version was
## a separate fixed block of terrain with a bay and a crag; Kirill: "I don't think we need an
## actual separate chunk ... extend the rng terrain to cover that area as well and use the castle
## as a landmark that just always stays at the same place"). What is fixed is only WHERE the
## castle stands, in heightmap pixels (SITE_PX): the low-X (western) corner of the valley's end,
## at the edge of the floor, close under the mountain on two sides -- a bridge will join it to the
## western ridge. Its ground is whatever this run generated; the shaping stages keep clear of it
## (filter_plan, SITE_KEEP_RADIUS), nothing grows in it (covers, through MountainWalls.on_mountain)
## and the valley's road ends at its foot (road_end).
##
## The mountain closes the valley inside the map (MountainWalls.raise_foot, side 2). Beyond the
## map's north edge its ground carries on as LENGTH m of terrain, the "north apron" (build_maps):
## as wide as the whole Terrain3D import (both side aprons + the map), rising from the edge by the
## same ramp as the side aprons and painted the same bare rock. The mountain rows of MountainWalls
## stand on its far edge. Its rows come first in the import, so the generated map's pixel (0, 0)
## is LENGTH m in +Z from the corner Terrain3D reports.
##
## The mountain area around the castle is to become playable; until that zone is built all of
## this is a blockout (Kirill, 2026-10-09): a plain block for the castle, a beam for the bridge.
##
## Static-only: never instantiated; call as TerrainCastle.some_func(...).
class_name TerrainCastle
extends RefCounted

## -- The castle's site --
## Its centre, in heightmap pixels of the generated map (x from the low-X edge, y = pz from the
## north edge). The floor's low-X edge is at px 69.5; the mountain's foot lies up to 34 m inside
## the low-X edge and up to MountainWalls.NORTH_FOOT_MAX m inside the north edge. TUNING.
const SITE_PX := Vector2(72.0, 78.0)
## Knots, cliff meshes and outcrops keep this far from the centre, m.
const SITE_KEEP_RADIUS := 40.0
## The valley's road ends this far outside the castle's high-X / south corner, m.
const ROAD_END_GAP := 8.0
## The stand-in for the castle, m (x, height, z). The height is fixed (Kirill, 2026-10-09:
## "hardcode tower standin height at 150m", then "let's make tower 200m"; before, its top followed
## the crest of the ridge west of it and came out 107..233 m depending on the seed; 250 since
## Kirill set it himself). Its base is PLACEHOLDER_SINK m below the lowest ground under it
## (sampled every SITE_GROUND_STEP m).
const PLACEHOLDER_SIZE := Vector3(30.0, 250.0, 24.0)
const PLACEHOLDER_SINK := 1.0
const SITE_GROUND_STEP := 3
const PLACEHOLDER_NAME := "CastlePlaceholder"
## The stand-in for the bridge: a plain beam from the castle's low-X face due west (-X) into the
## village. Its deck is BRIDGE_DECK_HEIGHT m above the castle's base (Kirill, 2026-10-09: the
## drawbridge has to be at the top -- "hardcode bridge at 240m, tower is 250m"; before, the deck
## followed the ridge's height and changed with the seed).
const BRIDGE_DECK_HEIGHT := 240.0
const BRIDGE_WIDTH := 6.0
const BRIDGE_THICKNESS := 3.0
## The village at the bridge's far end (2026-10-09): a photo scan of a hilltop village, cut down
## by tools/blender/prepare_cliff_village.py, standing on a shoulder of the ridge (see
## VILLAGE_BASE_RADII). It is only ever seen from the valley floor: no collision, and the scan is
## far too rough to walk in. What it stands on went through three versions that day: a cone of
## raised terrain under a 9 m landing pad (one stretched spire); a rock pillar built as a mesh
## (a seam against the ridge, a repeating texture); the broad terrain shoulder there is now.
const VILLAGE_SCENE := "res://assets/models/village/calcata/calcata_village.glb"
const VILLAGE_NAME := "CliffVillage"
## Its middle, in the generated map's pixels (x < 0 = beyond the map's low-X edge, on the
## mountain). The scan is the houses alone since its second cut: 114 m wide (x), 168 m long (z),
## 31 m from its cut-off bottom to the highest roof, the middle of its surface 18 m up.
## x: the shoulder's face toward the castle needs about 85 m of run from the top's rim to the
## ground beside the castle, and its far rim must stay on the import's west strip (-256).
const VILLAGE_PX := Vector2(-140.0, 100.0)
## Height of the bridge's deck above the scan's cut-off bottom: about street level.
const VILLAGE_DECK_ABOVE_BOTTOM := 15.0
## The beam runs this far in over the shoulder's rim, m: in among the first houses.
const VILLAGE_BRIDGE_REACH := 14.0
## The scan's colours are a sunny day's: multiplied by this toward the night's palette. TUNING.
## (0.42, 0.48, 0.62 at first: with the houses that dark nothing told them from the rock.)
const VILLAGE_TINT := Color(0.62, 0.66, 0.78)
## Seen from the valley floor the life-size village did not read as one (Kirill, 2026-10-09:
## "can't really see any buildings from far away, doesn't look like there's a village there"):
## a 15 m house 800 m away is about a degree tall. Three things answer that. TUNING, all of it.
## 1. The whole piece -- scan, base and where the bridge meets it -- is drawn this many times its
##    real size. Nothing stands next to it to give the scale away. 1 = life-size.
const VILLAGE_SCALE := 1.5
## 2. Lit windows: this many glowing panes (m, before VILLAGE_SCALE) on walls that face outward
##    -- vertices whose normal.y is within VILLAGE_WINDOW_WALL_NY of level and that point at
##    least VILLAGE_WINDOW_OUTWARD away from the village's middle -- no nearer to each other than
##    VILLAGE_WINDOW_SPACING m and at least VILLAGE_WINDOW_MIN_ABOVE_ROCK m above the base's top.
##    They always face the camera: from far away a window is a point of light.
const VILLAGE_WINDOWS := 160
const VILLAGE_WINDOW_SIZE := Vector2(1.6, 2.0)
const VILLAGE_WINDOW_COLOR := Color(1.0, 0.62, 0.26)
const VILLAGE_WINDOW_ENERGY := 6.0
const VILLAGE_WINDOW_WALL_NY := 0.35
const VILLAGE_WINDOW_OUTWARD := 0.15
const VILLAGE_WINDOW_SPACING := 5.0
const VILLAGE_WINDOW_MIN_ABOVE_ROCK := 2.5
const VILLAGE_WINDOW_OFFSET := 0.35 ## m a pane stands off its wall
## 3. The lighter tint above.
## More lights of the same kind (Kirill, 2026-10-09), all in m and all TUNING:
##  - round the rim of the shoulder's top, RIM_LIGHT_HEIGHT above it -- from close under it the
##    houses are hidden behind the rim, and these are what still shows;
##  - on the castle: windows on all four faces from CASTLE_LIGHT_FROM m above its base, more
##    of them toward the top;
##  - along the bridge: a lantern on each side every BRIDGE_LIGHT_SPACING m, BRIDGE_LIGHT_HEIGHT
##    above the deck.
## The rim lights' size and height are before VILLAGE_SCALE.
const RIM_LIGHTS := 44
const RIM_LIGHT_HEIGHT := 1.2
const RIM_LIGHT_SIZE := Vector2(1.5, 1.5)
const CASTLE_LIGHTS := 110
const CASTLE_LIGHT_FROM := 20.0
const CASTLE_LIGHT_SIZE := Vector2(1.6, 2.4)
const BRIDGE_LIGHT_SPACING := 8.0
const BRIDGE_LIGHT_HEIGHT := 1.6
const BRIDGE_LIGHT_SIZE := Vector2(1.1, 1.1)
const LIGHT_STAND_OFF := 0.6 ## m a light stands off the surface it is on
## The village's shoulder (2026-10-09): the rock the village stands on is TERRAIN -- the ridge
## itself, raised into a level-topped shoulder under it (massif_height). Before, the same day,
## it was a rock pillar built as a mesh: Kirill, "there's still a very obvious seam where the
## stone pillar connects and it has an obvious texture pattern, let's make it an extension of
## the terrain instead". Being terrain it is drawn, shaded and textured exactly like the ridge.
## Three owners of ground each take the higher of their own height and the shoulder's: the
## generated map past its foot line (raise_massif_on_map), the low-X apron
## (raise_massif_on_apron) and the north apron (build_maps). West of the low-X apron the import
## has MountainWalls.WEST_EXTRA more columns that are holes except where the shoulder stands
## (west_strip_maps; Kirill: "widen it only where the village is").
## The top is an ellipse of VILLAGE_BASE_RADII (m, x / z, before VILLAGE_SCALE) -- 5 m wider than
## the scan all round -- VILLAGE_BASE_TOP m above the scan's cut-off bottom: just under street
## level, so it fills the scan's ragged underside and shows as rock ground round the houses.
const VILLAGE_BASE_RADII := Vector2(62.0, 89.0)
const VILLAGE_BASE_TOP := 13.0
## Its shape, all in massif_height. TUNING.
##  - outline: lobes push the rim outward by up to MASSIF_BULGE of its radius (never inward:
##    the village must fit on top), cut to MASSIF_CASTLE_SIDE of that toward the castle;
##  - outside the rim the ground falls MASSIF_GRADE m per m, MASSIF_GRADE_CASTLE toward the
##    castle (the top's rim is about 85 m from the ground it must reach there; 2.6 = 69 deg);
##  - buttresses and gullies: the face stands up to MASSIF_RIBS m further out or in;
##  - MASSIF_LEDGE_STRENGTH of the fall is taken in steps MASSIF_LEDGE_EVERY m tall: a steep
##    face, then a ledge;
##  - MASSIF_ROUGH m of finer unevenness;
##  - on the map it fades in over the first MASSIF_FOOT_FADE m past the foot line.
## MASSIF_REACH: how far it can reach, in radii of the top's ellipse (a quick test).
const MASSIF_BULGE := 0.22
const MASSIF_CASTLE_SIDE := 0.3
const MASSIF_GRADE := 1.6
const MASSIF_GRADE_CASTLE := 2.6
const MASSIF_RIBS := 14.0
const MASSIF_LEDGE_EVERY := 30.0
const MASSIF_LEDGE_STRENGTH := 0.55
const MASSIF_LEDGE_WANDER := 22.0
## Within MASSIF_KEEP m of the top's rim nothing else may shape the generated map: no knots, no
## cliff meshes (shoulder_keepout), and the mountain's foot line there is at least
## MASSIF_MAP_FOOT m inside the map's edge. A cliff or knot at the edge used to hold the foot
## line at 0 on its rows; the map was then not raised there while the apron beside it was, and
## the shoulder had a canyon cut into it from the map's edge (Kirill: "huge cut in the terrain").
const MASSIF_KEEP := 95.0
const MASSIF_MAP_FOOT := 40.0
const MASSIF_ROUGH := 2.0
const MASSIF_FOOT_FADE := 6.0
const MASSIF_CUT_GRADE := 1.2 ## how steeply the ridge's own ground may rise from the top's rim, m per m (massif_ceiling)
const MASSIF_EDGE_GRADE := 3.0 ## the steepest the shoulder may leave the generated map's edge, m per m (see raise_massif_on_apron)
const MASSIF_REACH := 3.2
const MASSIF_OUTLINE_STEPS := 360
## A mountain row's mesh is kept this far under the shoulder's ground (MountainWalls._seat_lift).
const MASSIF_MESH_UNDER := 3.0

## World height of the shoulder's level top, and of the lowest ground under the castle (what
## the bridge's height is measured from). Set by prepare_massif; NAN before.
static var massif_top_y := NAN
static var site_ground_y := NAN
## The low-X apron's outer column per row as MountainWalls built it, before the shoulder was
## raised on it: where the shoulder stands higher than this there is ground west of the apron
## (west_strip_maps), and a mountain row's mesh is kept under it (MountainWalls._seat_lift).
static var natural_back_heights := PackedFloat32Array()
static var _massif_outline := PackedFloat32Array()
static var _massif_ribs: FastNoiseLite
static var _massif_fine: FastNoiseLite

## -- The north apron --
## Its length (Z), m. Terrain3D takes whole regions: with AREA_LENGTH and the hub's length it
## should come to a multiple of the region size (256 + 1024 + 512 = 1792), or the rest is padded
## with holes on the +Z end.
const LENGTH := 256
## Its ground leaves the map's edge at WALL_EDGE_GRADE (the grade the map's own ground has past
## the foot line, MountainWalls.FOOT_EXTRA_GRADE) and takes the ramp's shape over EDGE_BLEND m.
const WALL_EDGE_GRADE := 0.75
const EDGE_BLEND := 20.0
const EDGE_SMOOTH_RADIUS := 6 ## columns each way averaged into the height the ramp stands on
## Behind its crest the ramp falls away, but not below this many m above its start.
const WALL_BACK_MIN := 25.0
const WALL_RELIEF := 40.0 ## ridges and gullies on the ramp, m
const WALL_RELIEF_FREQUENCY := 1.0 / 100.0
const COLOR_BLEND := 20.0 ## m from the map's edge over which its own shading replaces the edge's colour

## The apron's heights along its two side edges, smoothed: what MountainWalls' seated side rows
## stand on there. Set by build_maps. One per apron row (row 0 = the northmost), [low X, high X].
static var side_edge_heights: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
## The whole north apron's heights as built (row-major, `north_apron_width` columns, row 0 = the
## northmost), for the mountain rows that stand on it: north_row_heights, north_apron_height.
static var north_apron_heights := PackedFloat32Array()
static var north_apron_width := 0

## The north apron's heights along the line `d` m north of the map's edge, one per import column,
## smoothed like the edges above; empty before build_maps.
static func north_row_heights(d: float) -> PackedFloat32Array:
	if north_apron_width <= 0:
		return PackedFloat32Array()
	var j := clampi(LENGTH - int(round(d)), 0, LENGTH - 1)
	return MountainWalls._row_average(north_apron_heights.slice(j * north_apron_width, (j + 1) * north_apron_width), MountainWalls.SEAT_SMOOTH_RADIUS)

## The north apron's ground height at import column `c`, `d` m north of the map's edge (between
## its samples); NAN off the apron.
static func north_apron_height(c: float, d: float) -> float:
	var j := float(LENGTH) - d
	if north_apron_width <= 0 or c < 0.0 or c > float(north_apron_width - 1) or j < 0.0 or j > float(LENGTH - 1):
		return NAN
	var c0 := mini(int(c), north_apron_width - 2)
	var j0 := mini(int(j), LENGTH - 2)
	var tc := c - float(c0)
	var tj := j - float(j0)
	var i := j0 * north_apron_width + c0
	return lerpf(lerpf(north_apron_heights[i], north_apron_heights[i + 1], tc), lerpf(north_apron_heights[i + north_apron_width], north_apron_heights[i + north_apron_width + 1], tc), tj)

## True where the castle stands: heightmap pixel (px, pz) within `pad` m of its footprint.
## Read-only: safe from worker threads.
static func covers(px: float, pz: float, pad: float = 0.0) -> bool:
	return absf(px - SITE_PX.x) <= PLACEHOLDER_SIZE.x * 0.5 + pad and absf(pz - SITE_PX.y) <= PLACEHOLDER_SIZE.z * 0.5 + pad

## True within MASSIF_KEEP + `pad` m of the rim of the village's shoulder (heightmap pixels):
## the generated map's shaping stages place nothing there.
static func shoulder_keepout(px: float, pz: float, pad: float = 0.0) -> bool:
	return massif_distance(px, pz) < MASSIF_KEEP + pad

## Where the valley's road ends, in heightmap pixels: off the castle's high-X / south corner.
static func road_end() -> Vector2:
	return SITE_PX + Vector2(PLACEHOLDER_SIZE.x * 0.5 + ROAD_END_GAP, PLACEHOLDER_SIZE.z * 0.5 + ROAD_END_GAP)

## Drops the entries of `plan` (planned cliff meshes or outcrops, each with px / pz) that reach
## into the castle's site; `reach` gives an entry's radius. Returns how many were dropped.
static func filter_plan(plan: Array, reach: Callable) -> int:
	var removed := 0
	for i in range(plan.size() - 1, -1, -1):
		var e: Dictionary = plan[i]
		if Vector2(float(e.px), float(e.pz)).distance_to(SITE_PX) < SITE_KEEP_RADIUS + float(reach.call(e)) or shoulder_keepout(float(e.px), float(e.pz), float(reach.call(e))):
			plan.remove_at(i)
			removed += 1
	return removed

## The north apron's maps for the Terrain3D import, `width` columns x LENGTH rows, row-major,
## row 0 = the northmost: {heights: PackedFloat32Array, control: PackedInt32Array, color:
## PackedByteArray (RGBA8)}. `edge_row` / `edge_color` = the heights and the colour-map pixels
## (RGBA8) of the import's row just south of it: the map's north edge with both side aprons.
## Its ridges and shading come from `master_seed`, like the side aprons' (a constant seed until
## 2026-10-09: it was the one piece of mountain that was the same on every run).
static func build_maps(edge_row: PackedFloat32Array, edge_color: PackedByteArray, width: int, master_seed: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var relief_noise := _noise(master_seed ^ 0x4E52544C, WALL_RELIEF_FREQUENCY, FastNoiseLite.FRACTAL_RIDGED, 4) # 'NRTL'
	var shade_noise := _noise(master_seed ^ 0x4E525348, 1.0 / 60.0, FastNoiseLite.FRACTAL_FBM, 3) # 'NRSH'
	var base := MountainWalls._row_average(edge_row, EDGE_SMOOTH_RADIUS)
	# The ramp only depends on the distance out: one table, 1 m apart.
	var ramp := PackedFloat32Array()
	ramp.resize(LENGTH + 1)
	for d in LENGTH + 1:
		ramp[d] = maxf(MountainWalls._ramp_height(float(d), WALL_EDGE_GRADE), minf(float(d), WALL_BACK_MIN))

	# -- Heights --
	var heights := PackedFloat32Array()
	heights.resize(width * LENGTH)
	var crest := -INF
	for j in LENGTH:
		var d := LENGTH - j # m north of the map's edge
		var relief := smoothstep(10.0, 60.0, float(d)) * WALL_RELIEF
		var join := smoothstep(0.0, EDGE_BLEND, float(d))
		for c in width:
			var body := base[c] + ramp[d] + relief * (0.5 + 0.5 * relief_noise.get_noise_2d(c, d))
			var h := lerpf(edge_row[c] + WALL_EDGE_GRADE * float(d), body, join)
			heights[j * width + c] = h
			crest = maxf(crest, h - base[c])

	# -- The village's shoulder, where it reaches north of the map: the higher of the two --
	var on_shoulder := PackedByteArray() # 1 = bare rock there (no turf, no snow)
	on_shoulder.resize(width * LENGTH)
	var shoulder_rows := massif_rows()
	var x_origin := float(MountainWalls.MAP_OFFSET_X) # this import column is the map's px 0
	for j in range(maxi(LENGTH + shoulder_rows.x, 0), LENGTH): # z = -(LENGTH - j) >= shoulder_rows.x
		for c in mini(int(x_origin) + int(MountainWalls.FOOT_MAX) + 2, width):
			var target := minf(massif_height(float(c) - x_origin, -float(LENGTH - j)), edge_row[c] + MASSIF_EDGE_GRADE * float(LENGTH - j))
			if target > heights[j * width + c]:
				heights[j * width + c] = target
				on_shoulder[j * width + c] = 1

	# -- The outer edges, for the mountain rows seated on them --
	var low_x_edge := PackedFloat32Array()
	var high_x_edge := PackedFloat32Array()
	for j in LENGTH:
		low_x_edge.append(heights[j * width])
		high_x_edge.append(heights[j * width + width - 1])
	north_apron_heights = heights
	north_apron_width = width
	side_edge_heights[0] = MountainWalls._row_average(low_x_edge, MountainWalls.SEAT_SMOOTH_RADIUS)
	side_edge_heights[1] = MountainWalls._row_average(high_x_edge, MountainWalls.SEAT_SMOOTH_RADIUS)

	# -- Ground and colour, from the finished shape: the mountain's, as on the side aprons --
	# (bare rock, turf on low ledges only, snow high up; creases darker, faint layers by height)
	var control := PackedInt32Array()
	control.resize(width * LENGTH)
	var color := PackedByteArray()
	color.resize(width * LENGTH * 4)
	var map_from := MountainWalls.MAP_OFFSET_X
	var map_to := MountainWalls.MAP_OFFSET_X + TerrainConfig.AREA_WIDTH
	for j in LENGTH:
		var j0 := maxi(j - 1, 0)
		var j1 := mini(j + 1, LENGTH - 1)
		var own_share := smoothstep(0.0, COLOR_BLEND, float(LENGTH - j))
		for c in width:
			var cell := j * width + c
			var c0 := maxi(c - 1, 0)
			var c1 := mini(c + 1, width - 1)
			var h := heights[cell]
			var dx := (heights[j * width + c1] - heights[j * width + c0]) / float(maxi(c1 - c0, 1))
			var dz := (heights[j1 * width + c] - heights[j0 * width + c]) / float(maxi(j1 - j0, 1))
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			var above := h - base[c]
			var turf := smoothstep(MountainWalls.APRON_TURF_NY_NONE, MountainWalls.APRON_TURF_NY_FULL, ny) \
				* (1.0 - smoothstep(MountainWalls.APRON_TURF_TOP - MountainWalls.APRON_TURF_FADE, MountainWalls.APRON_TURF_TOP, above)) * MountainWalls.APRON_TURF_AMOUNT
			var snow := smoothstep(MountainWalls.APRON_SNOW_FROM, MountainWalls.APRON_SNOW_FULL, above + MountainWalls.APRON_SNOW_WANDER * shade_noise.get_noise_2d(c * 2.0 + 50.0, j * 2.0)) \
				* smoothstep(MountainWalls.APRON_SNOW_NY_NONE, MountainWalls.APRON_SNOW_NY_FULL, ny)
			if on_shoulder[cell] == 1:
				turf = 0.0
				snow = 0.0
			if snow > 0.02:
				control[cell] = TerrainHeightmap.pack_control_blend(MountainWalls.APRON_ROCK, MountainWalls.APRON_SNOW_ID, snow)
			else:
				control[cell] = TerrainHeightmap.pack_control_blend(MountainWalls.APRON_ROCK, MountainWalls.APRON_TURF_ID, turf)
			var curvature := heights[j * width + c0] + heights[j * width + c1] + heights[j0 * width + c] + heights[j1 * width + c] - 4.0 * h # > 0 in a crease
			var shade := clampf(1.0 - curvature * MountainWalls.APRON_CREASE_SHADE, MountainWalls.APRON_CREASE_MIN, MountainWalls.APRON_CREASE_MAX) / MountainWalls.APRON_CREASE_MAX
			shade *= 1.0 - MountainWalls.APRON_STRATA_SHADE * (0.5 + 0.5 * sin((h + 4.0 * shade_noise.get_noise_2d(float(c) * 3.0, float(j) * 3.0)) * TAU / MountainWalls.APRON_STRATA_PERIOD))
			shade *= lerpf(MountainWalls.APRON_SHADE_MIN, 1.0, 0.5 + 0.5 * shade_noise.get_noise_2d(float(c), float(j)))
			shade = lerpf(shade, 1.0, snow * 0.7) # snow fills creases and covers the rock's layers
			var tint := MountainWalls.MOUNTAIN_TINT.lerp(MountainWalls.APRON_TURF_TINT, turf).lerp(MountainWalls.APRON_SNOW_TINT, snow)
			var final := Color(shade * tint.r, shade * tint.g, shade * tint.b)
			if own_share < 1.0 and edge_color.size() >= width * 4:
				# What the row south of it is coloured: the side aprons' pixels as they are, the
				# map's with the mountain's tint the ground paint multiplies into them later.
				var edge := Color(edge_color[c * 4] / 255.0, edge_color[c * 4 + 1] / 255.0, edge_color[c * 4 + 2] / 255.0)
				if c >= map_from and c < map_to:
					edge = Color(edge.r * MountainWalls.MOUNTAIN_TINT.r, edge.g * MountainWalls.MOUNTAIN_TINT.g, edge.b * MountainWalls.MOUNTAIN_TINT.b)
				final = edge.lerp(final, own_share)
			color[cell * 4] = int(255.0 * final.r)
			color[cell * 4 + 1] = int(255.0 * final.g)
			color[cell * 4 + 2] = int(255.0 * final.b)
			color[cell * 4 + 3] = 128 # roughness left as it is
	print("TERRAIN_GEN: north apron -- %dx%d m of terrain north of the map, crest up to %.0f m above the map's edge (%d ms)" % [width, LENGTH, crest, Time.get_ticks_msec() - t0])
	return {"heights": heights, "control": control, "color": color}

static func _noise(noise_seed: int, frequency: float, fractal: int, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH if fractal == FastNoiseLite.FRACTAL_FBM else FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = fractal
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise

## The stand-ins for the castle and its bridge: a plain dark block standing in the ground at
## SITE_PX and a beam from it into the western ridge, both with collision (reachable, not
## enterable). Their heights are read from the terrain as imported (`terrain`), so this runs
## after the import. Added to `parent_node` (deferred, like the other generated bodies).
static func spawn_placeholder(parent_node: Node, terrain: Terrain3D, heightmap_corner: Vector3) -> void:
	var old := parent_node.get_node_or_null(PLACEHOLDER_NAME)
	if old:
		old.name = PLACEHOLDER_NAME + "_old"
		old.queue_free()
	var data: Terrain3DData = terrain.get_data()
	var centre := Vector3(heightmap_corner.x + SITE_PX.x, 0.0, heightmap_corner.z + SITE_PX.y)
	var size := PLACEHOLDER_SIZE

	# The lowest ground under the footprint.
	var ground := INF
	for dz in range(-int(size.z * 0.5), int(size.z * 0.5) + 1, SITE_GROUND_STEP):
		for dx in range(-int(size.x * 0.5), int(size.x * 0.5) + 1, SITE_GROUND_STEP):
			var h := data.get_height(centre + Vector3(dx, 0.0, dz))
			if not is_nan(h):
				ground = minf(ground, h)
	if ground == INF:
		push_warning("TERRAIN_GEN: castle placeholder -- no terrain at its site, skipped")
		return
	var foot := Vector3(centre.x, ground - PLACEHOLDER_SINK, centre.z)

	var face_x := centre.x - size.x * 0.5
	print("TERRAIN_GEN: castle placeholder -- %.0f x %.0f m at map pixel (%.0f, %.0f), %.0f m tall, top %.0f m above the valley floor" % [size.x, size.z, SITE_PX.x, SITE_PX.y, size.y, foot.y + size.y - TerrainHeightmap.BASE_LEVEL])

	var body := StaticBody3D.new()
	body.name = PLACEHOLDER_NAME
	body.position = foot + Vector3(0.0, size.y * 0.5, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.12, 0.12, 0.14)
	material.roughness = 0.9
	_add_box(body, "Castle", size, Vector3.ZERO, material)

	# The bridge: from the castle's low-X face over the shoulder's rim into the village. Its
	# height is the one the shoulder was built for (prepare_massif), measured from the ground
	# under the castle before the road was graded beside it.
	var deck_y := bridge_deck_y() if not is_nan(site_ground_y) else foot.y + BRIDGE_DECK_HEIGHT
	var rim_radii := VILLAGE_BASE_RADII * VILLAGE_SCALE
	var across := clampf((SITE_PX.y - VILLAGE_PX.y) / rim_radii.y, -0.95, 0.95)
	var rim_x := heightmap_corner.x + VILLAGE_PX.x + rim_radii.x * sqrt(1.0 - across * across) # the plain ellipse on the bridge's row
	var span := face_x - (rim_x - VILLAGE_BRIDGE_REACH)
	var beam_size := Vector3(span, BRIDGE_THICKNESS, BRIDGE_WIDTH)
	_add_box(body, "Bridge", beam_size, Vector3(face_x - beam_size.x * 0.5, deck_y - BRIDGE_THICKNESS * 0.5, foot.z) - body.position, material)
	print("TERRAIN_GEN: castle bridge placeholder -- %.0f m span to the village, deck %.0f m above the castle's base (%.0f m below its top)" % [span, BRIDGE_DECK_HEIGHT, size.y - BRIDGE_DECK_HEIGHT])

	# Lights (in the body's own space: its origin is the middle of the castle block).
	var light_rng := RandomNumberGenerator.new()
	light_rng.seed = 0x43534C54 # 'CSLT': the same on every run
	# The castle: windows on its four faces, more of them toward the top.
	var castle_points: Array[Vector3] = []
	for i in CASTLE_LIGHTS:
		var up := lerpf(-size.y * 0.5 + CASTLE_LIGHT_FROM, size.y * 0.5 - 3.0, sqrt(light_rng.randf()))
		var face := light_rng.randi_range(0, 3)
		var along := light_rng.randf_range(-0.42, 0.42)
		if face < 2:
			castle_points.append(Vector3((size.x * 0.5 + LIGHT_STAND_OFF) * (1.0 if face == 0 else -1.0), up, along * size.z))
		else:
			castle_points.append(Vector3(along * size.x, up, (size.z * 0.5 + LIGHT_STAND_OFF) * (1.0 if face == 2 else -1.0)))
	_add_glow_points(body, "CastleLights", castle_points, CASTLE_LIGHT_SIZE, light_rng)
	# The bridge: a lantern on each side every BRIDGE_LIGHT_SPACING m.
	var bridge_points: Array[Vector3] = []
	var lantern_y := deck_y + BRIDGE_LIGHT_HEIGHT - body.position.y
	var lanterns := maxi(int(span / BRIDGE_LIGHT_SPACING), 1)
	for i in lanterns + 1:
		var x := face_x - span * float(i) / float(lanterns) - body.position.x
		for side: float in [-1.0, 1.0]:
			bridge_points.append(Vector3(x, lantern_y, side * (BRIDGE_WIDTH * 0.5 + LIGHT_STAND_OFF)))
	_add_glow_points(body, "BridgeLights", bridge_points, BRIDGE_LIGHT_SIZE, light_rng)
	print("TERRAIN_GEN: lights -- %d on the castle, %d along the bridge" % [castle_points.size(), bridge_points.size()])
	parent_node.add_child.call_deferred(body)
	_spawn_village(parent_node, heightmap_corner, deck_y)

## The village at the bridge's far end (VILLAGE_*): the scan standing on the shoulder's level
## top (massif_top_y), with its windows and the lights round the top's rim. `deck_y` = world
## height of the bridge's deck.
static func _spawn_village(parent_node: Node, heightmap_corner: Vector3, deck_y: float) -> void:
	var old := parent_node.get_node_or_null(VILLAGE_NAME)
	if old:
		old.name = VILLAGE_NAME + "_old"
		old.queue_free()
	var packed: PackedScene = null
	if ResourceLoader.exists(VILLAGE_SCENE):
		packed = load(VILLAGE_SCENE) as PackedScene
	if packed == null:
		push_warning("TERRAIN_GEN: %s could not be loaded -- no village at the bridge's end" % VILLAGE_SCENE)
		return
	var root := Node3D.new()
	root.name = VILLAGE_NAME
	var bottom_y := deck_y - VILLAGE_DECK_ABOVE_BOTTOM * VILLAGE_SCALE
	root.position = Vector3(heightmap_corner.x + VILLAGE_PX.x, bottom_y, heightmap_corner.z + VILLAGE_PX.y)

	var scan := packed.instantiate() as Node3D
	scan.name = "Scan"
	scan.scale = Vector3.ONE * VILLAGE_SCALE
	root.add_child(scan)
	var tris := 0
	var windows := 0
	for mesh_instance: MeshInstance3D in scan.find_children("*", "MeshInstance3D", true, false):
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		windows += _add_village_windows(mesh_instance)
		for surface in mesh_instance.mesh.get_surface_count():
			var array_mesh := mesh_instance.mesh as ArrayMesh
			if array_mesh:
				var indices: int = array_mesh.surface_get_array_index_len(surface)
				tris += (indices if indices > 0 else array_mesh.surface_get_array_len(surface)) / 3
			var own := mesh_instance.get_active_material(surface)
			if own is BaseMaterial3D: # a copy: the imported material itself is left as it is
				var tinted := own.duplicate() as BaseMaterial3D
				tinted.albedo_color = (own as BaseMaterial3D).albedo_color * VILLAGE_TINT
				mesh_instance.set_surface_override_material(surface, tinted)

	# Lights round the rim of the shoulder's top: from close under it the houses are hidden
	# behind the rim, and these are what still shows.
	var light_rng := RandomNumberGenerator.new()
	light_rng.seed = 0x52494D4C # 'RIML': the same on every run
	var rim_points: Array[Vector3] = []
	var rim_y := VILLAGE_BASE_TOP * VILLAGE_SCALE + RIM_LIGHT_HEIGHT * VILLAGE_SCALE
	for i in RIM_LIGHTS:
		var t := TAU * (float(i) + light_rng.randf_range(-0.3, 0.3)) / float(RIM_LIGHTS)
		var at := _massif_outline_point(t) + Vector2(cos(t), sin(t)) * LIGHT_STAND_OFF
		rim_points.append(Vector3(at.x, rim_y, at.y))
	_add_glow_points(root, "RimLights", rim_points, RIM_LIGHT_SIZE * VILLAGE_SCALE, light_rng)
	parent_node.add_child.call_deferred(root)
	print("TERRAIN_GEN: cliff village -- %d triangles, %d lit window(s) and %d rim light(s), drawn at %.1f x its real size, at map pixel (%.0f, %.0f), its bottom %.0f m above the valley floor (the shoulder's top: %.0f m)" % [
		tris, windows, rim_points.size(), VILLAGE_SCALE, VILLAGE_PX.x, VILLAGE_PX.y, bottom_y - TerrainHeightmap.BASE_LEVEL, massif_top_y - TerrainHeightmap.BASE_LEVEL])

# ---------------------------------------------------------------------------------------------
# The village's shoulder: terrain
# ---------------------------------------------------------------------------------------------

## Works out the shoulder for this run from the generated map's `map_heights` (AREA_WIDTH wide):
## the castle's base (the lowest ground under its footprint, the sample points spawn_placeholder
## reads too), the height of the shoulder's top, its outline. Before any massif_height call.
static func prepare_massif(map_heights: PackedFloat32Array) -> void:
	var ground := INF
	for dz in range(-int(PLACEHOLDER_SIZE.z * 0.5), int(PLACEHOLDER_SIZE.z * 0.5) + 1, SITE_GROUND_STEP):
		for dx in range(-int(PLACEHOLDER_SIZE.x * 0.5), int(PLACEHOLDER_SIZE.x * 0.5) + 1, SITE_GROUND_STEP):
			var px := clampi(int(SITE_PX.x) + dx, 0, TerrainConfig.AREA_WIDTH - 1)
			var pz := clampi(int(SITE_PX.y) + dz, 0, TerrainConfig.AREA_LENGTH - 1)
			ground = minf(ground, map_heights[pz * TerrainConfig.AREA_WIDTH + px])
	site_ground_y = ground
	# Level with the rock the scan's houses stand on: VILLAGE_BASE_TOP above its cut-off bottom.
	massif_top_y = bridge_deck_y() - (VILLAGE_DECK_ABOVE_BOTTOM - VILLAGE_BASE_TOP) * VILLAGE_SCALE
	_ensure_massif_shape()

## The shoulder's outline and noises: the same on every seed, needed (for massif_distance) before
## its height is known.
static func _ensure_massif_shape() -> void:
	if not _massif_outline.is_empty():
		return
	_massif_ribs = _noise(0x56494C4D, 1.0 / 70.0, FastNoiseLite.FRACTAL_FBM, 3) # 'VILM'
	_massif_fine = _noise(0x56494C4E, 1.0 / 18.0, FastNoiseLite.FRACTAL_FBM, 3)
	var lobes := _noise(0x56494C4C, 1.0 / 160.0, FastNoiseLite.FRACTAL_FBM, 2) # 'VILL'
	_massif_outline = PackedFloat32Array()
	_massif_outline.resize(MASSIF_OUTLINE_STEPS)
	for step in MASSIF_OUTLINE_STEPS:
		var t := TAU * float(step) / float(MASSIF_OUTLINE_STEPS)
		# Toward the castle (+X) the lobes are held back: the face there has the least room.
		var held := lerpf(1.0, MASSIF_CASTLE_SIDE, smoothstep(0.2, 0.9, cos(t)))
		_massif_outline[step] = 1.0 + MASSIF_BULGE * held * smoothstep(0.3, 0.8, 0.5 + 0.5 * lobes.get_noise_2d(cos(t) * 100.0, sin(t) * 100.0))

## World height of the bridge's deck (valid once prepare_massif has run).
static func bridge_deck_y() -> float:
	return site_ground_y - PLACEHOLDER_SINK + BRIDGE_DECK_HEIGHT

## How far out the top's rim is at ellipse parameter `t`, as a share of the plain ellipse.
static func _massif_bulge(t: float) -> float:
	var at := fposmod(t / TAU, 1.0) * float(MASSIF_OUTLINE_STEPS)
	var s0 := int(at) % MASSIF_OUTLINE_STEPS
	return lerpf(_massif_outline[s0], _massif_outline[(s0 + 1) % MASSIF_OUTLINE_STEPS], at - floorf(at))

## The top's rim at ellipse parameter `t`, in m from the village's middle (x, z).
static func _massif_outline_point(t: float) -> Vector2:
	var radii := VILLAGE_BASE_RADII * VILLAGE_SCALE
	return Vector2(cos(t) * radii.x, sin(t) * radii.y) * (_massif_bulge(t) if not _massif_outline.is_empty() else 1.0)

## World height of the shoulder at (x, z) in the generated map's pixels (x < 0 = beyond its low-X
## edge, z < 0 = beyond its north edge): level inside the rim, falling away outside it; -INF
## where the shoulder is not (and before prepare_massif). Whoever owns the ground there takes
## the higher of this and its own height. Read-only: safe from worker threads.
static func massif_height(x: float, z: float) -> float:
	if is_nan(massif_top_y):
		return -INF
	var d := massif_distance(x, z)
	if d == INF:
		return -INF
	if d <= 0.0:
		return massif_top_y
	var rel := Vector2(x - VILLAGE_PX.x, z - VILLAGE_PX.y)
	var toward_castle := smoothstep(0.2, 0.9, rel.x / maxf(rel.length(), 0.001))
	# Buttresses and gullies: the face stands further out or in (not toward the castle).
	d = maxf(d + MASSIF_RIBS * (1.0 - 0.8 * toward_castle) * smoothstep(0.0, 25.0, d) * _massif_ribs.get_noise_2d(x, z), 0.0)
	var fall := lerpf(MASSIF_GRADE, MASSIF_GRADE_CASTLE, toward_castle) * d
	# Taken partly in steps: a steep face, then a ledge. Never the same twice (Kirill: "even,
	# identical, step-like ridges, look unnatural"): the steps' height changes from place to
	# place, noise moves where each one falls by up to MASSIF_LEDGE_WANDER m, and whole stretches
	# of the face have none.
	var every := MASSIF_LEDGE_EVERY * (0.65 + 0.7 * (0.5 + 0.5 * _massif_ribs.get_noise_2d(x * 0.3 - 50.0, z * 0.3 + 210.0)))
	var wander := MASSIF_LEDGE_WANDER * _massif_ribs.get_noise_2d(x * 0.6 + 300.0, z * 0.6 - 120.0)
	var bands := maxf(fall + wander, 0.0) / every
	var stepped := maxf((floorf(bands) + smoothstep(0.0, 0.65, bands - floorf(bands))) * every - wander, 0.0)
	fall = lerpf(fall, stepped, MASSIF_LEDGE_STRENGTH * smoothstep(-0.15, 0.35, _massif_fine.get_noise_2d(x * 0.25 + 77.0, z * 0.25)))
	fall += MASSIF_ROUGH * smoothstep(0.0, 10.0, d) * _massif_fine.get_noise_2d(x, z)
	var height := massif_top_y - maxf(fall, 0.0)
	return height if height > TerrainHeightmap.BASE_LEVEL - 20.0 else -INF

## How far outside the rim of the shoulder's top (x, z) lies, m along the ray from the village's
## middle: 0 or less on the top itself, INF beyond the shoulder's reach (and before
## prepare_massif). Read-only: safe from worker threads.
static func massif_distance(x: float, z: float) -> float:
	if _massif_outline.is_empty():
		_ensure_massif_shape() # (only ever from the main thread, early in the heightmap build)
	var rel := Vector2(x - VILLAGE_PX.x, z - VILLAGE_PX.y)
	var radii := VILLAGE_BASE_RADII * VILLAGE_SCALE
	var e := Vector2(rel.x / radii.x, rel.y / radii.y)
	var q := e.length()
	if q > MASSIF_REACH:
		return INF
	var along := q / _massif_bulge(atan2(e.y, e.x)) # 1 on the rim
	return rel.length() * (1.0 - 1.0 / maxf(along, 0.001)) if along > 1.0 else along - 1.0

## The highest the ridge's own ground may stand at (x, z) next to the village: level with the
## shoulder's top on it, MASSIF_CUT_GRADE m higher per m outside its rim. INF beyond its reach.
## (On a seed whose ridge is taller than the shoulder the ridge would otherwise stand in the
## middle of the village.)
static func massif_ceiling(x: float, z: float) -> float:
	var d := massif_distance(x, z)
	return INF if d == INF else massif_top_y + MASSIF_CUT_GRADE * maxf(d, 0.0)

## The rows (z, in the generated map's pixels) the shoulder can reach: [first, last].
static func massif_rows() -> Vector2i:
	var reach := VILLAGE_BASE_RADII.y * VILLAGE_SCALE * MASSIF_REACH
	return Vector2i(int(floorf(VILLAGE_PX.y - reach)), int(ceilf(VILLAGE_PX.y + reach)))

## Raises the generated map's `heights` to the shoulder where its ground is the mountain's rock
## (past the foot line, fading in over the first MASSIF_FOOT_FADE m of it). After
## MountainWalls.raise_foot, before the road and all scattering. Returns the pixels raised.
static func raise_massif_on_map(heights: PackedFloat32Array) -> int:
	var t0 := Time.get_ticks_msec()
	prepare_massif(heights)
	var width := TerrainConfig.AREA_WIDTH
	var rows := massif_rows()
	var raised := 0
	for pz in range(maxi(rows.x, 0), mini(rows.y, TerrainConfig.AREA_LENGTH - 1) + 1):
		for px in mini(int(MountainWalls.FOOT_MAX + TerrainHeightmap.VALLEY_MEANDER_IN) + 2, width):
			var depth := MountainWalls.mountain_depth(px, pz)
			if depth <= 0.0:
				continue
			var target := massif_height(px, pz)
			var i := pz * width + px
			if target > heights[i]:
				heights[i] = lerpf(heights[i], target, smoothstep(0.0, MASSIF_FOOT_FADE, depth))
				raised += 1
	print("TERRAIN_GEN: village shoulder -- top %.0f m above the valley floor (the castle's base at %.1f m); %d px of the map's rock raised (%d ms)" % [
		massif_top_y - TerrainHeightmap.BASE_LEVEL, site_ground_y - TerrainHeightmap.BASE_LEVEL, raised, Time.get_ticks_msec() - t0])
	return raised

## Raises the low-X mountain apron's `heights` (`apron_width` columns x `rows` rows, column 0 =
## its outer edge, row = the generated map's row) to the shoulder. Returns a mask, 1 where it
## did: MountainWalls.apron_maps paints those pixels bare rock (no turf, no snow).
## `map_heights` = the generated map's finished heights: the map is only raised where its ground
## is the mountain's rock (raise_massif_on_map), so next to the map's edge the apron may stand
## no higher than MASSIF_EDGE_GRADE x its distance above the edge -- or a wall of any height
## could stand on the edge itself (96 m on one seed, before this).
## Also records the apron's outer column as it was before (natural_back_heights).
static func raise_massif_on_apron(heights: PackedFloat32Array, apron_width: int, rows: int, map_heights: PackedFloat32Array) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(apron_width * rows)
	natural_back_heights = PackedFloat32Array()
	natural_back_heights.resize(rows)
	for row in rows:
		natural_back_heights[row] = heights[row * apron_width]
	var span := massif_rows()
	for row in range(maxi(span.x, 0), mini(span.y, rows - 1) + 1):
		var edge := map_heights[mini(row, TerrainConfig.AREA_LENGTH - 1) * TerrainConfig.AREA_WIDTH]
		for a in apron_width:
			var x := float(a - apron_width)
			var i := row * apron_width + a
			# Cut back where the ridge stands higher than the village's ground allows ...
			var ceiling := massif_ceiling(x, float(row))
			if heights[i] > ceiling:
				heights[i] = ceiling
				mask[i] = 1
			# ... and raised to the shoulder where it is lower.
			var target := minf(massif_height(x, float(row)), edge + MASSIF_EDGE_GRADE * float(apron_width - a))
			if target > heights[i]:
				heights[i] = target
				mask[i] = 1
	return mask

## The strip of the Terrain3D import west of the low-X apron (MountainWalls.WEST_EXTRA columns,
## one row per row of the map + hub, column 0 = the westmost): ground only where the shoulder
## stands, holes everywhere else (Kirill: "widen it only where the village is"). `apron_heights`
## = the low-X apron's heights (`apron_width` columns): a hole repeats its outer column's height.
## {heights: PackedFloat32Array, control: PackedInt32Array, color: PackedByteArray (RGBA8)}.
static func west_strip_maps(apron_heights: PackedFloat32Array, apron_width: int, rows: int) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var width := MountainWalls.WEST_EXTRA
	var heights := PackedFloat32Array()
	heights.resize(width * rows)
	var control := PackedInt32Array()
	control.resize(width * rows)
	var hole := TerrainHeightmap.pack_control_blend(TerrainConfig.GROUND_TEXTURE_ID, TerrainConfig.GROUND_TEXTURE_ID, 0.0) | Terrain3DUtil.enc_hole(true)
	control.fill(hole)
	var color := PackedByteArray()
	color.resize(width * rows * 4)
	color.fill(255)
	var rock := TerrainHeightmap.pack_control_blend(MountainWalls.APRON_ROCK, MountainWalls.APRON_ROCK, 0.0)
	var span := massif_rows()
	var ground := 0
	for row in rows:
		var base := apron_heights[row * apron_width] # the apron's outer column (raised to the shoulder where that is higher)
		var natural := natural_back_heights[row] if row < natural_back_heights.size() else base # ... and as it was before
		var on_span := row >= span.x and row <= span.y
		for a in width:
			var i := row * width + a
			var x := float(a - width - apron_width)
			var target := massif_height(x, float(row)) if on_span else -INF
			# Ground: on the shoulder's top, and where it stands above the ridge's own back edge.
			if target > -INF and (target > natural + 0.5 or massif_distance(x, float(row)) <= 0.0):
				heights[i] = target
				control[i] = rock
				ground += 1
			else:
				heights[i] = base
	# Colour, from the finished shape: the mountain's tint, creases darker.
	for row in range(maxi(span.x, 0), mini(span.y, rows - 1) + 1):
		for a in width:
			var i := row * width + a
			var shade := 1.0
			if control[i] == rock:
				var curvature := heights[row * width + maxi(a - 1, 0)] + heights[row * width + mini(a + 1, width - 1)] + heights[maxi(row - 1, 0) * width + a] + heights[mini(row + 1, rows - 1) * width + a] - 4.0 * heights[i]
				shade = clampf(1.0 - curvature * MountainWalls.APRON_CREASE_SHADE, MountainWalls.APRON_CREASE_MIN, MountainWalls.APRON_CREASE_MAX) / MountainWalls.APRON_CREASE_MAX
			color[i * 4] = int(255.0 * shade * MountainWalls.MOUNTAIN_TINT.r)
			color[i * 4 + 1] = int(255.0 * shade * MountainWalls.MOUNTAIN_TINT.g)
			color[i * 4 + 2] = int(255.0 * shade * MountainWalls.MOUNTAIN_TINT.b)
	for i in width * rows:
		color[i * 4 + 3] = 128 # roughness left as it is
	print("TERRAIN_GEN: west strip -- %d x %d px west of the low-X apron, ground on %d of them (the village's shoulder), the rest holes (%d ms)" % [width, rows, ground, Time.get_ticks_msec() - t0])
	return {"heights": heights, "control": control, "color": color}

## Lit windows on one mesh of the village scan: small glowing panes on wall vertices picked at
## random (VILLAGE_WINDOW_*), as one MultiMesh under `mesh_instance`. Returns how many.
static func _add_village_windows(mesh_instance: MeshInstance3D) -> int:
	var array_mesh := mesh_instance.mesh as ArrayMesh
	if array_mesh == null or VILLAGE_WINDOWS <= 0:
		return 0
	# Wall vertices that face away from the village's middle, above the rock base's top.
	var spots: Array[Vector3] = []
	for surface in array_mesh.get_surface_count():
		var arrays := array_mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if arrays[Mesh.ARRAY_NORMAL] == null:
			continue
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			var v := vertices[i]
			var n := normals[i]
			if absf(n.y) > VILLAGE_WINDOW_WALL_NY or v.y < VILLAGE_BASE_TOP + VILLAGE_WINDOW_MIN_ABOVE_ROCK:
				continue
			if Vector2(n.x, n.z).dot(Vector2(v.x, v.z).normalized()) < VILLAGE_WINDOW_OUTWARD:
				continue
			spots.append(v + n * VILLAGE_WINDOW_OFFSET)
	if spots.is_empty():
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x57494E44 # 'WIND': the same windows on every run
	var chosen: Array[Vector3] = []
	for attempt in VILLAGE_WINDOWS * 6:
		if chosen.size() >= VILLAGE_WINDOWS:
			break
		var spot := spots[rng.randi_range(0, spots.size() - 1)]
		var clear := true
		for other in chosen:
			if other.distance_to(spot) < VILLAGE_WINDOW_SPACING:
				clear = false
				break
		if clear:
			chosen.append(spot)

	_add_glow_points(mesh_instance, "Windows", chosen, VILLAGE_WINDOW_SIZE, rng)
	return chosen.size()

## Points of light: one glowing pane of `pane_size` m (x 0.75..1.25 each) at every one of
## `points` (in `parent`'s own space), as one MultiMesh named `node_name` under `parent`. The
## panes always face the camera, so each reads as a point of light from any side and any angle.
static func _add_glow_points(parent: Node3D, node_name: String, points: Array[Vector3], pane_size: Vector2, rng: RandomNumberGenerator) -> void:
	if points.is_empty():
		return
	var pane := QuadMesh.new()
	pane.size = pane_size
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color.BLACK
	glow.emission_enabled = true
	glow.emission = VILLAGE_WINDOW_COLOR
	glow.emission_energy_multiplier = VILLAGE_WINDOW_ENERGY
	glow.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	glow.billboard_keep_scale = true
	pane.material = glow
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = pane
	multimesh.instance_count = points.size()
	for i in points.size():
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * rng.randf_range(0.75, 1.25)), points[i]))
	var lights := MultiMeshInstance3D.new()
	lights.name = node_name
	lights.multimesh = multimesh
	lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(lights)

## A box mesh with a matching collider, both children of `body` at `offset`.
static func _add_box(body: StaticBody3D, box_name: String, size: Vector3, offset: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	box.material = material
	var mesh := MeshInstance3D.new()
	mesh.name = box_name
	mesh.mesh = box
	mesh.position = offset
	body.add_child(mesh)
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.name = box_name + "Collider"
	collider.shape = shape
	collider.position = offset
	body.add_child(collider)
