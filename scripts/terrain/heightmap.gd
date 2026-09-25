## CPU-side heightmap pipeline: seed derivation, macro valley shape, noise layers, smoothing,
## and build_heightmap(), which runs every terrain-shaping stage in order and returns the maps
## WorldGenerator imports into Terrain3D. Also the color map and control-map packing.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainHeightmap.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainHeightmap
extends RefCounted

## Elevation range, in world units (meters). Kept modest -- this is a
## walkable demo zone, not a mountain sim -- but with enough relief that
## slopes and ridgelines actually read from ground level.
## RIDGE_AMPLITUDE and DETAIL_AMPLITUDE both cut down from the first pass --
## they were the main source of the sharp/rocky look (a tall, high-frequency
## ridged layer reads as jagged peaks no matter what erosion does to it).
## All four amplitudes cut further, and the noise frequencies below
## lowered to match (longer wavelengths), for an overall gentler terrain --
## less total relief, but what relief there is spans a wider area instead
## of packing several rises/dips into a short stretch.
const BASE_AMPLITUDE := 8.0
## Mid-scale rolling variation -- sized so several rises/dips actually fit
## inside a test-sized patch, unlike BASE_AMPLITUDE's much longer wavelength
## (which is close to the whole map size, so locally it reads as one gentle
## tilt rather than "terrain that goes up in places, down in others").
const MID_AMPLITUDE := 4.2
const RIDGE_AMPLITUDE := 2.8
const DETAIL_AMPLITUDE := 0.4
const BASE_LEVEL := 4.0 ## overall lift so most of the area sits above 0
const VALLEY_LEFT_WALL_HEIGHT := 16.0 ## world units, floor-to-rim rise on the low-X (left/tall mountain) side
const VALLEY_RIGHT_WALL_HEIGHT := 8.0 ## world units, floor-to-rim rise on the high-X (right/smaller) side
const VALLEY_WALL_NOISE_DAMPING := 0.35 ## fraction of full noise amplitude that still applies right at the rim (1.0 = no damping, in effect on the floor) -- keeps the wall reading as the macro shape rather than getting broken up by BASE_AMPLITUDE-scale noise, while still leaving some texture so it isn't a dead-smooth ramp

## -- Hydraulic erosion (simplified droplet simulation) --
## Each "droplet" starts at a random point, flows downhill across the
## heightmap picking up sediment on steep fast stretches and depositing it
## once it slows down or the slope flattens out, same as real runoff.
## Reference algorithm: Hans Theobald Beyer's thesis / the version popularized
## by Sebastian Lague's erosion tutorial, without the erosion-radius brush
## (bilinear point erosion/deposit only) for speed at this resolution.
## Iteration count now scales with area (density-based) instead of being a
## fixed number, so testing at AREA_SIZE=64 uses proportionally fewer
## droplets and 512 doesn't need retuning when we scale back up.
const EROSION_DENSITY := 0.075 ## droplets per heightmap pixel
const POST_FEATURE_EROSION_FRACTION := 0.15 ## fraction of EROSION_DENSITY's droplet count, run again AFTER cliff features carve in (see FEATURE_* below) -- adds fine runoff/edge detail onto the deliberately-crisp features without a full second erosion pass strong enough to blur their hand-tuned EDGE_SOFTNESS shaping away

## -- Post-erosion smoothing --
## A straightforward box blur over the heightmap. This is the most direct
## lever for "too jagged" specifically -- it rounds off any single-pixel
## spikes erosion or noise left behind, independent of the noise/erosion
## tuning above. SMOOTH_PASSES=0 disables it entirely for comparison.
## Runs BEFORE the deliberately-crisp cliff FEATURES are added (see
## FEATURE_* below), so strengthening this only softens erosion-carved
## dips/bumps -- it does not round off the engineered cliffs. Raised from
## 2/1 to 3/2 to round off small, locally-steep erosion bowls that were
## showing UV stretch under Terrain3D's flat projection even below the
## cliff-rock threshold -- kept on request.
const SMOOTH_PASSES := 3
const SMOOTH_RADIUS := 2 ## 2 = 5x5 box blur

## NOTE: FEATURE_MIN_LENGTH/MAX_LENGTH, FEATURE_MIN_STEP/MAX_STEP, FEATURE_
## EDGE_SOFTNESS, FEATURE_PLATEAU_WIDTH (and its _MIN_MULT/_MAX_MULT further
## below, alongside FEATURE_EDGE_SOFTNESS_MIN_MULT/_MAX_MULT) are the
## ORIGINAL single-archetype generator's length/step/edge params --
## superseded by the per-archetype ESCARPMENT_*/V_RAVINE_*/TERRACE_*/
## GENTLE_RISE_*/KNOLL_* constants further down (see _add_cliff_features /
## _place_line_feature / _place_knoll). Kept only as a record of the old
## tuning -- FEATURE_DENSITY, FEATURE_MIN_GAP, FEATURE_END_FALLOFF, and the
## FEATURE_CURVE_*/FEATURE_HEIGHT_*/FEATURE_EDGE_NOISE_* wander/jitter
## constants below are all still live and shared across every archetype.
## -- Sparse hard features (small cliffs / ledges / stream cuts) --
## Applied AFTER erosion+smoothing, on purpose: everything else in the
## heightmap gets rounded off and softened, but these should stay crisp --
## that contrast is what makes them read as a deliberate feature ("there's
## a low cliff by the path") instead of just more noise. Each feature is a
## short straight-ish "fault line": a band that steps the height up/down by
## a modest amount, with a smooth transition across its width (so it's a
## proper cliff face, not a 1-pixel wall) and a fade-out at both tips (so it
## blends into the surrounding terrain instead of just stopping). Kept short
## and modest in height deliberately -- these should be a local landmark
## you can walk around, not a barrier that blocks traversal.
const FEATURE_DENSITY := 1.5 / 3000.0 ## features per heightmap pixel (map area, not droplets) (2026-09-16: +5% -- more obstacles for the road A* to actually route around, per the road-snaking analysis; a small nudge, not a redesign)

## -- Macro color variation --
## Terrain3D's color map (the third import_images slot, left null/unused
## until now) multiplies directly into every pixel's albedo, and its alpha
## nudges roughness around a neutral 0.5 -- see _build_color_map. This
## doesn't touch which texture is painted where, it just tints what's
## already there using noise at a much lower frequency than any texture's
## own tiling (or the terrain noise layers above), so two patches painted
## with the exact same texture never look perfectly identical from a
## distance. This is the single biggest lever for "the same texture
## repeats as far as the eye can see", since it acts everywhere at once
## rather than only at texture boundaries like the slope/road blending
## below. Three independent noise fields/frequencies so brightness,
## warm/cool tint, and roughness patches don't all track each other 1:1.
const MACRO_TINT_FREQUENCY := 1.0 / 140.0
const MACRO_TINT_STRENGTH := 0.14 ## +/- fractional brightness swing
const MACRO_HUE_FREQUENCY := 1.0 / 95.0
const MACRO_HUE_STRENGTH := 0.05 ## subtle warm/cool tilt between the R and B channels
const MACRO_ROUGH_FREQUENCY := 1.0 / 60.0
const MACRO_ROUGH_STRENGTH := 0.06

## -- Blend-edge detail noise --
## Adds small, high-frequency noise into the road shoulder's smooth
## analytic boundary so it reads as an irregular dirt edge instead of a
## mathematically perfect contour -- a dead-smooth curve is one of the
## most obvious "this was generated" tells even when the textures
## themselves are fine.
const EDGE_NOISE_FREQUENCY := 1.0 / 14.0 ## (2026-09-16: lowered from 1/6 -- a 6-unit wavelength is a fast, tight zigzag that reads as noisy texture-level detail rather than an actual bend when the road is only 4 units wide and viewed from a distance/shallow angle; a longer ~14-unit wavelength produces fewer, bigger, slower sweeps that are actually perceptible as "the edge isn't straight" instead of blending into visual noise.)

## Derives one integer seed per pipeline sub-system from a single master
## seed, in a fixed order, so the mapping from master seed -> individual
## seeds never changes between runs. Keyed by name rather than index so
## callers don't need to remember an order.
static func _derive_seeds(master_seed: int) -> Dictionary:
	var seeder := RandomNumberGenerator.new()
	seeder.seed = master_seed
	return {
		"base": seeder.randi(),
		"mid": seeder.randi(),
		"ridge": seeder.randi(),
		"warp": seeder.randi(),
		"detail": seeder.randi(),
		"erosion": seeder.randi(),
		"features": seeder.randi(),
		"road": seeder.randi(),
		"macro_tint": seeder.randi(),
		"macro_hue": seeder.randi(),
		"macro_rough": seeder.randi(),
		"edge": seeder.randi(),
	}

## Returns {height, wall_t} for a given heightmap-pixel X position -- the
## valley's cross-section only depends on X, since its axis runs straight
## along Z (see the VALLEY_* consts' comment above). `height` is the macro
## valley elevation at this X, BEFORE any noise is added. `wall_t` is 0.0
## anywhere on the flat floor and smoothly ramps to 1.0 at the rim; callers
## use it to damp down noise amplitude on the steep walls (VALLEY_WALL_
## NOISE_DAMPING) so noise reads as texture riding on the wall rather than
## fighting the shape that's supposed to define the map.
static func _valley_profile(px: float, width: int) -> Dictionary:
	var x_norm := px / float(maxi(width - 1, 1))
	var floor_half := TerrainConfig.VALLEY_FLOOR_WIDTH_FRACTION * 0.5
	var floor_lo := 0.5 - floor_half
	var floor_hi := 0.5 + floor_half
	if x_norm >= floor_lo and x_norm <= floor_hi:
		return {"height": BASE_LEVEL, "wall_t": 0.0}
	if x_norm < floor_lo:
		var t := clampf((floor_lo - x_norm) / floor_lo, 0.0, 1.0)
		var wall_t := smoothstep(0.0, 1.0, t)
		return {"height": BASE_LEVEL + VALLEY_LEFT_WALL_HEIGHT * wall_t, "wall_t": wall_t}
	else:
		var t := clampf((x_norm - floor_hi) / (1.0 - floor_hi), 0.0, 1.0)
		var wall_t := smoothstep(0.0, 1.0, t)
		return {"height": BASE_LEVEL + VALLEY_RIGHT_WALL_HEIGHT * wall_t, "wall_t": wall_t}

## Three noise layers at different scales, combined and lightly shaped so
## it reads as terrain rather than a random bumpy blob:
##   base   -- low frequency FBM, the big rolling hills / valleys
##   ridge  -- ridged fractal, gives a few mountain-ridge-like features
##   detail -- high frequency FBM, small-scale roughness so it isn't
##             perfectly smooth up close
static func build_heightmap(master_seed: int = TerrainConfig.MASTER_SEED) -> Dictionary:
	# Perf instrumentation (2026-09-16): prints elapsed time for each stage
	# so a slow regeneration (e.g. after raising AREA_WIDTH/AREA_LENGTH) can
	# be attributed to a specific step instead of guessed at. t_stage resets
	# at the start of each stage; t_start tracks the grand total.
	var t_start := Time.get_ticks_msec()
	var t_stage := t_start
	var seeds := _derive_seeds(master_seed)

	var base_noise := FastNoiseLite.new()
	base_noise.seed = seeds.base
	base_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	base_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	base_noise.fractal_octaves = 5
	base_noise.fractal_lacunarity = 2.0
	base_noise.fractal_gain = 0.45
	# Lengthened from 1/180 -- bigger, gentler rolling terrain: each
	# rise/fall now spans a wider stretch of the map instead of packing
	# more of them into the same area.
	base_noise.frequency = 1.0 / 260.0

	var mid_noise := FastNoiseLite.new()
	mid_noise.seed = seeds.mid
	mid_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	mid_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	mid_noise.fractal_octaves = 4
	mid_noise.fractal_lacunarity = 2.0
	mid_noise.fractal_gain = 0.5
	# Lengthened from 1/55 -- same "bigger area per hill" goal as base_noise
	# above, just at mid_noise's own (originally shorter) scale.
	mid_noise.frequency = 1.0 / 95.0

	var ridge_noise := FastNoiseLite.new()
	ridge_noise.seed = seeds.ridge
	ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge_noise.fractal_octaves = 5
	ridge_noise.fractal_lacunarity = 2.2
	ridge_noise.fractal_gain = 0.5
	# Wavelength (1/frequency) needs to be meaningfully SMALLER than the map
	# itself, or the map only ever shows a small, nearly-monotonic slice of
	# one ridge cycle -- which reads as "cliffs are always a straight line",
	# since ridged noise only picks up its natural bends/branches/forks over
	# the course of a full wavelength. Previous value (1/260) had a longer
	# wavelength than the whole 256-unit map, so it was structurally
	# incapable of showing more than one straight-ish stretch. 1/70 gives
	# roughly 3-4 wavelengths across the map, room for real lateral curvature
	# and branching. One extra octave adds finer wiggle on top of that bend.
	# Widened somewhat (1/70 -> 1/90) for the same "gentler, bigger-area"
	# pass as the other layers -- kept well short of the map size, though,
	# so it doesn't regress back into the "always a straight line" problem
	# described above.
	ridge_noise.frequency = 1.0 / 90.0

	# Dedicated, gentle noise field for the domain warp below -- kept
	# separate from ridge_noise on purpose. The warp used to reuse
	# ridge_noise directly, which worked fine at its old, slow frequency
	# (1/260), but once ridge_noise's frequency was raised to 1/70 for
	# lateral cliff curvature, the SAME faster noise was also warping
	# base_noise/mid_noise's sample coordinates much more rapidly across
	# space -- and since those two layers carry the largest amplitudes
	# (BASE_AMPLITUDE=12, MID_AMPLITUDE=5), that turned the whole map
	# noticeably choppier/"bumpier" everywhere, not just at the ridgelines.
	# A separate, slow-frequency field keeps the big rolling hills smooth
	# regardless of how fast the ridge layer itself needs to wiggle.
	var warp_noise := FastNoiseLite.new()
	warp_noise.seed = seeds.warp
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	warp_noise.fractal_octaves = 3
	warp_noise.fractal_lacunarity = 2.0
	warp_noise.fractal_gain = 0.5
	# Kept matching base_noise's own (now longer) wavelength -- if this
	# stayed short while base/mid got stretched out, the warp itself would
	# reintroduce higher-frequency wiggle into the big layers it's bending,
	# working against the gentler goal.
	warp_noise.frequency = 1.0 / 260.0

	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = seeds.detail
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 3
	detail_noise.fractal_lacunarity = 2.0
	detail_noise.fractal_gain = 0.5
	# Slightly lengthened (1/22 -> 1/28) alongside DETAIL_AMPLITUDE's cut --
	# a touch less close-up roughness to match the overall gentler feel,
	# without losing the fine texture entirely.
	detail_noise.frequency = 1.0 / 28.0

	# Domain warp on the base layer only -- offsets what coordinates it
	# samples at, using the ridge noise as the warp field. This is what
	# keeps the big hills from looking like a tidy grid of noise bumps;
	# it bends the whole base pattern into more irregular, natural shapes.
	const WARP_STRENGTH := 40.0

	# Build into a flat PackedFloat32Array first, not the Image directly --
	# erosion needs to read/write the same heights thousands of times per
	# droplet, and Image.get_pixel/set_pixel's per-call Color boxing makes
	# that far too slow at this resolution. The Image is only assembled at
	# the very end, once, from the eroded array.
	# Per-column macro valley data, precomputed once since the valley's
	# cross-section only depends on X (see _valley_profile) -- avoids
	# recomputing/reallocating it AREA_LENGTH times over inside the loop
	# below.
	var valley_height := PackedFloat32Array()
	var valley_noise_scale := PackedFloat32Array()
	valley_height.resize(TerrainConfig.AREA_WIDTH)
	valley_noise_scale.resize(TerrainConfig.AREA_WIDTH)
	for px in TerrainConfig.AREA_WIDTH:
		var valley := _valley_profile(px, TerrainConfig.AREA_WIDTH)
		valley_height[px] = valley.height
		valley_noise_scale[px] = lerpf(1.0, VALLEY_WALL_NOISE_DAMPING, valley.wall_t)
	print("TERRAIN_GEN: valley cross-section (pre-noise) left_rim=%.2f floor=%.2f right_rim=%.2f" \
		% [valley_height[0], valley_height[int(TerrainConfig.AREA_WIDTH * 0.5)], valley_height[TerrainConfig.AREA_WIDTH - 1]])

	var heights := PackedFloat32Array()
	heights.resize(TerrainConfig.AREA_WIDTH * TerrainConfig.AREA_LENGTH)
	for pz in TerrainConfig.AREA_LENGTH:
		for px in TerrainConfig.AREA_WIDTH:
			var warp_x := px + warp_noise.get_noise_2d(px, pz) * WARP_STRENGTH
			var warp_z := pz + warp_noise.get_noise_2d(pz, px) * WARP_STRENGTH

			var base := base_noise.get_noise_2d(warp_x, warp_z) # -1..1
			var mid := mid_noise.get_noise_2d(warp_x, warp_z) # -1..1 -- shares the warp so it bends with the base layer instead of looking like an independent grid
			var ridge := ridge_noise.get_noise_2d(px, pz) # -1..1
			# Ridged shaping: fold around 0 so ridges add height rather than
			# also carving symmetric trenches, then SQUARE the fold instead of
			# using it linearly. Linear fold makes a sharp V-shaped cross
			# section (a knife-edge ridge); squaring it rounds the apex into
			# a dome/hill profile instead while still tapering to 0 at the
			# base -- same footprint, much less "jagged mountain" silhouette.
			var ridge_fold := maxf(0.0, 1.0 - absf(ridge) * 2.0)
			var ridge_shaped := ridge_fold * ridge_fold
			var detail := detail_noise.get_noise_2d(px, pz) # -1..1

			# The macro valley shape (flat floor -> steepening wall -> rim,
			# asymmetric left/right) is now the BASE of the height, replacing
			# the old flat BASE_LEVEL constant -- noise perturbs that shape
			# rather than defining the terrain's silhouette by itself. Noise
			# amplitude is damped on the walls (valley_noise_scale, full
			# strength on the floor) so the wall still reads as the macro
			# shape underneath its own texture instead of getting broken up.
			var height := valley_height[px] \
				+ (base * BASE_AMPLITUDE \
					+ mid * MID_AMPLITUDE \
					+ ridge_shaped * RIDGE_AMPLITUDE \
					+ detail * DETAIL_AMPLITUDE) * valley_noise_scale[px]
			heights[pz * TerrainConfig.AREA_WIDTH + px] = height
	print("TERRAIN_GEN: base noise+valley heightmap done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	var erosion_iterations := maxi(200, int(TerrainConfig.AREA_WIDTH * TerrainConfig.AREA_LENGTH * EROSION_DENSITY))
	print("TERRAIN_GEN: eroding (%d droplets)..." % erosion_iterations)
	var erosion_rng := RandomNumberGenerator.new()
	erosion_rng.seed = seeds.erosion
	TerrainErosion.erode(heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, erosion_rng, erosion_iterations)
	print("TERRAIN_GEN: erosion done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	if SMOOTH_PASSES > 0:
		print("TERRAIN_GEN: smoothing (%d pass(es))..." % SMOOTH_PASSES)
		smooth(heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, SMOOTH_PASSES, SMOOTH_RADIUS)
		print("TERRAIN_GEN: smoothing done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
		t_stage = Time.get_ticks_msec()

	var feature_count := maxi(1, int(TerrainConfig.AREA_WIDTH * TerrainConfig.AREA_LENGTH * FEATURE_DENSITY))
	print("TERRAIN_GEN: adding %d cliff/ledge feature(s)..." % feature_count)
	var feature_rng := RandomNumberGenerator.new()
	feature_rng.seed = seeds.features
	var cliff_features := CliffFeatures.add_cliff_features(heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, feature_rng, feature_count)
	print("TERRAIN_GEN: cliff features done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# Second, much lighter erosion pass -- runs AFTER carving so the crisp
	# features get real runoff/edge detail instead of none at all, but at
	# a fraction of the main pass's droplet count so it doesn't undo their
	# hand-tuned EDGE_SOFTNESS shaping. Continues erosion_rng's own sequence
	# rather than reseeding, so it's still fully deterministic per-seed.
	var post_feature_erosion_iterations := maxi(50, int(erosion_iterations * POST_FEATURE_EROSION_FRACTION))
	print("TERRAIN_GEN: post-feature erosion (%d droplets)..." % post_feature_erosion_iterations)
	TerrainErosion.erode(heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, erosion_rng, post_feature_erosion_iterations)
	print("TERRAIN_GEN: post-feature erosion done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# Cliff dressing is PLANNED here (2026-09-17 reorder, moved AGAIN the same day -- now
	# BEFORE road routing instead of after). Reasoning: cliff-dressing footprints are still
	# terrain, so once they're placed/flattened into the heightmap, the road should treat them
	# as real obstacles to route around, the same way it already routes around a too-steep
	# slope -- rather than cliff placement reactively dodging an already-drawn road. Doing this
	# before Terrain3D import (rather than after, in _ready()) is what lets
	# _flatten_terrain_for_cliff_dressing carve the plain `heights` array directly -- see that
	# function's own comment. Same salt-XOR derivation _ready() used to do locally for this RNG
	# (purely cosmetic placement, doesn't need to be in _derive_seeds' fixed derivation order
	# any more than boulder_rng does).
	var cliff_dressing_rng := RandomNumberGenerator.new()
	cliff_dressing_rng.seed = master_seed ^ 0x434C4646 # 'CLFF' salt
	var cliff_dressing_plan := CliffDressing.plan_cliff_dressing(cliff_features, heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, cliff_dressing_rng)
	CliffDressing.flatten_terrain_for_cliff_dressing(cliff_dressing_plan, heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)
	var cliff_dressing_top_profiles := CliffDressing.build_cliff_dressing_top_profiles()
	CliffDressing.raise_terrain_behind_cliff_dressing(cliff_dressing_plan, heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, cliff_dressing_top_profiles, master_seed ^ 0x52414953) # 'RAIS' salt, round 20
	var cliff_obstacle_mask := CliffDressing.build_cliff_dressing_obstacle_mask(cliff_dressing_plan, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)
	print("TERRAIN_GEN: cliff dressing planned + terrain flattened/raised to match (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# 2026-09-20 round 2: flat rock outcrops (mountainside) -- planned and the terrain conformed
	# to each one's real underside HERE, before road routing + Terrain3D import, same reasoning
	# as cliff dressing above. Instanced later in _ready (_place_outcrops).
	var outcrop_models := TerrainOutcrops.load_outcrop_models()
	var outcrop_rng := RandomNumberGenerator.new()
	outcrop_rng.seed = master_seed ^ 0x4F555443 # 'OUTC' salt
	var outcrop_plan := TerrainOutcrops.plan_outcrops(outcrop_models, heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, outcrop_rng, cliff_dressing_plan)
	TerrainOutcrops.fit_terrain_to_outcrops(outcrop_plan, outcrop_models, heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)
	TerrainOutcrops.add_outcrops_to_obstacle_mask(outcrop_plan, cliff_obstacle_mask, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)
	print("TERRAIN_GEN: outcrops planned + terrain fitted (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# Control map: defaults to ground everywhere; the road step below paints
	# over it where it runs. Built as plain ints (packed base/overlay/blend)
	# rather than floats, since that's what the road step naturally produces --
	# converted to the Image's float-encoded form only once, at the end.
	var control := PackedInt32Array()
	control.resize(TerrainConfig.AREA_WIDTH * TerrainConfig.AREA_LENGTH)
	var ground_packed := _pack_control(TerrainConfig.GROUND_TEXTURE_ID)
	for i in control.size():
		control[i] = ground_packed

	var edge_noise := FastNoiseLite.new()
	edge_noise.seed = seeds.edge
	edge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	edge_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	edge_noise.fractal_octaves = 2
	edge_noise.frequency = EDGE_NOISE_FREQUENCY

	print("TERRAIN_GEN: routing road...")
	var road_rng := RandomNumberGenerator.new()
	road_rng.seed = seeds.road
	var road_result := TerrainRoad.generate_road(heights, control, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, road_rng, edge_noise, cliff_obstacle_mask)
	var road_weight: PackedFloat32Array = road_result.weight
	print("TERRAIN_GEN: road routing done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	_print_roughness_stats(heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)

	# height_image built directly from `heights`' raw bytes (2026-09-16) --
	# `heights` is already a PackedFloat32Array in the exact row-major
	# (pz*width+px) layout Image.FORMAT_RF expects (one 32-bit float per
	# pixel), so create_from_data with to_byte_array() is a straight memcpy
	# equivalent to the old per-pixel set_pixel(px, pz, Color(v,0,0)) loop --
	# same bytes end up in the image either way -- just without a
	# width*length count of Image method calls + Color object allocations.
	# control_image keeps set_pixel: each pixel needs Terrain3DUtil.as_float's
	# int32-bits-as-float32-bits reinterpretation first, and that per-pixel
	# transform isn't worth risking a subtle mismatch for (it's a much
	# smaller share of this stage's cost than height_image was).
	var height_image := Image.create_from_data(TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, false, Image.FORMAT_RF, heights.to_byte_array())
	var control_image := Image.create(TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, false, Image.FORMAT_RF)
	for pz in TerrainConfig.AREA_LENGTH:
		for px in TerrainConfig.AREA_WIDTH:
			var idx := pz * TerrainConfig.AREA_WIDTH + px
			control_image.set_pixel(px, pz, Color(Terrain3DUtil.as_float(control[idx]), 0.0, 0.0))
	print("TERRAIN_GEN: height/control image assembly done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	print("TERRAIN_GEN: building macro color-variation map...")
	var color_image := _build_color_map(seeds, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH)
	print("TERRAIN_GEN: color map done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	print("TERRAIN_GEN: _build_heightmap TOTAL (%.2fs)" % ((Time.get_ticks_msec() - t_start) / 1000.0))
	return {"height": height_image, "control": control_image, "color": color_image, "cliff_features": cliff_features, "cliff_dressing_plan": cliff_dressing_plan, "cliff_dressing_top_profiles": cliff_dressing_top_profiles, "outcrop_plan": outcrop_plan, "outcrop_models": outcrop_models, "heights": heights, "road_weight": road_weight, "spawn_pixel": road_result.spawn_pixel, "exit_pixel": road_result.exit_pixel, "road_path": road_result.path}

## Builds the terrain's color map: a full-resolution RGBA image Terrain3D
## multiplies directly into every pixel's albedo (alpha nudges roughness
## around its neutral 0.5). See the MACRO_* constants' comment above for
## why this exists -- it's what keeps the same ground texture from looking
## identical patch to patch across the whole visible map.
static func _build_color_map(seeds: Dictionary, width: int, length: int) -> Image:
	var tint_noise := FastNoiseLite.new()
	tint_noise.seed = seeds.macro_tint
	tint_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	tint_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	tint_noise.fractal_octaves = 3
	tint_noise.frequency = MACRO_TINT_FREQUENCY

	var hue_noise := FastNoiseLite.new()
	hue_noise.seed = seeds.macro_hue
	hue_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hue_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	hue_noise.fractal_octaves = 3
	hue_noise.frequency = MACRO_HUE_FREQUENCY

	var rough_noise := FastNoiseLite.new()
	rough_noise.seed = seeds.macro_rough
	rough_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	rough_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	rough_noise.fractal_octaves = 2
	rough_noise.frequency = MACRO_ROUGH_FREQUENCY

	var image := Image.create(width, length, false, Image.FORMAT_RGBA8)
	for pz in length:
		for px in width:
			var tint := 1.0 + tint_noise.get_noise_2d(px, pz) * MACRO_TINT_STRENGTH
			var hue := hue_noise.get_noise_2d(px, pz) * MACRO_HUE_STRENGTH
			var rough := 0.5 + rough_noise.get_noise_2d(px, pz) * MACRO_ROUGH_STRENGTH
			image.set_pixel(px, pz, Color(tint + hue, tint, tint - hue, rough))
	return image

## Packs a solid, unblended control-map pixel for the given texture id
## (base = overlay = id, blend = 0) and returns it as the raw packed int --
## NOT yet the float-reinterpreted form an Image pixel needs (see
## Terrain3DUtil.as_float, applied once at image-assembly time above).
static func _pack_control(texture_id: int) -> int:
	return Terrain3DUtil.enc_base(texture_id) | Terrain3DUtil.enc_overlay(texture_id) | Terrain3DUtil.enc_blend(0)

## Packs a CROSS-FADED control-map pixel between two different texture ids --
## the companion _pack_control() above always sets base==overlay, which is a
## no-op blend (blending a texture with itself looks identical regardless of
## the blend value), and that's why the road edge used to be a razor-sharp
## swap no matter how jittered its outline was. Here base and overlay are
## genuinely different textures, and Terrain3D's shader actually cross-fades
## between them using blend (0 = 100% base, 255 = 100% overlay -- see
## Terrain3DUtil.enc_blend/get_blend). blend_frac is 0.0..1.0 and gets
## rounded to that 0-255 byte range.
static func pack_control_blend(base_id: int, overlay_id: int, blend_frac: float) -> int:
	var blend_byte := clampi(int(round(clampf(blend_frac, 0.0, 1.0) * 255.0)), 0, 255)
	return Terrain3DUtil.enc_base(base_id) | Terrain3DUtil.enc_overlay(overlay_id) | Terrain3DUtil.enc_blend(blend_byte)

## Prints min/max height and the average absolute height difference
## between horizontally/vertically adjacent pixels ("roughness") plus the
## single sharpest jump found -- the number to actually watch when tuning
## for "smoother". A gentle rolling hill has an average adjacent delta of a
## few hundredths to low tenths of a unit at 1 vertex/unit spacing; the
## first (too jagged) pass was landing well above 1.0 in places. Printed
## regardless of APPLY_TO_TERRAIN so tuning never needs to touch the live
## terrain to see whether a change helped.
static func _print_roughness_stats(heights: PackedFloat32Array, width: int, length: int) -> void:
	var min_h := heights[0]
	var max_h := heights[0]
	var delta_sum := 0.0
	var delta_count := 0
	var max_delta := 0.0
	for pz in length:
		for px in width:
			var h := heights[pz * width + px]
			min_h = minf(min_h, h)
			max_h = maxf(max_h, h)
			if px < width - 1:
				var dx := absf(h - heights[pz * width + px + 1])
				delta_sum += dx
				delta_count += 1
				max_delta = maxf(max_delta, dx)
			if pz < length - 1:
				var dz := absf(h - heights[(pz + 1) * width + px])
				delta_sum += dz
				delta_count += 1
				max_delta = maxf(max_delta, dz)
	print("TERRAIN_GEN: height range=[%.2f, %.2f] avg_adjacent_delta=%.4f max_adjacent_delta=%.4f" \
		% [min_h, max_h, delta_sum / delta_count, max_delta])

## Simple box blur, `passes` times, with a (2*radius+1)^2 window and
## clamped-to-edge sampling. This is the direct fix for "jagged/rocky":
## it doesn't care why a spike is there (noise, erosion, a single bad
## droplet) -- it just rounds off anything sharper than its window, which
## is exactly what removes a rocky/jagged read while leaving the big
## rolling shapes (hills, valleys) intact since those span many pixels.
## Separable, SLIDING-WINDOW box blur (2026-09-16, second pass on this
## function -- first cut it from a full 2D kernel to an independent
## horizontal-then-vertical pass, see the earlier comment history in this
## project's CLAUDE.md; this second change adds a running sum on top of
## that separation). A box filter's per-position sum only changes by ONE
## term leaving and ONE term entering as the window slides over by a
## single pixel, so each 1D pass now costs O(1) amortized work per pixel
## (one add, one subtract) instead of O(2*radius+1) full resamples --
## independent of radius, not just cheaper at a fixed radius.
##
## Verified equivalent to plain per-position resampling even at clamped
## edges, where the same clamped index can legitimately appear more than
## once in one window: track the leaving/entering term by its UNCLAMPED
## window position (each independently clamped only at the point of
## lookup), not by array index, and the running sum stays exactly correct
## through the clamped region too. Concretely, sliding from px-1 to px:
## the window's unclamped range shifts from [px-1-radius, px-1+radius] to
## [px-radius, px+radius], so the term leaving is always unclamped
## position (px-1-radius) and the term entering is always unclamped
## position (px+radius) -- true whether or not either lands outside
## [0, width-1] and needs clamping.
##
## The vertical pass keeps one running sum PER COLUMN (`col_sum`, sized
## `width`) rather than a single scalar, specifically so the loop order can
## stay row-major (pz outer, px inner) for sequential/cache-friendly access
## into row_buffer and heights -- a column-outer loop would have the same
## O(1)-per-pixel amortized cost but jump by a full row's stride on every
## single read.
##
## Per-stage timing (see _build_heightmap) showed this function, even
## after the horizontal/vertical separation above, was still by far the
## single biggest cost in a heightmap build (the ROAD_SMOOTH_RADIUS=3
## call inside _generate_road alone was ~32% of total build time) -- this
## sliding-window change is the further fix for that.
static func smooth(heights: PackedFloat32Array, width: int, length: int, passes: int, radius: int) -> void:
	var window := 2 * radius + 1
	var row_buffer := PackedFloat32Array()
	row_buffer.resize(width * length)
	var col_sum := PackedFloat32Array()
	col_sum.resize(width)
	for p in passes:
		# Horizontal pass: row_buffer[pz][px] = sliding-window avg over
		# heights[pz][clamp(px+dx)]. Reads only from `heights` (this pass's
		# input), writes only to `row_buffer` -- no aliasing hazard.
		for pz in length:
			var row_start := pz * width
			var sum := 0.0
			for dx in range(-radius, radius + 1):
				sum += heights[row_start + clampi(dx, 0, width - 1)]
			row_buffer[row_start] = sum / window
			for px in range(1, width):
				var leaving := clampi(px - 1 - radius, 0, width - 1)
				var entering := clampi(px + radius, 0, width - 1)
				sum += heights[row_start + entering] - heights[row_start + leaving]
				row_buffer[row_start + px] = sum / window

		# Vertical pass: heights[pz][px] = sliding-window avg over
		# row_buffer[clamp(pz+dz)][px]. Reads only from `row_buffer`, writes
		# only to `heights` -- safe to write in place since this pass never
		# reads `heights`.
		col_sum.fill(0.0)
		for dz in range(-radius, radius + 1):
			var base := clampi(dz, 0, length - 1) * width
			for px in width:
				col_sum[px] += row_buffer[base + px]
		for px in width:
			heights[px] = col_sum[px] / window
		for pz in range(1, length):
			var leaving_base := clampi(pz - 1 - radius, 0, length - 1) * width
			var entering_base := clampi(pz + radius, 0, length - 1) * width
			var row_base := pz * width
			for px in width:
				col_sum[px] += row_buffer[entering_base + px] - row_buffer[leaving_base + px]
				heights[row_base + px] = col_sum[px] / window
