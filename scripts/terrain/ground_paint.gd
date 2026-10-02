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
const BARE_VERGE_LO := 0.47
const BARE_VERGE_HI := 0.6
const BARE_ROAD_CLEAR := 0.8
const BARE_ROAD_REACH := 3.5
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
const GRASS_TINT := Color(0.62, 0.85, 0.55)
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
const LITTER_SEAM_GRASS_MIN := 0.3 ## a Ground/Grass neighbour with at least this much grass counts as a seam
const LITTER_SEAM_FADE := 0.5
const PAIR_GROUND_GRASS := 1
const PAIR_GROUND_LITTER := 2

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
## Where 8-neighbouring rock vertices use DIFFERENT rock textures, Terrain3D draws a hard 1 m
## seam (overlay id swap) -- fade both sides' rock blend by this so the swap happens mostly in soil.
const ROCK_TYPE_SEAM_FADE := 0.4
## Rock vertices with fewer than ROCK_ISLAND_MIN rocky 8-neighbours render as lone squares --
## their blend is multiplied by ROCK_ISLAND_FADE.
const ROCK_ISLAND_MIN := 3
const ROCK_ISLAND_FADE := 0.4
const ROCK_NONE := 255 ## rock_of marker: not a rock vertex
const ROCK_TYPE_MODE_RADIUS := 2 ## majority-filter window half-size (vertices = metres)
const ROCK_TYPE_MODE_PASSES := 2
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
	# 2026-09-29 domain warp -- drawn AFTER the existing noise seeds so those stay as they were.
	var warp_x := GrassScatter._noise_bytes(rng.randi(), ROCK_WARP_FREQ, width, length)
	var warp_z := GrassScatter._noise_bytes(rng.randi(), ROCK_WARP_FREQ, width, length)
	# Rock vertices are packed in a post-pass (seam/island fade): per vertex its rock id
	# (ROCK_NONE = soil/road), soil base and pre-spray rockiness.
	var rock_of := PackedByteArray()
	rock_of.resize(n)
	rock_of.fill(ROCK_NONE)
	var soil_of := PackedByteArray()
	soil_of.resize(n)
	var rocky_of := PackedFloat32Array()
	rocky_of.resize(n)
	# Soil vertices: which pair (PAIR_*, 0 = other) and the pre-spray blend, for the litter seam pass.
	var soil_pair := PackedByteArray()
	soil_pair.resize(n)
	var soil_b := PackedFloat32Array()
	soil_b.resize(n)
	var litter_ok := terrain.get_assets() != null and terrain.get_assets().get_texture(PINE_LITTER_ID) != null
	if not litter_ok:
		print("GROUND_PAINT: texture id %d (PineLitter) not registered -- no litter painted; run fix_textures() in tools/assign_flat_textures.gd" % PINE_LITTER_ID)
	var litter_full := 0
	var litter_ramp := 0

	var coverage_bytes := GrassScatter.density_image.get_data() # RGBA8, R = coverage
	var worn_bytes := GrassScatter.worn
	if worn_bytes.size() != n:
		worn_bytes = PackedByteArray()
		worn_bytes.resize(n)
	var old_control: PackedByteArray = (maps.control as Image).get_data() # FORMAT_RF: uint32 bits
	# Distance to the road's painted vertices: litter fades out toward them (LITTER_ROAD_*).
	var road_d := _new_field(n, LITTER_ROAD_REACH)
	# Distance to stumps / logs, for the litter collar (boulders: boulder_d above).
	var dead_d := _new_field(n, LITTER_COLLAR_REACH)
	if litter_ok:
		for kc in DeadfallScatter.deadfall_keep_circles:
			GrassScatter._stamp_circle(dead_d, width, length, kc.x, kc.y, kc.z, LITTER_COLLAR_REACH)
	# Distance past each tree's litter core (0 inside it).
	var tree_d := _new_field(n, LITTER_TREE_FADE + LITTER_EDGE_NOISE)
	if litter_ok:
		for tp in TreeScatter.tree_points:
			GrassScatter._stamp_circle(tree_d, width, length, tp.x, tp.y, LITTER_TREE_CORE * tp.z, LITTER_TREE_FADE + LITTER_EDGE_NOISE)
	var bare_sum := 0.0
	# Always built: the road distance also drives the bare verge (BARE_ROAD_*).
	for pz in length:
		for px in width:
			var c := old_control.decode_u32((pz * width + px) * 4)
			if Terrain3DUtil.get_base(c) == ROAD_ID or Terrain3DUtil.get_overlay(c) == ROAD_ID:
				GrassScatter._stamp_circle(road_d, width, length, px, pz, 0.0, LITTER_ROAD_REACH)
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
	var w1 := width - 1
	var l1 := length - 1
	for pz in length:
		var zm := maxi(pz - 1, 0)
		var zp := mini(pz + 1, l1)
		for px in width:
			var i := pz * width + px
			var old := old_control.decode_u32(i * 4)
			# Verge: is the roadside here worn to soil (1) or grown over (0)? Regional noise, so soil
			# and grass alternate along the road in stretches instead of one even strip (BARE_VERGE_*).
			var verge := smoothstep(BARE_VERGE_LO, BARE_VERGE_HI, 0.6 * (type_b[i] / 255.0) + 0.4 * (big_n[i] / 255.0))
			if Terrain3DUtil.get_base(old) == ROAD_ID or Terrain3DUtil.get_overlay(old) == ROAD_ID:
				# Road vertices keep their Road blend; only what the road fades INTO at its edge
				# changes: Ground on a worn verge, Grass elsewhere (TerrainRoad paints Ground).
				control[i] = TerrainHeightmap.pack_control_blend(GROUND_ID if verge >= 0.5 else GRASS_ID, ROAD_ID, Terrain3DUtil.get_blend(old) / 255.0)
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
			patch_shade[i] = int(round(255.0 * (1.0 - PATCH_SHADE * g - GAP_SHADE * (1.0 - g) * smoothstep(0.05, 0.25, cov))))
			var spray := spray_n[i] / 255.0 - 0.5

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
			var bare := maxf(
				verge * (1.0 - smoothstep(BARE_ROAD_CLEAR, BARE_ROAD_REACH, road_d[j])),
				BARE_WORN_MAX * worn_bytes[i] / 255.0)
			# No turf on steep ground or against cliffs (user screenshot 2026-10-01: grass up a bank
			# and blending into a cliff mesh) -- there the soil under the rock texture is Ground.
			bare = maxf(bare, maxf(1.0 - smoothstep(BARE_NY_FULL, BARE_NY_NONE, ny), 1.0 - smoothstep(BARE_CLIFF_CLEAR, BARE_CLIFF_REACH, cliff_d[j])))

			if rocky < ROCKY_MIN:
				counts.soil += 1
				if lit >= LITTER_FULL:
					litter_full += 1
					control[i] = TerrainHeightmap.pack_control_blend(PINE_LITTER_ID, GRASS_ID, _spray(g, spray))
				elif lit > bare and lit > LITTER_MIN:
					litter_ramp += 1
					soil_pair[i] = PAIR_GROUND_LITTER
					soil_b[i] = lit / LITTER_FULL
					control[i] = TerrainHeightmap.pack_control_blend(GRASS_ID, PINE_LITTER_ID, _spray(soil_b[i], spray))
				else:
					bare_sum += bare
					soil_pair[i] = PAIR_GROUND_GRASS
					soil_b[i] = bare
					control[i] = TerrainHeightmap.pack_control_blend(GRASS_ID, GROUND_ID, _spray(bare, spray))
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
			counts.rock += 1
			var soil := PINE_LITTER_ID if lit >= 0.5 else (GROUND_ID if bare >= 0.5 else GRASS_ID)
			rock_of[i] = rock_id
			soil_of[i] = soil
			rocky_of[i] = rocky

	# Rock-type majority filter (2026-09-29): the per-vertex "highest weight wins" type pick flips
	# between neighbours all the time (first run: 9818 of ~18.9k rock vertices sat on a type seam),
	# and every flip is a hard 1 m Terrain3D seam. Each rock vertex takes the most common type among
	# the rock vertices within ROCK_TYPE_MODE_RADIUS, ROCK_TYPE_MODE_PASSES times -> coherent regions.
	for _mp in ROCK_TYPE_MODE_PASSES:
		var src := rock_of.duplicate()
		for pz in length:
			for px in width:
				var i := pz * width + px
				var rid := src[i]
				if rid == ROCK_NONE:
					continue
				var tally := {}
				for dz in range(-ROCK_TYPE_MODE_RADIUS, ROCK_TYPE_MODE_RADIUS + 1):
					var zz := pz + dz
					if zz < 0 or zz >= length:
						continue
					for dx in range(-ROCK_TYPE_MODE_RADIUS, ROCK_TYPE_MODE_RADIUS + 1):
						var xx := px + dx
						if xx < 0 or xx >= width:
							continue
						var nr := src[zz * width + xx]
						if nr != ROCK_NONE:
							tally[nr] = int(tally.get(nr, 0)) + 1
				var best_id := rid
				var best_n := int(tally.get(rid, 0))
				for k in tally:
					if int(tally[k]) > best_n:
						best_n = int(tally[k])
						best_id = k
				rock_of[i] = best_id

	# Post-pass (2026-09-29): pack rock vertices, fading hard rock-type seams and lone rock squares.
	var seams := 0
	var islands := 0
	for pz in length:
		for px in width:
			var i := pz * width + px
			var rid := rock_of[i]
			if rid == ROCK_NONE:
				continue
			var rocky_nb := 0
			var seam := false
			for dz in range(-1, 2):
				var zz := pz + dz
				if zz < 0 or zz >= length:
					continue
				for dx in range(-1, 2):
					var xx := px + dx
					if (dx == 0 and dz == 0) or xx < 0 or xx >= width:
						continue
					var nr := rock_of[zz * width + xx]
					if nr == ROCK_NONE:
						continue
					rocky_nb += 1
					if nr != rid:
						seam = true
			var b := rocky_of[i]
			if seam:
				b *= ROCK_TYPE_SEAM_FADE
				seams += 1
			if rocky_nb < ROCK_ISLAND_MIN:
				b *= ROCK_ISLAND_FADE
				islands += 1
			control[i] = TerrainHeightmap.pack_control_blend(soil_of[i], rid, _spray(b, spray_n[i] / 255.0 - 0.5))
	# Litter seam pass: a litter-ramp vertex next to a grassy Ground/Grass vertex swaps overlays
	# mid-blend (a blocky 1 m step) -- fade both toward Ground so the swap happens in soil.
	var litter_seams := 0
	var faded := PackedByteArray()
	faded.resize(n)
	for pz in length:
		for px in width:
			var i := pz * width + px
			if soil_pair[i] != PAIR_GROUND_LITTER:
				continue
			var hit := false
			for dz in range(-1, 2):
				var zz := pz + dz
				if zz < 0 or zz >= length:
					continue
				for dx in range(-1, 2):
					var xx := px + dx
					if xx < 0 or xx >= width:
						continue
					var k := zz * width + xx
					if soil_pair[k] != PAIR_GROUND_GRASS or soil_b[k] < LITTER_SEAM_GRASS_MIN:
						continue
					hit = true
					if faded[k] == 0:
						faded[k] = 1
						control[k] = TerrainHeightmap.pack_control_blend(GRASS_ID, GROUND_ID, _spray(soil_b[k] * LITTER_SEAM_FADE, spray_n[k] / 255.0 - 0.5))
			if hit:
				litter_seams += 1
				control[i] = TerrainHeightmap.pack_control_blend(GRASS_ID, PINE_LITTER_ID, _spray(soil_b[i] * LITTER_SEAM_FADE, spray_n[i] / 255.0 - 0.5))
	print("GROUND_PAINT v2: litter -- %.1f%% of vertices full litter, %.1f%% on the ramp, %d ramp vertices faded at bare-soil seams; bare soil ~%.1f%% of the map (rest of the open ground = Grass)" % [100.0 * litter_full / n, 100.0 * litter_ramp / n, litter_seams, 100.0 * bare_sum / n])
	last_stats["seams"] = seams
	last_stats["islands"] = islands
	print("GROUND_PAINT v2: shape softening -- %d rock-type seam vertices faded, %d island vertices faded, warp +-%.1f m" % [seams, islands, ROCK_WARP_AMP])
	var t_px := Time.get_ticks_msec() - t0

	# -- Write into each region's control image, then push to the GPU --
	var data: Terrain3DData = terrain.get_data()
	var rs := terrain.get_region_size()
	var regions_written := 0
	var regions_shaded := 0
	var color_src: PackedByteArray = (maps.color as Image).get_data() if maps.get("color") is Image and (maps.color as Image).get_format() == Image.FORMAT_RGBA8 else PackedByteArray()
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
		# Colour map: the generated macro colour (maps.color) x the patch shade.
		var cimg: Image = region.get_color_map()
		var shade_ok := cimg != null and cimg.get_format() == Image.FORMAT_RGBA8 and color_src.size() == n * 4
		var cbytes := cimg.get_data() if shade_ok else PackedByteArray()
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
				if shade_ok:
					var si := (pz * width + px) * 4
					var di := (lz * rs + lx) * 4
					var s := patch_shade[pz * width + px]
					cbytes[di] = color_src[si] * s / 255
					cbytes[di + 1] = color_src[si + 1] * s / 255
					cbytes[di + 2] = color_src[si + 2] * s / 255
		if wrote:
			region.set_control_map(Image.create_from_data(rs, rs, false, Image.FORMAT_RF, bytes))
			regions_written += 1
			if shade_ok:
				# The region's colour map carries mipmaps (the shader samples it mipmapped):
				# rebuild from level 0 and regenerate them.
				var shaded := Image.create_from_data(rs, rs, false, Image.FORMAT_RGBA8, cbytes.slice(0, rs * rs * 4))
				if cimg.has_mipmaps():
					shaded.generate_mipmaps()
				region.set_color_map(shaded)
				regions_shaded += 1
	data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
	if regions_shaded > 0:
		data.update_maps(Terrain3DRegion.TYPE_COLOR, true, false)
	var grass_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture(GRASS_ID) if terrain.get_assets() else null
	if grass_asset:
		grass_asset.set_albedo_color(GRASS_TINT)
	print("GROUND_PAINT v2: grounding -- patch shade %.2f written to %d region colour map(s); Grass tint %s" % [PATCH_SHADE, regions_shaded, GRASS_TINT if grass_asset else "NOT SET"])
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
