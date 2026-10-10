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
##
## v3 (2026-10-10, Kirill: the textures "all look like they're following a grid"): measured on one
## seed, 9.3 % of vertex-to-vertex edges showed 25 % or more of a texture the other side did not
## hold. v2 mixed up to four textures by weight everywhere but a vertex holds two, so it chose
## the pair by hard cuts (litter vs bare soil by the larger, the soil under a rock by a
## threshold) and only dimmed the seams. Now the ground is PATCHES of one texture each:
##   - the weights are as before (grass / litter / soil, rockiness, the rock type); each vertex
##     takes the texture with the largest one, and a majority filter removes specks;
##   - the border pass (_blend_band) gives every vertex within BORDER_FADE m of a border the pair
##     (its texture, the one across), 50/50 at the border. Both sides hold the same pair, so the
##     edge is drawn by the shares, the spray and the textures' relief.
## Not possible this way: wide areas of a partial mix (say 30 % stones in grass), and a soft
## edge where three textures meet. Tried first the same day and dropped: keeping the weights,
## taking the two largest per vertex and fading a texture out where a neighbour does not hold it
## -- three and four textures mix over most of the map, so the fades fought each other on 30 %
## of the vertices and the count of visible steps did not fall.
## What v2's list above says about pairs and seam fades no longer applies.
## These layers are ground only -- the cliff MESHES keep their own materials.
class_name TerrainGroundPaint
extends RefCounted

## Texture ids -- must match TEXTURES_BY_ID in tools/assign_flat_textures.gd.
const GROUND_ID := 0 ## TerrainConfig.GROUND_TEXTURE_ID
const ROAD_ID := 1 ## TerrainRoad.ROAD_TEXTURE_ID
const ROCK_FACE_ID := 2 ## rock_face_03 -- bare rock ground
const COAST_SAND_ROCKS_ID := 3 ## coast_sand_rocks_02 -- cliff meets grass
const AERIAL_ROCKS_ID := 4 ## aerial_rocks_04 -- mossy rock ground
const GRASS_ID := 5 ## grass002 (ambientCG)
const ROCKY_TRAIL_ID := 6 ## rocky_trail_02 -- scree
const ROCKY_TERRAIN_ID := 7 ## rocky_terrain_03 -- scree with grass
const PINE_LITTER_ID := 8 ## pine_litter -- needle litter under canopy (baked from a floor scan)

## -- Open ground (2026-10-01): GRASS is the default surface. Before, Ground (bright tan soil) was
## the default and Grass was painted only under the blade patches, so every gap between patches
## read as a bright empty hole (docs/forest_floor_plan.md). Now a soil vertex is base Grass with
## Ground as the overlay, blend = "bare":
##   - the road verge: 1 within BARE_ROAD_CLEAR m of a road vertex (their base is Ground, so the
##     pair swap there shows the same texture), 0 from BARE_ROAD_REACH m;
##   - sparse worn patches: GrassScatter.worn, at most BARE_WORN_MAX.
## The header's "SOIL: Ground <-> Grass" description and GRASS_TEXTURE_GROW predate this.
## Verge (user 2026-10-01: no uniform soil strip along the road): worn-to-soil stretches where the
## verge noise is above BARE_VERGE_LO..HI, grass up to the stones elsewhere. Road vertices get the
## matching base (Ground / Grass) so the pair swap at the road edge shows the same texture.
## 2026-10-10: the verge is GrassScatter.verge_soil now (see VERGE_* there); the BARE_VERGE_* and
## BARE_ROAD_* constants that described the strip are gone.
## 2026-10-02: the worn-patch noise is GrassScatter's (GrassScatter.worn / WORN_*), so the grass
## thins out over the same patches; only the blend cap is set here.
const BARE_WORN_MAX := 0.8
const BARE_NY_FULL := 0.8 ## normal.y at/below this (~37 deg) -> fully bare
const BARE_NY_NONE := 0.93 ## at/above this (~21 deg) -> slope adds no bare soil
const BARE_CLIFF_CLEAR := 1.5 ## m from a cliff face / cliff-mesh footprint / outcrop: fully bare within this
const BARE_CLIFF_REACH := 5.0 ## ...and no effect from here
## -- Grass colour match + baked grounding (2026-10-02, docs/forest_floor_plan.md steps 1 + 5) --
## GRASS_TINT: Terrain3D's per-texture albedo multiplier (linear, no sRGB conversion in the shader)
## for the Grass texture, set at runtime in paint() -- terrain_assets.tres keeps white. Grass002
## averages linear ~(0.040, 0.070, 0.017) (tools/assign_flat_textures.gd diag_average_color):
## yellower and ~5x brighter than the blades' mean albedo (base_color x their root-to-tip AO
## ~ (0.0016, 0.013, 0.0003)). White = off. The value reaches the shader as written (checked:
## _texture_color_array holds it unconverted).
## First try (0.25, 0.48, 0.16) -- green down to the blade-tip albedo -- read PITCH BLACK in-game
## (Kirill): the scene is moonlit and the colour grade remaps by brightness, so halving the
## ground's albedo crushes it; matching albedo numbers is the wrong target. Now mostly a hue
## shift (less red and blue = greener, less yellow) with ~15 % darkening. Tune by eye.
## 2026-10-02 (Kirill, tuning panel): lightened from (0.62, 0.85, 0.55) so the lantern reads on it.
const GRASS_TINT := Color(0.688, 0.938, 0.612)
## Ground under the tall blade patches is darkened through the terrain COLOR map (multiplied into
## albedo, 1 px = 1 m): x (1 - PATCH_SHADE) under a full patch, following the same softened patch
## keep the litter blend uses, so the shade fades out over ~1 m at the outline. This is the
## occlusion the blades would cast on the soil; it survives distance and the painterly pass.
## Not shaded: the short-grass gaps, road vertices. Not done: shade under ferns / bushes
## (UnderstoryScatter keeps no plant positions).
const PATCH_SHADE := 0.35 ## was 0.45 with the first tint (pitch black together), then 0.25
## The short-grass gaps get a lighter shade (where grass_cull.glsl's SHORT_COVER_* gate lets short
## blades grow). Kirill, after the hue match: the blades, the short ones most, blended into the
## texture -- same hue AND same value. The separation is now by value: darker ground, lighter
## blade tops (short_tip_blend in grass_blade.gdshader).
const GAP_SHADE := 0.18
const ROCK_TYPES: Array[int] = [ROCK_FACE_ID, AERIAL_ROCKS_ID, ROCKY_TRAIL_ID, ROCKY_TERRAIN_ID, COAST_SAND_ROCKS_ID]

## -- Litter under canopy (2026-10-01, docs/forest_floor_plan.md step 2) --
## Litter is a patch under each tree (user decision 2026-10-01; v1 was a stand-wide carpet from
## canopy cover): full within LITTER_TREE_CORE m x tree scale of the trunk, gone LITTER_TREE_FADE m
## further out, the edge moved +-LITTER_EDGE_NOISE/2 m by noise. Close trees merge into one patch.
## Then cut by slope, cliffs and the road (constants below). Soil vertices then use
## one of three pairs, chosen so neighbours with different pairs show the same texture at the swap:
##   litter >= LITTER_FULL          base PineLitter, overlay Grass,      blend = grass
##   litter > grass (the ramp)      base Ground,     overlay PineLitter, blend = litter / LITTER_FULL
##   otherwise                      base Ground,     overlay Grass,      blend = grass
## Only a grass patch crossing the ramp swaps overlays mid-blend; both sides are faded there.
const LITTER_TREE_CORE := 1.6
const LITTER_TREE_FADE := 2.2
const LITTER_EDGE_NOISE := 1.6
## Slope + cliff cuts (user screenshot 2026-10-01: litter on a steep bank, stretched by the
## top-down projection and showing through the rock texture as its "soil" up to a cliff mesh).
## normal.y at/below NY_NONE (~37 deg) -> no litter, at/above NY_FULL (~23 deg) -> unaffected;
## none within CLIFF_CLEAR m of a cliff face / cliff-mesh footprint / outcrop, full from CLIFF_REACH.
const LITTER_NY_NONE := 0.8
const LITTER_NY_FULL := 0.92
const LITTER_CLIFF_CLEAR := 0.5
const LITTER_CLIFF_REACH := 3.0
## Strays (2026-10-01): litter away from the trunks, only where nearby trees can supply it
## (supply = canopy cover between SUPPLY_LO and SUPPLY_HI). All go through the cuts above.
##   collar  -- within COLLAR_REACH m of a boulder / stump / log: full on its uphill side, x COLLAR_SIDE elsewhere
##   hollow  -- concave ground (ravine floors, gullies, dug-out features): laplacian CURV_LO..CURV_HI
##   drift   -- noise blobs in and beside stands (own, lower supply band)
const LITTER_SUPPLY_LO := 0.3
const LITTER_SUPPLY_HI := 0.6
const LITTER_COLLAR_REACH := 1.4
const LITTER_COLLAR_SIDE := 0.5
const LITTER_UPHILL_STEP := 1.2
const LITTER_CURV_LO := 0.05
const LITTER_CURV_HI := 0.12
const LITTER_DRIFT_LO := 0.66
const LITTER_DRIFT_HI := 0.8
const LITTER_DRIFT_SUPPLY_LO := 0.15
const LITTER_DRIFT_SUPPLY_HI := 0.45
const LITTER_FULL := 0.85
const LITTER_MIN := 0.02
## Road vertices keep their own pair (Ground + Road), so full litter right beside them is a pair
## swap between two unlike textures: a blocky, straight 1 m edge (user screenshot 2026-10-01).
## Litter is 0 within LITTER_ROAD_CLEAR m of a road vertex and back to full at LITTER_ROAD_REACH,
## which puts the verge on the Ground/PineLitter ramp pair instead.
const LITTER_ROAD_CLEAR := 1.0
const LITTER_ROAD_REACH := 6.0

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
## 2026-09-29 (Kirill, screenshot: "the application of different additional textures is too
## angular and looks artificial"): the rock patches traced their sources' shapes -- straight edges
## and corners around cliff-mesh RECTANGLES, little squares around boulders -- because the
## ramp was narrow (0.35-0.75) with little small-scale noise, the proximity fields were read at
## the exact pixel (their iso-lines ARE the rect/circle shapes), and tiny patches of a few 1 m
## vertices render as squares/diamonds. Now: wider ramp + more ragged noise, domain-warped
## proximity lookup (ROCK_WARP_*), and a post-pass that fades rock-type seams and isolated rock
## vertices (ROCK_TYPE_SEAM_FADE / ROCK_ISLAND_*). Was SMALL 0.35, LO 0.35, HI 0.75.
const ROCKY_SMALL := 0.5
const ROCKY_LO := 0.25
const ROCKY_HI := 0.85
## Domain warp: the proximity fields are sampled at a noise-offset position (+-ROCK_WARP_AMP m,
## features ~1/ROCK_WARP_FREQ m), so rect/circle iso-lines become irregular blobs.
const ROCK_WARP_AMP := 3.5
const ROCK_WARP_FREQ := 0.09
## v3 (2026-10-10, see the header). ROAD_MARK: a road vertex in the per-vertex texture map.
## BORDER_FADE: metres from a border over which the texture across it fades out (larger = softer,
## wider edges). BORDER_RADIUS: how far the search for a border looks, in vertices (at least
## BORDER_FADE + 0.5). THIRD_FADE: metres from a third texture within which the blend is held
## back. DOM_MODE_RADIUS / DOM_MODE_PASSES: the majority filter's window half-size (vertices) and its
## passes (larger / more = fewer small patches, rounder shapes).
const ROAD_MARK := 255
const BORDER_FADE := 2.5
const BORDER_RADIUS := 3
const THIRD_FADE := 2.0
const DOM_MODE_RADIUS := 2
const DOM_MODE_PASSES := 2
const ROCKY_MIN := 0.03 ## below this a vertex is plain soil
## The band of scree across the mountain's foot line (see paint): m up the rock, m out into the
## valley, and how far noise moves each pixel's place in it. The mountain's colour fades out
## across the same band.
const MOUNTAIN_SCREE_IN := 5.0
const MOUNTAIN_SCREE_OUT := 7.0
const MOUNTAIN_SCREE_JITTER := 2.0
const STEEP_NY_FULL := 0.62## normal.y at/below this -> fully steep (bare rock likely)
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
	var cliff_circles := PackedFloat64Array() # stamped together on worker threads (GrassScatter.stamp_circles)
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
			cliff_circles.append_array(PackedFloat64Array([p.x, p.y, face_r]))
			t += FACE_STAMP_STEP
	var rects := UnderstoryScatter._build_keep_rects(maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles)
	for kr in rects:
		GrassScatter._stamp_rect(cliff_d, width, length, kr, CLIFF_REACH)
	for oc in maps.outcrop_plan:
		cliff_circles.append_array(PackedFloat64Array([float(oc.px), float(oc.pz), float(oc.radius)]))
	cliff_d = GrassScatter.stamp_circles(cliff_d, width, length, cliff_circles, CLIFF_REACH)
	# The rock band along the edge where the mountain wall begins (2026-10-08): painted like a cliff's foot.
	MountainWalls.stamp_rock_distance(cliff_d, width, length, CLIFF_REACH)
	var boulder_d := _new_field(n, BOULDER_REACH)
	boulder_d = GrassScatter.stamp_circles(boulder_d, width, length, GrassScatter.pack_circles(RockScatter.rock_keep_circles), BOULDER_REACH)
	var scree_d := _new_field(n, SCREE_REACH)
	var scree_circles: Array[Vector3] = []
	GrassScatter._add_scree_band_circles(maps.cliff_features, scree_circles)
	scree_d = GrassScatter.stamp_circles(scree_d, width, length, GrassScatter.pack_circles(scree_circles), SCREE_REACH)
	var t_dist := Time.get_ticks_msec() - t0

	# -- Shade (moss), same fields the understory uses --
	var gw := int(ceil(float(width) / UnderstoryScatter.CELL)) + 1
	var gl := int(ceil(float(length) / UnderstoryScatter.CELL)) + 1
	var canopy := UnderstoryScatter._build_canopy_grid(gw, gl)
	var cliff_shade := UnderstoryScatter._build_cliff_shade_grid(gw, gl, maps.cliff_features, UnderstoryScatter._sun_to_dir(parent_node))

	# -- Noise fields (C++ get_image, one byte per pixel) --
	# Seeds drawn in this fixed order, images rendered together on worker threads (2026-10-05).
	# 2026-09-29 domain warp -- drawn AFTER the existing noise seeds so those stay as they were.
	var noise_specs: Array = []
	for freq: float in [ROCK_BIG_FREQ, ROCK_SMALL_FREQ, TYPE_NOISE_FREQ, TYPE_NOISE_FREQ, SPRAY_FREQ, ROCK_WARP_FREQ, ROCK_WARP_FREQ]:
		noise_specs.append([GrassScatter._noise(rng.randi(), freq), width, length])
	var noise_images := GrassScatter.noise_images_parallel(noise_specs)
	var big_n: PackedByteArray = (noise_images[0] as Image).get_data()
	var small_n: PackedByteArray = (noise_images[1] as Image).get_data()
	var type_a: PackedByteArray = (noise_images[2] as Image).get_data()
	var type_b: PackedByteArray = (noise_images[3] as Image).get_data()
	var spray_n: PackedByteArray = (noise_images[4] as Image).get_data()
	var warp_x: PackedByteArray = (noise_images[5] as Image).get_data()
	var warp_z: PackedByteArray = (noise_images[6] as Image).get_data()
	var litter_ok := terrain.get_assets() != null and terrain.get_assets().get_texture_asset(PINE_LITTER_ID) != null
	if not litter_ok:
		print("GROUND_PAINT: texture id %d (PineLitter) not registered -- no litter painted; run fix_textures() in tools/assign_flat_textures.gd" % PINE_LITTER_ID)
	var litter_full := 0
	var litter_ramp := 0

	var coverage_bytes := GrassScatter.density_image.get_data() # RGBA8, R = coverage
	var worn_bytes := GrassScatter.worn
	if worn_bytes.size() != n:
		worn_bytes = PackedByteArray()
		worn_bytes.resize(n)
	var verge_bytes := GrassScatter.verge_soil
	if verge_bytes.size() != n:
		verge_bytes = PackedByteArray()
		verge_bytes.resize(n)
	var old_control: PackedByteArray = (maps.control as Image).get_data() # FORMAT_RF: uint32 bits
	# Distance to the road's painted vertices: litter fades out toward them (LITTER_ROAD_*).
	var road_d := _new_field(n, LITTER_ROAD_REACH)
	# Distance to stumps / logs, for the litter collar (boulders: boulder_d above).
	var dead_d := _new_field(n, LITTER_COLLAR_REACH)
	if litter_ok:
		dead_d = GrassScatter.stamp_circles(dead_d, width, length, GrassScatter.pack_circles(DeadfallScatter.deadfall_keep_circles), LITTER_COLLAR_REACH)
	# Distance past each tree's litter core (0 inside it).
	var tree_d := _new_field(n, LITTER_TREE_FADE + LITTER_EDGE_NOISE)
	if litter_ok:
		var tree_circles := PackedFloat64Array()
		for tp in TreeScatter.tree_points:
			tree_circles.append_array(PackedFloat64Array([tp.x, tp.y, LITTER_TREE_CORE * tp.z]))
		tree_d = GrassScatter.stamp_circles(tree_d, width, length, tree_circles, LITTER_TREE_FADE + LITTER_EDGE_NOISE)
	var bare_sum := 0.0
	# Always built: the road distance also drives the bare verge (BARE_ROAD_*).
	var road_circles := PackedFloat64Array()
	for pz in length:
		for px in width:
			var c := old_control.decode_u32((pz * width + px) * 4)
			if ((c >> 27) & 0x1F) == ROAD_ID or ((c >> 22) & 0x1F) == ROAD_ID: # base / overlay bits, see _paint_band
				road_circles.append_array(PackedFloat64Array([px, pz, 0.0]))
	road_d = GrassScatter.stamp_circles(road_d, width, length, road_circles, LITTER_ROAD_REACH)
	var control := PackedInt32Array()
	control.resize(n)
	# Colour-map multiplier per vertex, 255 = unchanged (PATCH_SHADE).
	var patch_shade := PackedByteArray()
	patch_shade.resize(n)
	patch_shade.fill(255)
	var counts := {"road": 0, "soil": 0, "rock": 0}
	var type_counts := {}
	for id in ROCK_TYPES:
		type_counts[id] = 0
	var grass_sum := 0.0
	var t_prep := Time.get_ticks_msec() - t0
	# Main per-vertex pass, in row bands on the engine's worker threads (2026-10-05: it was 740 ms
	# on the main thread). A vertex only reads the shared fields and writes its own slot, so the
	# result is the same as the single loop's -- see _paint_band.
	var bands := ceili(float(length) / PAINT_BAND_ROWS)
	var band_out: Array = []
	band_out.resize(bands)
	# The patch map as bytes + GrassScatter.patch_keep's smoothstep of each byte value. The value
	# goes through a float32 first because that is what Image.get_pixel() returns for it.
	var byte_as_f32 := PackedFloat32Array()
	byte_as_f32.resize(256)
	var patch_nv := PackedFloat64Array()
	patch_nv.resize(256)
	for v in 256:
		byte_as_f32[v] = v / 255.0
		patch_nv[v] = smoothstep(GrassScatter.PATCH_N_LO, GrassScatter.PATCH_N_HI, byte_as_f32[v])
	var ctx := {
		"width": width, "length": length, "heights": heights, "old_control": old_control,
		"coverage_bytes": coverage_bytes, "worn_bytes": worn_bytes, "verge_bytes": verge_bytes,
		"big_n": big_n, "small_n": small_n, "type_a": type_a, "type_b": type_b, "spray_n": spray_n,
		"warp_x": warp_x, "warp_z": warp_z,
		"cliff_d": cliff_d, "boulder_d": boulder_d, "scree_d": scree_d, "road_d": road_d,
		"dead_d": dead_d, "tree_d": tree_d,
		"canopy": canopy, "cliff_shade": cliff_shade, "gw": gw, "gl": gl, "litter_ok": litter_ok,
		"patch_bytes": GrassScatter.patch_image.get_data(), "patch_nv": patch_nv,
		"out": band_out, "mutex": Mutex.new(),
	}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_paint_band.bind(ctx), bands, -1, true))
	control.clear()
	patch_shade.clear()
	# Per vertex, from the bands: its largest texture (ROAD_MARK = a road vertex, packed in control).
	var dom := PackedByteArray()
	for b: Dictionary in band_out:
		control.append_array(b.control)
		patch_shade.append_array(b.patch_shade)
		dom.append_array(b.dom)
		counts.road += b.road
		counts.soil += b.soil
		counts.rock += b.rock
		for id in ROCK_TYPES:
			type_counts[id] += b.type_counts[id]
		grass_sum += b.grass_sum
		bare_sum += b.bare_sum
		litter_full += b.litter_full
		litter_ramp += b.litter_ramp
	var t_main := Time.get_ticks_msec() - t0
	# The mountain (2026-10-08): past its foot line (MountainWalls.raise_foot) the ground is the same
	# bare rock face as the mountain apron beyond the map's edge. Across the line lies a band of
	# scree, as at the foot of a real face: rock -> scree over MOUNTAIN_SCREE_IN m up the rock,
	# scree -> scree with grass over MOUNTAIN_SCREE_OUT m into the valley, the positions shaken by
	# noise so no band edge is a clean line. (Before: rock faded straight into turf.)
	# Both long sides and the north end: [the side's foot line, m inside its edge per row (per
	# column for the north end)]. Every pixel within reach of a line is painted by how far past
	# the NEAREST line it lies (MountainWalls.mountain_depth), so the sides agree in the corners.
	var mountain_feet: Array[PackedFloat32Array] = [maps.get("mountain_foot", PackedFloat32Array()), maps.get("mountain_foot_right", PackedFloat32Array()), maps.get("mountain_foot_north", PackedFloat32Array())]
	# 2026-10-10 (v3): the band is regions -- rock, then scree with grass -- whose edges
	# the border pass below blends like any others.
	var scree_noise := GrassScatter._noise(hash(mountain_feet[0]), 1.0 / 4.0)
	# 2026-10-10: in row bands on worker threads (_mountain_band; the loop was 0.13 s here).
	var mountain_out: Array = []
	mountain_out.resize(bands)
	var mountain_ctx := {"width": width, "length": length, "dom": dom, "feet": mountain_feet, "noise": scree_noise, "rock_id": MountainWalls.rock_texture_id, "out": mountain_out, "mutex": Mutex.new()}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_mountain_band.bind(mountain_ctx), bands, TerrainUtil.object_call_threads(), true))
	var with_mountain := PackedByteArray()
	for mb: PackedByteArray in mountain_out:
		with_mountain.append_array(mb)
	dom = with_mountain
	# Majority filter: each vertex takes the most common texture within DOM_MODE_RADIUS
	# of it, DOM_MODE_PASSES times. Removes specks of a few vertices and rounds corners.
	for _mp in DOM_MODE_PASSES:
		var mode_out: Array = []
		mode_out.resize(bands)
		var mode_ctx := {"width": width, "length": length, "src": dom, "grid": _uniform_grid(dom, width, length), "out": mode_out, "mutex": Mutex.new()}
		WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_mode_band.bind(mode_ctx), bands, -1, true))
		var filtered := PackedByteArray()
		for b: PackedByteArray in mode_out:
			filtered.append_array(b)
		dom = filtered
	# Border pass: every vertex near a border gets the pair (its texture, the one across).
	var blend_out: Array = []
	blend_out.resize(bands)
	var blend_ctx := {"width": width, "length": length, "dom": dom, "grid": _uniform_grid(dom, width, length), "spray_n": spray_n, "road_control": control, "out": blend_out, "mutex": Mutex.new()}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_blend_band.bind(blend_ctx), bands, -1, true))
	var blended := PackedInt32Array()
	var n_border := 0
	var n_third := 0
	for b: Dictionary in blend_out:
		blended.append_array(b.control)
		n_border += b.border
		n_third += b.third
	control = blended
	print("GROUND_PAINT v3: litter weight full on %.1f%% of vertices, partial on %.1f%%; mean bare-soil weight %.2f; %.1f%% of vertices within %d m of a border, %.1f%% of them near a third texture (blend held back there)" % [100.0 * litter_full / n, 100.0 * litter_ramp / n, bare_sum / n, 100.0 * n_border / n, BORDER_RADIUS, 100.0 * n_third / maxf(1.0, n_border)])
	var t_px := Time.get_ticks_msec() - t0
	# Output checksum: must stay the same across a change that is only meant to be faster.
	print("GROUND_PAINT v3: checksum control %d, patch shade %d; timing prep %d ms, main loop %d ms, mountain + filter + borders %d ms" % [hash(control), hash(patch_shade), t_prep - t_dist, t_main - t_prep, t_px - t_main])
	# -- Write into each region's control image, then push to the GPU --
	var data: Terrain3DData = terrain.get_data()
	var rs := terrain.get_region_size()
	var regions_written := 0
	var regions_shaded := 0
	var region_sum := 0 # checksum of what was written, region by region
	var color_src: PackedByteArray = (maps.color as Image).get_data() if maps.get("color") is Image and (maps.color as Image).get_format() == Image.FORMAT_RGBA8 else PackedByteArray()
	# 2026-10-10: the pixels of every region are worked out on worker threads (one task per
	# region, _region_band; this loop was 0.5 s on the main thread, most of it spent stepping
	# over the 13 regions that hold no map pixel). Images are read and set here, on the main thread.
	var jobs: Array = []
	for loc: Vector2i in data.get_region_locations():
		var region: Terrain3DRegion = data.get_region(loc)
		if region == null:
			continue
		var img: Image = region.get_control_map()
		if img == null:
			continue
		var ox := loc.x * rs - int(corner.x) # region pixel (0,0) in heightmap-pixel space
		var oz := loc.y * rs - int(corner.z)
		if ox + rs <= 0 or ox >= width or oz + rs <= 0 or oz >= length:
			continue # no map pixel in this region (apron, hub, north end)
		# Colour map: the generated macro colour (maps.color) x the patch shade.
		var cimg: Image = region.get_color_map()
		var shade_ok := cimg != null and cimg.get_format() == Image.FORMAT_RGBA8 and color_src.size() == n * 4
		jobs.append({"region": region, "bytes": img.get_data(), "ox": ox, "oz": oz, "shade_ok": shade_ok,
			"cbytes": cimg.get_data() if shade_ok else PackedByteArray(), "mipmaps": shade_ok and cimg.has_mipmaps()})
	var job_out: Array = []
	job_out.resize(jobs.size())
	var region_ctx := {"jobs": jobs, "control": control, "patch_shade": patch_shade, "color_src": color_src, "width": width, "length": length, "rs": rs, "out": job_out, "mutex": Mutex.new()}
	if not jobs.is_empty():
		WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_region_band.bind(region_ctx), jobs.size(), -1, true))
	for k in jobs.size():
		var job: Dictionary = jobs[k]
		var done: Dictionary = job_out[k]
		var region: Terrain3DRegion = job.region
		var bytes: PackedByteArray = done.bytes
		var cbytes: PackedByteArray = done.cbytes
		region_sum = hash([region_sum, hash(bytes), hash(cbytes.slice(0, rs * rs * 4)) if job.shade_ok else 0])
		region.set_control_map(Image.create_from_data(rs, rs, false, Image.FORMAT_RF, bytes))
		regions_written += 1
		if job.shade_ok:
			# The region's colour map carries mipmaps (the shader samples it mipmapped):
			# rebuild from level 0 and regenerate them.
			var shaded := Image.create_from_data(rs, rs, false, Image.FORMAT_RGBA8, cbytes.slice(0, rs * rs * 4))
			if job.mipmaps:
				shaded.generate_mipmaps()
			region.set_color_map(shaded)
			regions_shaded += 1
	data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
	if regions_shaded > 0:
		data.update_maps(Terrain3DRegion.TYPE_COLOR, true, false)
	var grass_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(GRASS_ID) if terrain.get_assets() else null
	if grass_asset:
		grass_asset.set_albedo_color(GRASS_TINT)
	print("GROUND_PAINT v2: grounding -- patch shade %.2f written to %d region colour map(s); Grass tint %s; checksum of the regions written %d" % [PATCH_SHADE, regions_shaded, GRASS_TINT if grass_asset else "NOT SET", region_sum])
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

## paint()'s pixels for one Terrain3D region (jobs[index]): the control map's, and the colour
## map's -- the generated macro colour x the patch shade x the mountain's tint. Worker thread: the
## region's own byte arrays are copies of this task's, everything else is only read.
static func _region_band(index: int, ctx: Dictionary) -> void:
	var job: Dictionary = (ctx.jobs as Array)[index]
	var control: PackedInt32Array = ctx.control
	var patch_shade: PackedByteArray = ctx.patch_shade
	var color_src: PackedByteArray = ctx.color_src
	var width: int = ctx.width
	var length: int = ctx.length
	var rs: int = ctx.rs
	var bytes: PackedByteArray = job.bytes
	var cbytes: PackedByteArray = job.cbytes
	var ox: int = job.ox
	var oz: int = job.oz
	var shade_ok: bool = job.shade_ok
	for lz in range(maxi(-oz, 0), mini(length - oz, rs)):
		var pz := oz + lz
		for lx in range(maxi(-ox, 0), mini(width - ox, rs)):
			var px := ox + lx
			bytes.encode_u32((lz * rs + lx) * 4, control[pz * width + px])
			if shade_ok:
				var si := (pz * width + px) * 4
				var di := (lz * rs + lx) * 4
				var s := patch_shade[pz * width + px]
				# Past the mountain's foot line the ground takes the mountain's colour, fading out
				# across the scree band.
				var mountain := smoothstep(-MOUNTAIN_SCREE_OUT, MOUNTAIN_SCREE_IN, MountainWalls.mountain_depth(px, pz))
				cbytes[di] = int(color_src[si] * s / 255 * lerpf(1.0, MountainWalls.MOUNTAIN_TINT.r, mountain))
				cbytes[di + 1] = int(color_src[si + 1] * s / 255 * lerpf(1.0, MountainWalls.MOUNTAIN_TINT.g, mountain))
				cbytes[di + 2] = int(color_src[si + 2] * s / 255 * lerpf(1.0, MountainWalls.MOUNTAIN_TINT.b, mountain))
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[index] = {"bytes": bytes, "cbytes": cbytes}
	mutex.unlock()
const PAINT_BAND_ROWS := 16 ## rows per worker-thread task in paint()

## TerrainHeightmap.pack_control_blend with the bits packed here (base << 27, overlay << 22,
## blend byte << 14) instead of through three Terrain3DUtil calls -- for the per-vertex loop.
static func _pack(base_id: int, overlay_id: int, blend_frac: float) -> int:
	var blend_byte := clampi(int(round(clampf(blend_frac, 0.0, 1.0) * 255.0)), 0, 255)
	return ((base_id & 0x1F) << 27) | ((overlay_id & 0x1F) << 22) | (blend_byte << 14)

## paint()'s main per-vertex pass for rows [band * PAINT_BAND_ROWS, +PAINT_BAND_ROWS). Runs on a
## worker thread: it only READS the shared arrays in ctx (a write to a shared packed array from a
## thread would silently copy it) and fills its own band-sized outputs, which paint() joins in
## band order. Output index li is band-local; i / j / k index the full-map inputs.
static func _paint_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var length: int = ctx.length
	var heights: PackedFloat32Array = ctx.heights
	var old_control: PackedByteArray = ctx.old_control
	var coverage_bytes: PackedByteArray = ctx.coverage_bytes
	var worn_bytes: PackedByteArray = ctx.worn_bytes
	var verge_bytes: PackedByteArray = ctx.verge_bytes
	var big_n: PackedByteArray = ctx.big_n
	var small_n: PackedByteArray = ctx.small_n
	var type_a: PackedByteArray = ctx.type_a
	var type_b: PackedByteArray = ctx.type_b
	var spray_n: PackedByteArray = ctx.spray_n
	var warp_x: PackedByteArray = ctx.warp_x
	var warp_z: PackedByteArray = ctx.warp_z
	var cliff_d: PackedFloat32Array = ctx.cliff_d
	var boulder_d: PackedFloat32Array = ctx.boulder_d
	var scree_d: PackedFloat32Array = ctx.scree_d
	var road_d: PackedFloat32Array = ctx.road_d
	var dead_d: PackedFloat32Array = ctx.dead_d
	var tree_d: PackedFloat32Array = ctx.tree_d
	var canopy: PackedFloat32Array = ctx.canopy
	var cliff_shade: PackedFloat32Array = ctx.cliff_shade
	var gw: int = ctx.gw
	var gl: int = ctx.gl
	var litter_ok: bool = ctx.litter_ok
	var patch_bytes: PackedByteArray = ctx.patch_bytes
	var patch_nv: PackedFloat64Array = ctx.patch_nv
	var pw := width * GrassScatter.PATCH_RES
	var pw1 := pw - 1
	var pl1 := length * GrassScatter.PATCH_RES - 1
	var edge2 := 2.0 * GrassScatter.PATCH_EDGE

	var z0 := band * PAINT_BAND_ROWS
	var z1 := mini(z0 + PAINT_BAND_ROWS, length)
	var bn := (z1 - z0) * width
	var control := PackedInt32Array()
	control.resize(bn)
	var patch_shade := PackedByteArray()
	patch_shade.resize(bn)
	patch_shade.fill(255)
	# Per vertex: the texture that is largest there (ROAD_MARK on a road vertex, whose control is
	# packed here).
	var dom := PackedByteArray()
	dom.resize(bn)
	var n_road := 0
	var n_soil := 0
	var n_rock := 0
	var type_counts := {}
	for id in ROCK_TYPES:
		type_counts[id] = 0
	var grass_sum := 0.0
	var bare_sum := 0.0
	var litter_full := 0
	var litter_ramp := 0

	var w1 := width - 1
	var l1 := length - 1
	for pz in range(z0, z1):
		var zm := maxi(pz - 1, 0)
		var zp := mini(pz + 1, l1)
		for px in width:
			var i := pz * width + px
			var li := (pz - z0) * width + px
			var old := old_control.decode_u32(i * 4)
			# Verge: how far the roadside here is worn to soil, 0..1 -- GrassScatter.verge_soil, the
			# same field that keeps the blades off it (2026-10-10; before, a noise of this module's
			# own switched whole stretches of a fixed-width strip on and off: rectangles).
			var verge := verge_bytes[i] / 255.0
			# Control-map bits read directly (base = bits 27-31, overlay = 22-26, blend = 14-21; same
			# as Terrain3DUtil.get_base / get_overlay / get_blend, without the calls).
			if ((old >> 27) & 0x1F) == ROAD_ID or ((old >> 22) & 0x1F) == ROAD_ID:
				# Road vertices keep their Road blend; only what the road fades INTO at its edge
				# changes: Ground on a worn verge, Grass elsewhere (TerrainRoad paints Ground).
				control[li] = _pack(GROUND_ID if verge >= 0.5 else GRASS_ID, ROAD_ID, ((old >> 14) & 0xFF) / 255.0)
				dom[li] = ROAD_MARK
				n_road += 1
				continue

			# Grass = the blades' own patch keep, softened over +-0.5 m (5 taps) so the 1 m vertex
			# grid doesn't stair-step the patch outlines.
			var cov := coverage_bytes[i * 4] / 255.0
			cov += GRASS_TEXTURE_GROW * smoothstep(0.0, 0.1, cov) # texture margin (blades unaffected)
			var g := 0.0
			if cov > 0.0:
				# GrassScatter.patch_keep at the vertex + the 4 half-metre taps around it, read from
				# the patch map's bytes (patch_nv = its smoothstep, per byte value).
				var tx := px * 2
				var tz := pz * 2
				var trow := tz * pw
				var nv := patch_nv[patch_bytes[trow + tx]]
				g = 2.0 * smoothstep(nv, nv + edge2, cov)
				nv = patch_nv[patch_bytes[trow + maxi(tx - 1, 0)]]
				g += smoothstep(nv, nv + edge2, cov)
				nv = patch_nv[patch_bytes[trow + mini(tx + 1, pw1)]]
				g += smoothstep(nv, nv + edge2, cov)
				nv = patch_nv[patch_bytes[maxi(tz - 1, 0) * pw + tx]]
				g += smoothstep(nv, nv + edge2, cov)
				nv = patch_nv[patch_bytes[mini(tz + 1, pl1) * pw + tx]]
				g += smoothstep(nv, nv + edge2, cov)
				g /= 6.0
			grass_sum += g
			patch_shade[li] = int(round(255.0 * (1.0 - PATCH_SHADE * g - GAP_SHADE * (1.0 - g) * smoothstep(0.05, 0.25, cov))))

			# Rockiness.
			var xm := maxi(px - 1, 0)
			var xp := mini(px + 1, w1)
			var dx := (heights[pz * width + xp] - heights[pz * width + xm]) / float(xp - xm)
			var dz := (heights[zp * width + px] - heights[zm * width + px]) / float(zp - zm)
			var ny := 1.0 / sqrt(1.0 + dx * dx + dz * dz)
			var steep := 1.0 - smoothstep(STEEP_NY_FULL, STEEP_NY_NONE, ny)
			# Domain-warped lookup (ROCK_WARP_*): iso-lines of the rect/circle fields turn into blobs.
			var wpx := clampi(int(round(px + (warp_x[i] / 255.0 - 0.5) * 2.0 * ROCK_WARP_AMP)), 0, w1)
			var wpz := clampi(int(round(pz + (warp_z[i] / 255.0 - 0.5) * 2.0 * ROCK_WARP_AMP)), 0, l1)
			var j := wpz * width + wpx
			var p_cliff := 1.0 - smoothstep(0.0, CLIFF_REACH, cliff_d[j])
			var p_boulder := (1.0 - smoothstep(0.0, BOULDER_REACH, boulder_d[j])) * BOULDER_STRENGTH
			var p_scree := 1.0 - smoothstep(0.0, SCREE_REACH, scree_d[j])
			var prox := maxf(maxf(p_cliff, p_boulder), p_scree)
			var nb := big_n[i] / 255.0
			var rocky := 0.0
			if prox > 0.0:
				rocky = smoothstep(ROCKY_LO, ROCKY_HI, prox * (ROCKY_BASE + ROCKY_BIG * nb) + ROCKY_SMALL * (small_n[i] / 255.0 - 0.5))
			rocky = maxf(rocky, steep * (0.6 + 0.4 * nb))

			var canopy_c := UnderstoryScatter._grid_sample(canopy, gw, gl, px, pz)
			var lit := 0.0
			if litter_ok:
				lit = 1.0 - smoothstep(0.0, LITTER_TREE_FADE, tree_d[i] + LITTER_EDGE_NOISE * (small_n[i] / 255.0 - 0.5))
				# Strays (LITTER_SUPPLY_* etc.): only where nearby trees can supply them.
				var supply := smoothstep(LITTER_SUPPLY_LO, LITTER_SUPPLY_HI, canopy_c)
				if supply > 0.0:
					# Collar around boulders / stumps / logs. k = the spot LITTER_UPHILL_STEP m downhill:
					# an obstacle there means this vertex is on its uphill side, where litter stops.
					var k := j
					var glen := sqrt(dx * dx + dz * dz)
					if glen > 0.04:
						k = clampi(int(round(wpz - dz / glen * LITTER_UPHILL_STEP)), 0, l1) * width + clampi(int(round(wpx - dx / glen * LITTER_UPHILL_STEP)), 0, w1)
					var collar := maxf(
						LITTER_COLLAR_SIDE * (1.0 - smoothstep(0.0, LITTER_COLLAR_REACH, minf(boulder_d[j], dead_d[j]))),
						1.0 - smoothstep(0.0, LITTER_COLLAR_REACH, minf(boulder_d[k], dead_d[k])))
					# Hollows: laplacian of the height, + = concave (same measure as GrassScatter's).
					var curv := (heights[pz * width + maxi(px - GrassScatter.CURV_RADIUS, 0)] + heights[pz * width + mini(px + GrassScatter.CURV_RADIUS, w1)] \
						+ heights[maxi(pz - GrassScatter.CURV_RADIUS, 0) * width + px] + heights[mini(pz + GrassScatter.CURV_RADIUS, l1) * width + px] \
						- 4.0 * heights[i]) / float(GrassScatter.CURV_RADIUS * GrassScatter.CURV_RADIUS)
					var hollow := smoothstep(LITTER_CURV_LO, LITTER_CURV_HI, curv)
					lit = maxf(lit, supply * maxf(collar, hollow))
				# Wind drifts: noise blobs in and beside stands.
				var drift := smoothstep(LITTER_DRIFT_LO, LITTER_DRIFT_HI, 0.6 * nb + 0.4 * (small_n[i] / 255.0))
				lit = maxf(lit, drift * smoothstep(LITTER_DRIFT_SUPPLY_LO, LITTER_DRIFT_SUPPLY_HI, canopy_c))
				# Read at the warped position (j), so the fade line along the road is ragged.
				lit *= smoothstep(LITTER_ROAD_CLEAR, LITTER_ROAD_REACH, road_d[j])
				lit *= smoothstep(LITTER_NY_NONE, LITTER_NY_FULL, ny) * smoothstep(LITTER_CLIFF_CLEAR, LITTER_CLIFF_REACH, cliff_d[j])

			# Bare soil (BARE_*): the road verge + sparse worn patches. Everything else is Grass.
			var bare := maxf(verge, BARE_WORN_MAX * worn_bytes[i] / 255.0)
			# No turf on steep ground or against cliffs (user screenshot 2026-10-01: grass up a bank
			# and blending into a cliff mesh) -- there the soil under the rock texture is Ground.
			bare = maxf(bare, maxf(1.0 - smoothstep(BARE_NY_FULL, BARE_NY_NONE, ny), 1.0 - smoothstep(BARE_CLIFF_CLEAR, BARE_CLIFF_REACH, cliff_d[j])))

			if rocky < ROCKY_MIN:
				rocky = 0.0
			# The vertex takes the texture with the largest weight (v3, see the header).
			var lw := clampf(lit / LITTER_FULL, 0.0, 1.0)
			var w_litter := lw * (1.0 - g * lw) # grass patches show through full litter
			var w_ground := bare * (1.0 - lw)
			var w_grass := maxf(1.0 - w_litter - w_ground, 0.0)
			bare_sum += w_ground
			if lw >= 1.0:
				litter_full += 1
			elif lit > LITTER_MIN:
				litter_ramp += 1
			var d_id := GRASS_ID
			var d_w := w_grass
			if w_litter > d_w:
				d_w = w_litter
				d_id = PINE_LITTER_ID
			if w_ground > d_w:
				d_w = w_ground
				d_id = GROUND_ID
			if rocky <= d_w * (1.0 - rocky):
				n_soil += 1
				dom[li] = d_id
				continue

			# Rock type: correlated weights + regional noise, highest wins.
			var ta := type_a[i] / 255.0
			var tb := type_b[i] / 255.0
			var shade := maxf(canopy_c, UnderstoryScatter._grid_sample(cliff_shade, gw, gl, px, pz))
			var flat := smoothstep(STEEP_NY_NONE, FLAT_NY, ny)
			var core := 1.0 - smoothstep(0.0, 2.5, cliff_d[j])
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
			n_rock += 1
			dom[li] = rock_id

	var result := {
		"control": control, "patch_shade": patch_shade, "dom": dom,
		"road": n_road, "soil": n_soil, "rock": n_rock, "type_counts": type_counts,
		"grass_sum": grass_sum, "bare_sum": bare_sum, "litter_full": litter_full, "litter_ramp": litter_ramp,
	}
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = result
	mutex.unlock()

## Per 8 x 8 block of vertices: the texture every vertex of it has, or UNIFORM_MIXED. A window of
## up to 8 vertices across touches at most 2 x 2 blocks, so "its four corner blocks all hold my
## texture" means the whole window does -- which lets the majority filter and the border pass skip
## their per-vertex window scan on ground far from any border (about half the map; 2026-10-10).
## Built in bands on worker threads.
const UNIFORM_MIXED := 254
static func _uniform_grid(dom: PackedByteArray, width: int, length: int) -> PackedByteArray:
	var grid_l := (length + 7) >> 3
	var bands := ceili(float(grid_l) / 4.0)
	var out: Array = []
	out.resize(bands)
	var ctx := {"dom": dom, "width": width, "length": length, "out": out, "mutex": Mutex.new()}
	WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(_uniform_band.bind(ctx), bands, -1, true))
	var grid := PackedByteArray()
	for b: PackedByteArray in out:
		grid.append_array(b)
	return grid

static func _uniform_band(band: int, ctx: Dictionary) -> void:
	var dom: PackedByteArray = ctx.dom
	var width: int = ctx.width
	var length: int = ctx.length
	var grid_w := (width + 7) >> 3
	var grid_l := (length + 7) >> 3
	var g0 := band * 4
	var g1 := mini(g0 + 4, grid_l)
	var out := PackedByteArray()
	out.resize((g1 - g0) * grid_w)
	for gz in range(g0, g1):
		for gx in grid_w:
			var first := dom[(gz << 3) * width + (gx << 3)]
			var value := first
			for pz in range(gz << 3, mini((gz << 3) + 8, length)):
				var row := pz * width
				for px in range(gx << 3, mini((gx << 3) + 8, width)):
					if dom[row + px] != first:
						value = UNIFORM_MIXED
						break
				if value == UNIFORM_MIXED:
					break
			out[(gz - g0) * grid_w + gx] = value
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = out
	mutex.unlock()
## paint()'s mountain band for rows [band * PAINT_BAND_ROWS, +PAINT_BAND_ROWS): the three sides in
## their order, each over the pixels it covered in the single loop that fall in these rows, so a
## corner pixel still ends with the last side's answer. Worker thread; returns the band's slice.
static func _mountain_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var length: int = ctx.length
	var dom: PackedByteArray = ctx.dom
	var feet: Array[PackedFloat32Array] = ctx.feet
	var scree_noise: FastNoiseLite = ctx.noise
	var rock_id: int = ctx.rock_id
	var z_from := band * PAINT_BAND_ROWS
	var z_to := mini(z_from + PAINT_BAND_ROWS, length) - 1
	var out := dom.slice(z_from * width, (z_to + 1) * width)
	var scree_half := MOUNTAIN_SCREE_IN * 0.5
	for side in 3:
		var mountain_foot := feet[side]
		var along_count := mini(mountain_foot.size(), width if side == 2 else length)
		# Sides 0 and 1 run along the rows: only this band's. Side 2 runs along the columns.
		for along in (range(z_from, mini(z_to + 1, along_count)) if side < 2 else range(along_count)):
			var line := mountain_foot[along]
			if line <= 0.0: # a cliff or knot stands at the edge here: no mountain foot
				continue
			var inside_count := clampi(int(line + MOUNTAIN_SCREE_OUT) + 2, 0, length if side == 2 else width)
			for inside in (range(inside_count) if side < 2 else range(z_from, mini(z_to + 1, inside_count))):
				var px: int = inside if side == 0 else (width - 1 - inside if side == 1 else along)
				var pz: int = along if side < 2 else inside
				var t := -MountainWalls.mountain_depth(px, pz) + scree_noise.get_noise_2d(px, pz) * MOUNTAIN_SCREE_JITTER # < 0 on the rock
				var i := (pz - z_from) * width + px
				# Two regions since later the same day (Kirill: "remove rocky trail from the mix",
				# extend rock face in its stead): RockyTrail lay between these two.
				if t < scree_half:
					out[i] = rock_id # the mountain's own rock texture
				elif t < MOUNTAIN_SCREE_OUT:
					out[i] = ROCKY_TERRAIN_ID
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = out
	mutex.unlock()
## One band of the majority filter (see paint()): each vertex takes the most common texture within
## DOM_MODE_RADIUS of it, read from the unfiltered `src`; its own wins a tie. Road vertices
## are left alone and not counted. Worker thread, same rules as _paint_band.
static func _mode_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var length: int = ctx.length
	var src: PackedByteArray = ctx.src
	var grid: PackedByteArray = ctx.grid
	var grid_w := (width + 7) >> 3
	var z0 := band * PAINT_BAND_ROWS
	var z1 := mini(z0 + PAINT_BAND_ROWS, length)
	var out := src.slice(z0 * width, z1 * width)
	var tally := PackedInt32Array()
	tally.resize(32)
	for pz in range(z0, z1):
		var za := maxi(pz - DOM_MODE_RADIUS, 0)
		var zb := mini(pz + DOM_MODE_RADIUS, length - 1)
		for px in width:
			var own := src[pz * width + px]
			if own == ROAD_MARK:
				continue
			var xa := maxi(px - DOM_MODE_RADIUS, 0)
			var xb := mini(px + DOM_MODE_RADIUS, width - 1)
			# All of the window in blocks of this one texture: nothing to count (see _uniform_grid).
			if grid[(za >> 3) * grid_w + (xa >> 3)] == own and grid[(za >> 3) * grid_w + (xb >> 3)] == own and grid[(zb >> 3) * grid_w + (xa >> 3)] == own and grid[(zb >> 3) * grid_w + (xb >> 3)] == own:
				continue
			var same := 0
			var cells := 0
			for zz in range(za, zb + 1):
				for xx in range(xa, xb + 1):
					var v := src[zz * width + xx]
					if v == ROAD_MARK:
						continue
					cells += 1
					if v == own:
						same += 1
			if same * 2 > cells:
				continue # already the majority
			tally.fill(0)
			var best_id := own
			var best_n := same
			for zz in range(za, zb + 1):
				for xx in range(xa, xb + 1):
					var v := src[zz * width + xx]
					if v == ROAD_MARK:
						continue
					tally[v] += 1
					if tally[v] > best_n:
						best_n = tally[v]
						best_id = v
			out[(pz - z0) * width + px] = best_id
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = out
	mutex.unlock()

## The border pass (see paint() and the header): packs every vertex. It looks for the nearest
## vertex of another texture within BORDER_RADIUS; the pair is (own, that one), the other's share
## 0.5 at the border and 0 from BORDER_FADE m inside. Both sides of a border so hold the same two
## textures at nearly the same shares, and the edge is drawn by the shares and the textures'
## relief, not by the vertex grid. Near a THIRD texture the share is held back (THIRD_FADE): a
## vertex holds two textures only, so around a three-way corner the edges stay hard.
static func _blend_band(band: int, ctx: Dictionary) -> void:
	var width: int = ctx.width
	var length: int = ctx.length
	var dom: PackedByteArray = ctx.dom
	var grid: PackedByteArray = ctx.grid
	var grid_w := (width + 7) >> 3
	var spray_n: PackedByteArray = ctx.spray_n
	var road_control: PackedInt32Array = ctx.road_control
	var z0 := band * PAINT_BAND_ROWS
	var z1 := mini(z0 + PAINT_BAND_ROWS, length)
	var control := PackedInt32Array()
	control.resize((z1 - z0) * width)
	var border := 0
	var third := 0
	var far := (BORDER_RADIUS + 1) * (BORDER_RADIUS + 1) * 2
	for pz in range(z0, z1):
		var za := maxi(pz - BORDER_RADIUS, 0)
		var zb := mini(pz + BORDER_RADIUS, length - 1)
		for px in width:
			var i := pz * width + px
			var li := (pz - z0) * width + px
			var a := dom[i]
			if a == ROAD_MARK:
				# What the road's edge fades into is the patch beside it: the texture of the nearest
				# vertex off the road within 2 m. (Before 2026-10-10 each road vertex chose soil or
				# grass for itself, which left lone soil squares along the edge.)
				var beside := -1
				var beside_d := 99
				for zz in range(maxi(pz - 2, 0), mini(pz + 2, length - 1) + 1):
					for xx in range(maxi(px - 2, 0), mini(px + 2, width - 1) + 1):
						var u := dom[zz * width + xx]
						var d := (zz - pz) * (zz - pz) + (xx - px) * (xx - px)
						if u != ROAD_MARK and d < beside_d:
							beside_d = d
							beside = u
				control[li] = road_control[i] if beside < 0 else (road_control[i] & 0x07FFFFFF) | ((beside & 0x1F) << 27)
				continue
			# The two nearest other textures: e1 at d1 (squared), e2 at d2.
			var e1 := -1
			var e2 := -1
			var d1 := far
			var d2 := far
			var xa := maxi(px - BORDER_RADIUS, 0)
			var xb := mini(px + BORDER_RADIUS, width - 1)
			# All of the window in blocks of this one texture: no border near (see _uniform_grid).
			if grid[(za >> 3) * grid_w + (xa >> 3)] == a and grid[(za >> 3) * grid_w + (xb >> 3)] == a and grid[(zb >> 3) * grid_w + (xa >> 3)] == a and grid[(zb >> 3) * grid_w + (xb >> 3)] == a:
				control[li] = _pack(a, a, 0.0)
				continue
			for zz in range(za, zb + 1):
				var row := zz * width
				var dz2 := (zz - pz) * (zz - pz)
				for xx in range(xa, xb + 1):
					var u := dom[row + xx]
					if u == a or u == ROAD_MARK:
						continue
					var d := dz2 + (xx - px) * (xx - px)
					if u == e1:
						if d < d1:
							d1 = d
					elif u == e2:
						if d < d2:
							d2 = d
							if d2 < d1:
								var sw_e := e1
								var sw_d := d1
								e1 = e2
								d1 = d2
								e2 = sw_e
								d2 = sw_d
					elif d < d1:
						e2 = e1
						d2 = d1
						e1 = u
						d1 = d
					elif d < d2:
						e2 = u
						d2 = d
			if e1 < 0:
				control[li] = _pack(a, a, 0.0)
				continue
			border += 1
			# The border runs half a metre short of the nearest other vertex.
			var share := 0.5 * (1.0 - smoothstep(0.0, BORDER_FADE, sqrt(float(d1)) - 0.5))
			if e2 >= 0:
				var hold := smoothstep(0.0, THIRD_FADE, sqrt(float(d2)) - 0.5)
				if hold < 1.0:
					third += 1
					share *= hold
			# Spray moves the share of the texture with the LOWER id: the two sides of a border
			# hold the same pair the other way round and so move the same way.
			var s := spray_n[i] / 255.0 - 0.5
			if share > 0.0:
				if a < e1:
					share = 1.0 - _spray(1.0 - share, s)
				else:
					share = _spray(share, s)
			control[li] = _pack(a, e1, share)
	var mutex: Mutex = ctx.mutex
	mutex.lock()
	(ctx.out as Array)[band] = {"control": control, "border": border, "third": third}
	mutex.unlock()
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
