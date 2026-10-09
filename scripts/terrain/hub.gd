## The hub (2026-10-06): a fixed strip of ground joined to the south (+Z) edge of the generated map
## -- the village plateau, raised above the valley floor, and the scarp that drops from its north
## edge to the map (2026-10-07; before that the plateau was at floor height with a hill between it
## and the map). Built from HUB_SEED, never from the run's seed, so it is the same every run; only
## the last JOIN_BLEND_LENGTH m of the foot follow this run's generated edge.
##
## The generated map and its stages are untouched: the hub is its own height array (hub row 0 is
## the row just south of the map's last row), joined to the generated images only for the
## Terrain3D import (join_images). World z of hub row j = heightmap_corner.z + AREA_LENGTH + j.
##
## North to south: foot (valley-floor height), scarp, village plateau up to the strip's south edge.
## The scarp is too steep to walk; a switchback trail (benches cut into the face, _trail_points)
## is the way down. The valley's walls (TerrainHeightmap.valley_profile) continue along the whole
## strip, on top of the plateau too, so the scarp cannot be walked around.
##
## Static-only: never instantiated; call as TerrainHub.some_func(...).
class_name TerrainHub
extends RefCounted

const HUB_SEED := 20261006
## Length of the strip (Z), m. Terrain3D takes whole regions: keep it a multiple of the region size.
const STRIP_LENGTH := 512
const FOOT_LENGTH := 30 ## m of valley floor between the map's edge and the scarp
## Horizontal run of the scarp, m. With PLATEAU_HEIGHT 30 the face is at 49 deg (walking limit: 45).
const SCARP_LENGTH := 26
## Plateau height above the valley floor, m (the tallest trees are about 27 m).
const PLATEAU_HEIGHT := 30.0
## The village plateau takes the rest of the strip (456 m with the lengths above).
const PLATEAU_LENGTH := STRIP_LENGTH - FOOT_LENGTH - SCARP_LENGTH
const JOIN_BLEND_LENGTH := 30 ## m at the foot that blend into the generated map's edge row

## The trail down the scarp: from the middle of the plateau's edge to the middle of the foot, in
## four legs (half, full, full, half) with three hairpins, each TRAIL_HALF_SPAN m to one side of
## the valley's centre line. Grade with the values here: 30 m over 180 m, about 10 deg.
const TRAIL_HALF_SPAN := 30.0
const TRAIL_WIDTH := 4.0 ## m, the flat bench
const TRAIL_BANK := 2.5 ## m beside the bench over which the cut blends back into the face

const HILL_NOISE_AMPLITUDE := 2.0 ## m, broad unevenness on the scarp and the foot (none on the plateau)
const HILL_NOISE_FREQUENCY := 1.0 / 70.0
const DETAIL_NOISE_AMPLITUDE := 0.15 ## m on the plateau and the trail, DETAIL_NOISE_SLOPE_AMPLITUDE below them
const DETAIL_NOISE_SLOPE_AMPLITUDE := 0.5
const DETAIL_NOISE_FREQUENCY := 1.0 / 28.0
const RELIEF_FULL_AT := 6.0 ## m below the plateau where the slope noise reaches full strength

const SPAWN_INSET := 20 ## m from the trail's head onto the plateau where the player starts

## Height of the strip's centre line at hub row `row`, before walls, noise and the trail.
static func _centre_height(row: float) -> float:
	var floor_h: float = TerrainHeightmap.BASE_LEVEL
	var scarp_end := float(FOOT_LENGTH + SCARP_LENGTH)
	if row < FOOT_LENGTH:
		return floor_h
	if row < scarp_end:
		return floor_h + PLATEAU_HEIGHT * (row - FOOT_LENGTH) / SCARP_LENGTH
	return floor_h + PLATEAU_HEIGHT

## The trail's centre line, top to bottom, as (px, hub row, height above the valley floor). Every
## point lies on the bare scarp at its own height, so the benches cut and fill about equally.
static func _trail_points() -> PackedVector3Array:
	var centre_x := TerrainConfig.AREA_WIDTH * 0.5
	var points := PackedVector3Array()
	# [sideways offset in half spans, fraction of the scarp's height]; the height drops in
	# proportion to the sideways distance, so the grade is the same on every leg.
	for corner: Array in [[0.0, 1.0], [1.0, 5.0 / 6.0], [-1.0, 0.5], [1.0, 1.0 / 6.0], [0.0, 0.0]]:
		var offset: float = corner[0]
		var fraction: float = corner[1]
		points.append(Vector3(centre_x + offset * TRAIL_HALF_SPAN, FOOT_LENGTH + fraction * SCARP_LENGTH, fraction * PLATEAU_HEIGHT))
	return points

## The hub's heights, AREA_WIDTH x STRIP_LENGTH, row-major like the generated `heights`.
## `map_heights` is only read along its last row (the join).
static func build_heights(map_heights: PackedFloat32Array) -> PackedFloat32Array:
	var t0 := Time.get_ticks_msec()
	var width := TerrainConfig.AREA_WIDTH
	var hill_noise := FastNoiseLite.new()
	hill_noise.seed = HUB_SEED
	hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hill_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	hill_noise.fractal_octaves = 3
	hill_noise.frequency = HILL_NOISE_FREQUENCY
	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = HUB_SEED + 1
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 3
	detail_noise.frequency = DETAIL_NOISE_FREQUENCY

	# The valley's cross-section only depends on x: its wall rise above the floor, per column.
	var wall_rise := PackedFloat32Array()
	wall_rise.resize(width)
	for px in width:
		wall_rise[px] = float(TerrainHeightmap.valley_profile(px, width).height) - TerrainHeightmap.BASE_LEVEL

	# The trail only reaches this far from its centre line: the rows and columns it can touch.
	var trail := _trail_points()
	var trail_half := TRAIL_WIDTH * 0.5
	var trail_reach := trail_half + TRAIL_BANK
	var trail_row_lo := FOOT_LENGTH - trail_reach
	var trail_row_hi := FOOT_LENGTH + SCARP_LENGTH + trail_reach
	var trail_px_lo := width * 0.5 - TRAIL_HALF_SPAN - trail_reach
	var trail_px_hi := width * 0.5 + TRAIL_HALF_SPAN + trail_reach

	var plateau_h: float = TerrainHeightmap.BASE_LEVEL + PLATEAU_HEIGHT
	var edge_row := (TerrainConfig.AREA_LENGTH - 1) * width
	var heights := PackedFloat32Array()
	heights.resize(width * STRIP_LENGTH)
	for row in STRIP_LENGTH:
		var centre := _centre_height(row)
		var relief := clampf(absf(centre - plateau_h) / RELIEF_FULL_AT, 0.0, 1.0)
		var detail_amp := lerpf(DETAIL_NOISE_AMPLITUDE, DETAIL_NOISE_SLOPE_AMPLITUDE, relief)
		var trail_row := row >= trail_row_lo and row <= trail_row_hi
		# Hub row 0 is 1 m from the map's last row.
		var join := smoothstep(0.0, float(JOIN_BLEND_LENGTH), float(row + 1))
		for px in width:
			var detail := detail_noise.get_noise_2d(px, row)
			var h := centre + wall_rise[px] \
				+ hill_noise.get_noise_2d(px, row) * HILL_NOISE_AMPLITUDE * relief \
				+ detail * detail_amp
			if trail_row and px >= trail_px_lo and px <= trail_px_hi:
				# Every leg in reach pulls the ground to its own height; where two legs meet at
				# a hairpin their heights are averaged by weight, so the turn has no step.
				var here := Vector2(px, row)
				var weight_sum := 0.0
				var rise_sum := 0.0
				var strongest := 0.0
				for i in trail.size() - 1:
					var a := trail[i]
					var b := trail[i + 1]
					var leg := Vector2(b.x - a.x, b.y - a.y)
					var t := clampf((here - Vector2(a.x, a.y)).dot(leg) / leg.length_squared(), 0.0, 1.0)
					var weight := 1.0 - smoothstep(trail_half, trail_reach, here.distance_to(Vector2(a.x, a.y) + leg * t))
					if weight > 0.0:
						weight_sum += weight
						rise_sum += weight * lerpf(a.z, b.z, t)
						strongest = maxf(strongest, weight)
				if strongest > 0.0:
					var bench := TerrainHeightmap.BASE_LEVEL + wall_rise[px] + rise_sum / weight_sum + detail * DETAIL_NOISE_AMPLITUDE
					h = lerpf(h, bench, strongest)
			if join < 1.0:
				h = lerpf(map_heights[edge_row + px], h, join)
			heights[row * width + px] = h
	print("TERRAIN_GEN: hub -- %dx%d strip, plateau at %.1f m, %d m scarp with a %d-leg trail, checksum %d (%d ms)" % [width, STRIP_LENGTH, plateau_h, SCARP_LENGTH, trail.size() - 1, hash(heights), Time.get_ticks_msec() - t0])
	return heights

## The [HEIGHT, CONTROL, COLOR] images for Terrain3D's import: the generated map's, with the hub's
## rows added below them. The hub is plain ground texture and neutral colour for now.
##
## Terrain3D stores whole regions: when AREA_WIDTH is not a multiple of `region_size`, every row is
## widened to the next multiple on its +X end (where Terrain3D would put the leftover anyway). The
## added pixels repeat the row's last height and are holes -- no ground drawn, no collision.
##
## On the low-X side every row first gets the mountain apron's MountainWalls.APRON_WIDTH pixels
## (real terrain, see MountainWalls.apron_maps): the generated map's pixel (0, 0) is then that
## far in +X from the corner Terrain3D reports (WorldGenerator adds it to heightmap_corner).
static func join_images(maps: Dictionary, hub_heights: PackedFloat32Array, region_size: int, master_seed: int) -> Array[Image]:
	var width := TerrainConfig.AREA_WIDTH
	var total_length := TerrainConfig.AREA_LENGTH + STRIP_LENGTH

	var height_bytes: PackedByteArray = (maps.heights as PackedFloat32Array).to_byte_array()
	height_bytes.append_array(hub_heights.to_byte_array())

	# Control pixels are the packed int's own bytes (Terrain3DUtil.as_float is a reinterpretation).
	var hub_control := PackedInt32Array()
	hub_control.resize(width * STRIP_LENGTH)
	hub_control.fill(TerrainHeightmap.pack_control_blend(TerrainConfig.GROUND_TEXTURE_ID, TerrainConfig.GROUND_TEXTURE_ID, 0.0))
	var control_bytes: PackedByteArray = (maps.control as Image).get_data()
	control_bytes.append_array(hub_control.to_byte_array())

	# Colour: white = no tint, alpha 0.5 = roughness left as it is.
	var color_row := PackedByteArray()
	color_row.resize(width * 4)
	color_row.fill(255)
	for px in width:
		color_row[px * 4 + 3] = 128
	var color_bytes: PackedByteArray = (maps.color as Image).get_data()
	for row in STRIP_LENGTH:
		color_bytes.append_array(color_row)

	var apron := MountainWalls.APRON_WIDTH
	if apron > 0:
		var apron_maps := MountainWalls.apron_maps(maps, master_seed)
		height_bytes = _join_columns((apron_maps.heights as PackedFloat32Array).to_byte_array(), apron, height_bytes, width, total_length)
		control_bytes = _join_columns((apron_maps.control as PackedInt32Array).to_byte_array(), apron, control_bytes, width, total_length)
		color_bytes = _join_columns(apron_maps.color, apron, color_bytes, width, total_length)
		width += apron
		# ... and the high-X side's apron after the map's columns.
		var right_maps := MountainWalls.apron_maps(maps, master_seed, 1)
		height_bytes = _join_columns(height_bytes, width, (right_maps.heights as PackedFloat32Array).to_byte_array(), apron, total_length)
		control_bytes = _join_columns(control_bytes, width, (right_maps.control as PackedInt32Array).to_byte_array(), apron, total_length)
		color_bytes = _join_columns(color_bytes, width, right_maps.color, apron, total_length)
		width += apron
		# ... and west of the low-X apron MountainWalls.WEST_EXTRA more columns: holes, except
		# where the village's shoulder stands (TerrainCastle.west_strip_maps).
		var west_maps := TerrainCastle.west_strip_maps(apron_maps.heights, apron, total_length)
		var west := MountainWalls.WEST_EXTRA
		height_bytes = _join_columns((west_maps.heights as PackedFloat32Array).to_byte_array(), west, height_bytes, width, total_length)
		control_bytes = _join_columns((west_maps.control as PackedInt32Array).to_byte_array(), west, control_bytes, width, total_length)
		color_bytes = _join_columns(west_maps.color, west, color_bytes, width, total_length)
		width += west
	# The north apron: TerrainCastle.LENGTH rows of mountain north of the map, as wide as map + aprons. They come
	# first in the image (row 0 = northmost), so the generated map's pixel (0, 0) is then that many
	# rows in +Z from the corner Terrain3D reports (WorldGenerator adds it to heightmap_corner).
	var castle := TerrainCastle.build_maps(height_bytes.slice(0, width * 4).to_float32_array(), color_bytes.slice(0, width * 4), width, master_seed)
	var castle_heights: PackedByteArray = (castle.heights as PackedFloat32Array).to_byte_array()
	castle_heights.append_array(height_bytes)
	height_bytes = castle_heights
	var castle_control: PackedByteArray = (castle.control as PackedInt32Array).to_byte_array()
	castle_control.append_array(control_bytes)
	control_bytes = castle_control
	var castle_color: PackedByteArray = castle.color
	castle_color.append_array(color_bytes)
	color_bytes = castle_color
	total_length += TerrainCastle.LENGTH
	var pad := (region_size - width % region_size) % region_size
	if pad > 0:
		var hole := PackedInt32Array([TerrainHeightmap.pack_control_blend(TerrainConfig.GROUND_TEXTURE_ID, TerrainConfig.GROUND_TEXTURE_ID, 0.0) | Terrain3DUtil.enc_hole(true)])
		height_bytes = _pad_rows(height_bytes, width, total_length, pad, PackedByteArray())
		control_bytes = _pad_rows(control_bytes, width, total_length, pad, hole.to_byte_array())
		color_bytes = _pad_rows(color_bytes, width, total_length, pad, PackedByteArray([255, 255, 255, 128]))
		print("TERRAIN_GEN: import padded from %d to %d px wide (%d px of holes on the +X side)" % [width, width + pad, pad])
	# The same for the length (AREA_LENGTH + STRIP_LENGTH): whole rows of holes added on the +Z end,
	# each repeating the heights of the last real row.
	var pad_rows := (region_size - total_length % region_size) % region_size
	if pad_rows > 0:
		var row_bytes := (width + pad) * 4
		var last_heights := height_bytes.slice(height_bytes.size() - row_bytes)
		var hole_row := PackedInt32Array()
		hole_row.resize(width + pad)
		hole_row.fill(TerrainHeightmap.pack_control_blend(TerrainConfig.GROUND_TEXTURE_ID, TerrainConfig.GROUND_TEXTURE_ID, 0.0) | Terrain3DUtil.enc_hole(true))
		var last_colors := color_bytes.slice(color_bytes.size() - row_bytes)
		for row in pad_rows:
			height_bytes.append_array(last_heights)
			control_bytes.append_array(hole_row.to_byte_array())
			color_bytes.append_array(last_colors)
		print("TERRAIN_GEN: import padded from %d to %d px long (%d rows of holes on the +Z end)" % [total_length, total_length + pad_rows, pad_rows])

	return [
		Image.create_from_data(width + pad, total_length + pad_rows, false, Image.FORMAT_RF, height_bytes),
		Image.create_from_data(width + pad, total_length + pad_rows, false, Image.FORMAT_RF, control_bytes),
		Image.create_from_data(width + pad, total_length + pad_rows, false, Image.FORMAT_RGBA8, color_bytes),
	]

## Two images of 4-byte pixels with the same number of rows, side by side: `left` first.
static func _join_columns(left: PackedByteArray, left_width: int, right: PackedByteArray, right_width: int, rows: int) -> PackedByteArray:
	var out := PackedByteArray()
	for row in rows:
		out.append_array(left.slice(row * left_width * 4, (row + 1) * left_width * 4))
		out.append_array(right.slice(row * right_width * 4, (row + 1) * right_width * 4))
	return out

## `bytes` (rows of `width` 4-byte pixels) with `pad` pixels added to the end of every row: copies
## of `fill` (one pixel), or of the row's own last pixel when `fill` is empty.
static func _pad_rows(bytes: PackedByteArray, width: int, rows: int, pad: int, fill: PackedByteArray) -> PackedByteArray:
	var row_bytes := width * 4
	var out := PackedByteArray()
	for row in rows:
		var row_end := (row + 1) * row_bytes
		out.append_array(bytes.slice(row * row_bytes, row_end))
		var pixel := fill if not fill.is_empty() else bytes.slice(row_end - 4, row_end)
		for i in pad:
			out.append_array(pixel)
	return out

## Where the player starts, as (px, height, pz) in heightmap-pixel space (pz counted from the
## generated map's row 0): the centre of the valley, SPAWN_INSET m onto the plateau from the
## trail's head.
static func spawn_pixel(hub_heights: PackedFloat32Array) -> Vector3:
	var px := int(TerrainConfig.AREA_WIDTH * 0.5)
	var row := FOOT_LENGTH + SCARP_LENGTH + SPAWN_INSET
	return Vector3(px, hub_heights[row * TerrainConfig.AREA_WIDTH + px], TerrainConfig.AREA_LENGTH + row)
