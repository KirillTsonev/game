## Ground texturing -- rewrites the terrain CONTROL MAP after the vegetation bakes (2026-09-27, v2).
##
## Static-only module (see terrain_gen.gd's header table): call as TerrainGroundPaint.paint(...).
## Must run AFTER GrassScatter.bake (reads its coverage + patch map) -- which itself runs after
## boulders/trees, so this can't happen in TerrainHeightmap.build_heightmap where the first control
## map (ground everywhere + road) is built and imported. Edits each Terrain3D region's control
## image in place and pushes it with data.update_maps(CONTROL) -- no re-import, instances untouched.
##
## How Terrain3D blends (docs: shader_design / texture_painting): the control map is PER VERTEX
## (1 m); each vertex holds base id, overlay id and a blend byte; a pixel mixes its 4 surrounding
## vertices bilinearly, sharpened by each texture's HEIGHT (albedo alpha) and blend_sharpness.
## So transitions look natural when (a) neighbouring vertices keep the SAME base/overlay pair and
## only the blend value varies, and (b) that blend varies gradually + randomly ("spray"), letting
## height blending carve the actual edge shape. v1 picked the top-2 of 8 weights per vertex, which
## swapped pairs between neighbours -> hard 1 m seams; it also used pure distance rings.
##
## v2 layout (field notes: correlate layers, clumped-with-gaps, noise-jittered edges, a transition
## material between rock and grass):
##   - ROAD vertices are kept exactly as TerrainRoad painted them.
##   - SOIL: Ground <-> Grass. Grass weight = the blade PATCH keep (GrassScatter.patch_keep -- the
##     exact function the GPU grass uses), so the grass texture lies under the grass blades.
##   - ROCKINESS: proximity to cliffs faces / cliff meshes / outcrops, boulders & erratics, and the
##     scree band, plus steep ground -- multiplied by two-scale noise so rock ground forms irregular
##     PATCHES that cluster near rocks with gaps between, not rings.
##   - ROCK TYPE per vertex by correlation + regional noise: RockFace (cliff cores, steep ground),
##     AerialRocks (moss -- shade from canopy / cliff shadow), RockyTrail (scree -- near scree and
##     boulders), RockyTerrain (scree with grass -- where the grass is), CoastSandRocks (cliff meets
##     grass -- flatter ground around cliffs).
##   - Vertex pair: open ground -> base Ground, overlay Grass, blend = grass weight.
##     Rocky ground -> base = its soil (Grass/Ground), overlay = its rock type, blend = rockiness.
##   - SPRAY: small-scale noise added to every blend value, strongest mid-transition.
## These layers are ground only -- the cliff MESHES keep their own materials.
class_name TerrainGroundPaint
extends RefCounted

## Texture ids -- must match TEXTURES_BY_ID in tools/assign_flat_textures.gd.
const GROUND_ID := 0 ## TerrainConfig.GROUND_TEXTURE_ID
const ROAD_ID := 1 ## TerrainRoad.ROAD_TEXTURE_ID
const ROCK_FACE_ID := 2 ## rock_face_03 -- bare rock ground
const COAST_SAND_ROCKS_ID := 3 ## coast_sand_rocks_02 -- cliff meets grass
const AERIAL_ROCKS_ID := 4 ## aerial_rocks_04 -- mossy rock ground
const GRASS_ID := 5 ## grass_ground
const ROCKY_TRAIL_ID := 6 ## rocky_trail_02 -- scree
const ROCKY_TERRAIN_ID := 7 ## rocky_terrain_03 -- scree with grass
const ROCK_TYPES: Array[int] = [ROCK_FACE_ID, AERIAL_ROCKS_ID, ROCKY_TRAIL_ID, ROCKY_TERRAIN_ID, COAST_SAND_ROCKS_ID]

## Terrain material: height-blend sharpness (0..1; Terrain3D default 0.5 = exponent ~36, very hard
## edges). Lower = softer, more gradual transitions.
const BLEND_SHARPNESS := 0.25

## -- Grass texture margin: the texture's patch test uses coverage + this (noise units; patches
## are ~5 m features, so 0.1 ~ roughly +0.5-1 m of texture around each blade patch), so the grass
## texture reaches a bit past the blades and reads through them. Faded out where coverage ~0
## (road, bare rock) so it never spreads onto grass-free ground. 0 = texture exactly = blades.
const GRASS_TEXTURE_GROW := 0.12

## -- Rock proximity (m over which each source's influence falls to 0) --
const CLIFF_REACH := 7.0 ## from escarpment faces / cliff-mesh footprints / outcrops
const BOULDER_REACH := 2.5 ## from each boulder / erratic footprint
const SCREE_REACH := 3.0 ## from the scree band along cliff feet
const BOULDER_STRENGTH := 0.85
const CLIFF_MIN_STEP := 1.5 ## m -- escarpments lower than this don't count as rock sources
const FACE_MAX_HALF_WIDTH := 3.0 ## m -- cap on edge_softness used as the face half-width
const FACE_STAMP_STEP := 0.5
## -- Rockiness = smoothstep(ROCKY_LO, ROCKY_HI, prox * (BASE + BIG * big_noise) + SMALL * (small_noise - 0.5)) --
const ROCK_BIG_FREQ := 0.07 ## ~14 m clumps
const ROCK_SMALL_FREQ := 0.25 ## ~4 m ragged edges
const ROCKY_BASE := 0.45
const ROCKY_BIG := 0.85
const ROCKY_SMALL := 0.35
const ROCKY_LO := 0.35
const ROCKY_HI := 0.75
const ROCKY_MIN := 0.03 ## below this a vertex is plain soil
const STEEP_NY_FULL := 0.62 ## normal.y at/below this -> fully steep (bare rock likely)
const STEEP_NY_NONE := 0.82 ## at/above this -> not steep
const FLAT_NY := 0.9 ## CoastSandRocks favours ground flatter than this

## -- Rock type selection --
const TYPE_NOISE_FREQ := 0.045 ## ~22 m regions: which rock type dominates locally
const MOSS_SHADE_LO := 0.3
const MOSS_SHADE_HI := 0.7

## -- Spray: blend += (noise - 0.5) * SPRAY_AMP * (SPRAY_FLOOR + 4 b (1 - b) * (1 - SPRAY_FLOOR)) --
const SPRAY_FREQ := 0.6 ## ~1.7 m
const SPRAY_AMP := 0.45
const SPRAY_FLOOR := 0.3

## Last run's stats, for debugging.
static var last_stats: Dictionary = {}

static func paint(parent_node: Node, terrain: Terrain3D, maps: Dictionary, corner: Vector3, rng: RandomNumberGenerator) -> void:
	var t0 := Time.get_ticks_msec()
	var width := TerrainConfig.AREA_WIDTH
	var length := TerrainConfig.AREA_LENGTH
	var n := width * length
	if GrassScatter.density_image == null or GrassScatter.patch_image == null:
		push_warning("GROUND_PAINT: no grass bake -- control map left as built")
		return
	var heights: PackedFloat32Array = maps.heights

	# -- Distance fields (m, capped) to the three rock-source families --
	var cliff_d := _new_field(n, CLIFF_REACH)
	var faces := 0
	for f in maps.cliff_features:
		if not f.has("step_height") or absf(float(f.step_height)) < CLIFF_MIN_STEP:
			continue
		faces += 1
		var perp := Vector2(f.perp_x, f.perp_z)
		var axis := Vector2(f.axis_x, f.axis_z)
		var half_len: float = f.half_len
		var center: Vector2 = f.center
		var face_r := minf(float(f.edge_softness), FACE_MAX_HALF_WIDTH)
		var t := -half_len
		while t <= half_len:
			var nt := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve := float(f.curve_amplitude) * lerpf(sin(nt * PI * float(f.curve_frequency) + float(f.curve_phase)), sin(nt * PI * float(f.curve_frequency2) + float(f.curve_phase2)), float(f.curve_weight2))
			var p := center + axis * t + perp * curve
			GrassScatter._stamp_circle(cliff_d, width, length, p.x, p.y, face_r, CLIFF_REACH)
			t += FACE_STAMP_STEP
	var rects := UnderstoryScatter._build_keep_rects(maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles)
	for kr in rects:
		GrassScatter._stamp_rect(cliff_d, width, length, kr, CLIFF_REACH)
	for oc in maps.outcrop_plan:
		GrassScatter._stamp_circle(cliff_d, width, length, float(oc.px), float(oc.pz), float(oc.radius), CLIFF_REACH)
	var boulder_d := _new_field(n, BOULDER_REACH)
	for c in RockScatter.rock_keep_circles:
		GrassScatter._stamp_circle(boulder_d, width, length, c.x, c.y, c.z, BOULDER_REACH)
	var scree_d := _new_field(n, SCREE_REACH)
	var scree_circles: Array[Vector3] = []
	GrassScatter._add_scree_band_circles(maps.cliff_features, scree_circles)
	for c in scree_circles:
		GrassScatter._stamp_circle(scree_d, width, length, c.x, c.y, c.z, SCREE_REACH)
	var t_dist := Time.get_ticks_msec() - t0

	# -- Shade (moss), same fields the understory uses --
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var cliff_shade := UnderstoryScatter._build_cliff_shade_grid(gw, gl, maps.cliff_features, UnderstoryScatter._sun_to_dir(parent_node))

	# -- Noise fields (C++ get_image, one byte per pixel) --
	var big_n := GrassScatter._noise_bytes(rng.randi(), ROCK_BIG_FREQ, width, length)
	var small_n := GrassScatter._noise_bytes(rng.randi(), ROCK_SMALL_FREQ, width, length)
	var type_a := GrassScatter._noise_bytes(rng.randi(), TYPE_NOISE_FREQ, width, length)
	var type_b := GrassScatter._noise_bytes(rng.randi(), TYPE_NOISE_FREQ, width, length)
	var spray_n := GrassScatter._noise_bytes(rng.randi(), SPRAY_FREQ, width, length)

	var coverage_bytes := GrassScatter.density_image.get_data() # RGBA8, R = coverage
	var old_control: PackedByteArray = (maps.control as Image).get_data() # FORMAT_RF: uint32 bits
	var control := PackedInt32Array()
	control.resize(n)
	var counts := {"road": 0, "soil": 0, "rock": 0}
	var type_counts := {}
	for id in ROCK_TYPES:
		type_counts[id] = 0
	var grass_sum := 0.0
	var w1 := width - 1
	var l1 := length - 1
	for pz in length:
		var zm := maxi(pz - 1, 0)
		var zp := mini(pz + 1, l1)
		for px in width:
			var i := pz * width + px
			var old := old_control.decode_u32(i * 4)
			if Terrain3DUtil.get_base(old) == ROAD_ID or Terrain3DUtil.get_overlay(old) == ROAD_ID:
				control[i] = old
				counts.road += 1
				continue

			# Grass = the blades' own patch keep, softened over +-0.5 m (5 taps) so the 1 m vertex
			# grid doesn't stair-step the patch outlines.
			var cov := coverage_bytes[i * 4] / 255.0
			cov += GRASS_TEXTURE_GROW * smoothstep(0.0, 0.1, cov) # texture margin (blades unaffected)
			var g := 0.0
			if cov > 0.0:
				g = (2.0 * GrassScatter.patch_keep(px, pz, cov)
					+ _patch_keep_half(px * 2 - 1, pz * 2, cov, width, length)
					+ _patch_keep_half(px * 2 + 1, pz * 2, cov, width, length)
					+ _patch_keep_half(px * 2, pz * 2 - 1, cov, width, length)
					+ _patch_keep_half(px * 2, pz * 2 + 1, cov, width, length)) / 6.0
			grass_sum += g
			var spray := spray_n[i] / 255.0 - 0.5

			# Rockiness.
			var xm := maxi(px - 1, 0)
			var xp := mini(px + 1, w1)
			var dx := (heights[pz * width + xp] - heights[pz * width + xm]) / float(xp - xm)
			var dz := (heights[zp * width + px] - heights[zm * width + px]) / float(zp - zm)
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			var steep := 1.0 - smoothstep(STEEP_NY_FULL, STEEP_NY_NONE, ny)
			var p_cliff := 1.0 - smoothstep(0.0, CLIFF_REACH, cliff_d[i])
			var p_boulder := (1.0 - smoothstep(0.0, BOULDER_REACH, boulder_d[i])) * BOULDER_STRENGTH
			var p_scree := 1.0 - smoothstep(0.0, SCREE_REACH, scree_d[i])
			var prox := maxf(maxf(p_cliff, p_boulder), p_scree)
			var nb := big_n[i] / 255.0
			var rocky := 0.0
			if prox > 0.0:
				rocky = smoothstep(ROCKY_LO, ROCKY_HI, prox * (ROCKY_BASE + ROCKY_BIG * nb) + ROCKY_SMALL * (small_n[i] / 255.0 - 0.5))
			rocky = maxf(rocky, steep * (0.6 + 0.4 * nb))

			if rocky < ROCKY_MIN:
				counts.soil += 1
				control[i] = TerrainHeightmap.pack_control_blend(GROUND_ID, GRASS_ID, _spray(g, spray))
				continue

			# Rock type: correlated weights + regional noise, highest wins.
			var ta := type_a[i] / 255.0
			var tb := type_b[i] / 255.0
			var shade := maxf(UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz), UnderstoryScatter._grid_sample(cliff_shade, gw, gl, px, pz))
			var flat := smoothstep(STEEP_NY_NONE, FLAT_NY, ny)
			var core := 1.0 - smoothstep(0.0, 2.5, cliff_d[i])
			var w_face := 0.3 + 1.1 * core + 1.0 * steep + 0.5 * ta
			var w_moss := 1.7 * smoothstep(MOSS_SHADE_LO, MOSS_SHADE_HI, shade + 0.25 * (tb - 0.5)) + 0.2 * tb
			var w_trail := 1.1 * p_scree + 0.8 * p_boulder / BOULDER_STRENGTH + 0.5 * (1.0 - ta)
			var w_terr := 0.4 + 0.7 * g + 0.6 * tb
			var w_coast := flat * (0.5 + 1.2 * p_cliff * (1.0 - core)) + 0.5 * (1.0 - tb)
			var rock_id := ROCK_FACE_ID
			var best := w_face
			if w_moss > best:
				best = w_moss
				rock_id = AERIAL_ROCKS_ID
			if w_trail > best:
				best = w_trail
				rock_id = ROCKY_TRAIL_ID
			if w_terr > best:
				best = w_terr
				rock_id = ROCKY_TERRAIN_ID
			if w_coast > best:
				rock_id = COAST_SAND_ROCKS_ID
			type_counts[rock_id] += 1
			counts.rock += 1
			var soil := GRASS_ID if g >= 0.5 else GROUND_ID
			control[i] = TerrainHeightmap.pack_control_blend(soil, rock_id, _spray(rocky, spray))
	var t_px := Time.get_ticks_msec() - t0

	# -- Write into each region's control image, then push to the GPU --
	var data: Terrain3DData = terrain.get_data()
	var rs := terrain.get_region_size()
	var regions_written := 0
	for loc: Vector2i in data.get_region_locations():
		var region: Terrain3DRegion = data.get_region(loc)
		if region == null:
			continue
		var img: Image = region.get_control_map()
		if img == null:
			continue
		var bytes := img.get_data()
		var ox := loc.x * rs - int(corner.x) # region pixel (0,0) in heightmap-pixel space
		var oz := loc.y * rs - int(corner.z)
		var wrote := false
		for lz in rs:
			var pz := oz + lz
			if pz < 0 or pz >= length:
				continue
			for lx in rs:
				var px := ox + lx
				if px < 0 or px >= width:
					continue
				bytes.encode_u32((lz * rs + lx) * 4, control[pz * width + px])
				wrote = true
		if wrote:
			region.set_control_map(Image.create_from_data(rs, rs, false, Image.FORMAT_RF, bytes))
			regions_written += 1
	data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
	if terrain.material:
		terrain.material.set_shader_param(&"blend_sharpness", BLEND_SHARPNESS)

	var names := {ROCK_FACE_ID: "rock_face", AERIAL_ROCKS_ID: "aerial(moss)", ROCKY_TRAIL_ID: "rocky_trail", ROCKY_TERRAIN_ID: "rocky_terrain", COAST_SAND_ROCKS_ID: "coast_sand"}
	var parts := PackedStringArray()
	for id in ROCK_TYPES:
		parts.append("%s %d" % [names[id], type_counts[id]])
	last_stats = {"counts": counts, "types": type_counts}
	print("GROUND_PAINT v2: %.1f%% soil (mean grass %.2f), %.1f%% rocky, %.1f%% road; rock vertices by type: %s" % [
		100.0 * counts.soil / n, grass_sum / maxf(1.0, n - counts.road), 100.0 * counts.rock / n, 100.0 * counts.road / n, ", ".join(parts)])
	print("GROUND_PAINT v2: sources %d escarpment face(s), %d cliff-mesh rect(s), %d outcrop(s), %d boulder(s), %d scree pt(s); %d region(s) written; blend_sharpness %.2f; timing dist %d ms, pixels %d ms, total %d ms" % [
		faces, rects.size(), maps.outcrop_plan.size(), RockScatter.rock_keep_circles.size(), scree_circles.size(), regions_written, BLEND_SHARPNESS, t_dist, t_px - t_dist, Time.get_ticks_msec() - t0])

static func _new_field(n: int, cap: float) -> PackedFloat32Array:
	var f := PackedFloat32Array()
	f.resize(n)
	f.fill(cap)
	return f

## patch keep at a patch-map TEXEL (0.5 m units) -- used for the +-0.5 m softening taps.
static func _patch_keep_half(tx: int, tz: int, c: float, width: int, length: int) -> float:
	tx = clampi(tx, 0, width * GrassScatter.PATCH_RES - 1)
	tz = clampi(tz, 0, length * GrassScatter.PATCH_RES - 1)
	var nv := smoothstep(GrassScatter.PATCH_N_LO, GrassScatter.PATCH_N_HI, GrassScatter.patch_image.get_pixel(tx, tz).r)
	return smoothstep(nv, nv + 2.0 * GrassScatter.PATCH_EDGE, c)

## "Spray": jitter a blend value with small-scale noise, strongest mid-transition.
static func _spray(b: float, s: float) -> float:
	return clampf(b + s * SPRAY_AMP * (SPRAY_FLOOR + 4.0 * b * (1.0 - b) * (1.0 - SPRAY_FLOOR)), 0.0, 1.0)
