extends Node3D

## 2026-09-18 debug scaffolding (Kirill: "comment temporarily the script generating the
## terrain, instead of that, generate yellow debug boxes, with the same logic"): while
## chasing the cliff-dressing lateral-raise bug, _raise_terrain_behind_cliff_dressing below
## records every pixel it WOULD have modified (and the exact blended height it would have
## written) here instead of touching `heights`, in grid-space (pre-heightmap_corner) since
## that offset isn't known yet when the raise pass runs. _spawn_raise_debug_boxes converts
## these into a continuous yellow surface once heightmap_corner is known (a full-resolution
## buffer, not sparse points, so adjacent pixels can be triangulated into quads -- see
## RAISE_DEBUG_UNSET below for how "this pixel was never touched" is marked). Remove both
## once the real fix is confirmed in-game and this scaffolding is no longer needed.
const RAISE_DEBUG_UNSET := -1e8 ## sentinel marking a heightmap pixel the raise pass never touched at all
var _raise_debug_heights: PackedFloat32Array = PackedFloat32Array()
## 2026-09-18 round 19: the raise pass now writes this surface into the real terrain, so the
## overlay would sit exactly on the ground and z-fight. Hidden, not removed -- flip to true to
## bring the color-coded preview back for further debugging.
const RAISE_DEBUG_SHOW_SURFACE := false
## 2026-09-18 round 16 ("still nothing" -- the last two fixes targeted a JOIN case, but the
## mesh actually closest to Kirill's repro position turned out to be fully isolated on both
## sides -- nearest_gap_left=91.13, nearest_gap_right=inf -- so neither fix could have done
## anything there. The combined max() debug surface makes multiple overlapping placements'
## contributions visually indistinguishable, which is exactly how that got misattributed.
## Track which plan entry_index actually WON the max at each pixel so the surface can be
## colored per-contributing-mesh instead of a single flat yellow, making this unambiguous
## from a screenshot alone next time.
var _raise_debug_entry_index: PackedInt32Array = PackedInt32Array()

## -- Master seed --
## Every noise layer, the erosion RNG, and the cliff-feature RNG derive
## their individual seed from this ONE value (via _derive_seeds below)
## instead of each carrying its own hardcoded seed. That's what makes both
## "one seed per runtime session" and "regenerate the exact same map later
## from a saved seed" simple: change this number and the whole pipeline
## reshuffles together as one unit.
##
## -1 (default) -- randomize: a fresh seed is rolled via randi() every time
##                 this scene runs, so every run is a different map. The
##                 seed actually used is always printed at the top of the
##                 console output, specifically so a result you like can be
##                 reproduced: copy that printed number in here to pin it.
## any other int -- always regenerate that exact map (byte-identical every
##                  run). Useful while tuning a specific result, or for
##                  pinning down a bug tied to one particular seed.
const MASTER_SEED := -1
#const MASTER_SEED := 1195801279

## World-space size of the area to (re)generate, in world units --
## independent X (width) and Z (length) so it doesn't have to be square.
## For a LIVE (not TEST) regeneration, keep each a multiple of Terrain3D's
## region size (256 by default, read at runtime via get_region_size() in
## _ready() -- see the heightmap_corner comment below) so it aligns cleanly
## on region boundaries. Erosion iterations and smoothing below both scale
## with AREA_WIDTH*AREA_LENGTH, so no other retuning is needed when you
## resize either axis. When either axis exceeds the region size, Terrain3D
## spans multiple regions -- see the heightmap_corner gotcha in _ready().
const AREA_WIDTH := 256 ## X axis -- one region's worth of real generated terrain, no flat filler
const AREA_LENGTH := 512 ## Z axis -- spans two regions (see note above)
const VERTEX_SPACING := 1.0

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

## -- Macro valley shape --
## The playable area reads as a U-shaped glacial valley: a flat-ish floor in
## the middle of the map, steepening walls on both sides, up to a rim. This
## runs BEFORE the noise layers below and defines the macro shape noise
## perturbs -- noise no longer defines the terrain's overall silhouette by
## itself (see _valley_profile and its use in _build_heightmap). The
## valley's long axis is straight, aligned with the map's Z axis at the
## map's X-center (x = AREA_WIDTH*0.5) -- this deliberately matches the
## road's forced north/south endpoints (_generate_road), which are also
## pinned to x = width*0.5, so the road that gets routed afterward naturally
## starts and ends on the valley floor, then curves around whatever macro/
## micro terrain (wall, cliff features) its A* pathfinding finds in the way
## -- the valley SHAPE stays a straight-axis macro feature; only the road's
## routed path bends.
## Asymmetric on purpose: LEFT wall (low X) is the tall mountain boundary,
## RIGHT wall (high X) is the smaller one -- both are geometry-only for now
## (no distinct meshes/textures/snow/fog yet -- that's an explicitly later
## pass, not part of this macro-shape work).
const VALLEY_FLOOR_WIDTH_FRACTION := 0.55 ## fraction of AREA_WIDTH that's floor (flat-ish, walkable, room for nooks/crannies/snaking paths/structures/ruins/woods/glades/meadow/caves later) -- the remaining (1-this)/2 on each side is wall
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
const MAX_DROPLET_LIFETIME := 32
const INERTIA := 0.1 ## 0 = always follows steepest descent, 1 = never turns -- raised slightly so droplets wander instead of cutting razor-straight channels
const SEDIMENT_CAPACITY_FACTOR := 3.0 ## lower than before -- less aggressive carving
const MIN_SEDIMENT_CAPACITY := 0.01
const ERODE_SPEED := 0.15 ## halved -- was carving canyon-sharp walls
const DEPOSIT_SPEED := 0.45 ## raised -- fills back in faster, rounds off peaks
const EVAPORATE_SPEED := 0.02
const GRAVITY := 4.0
const INITIAL_WATER_VOLUME := 1.0
const INITIAL_SPEED := 1.0

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
const FEATURE_MIN_LENGTH := 24.0 ## world units, the walkable length of the cliff line
const FEATURE_MAX_LENGTH := 56.0
## Both raised from 1.25/3.0. The face's actual steepest slope is
## 1.5*step_height/(2*FEATURE_EDGE_SOFTNESS) (derivative of the smoothstep
## at its midpoint) -- with the old 1.25-3.0 range and EDGE_SOFTNESS=7.0,
## that tops out around rise/run 0.32 (~18 degrees), nowhere near
## 1.0 (45 degrees). So the feature was geometrically present in the
## heightmap but never steep enough to read visually as a cliff instead of
## a gentle grassy rise -- it was invisible by construction, not by a
## placement/shape bug. See FEATURE_EDGE_SOFTNESS below for the other half
## of this fix. (Rock texturing based on this slope threshold was removed
## later -- these features are geometry-only cliffs/ledges now.)
const FEATURE_MIN_STEP := 2.5 ## world units of height change across the cliff face -- small features stay a soft grassy ledge for variety
const FEATURE_MAX_STEP := 5.0 ## the biggest features are the tallest, steepest cliff faces this generator produces
## Widened from 3.5: Terrain3D's projection switch is a hard binary cutoff
## at exactly 45 degrees with no blending across it, so there's always a
## visible seam line where the
## surface crosses that angle -- a real limitation of this technique, not
## something texture/slope tuning alone fully removes. Widening the
## transition spreads that crossing over more world-space distance (more
## triangles, gentler curvature there), which softens how sharp the seam
## reads without changing the cliffs' overall height/shape.
## Narrowed back down from 7.0. That widen was meant to soften Terrain3D's
## hard 45-degree texture-projection seam, but it had an unnoticed side
## effect: it also capped the face's own steepest slope well below the
## 45-degree threshold needed for ANY rock texture to appear at all (see
## FEATURE_MIN_STEP/MAX_STEP above for the math) -- trading a softer seam
## for a cliff that never renders as a cliff. Visibility wins that
## tradeoff: a real cliff with a slightly sharper texture seam beats an
## invisible one.
const FEATURE_EDGE_SOFTNESS := 3.0 ## half-width, in units, of the smooth transition across the face
const FEATURE_END_FALLOFF := 6.0 ## units of fade-out at each tip of the line
## How far perpendicular to the fault line the raised/lowered plateau
## extends on its "high" side before blending back down into unmodified
## terrain. Deliberately kept well under FEATURE_MIN_LENGTH -- if this were
## as wide as (or wider than) the feature is long, the footprint reads as a
## round blob/mound instead of an elongated wall, which is what happened
## when the lateral falloff below was first added using `reach` (which
## scales with length) as its width instead of a dedicated, much smaller
## constant.
## Must clear FEATURE_EDGE_SOFTNESS (the face's own 0-to-1 ramp, which only
## finishes climbing around d=EDGE_SOFTNESS) by a real margin -- a first
## pass at 9.0 put this falloff's own start (PLATEAU_WIDTH-END_FALLOFF=3)
## and the face's finish (~7) on top of each other, so the two opposing
## smoothsteps nearly canceled out and the cliffs became almost invisible.
## 16.0 leaves a genuine flat-topped plateau between the two transitions.
const FEATURE_PLATEAU_WIDTH := 16.0
const FEATURE_MIN_GAP := 15.0 ## minimum CLEAR gap, in units, required between two features' actual footprints (not just their centers) -- see _add_cliff_features

## A perfectly straight line with a constant height reads as artificial.
## These add a gentle sideways wander to the fault line and a gentle rise
## and fall to its height, both as smooth sine modulation along its length
## rather than anything jagged.
const FEATURE_CURVE_AMPLITUDE_FRACTION := 0.25 ## max sideways wander, as a fraction of the feature's own half-length -- naturally tiny for short features, more noticeable for long ones
const FEATURE_CURVE_FREQ_MIN := 0.6 ## how many sine half-cycles the wander completes across the feature's full length
const FEATURE_CURVE_FREQ_MAX := 1.3
const FEATURE_HEIGHT_VARIATION_FRACTION := 0.35 ## max rise/fall in step height along the length, as a fraction of the base step height
const FEATURE_HEIGHT_FREQ_MIN := 0.6
const FEATURE_HEIGHT_FREQ_MAX := 1.6

## Every feature above is built from ONE sine wander + ONE sine height
## ripple, drawn from fairly narrow ranges -- so every cliff ends up as the
## same single clean "C"/"S" bend, just rotated and rescaled, which is why a
## field of them reads as one stamp copy-pasted around the map. The consts
## below add a second, faster and independently-weighted sine harmonic on
## top of the first (so some features stay a simple bend while others wobble
## more), per-feature random plateau width / edge softness (so footprints
## aren't all identically proportioned), and small-scale simplex noise
## jitter on the fault line's own edge (so the face itself isn't a perfect
## analytic curve -- real cliff edges aren't).
const FEATURE_CURVE_FREQ2_MIN := 1.6 ## second wander harmonic -- deliberately faster than FREQ_MIN/MAX above
const FEATURE_CURVE_FREQ2_MAX := 3.4
const FEATURE_CURVE_WEIGHT2_MIN := 0.1 ## how much the second harmonic contributes vs. the first, per feature
const FEATURE_CURVE_WEIGHT2_MAX := 0.55
const FEATURE_HEIGHT_FREQ2_MIN := 1.4
const FEATURE_HEIGHT_FREQ2_MAX := 3.2
const FEATURE_HEIGHT_WEIGHT2_MIN := 0.1
const FEATURE_HEIGHT_WEIGHT2_MAX := 0.5
const FEATURE_PLATEAU_WIDTH_MIN_MULT := 0.6 ## per-feature plateau width = FEATURE_PLATEAU_WIDTH * random multiplier in this range
const FEATURE_PLATEAU_WIDTH_MAX_MULT := 1.5
const FEATURE_EDGE_SOFTNESS_MIN_MULT := 0.7 ## per-feature edge softness = FEATURE_EDGE_SOFTNESS * random multiplier in this range
const FEATURE_EDGE_SOFTNESS_MAX_MULT := 1.4
const FEATURE_EDGE_NOISE_AMPLITUDE := 1.4 ## world units the fault edge is perturbed by, sampled from simplex noise -- breaks up the perfectly smooth analytic curve
const FEATURE_EDGE_NOISE_FREQUENCY := 0.12 ## noise sample frequency in heightmap pixels -- tuned so the wiggle reads as texture on the edge, not a whole extra bend

## -- Archetype-driven cliff/ledge/knoll features --
## Replaces the old single continuously-parameterized "fault line" shape --
## still the frame most archetypes below reuse (axis + perpendicular offset
## + sine wander + end falloff, see _place_line_feature) -- with five
## distinct archetypes, each with its own parameter ranges, so a field of
## these reads as separate landmarks instead of one shape stamped around at
## different sizes. See _add_cliff_features for the roll order: zone first,
## then an archetype weighted for that zone, then that archetype's params.
enum FeatureArchetype { ESCARPMENT, V_RAVINE, TERRACE, GENTLE_RISE, KNOLL }

## wall_t (0 = floor, 1 = rim -- see _valley_profile) boundary between the
## steep "wall" zone and the "transition" zone near the rim, for feature
## placement purposes only (a separate concern from the macro shape itself).
const ZONE_TRANSITION_WALL_T := 0.7

## Which zone a candidate feature's CENTER gets drawn from, before the
## per-zone archetype weights below pick its shape. Roughly proportional to
## how much of the map each zone covers (the floor is VALLEY_FLOOR_WIDTH_
## FRACTION of the width; the two walls split most of the rest, with the
## narrower rim "transition" band getting the smallest share).
const ZONE_PICK_WEIGHTS := {"floor": 0.5, "wall": 0.35, "transition": 0.15}

## Per-zone archetype weights -- which shape gets rolled once a zone is
## picked. Escarpments/ravines read as naturally cut into a steep wall; a
## terrace reads as a shelf where the wall eases toward the rim; knolls and
## gentle rises read as floor-level texture. Weights don't need to sum to 1
## (see _weighted_pick) -- kept roughly summing to 1 here for readability.
const ZONE_ARCHETYPE_WEIGHTS := {
	"floor": {FeatureArchetype.KNOLL: 0.55, FeatureArchetype.GENTLE_RISE: 0.35, FeatureArchetype.V_RAVINE: 0.1},
	"wall": {FeatureArchetype.ESCARPMENT: 0.5, FeatureArchetype.V_RAVINE: 0.3, FeatureArchetype.GENTLE_RISE: 0.15, FeatureArchetype.KNOLL: 0.05},
	"transition": {FeatureArchetype.TERRACE: 0.55, FeatureArchetype.GENTLE_RISE: 0.25, FeatureArchetype.ESCARPMENT: 0.15, FeatureArchetype.KNOLL: 0.05},
}

## ESCARPMENT: steep, tall, narrow, minimal wander -- the sharpest
## archetype, closest to the old generator's one-and-only shape.
const ESCARPMENT_LENGTH_MIN := 12.0
const ESCARPMENT_LENGTH_MAX := 26.0
const ESCARPMENT_STEP_MIN := 3.0
const ESCARPMENT_STEP_MAX := 6.0
const ESCARPMENT_EDGE_SOFTNESS := 2.2 ## narrower/sharper than a terrace or gentle rise
const ESCARPMENT_PLATEAU_WIDTH := 14.0
const ESCARPMENT_WANDER_FRACTION := 0.15 ## fraction of half-length -- escarpments stay mostly straight

## V_RAVINE: a long, narrow cut with a flat floor and two symmetric walls --
## an archetype the old generator couldn't produce at all (it only ever made
## a one-sided step). See _place_line_feature's V_RAVINE branch for the
## cross-section formula.
const V_RAVINE_LENGTH_MIN := 20.0
const V_RAVINE_LENGTH_MAX := 40.0
const V_RAVINE_DEPTH_MIN := 3.0
const V_RAVINE_DEPTH_MAX := 6.0
const V_RAVINE_WIDTH_MIN := 6.0 ## distance between the two walls, at the floor
const V_RAVINE_WIDTH_MAX := 14.0
const V_RAVINE_EDGE_SOFTNESS := 2.5
const V_RAVINE_WANDER_FRACTION := 0.3

## TERRACE: wide flat plateau, gentle wall -- a shelf/bench along the
## mountainside, favored at the wall-to-rim transition.
const TERRACE_LENGTH_MIN := 16.0
const TERRACE_LENGTH_MAX := 32.0
const TERRACE_STEP_MIN := 1.5
const TERRACE_STEP_MAX := 3.0
const TERRACE_EDGE_SOFTNESS := 5.0 ## wide, gentle transition
const TERRACE_PLATEAU_WIDTH := 22.0 ## broad flat top
const TERRACE_WANDER_FRACTION := 0.2

## GENTLE_RISE / SHOULDER: the mildest archetype -- soft, low step, mostly
## just breaks up otherwise-flat stretches without reading as a hazard.
const GENTLE_RISE_LENGTH_MIN := 10.0
const GENTLE_RISE_LENGTH_MAX := 24.0
const GENTLE_RISE_STEP_MIN := 0.8
const GENTLE_RISE_STEP_MAX := 2.0
const GENTLE_RISE_EDGE_SOFTNESS := 6.0 ## very soft, almost a ramp
const GENTLE_RISE_PLATEAU_WIDTH := 12.0
const GENTLE_RISE_WANDER_FRACTION := 0.25

## KNOLL / MOUND: radial (not a fault-line band), small, either a positive
## mound or a shallow negative hollow. NOT a perfect circle -- a random
## rotation + elliptical squash (KNOLL_ASPECT) elongates it, and two
## angular sine harmonics (KNOLL_WOBBLE_*) wobble the edge on top of that,
## so a field of these reads as organic lumps/hollows rather than the same
## disc stamped at different sizes (see _place_knoll).
const KNOLL_RADIUS_MIN := 4.0
const KNOLL_RADIUS_MAX := 9.0
const KNOLL_HEIGHT_MIN := 1.0
const KNOLL_HEIGHT_MAX := 2.5
const KNOLL_EDGE_SOFTNESS := 2.0 ## radial falloff softness
const KNOLL_ASPECT_MIN := 0.5 ## minor/major axis ratio -- 1.0 would be a perfect circle
const KNOLL_ASPECT_MAX := 0.9
const KNOLL_WOBBLE_FREQ1_MIN := 2.0 ## angular wobble, in cycles per full revolution -- a slow + a fast harmonic mixed keeps the edge irregular at more than one scale
const KNOLL_WOBBLE_FREQ1_MAX := 3.0
const KNOLL_WOBBLE_FREQ2_MIN := 4.0
const KNOLL_WOBBLE_FREQ2_MAX := 6.0
const KNOLL_WOBBLE_AMP1_MIN := 0.08 ## fraction of radius
const KNOLL_WOBBLE_AMP1_MAX := 0.22
const KNOLL_WOBBLE_AMP2_MIN := 0.05
const KNOLL_WOBBLE_AMP2_MAX := 0.15

## -- Cliff-face boulder scattering --
## Placed along each cliff feature's low-side foot, using the exact same
## fault-line data _add_cliff_features already computes (center,
## orientation, half-length, step_height) rather than re-deriving anything
## from the final heightmap -- real talus/rockfall accumulates specifically
## at the base of a cliff, not scattered uniformly across open ground.
## Uses Boulder01 (mesh id 1 in terrain_assets.tres -- see
## tools/setup_rock_assets.gd).
const BOULDER_MESH_ID := 1
const BOULDER_MIN_PER_FEATURE := 1
const BOULDER_MAX_PER_FEATURE := 6 ## before length scaling -- see _scatter_boulders (bumped 3->6: a real talus fan is denser than a token rock or two)
const BOULDER_PER_FEATURE_LENGTH_DIVISOR := 5.0 ## roughly 1 boulder per this many world units of cliff length (bumped from 8: longer cliff faces should earn meaningfully more talus, since more cliff = more rockfall)
const BOULDER_FOOT_MARGIN_MIN := 1.0 ## units past the face's own edge softness before the nearest boulder can sit
const BOULDER_FOOT_MARGIN_MAX := 4.0
const BOULDER_LATERAL_JITTER := 2.0 ## random scatter off the fault line itself, so boulders don't read as a ruler-straight row
const BOULDER_END_INSET_FRACTION := 0.15 ## keep boulders off the very tapering tips of the cliff line
const BOULDER_SCALE_MIN := 0.7
const BOULDER_SCALE_MAX := 1.4
const BOULDER_EMBED_DEPTH := 0.05 ## sinks the boulder slightly into the ground so its (non-zero) mesh-space base never floats visibly above the terrain -- kept small since Boulder01's own origin already sits close to its base (see boulder_01_1k's AABB)
const BOULDER_FOOT_MARGIN_STEP_BACK := 2.5 ## extra distance added per retry when the first-choice spot is too steep -- see _scatter_boulders
const BOULDER_MAX_PLACEMENT_ATTEMPTS := 4
const BOULDER_MAX_SLOPE_NORMAL_Y := 0.85 ## reject (and retry farther out) any spot steeper than this normal.y -- keeps boulders off the cliff face itself, not just past its nominal edge
const BOULDER_SCENE_PATH := "res://assets/models/rocks/boulder_01/boulder_01_2k.glb" ## source mesh for the runtime-built collision shape (its LOD0 mesh's simplified convex hull) -- see _scatter_boulders. 2026-09-24: was the 1k glb, now the same 2k glb the boulder renders with (1k deleted)
const BOULDER_COLLIDER_CONTAINER_NAME := "BoulderColliders" ## sibling Node3D (under the same parent as this generator/the live Terrain3D) that holds one StaticBody3D+CollisionShape3D per scattered boulder, rebuilt fresh every run

## -- Cliff-face set dressing (2026-09-17) --
## 5 large cliff-scale meshes (5-20m, real-world dimensions confirmed on
## Poly Haven), placed deliberately along fault-line features by
## _dress_cliff_faces -- NOT scattered by the boulder density formula
## above, which is tuned for 0.7-1.4x boulder-scale props and would badly
## overlap objects this large. See handoff_terrain_textures.md for why
## Terrain3D's own texture system can't give cliff faces real depth/mass
## on its own (no per-texture height slot), which is what these meshes are
## for -- geometric relief and detail Terrain3D's shader can't provide.
const CLIFF_DRESSING_NODE_NAME := "CliffDressing" ## sibling Node3D holding these, rebuilt fresh every run like BoulderColliders/RoadMesh
## "real_size" is each model's own AABB width (X); "height"/"depth" are its AABB height (Y)
## and depth (Z) -- all three measured directly off the imported GLBs on 2026-09-17 (see the
## debug cube in _dress_cliff_faces, which is sized from these to show each placement's real
## footprint before any terrain-fitting work touches the heightmap again).
const CLIFF_DRESSING_DEFS := [
	{"name": "namaqualand_cliff_01", "glb": "res://assets/models/cliffs/namaqualand_cliff_01/namaqualand_cliff_01_2k.glb", "diff": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_diff_2k.jpg", "nor": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_nor_gl_2k.exr", "rough": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_rough_2k.exr", "real_size": 8.3, "height": 4.96, "depth": 4.39},
	# 2026-09-20: mountainside moved out of the cliff system -> OUTCROP_DEFS (laid flat,
	# scattered on the valley floor by _scatter_outcrops). Kirill: "looks very out of place".
	{"name": "namaqualand_cliff_02", "glb": "res://assets/models/cliffs/namaqualand_cliff_02/namaqualand_cliff_02_2k.glb", "diff": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_diff_2k.jpg", "nor": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_nor_gl_2k.exr", "rough": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_rough_2k.exr", "real_size": 20.2, "height": 7.18, "depth": 6.59},
]
const CLIFF_DRESSING_SCALE_MIN := 0.85 ## random scale jitter on top of the real-size placement below, for visual variety only -- not what makes these fit the terrain (that's the per-model real_size + placement spacing)
const CLIFF_DRESSING_SCALE_MAX := 1.2
const CLIFF_DRESSING_EMBED_DEPTH := 1.5 ## sink the mesh's base this far below the sampled terrain height (scaled by that instance's own scale jitter) so its bottom edge never floats visibly above the ground regardless of the source mesh's own base/pivot
const CLIFF_DRESSING_SPACING := 6.0 ## world-space gap enforced between two dressing meshes placed along the same fault line
const CLIFF_DRESSING_YAW_JITTER := 0.35 ## radians of random extra yaw on top of the fault line's own perpendicular direction, so faces don't all look perfectly parallel-planar
## How far past the fault line's own smoothstep transition (see FEATURE_EDGE_SOFTNESS,
## _place_line_feature) to sample, in the low-side direction, for the mesh's VERTICAL
## anchor. The fault line's face blend is 0 (unmodified low-side terrain) at
## -edge_softness and 1 (full plateau) at +edge_softness, with the line itself
## (where cliff meshes are horizontally centered) sitting at the midpoint (0.5) --
## sampling height there bakes in roughly HALF the step height, floating the mesh's
## base well above the true low-side floor. edge_softness is randomized per-feature
## as FEATURE_EDGE_SOFTNESS(3.0) * a 0.7-1.4 multiplier (see FEATURE_EDGE_SOFTNESS_MIN/MAX_MULT),
## so max half-width is 4.2 -- this clears that with margin, reaching genuinely flat,
## unmodified low-side ground for every feature regardless of its own jittered softness.
const CLIFF_DRESSING_FOOT_SAMPLE_OFFSET := 8.0
## How far past a cliff-dressing mesh's own rotated footprint (in world units) the
## terrain-flatten blend (_flatten_terrain_for_cliff_dressing) fades back out to the
## untouched heightmap -- 0 would leave a hard, visible shelf edge right at the mesh's
## bounding box; this softens that into a gradual slope instead. This is the FLOOR of that
## blend for a placement whose target (low-side) height is already close to the surrounding
## natural terrain; see CLIFF_DRESSING_FLATTEN_SOFTNESS_MAX below for when it isn't.
const CLIFF_DRESSING_FLATTEN_SOFTNESS := 2.5
## 2026-09-18 round 5 ("left side is not 31 degrees"): rounds 1-4 only widened
## _raise_terrain_behind_cliff_dressing's BEHIND-the-mesh blend -- but that function only ever
## touches pixels in the mesh's own back half and beyond (see its d_behind/inner_ramp check);
## anywhere beside or in front of the mesh is carved ENTIRELY by the flatten pass above, using
## a fixed 2.5-unit softness regardless of how far target_height (the low-side sample) sits
## from the natural terrain around it -- on uneven ground that gap can be large, producing
## exactly the steep-banked "moat" around the mesh the screenshot showed. Cap for the same
## per-placement slope-based widening applied there, kept modest since this blend wraps the
## mesh's visible/walkable front too, not just the hidden back.
const CLIFF_DRESSING_FLATTEN_SOFTNESS_MAX := 10.0
## _raise_terrain_behind_cliff_dressing (2026-09-17, "turn the magenta boxes into terrain"):
## how far behind the mesh's own already-flattened footprint the ground ramps up from the
## low-side height to the mesh's own visible top height (see CLIFF_DRESSING_RAISE_PLATEAU_
## DEPTH/FADE_DISTANCE below for what happens past this).
const CLIFF_DRESSING_RAISE_RAMP_DISTANCE := 10.0
## 2026-09-21 (Kirill: "raise it at the top of the mesh just a bit, there are still small gaps
## sometimes"): the raised ground behind a cliff mesh aims at EXACTLY the model's own sampled
## top height (origin_y + top_local_y * scale_jitter), so ground and rock meet at a shared
## line with zero overlap. At that exact height any small error -- the 25-sample top profile
## missing a local dip between slices, the heightmap's 1-unit pixel grid quantising the
## meeting line, or Terrain3D's own vertex interpolation -- shows through as a hairline gap.
## This lifts the plateau target by a flat amount in WORLD units (applied after scale_jitter,
## so it is the same real-world overlap on a 0.8x and a 1.2x placement rather than growing
## with the model) to give that meeting a deliberate bit of overlap instead of a knife-edge.
## TUNING: raise until the gaps close, then stop -- too much and the soil visibly climbs over
## the crest and is seen from the front, which is the opposite failure. 0.0 restores the old
## exact-match behaviour. The per-run value is echoed in the round19 raise-pass print.
const CLIFF_DRESSING_RAISE_TOP_LIFT := 0.02
## How far the raised ground stays at full plateau height once the ramp above reaches it,
## before CLIFF_DRESSING_RAISE_FADE_DISTANCE below starts blending it back down -- without
## some hold distance the plateau would be a knife-edge ridge instead of actual standable
## ground behind the face.
const CLIFF_DRESSING_RAISE_PLATEAU_DEPTH := 10.0
## How far past the plateau (see above) the raised terrain fades back down to the untouched,
## naturally-generated heightmap -- this is what keeps the raise a self-contained landform
## blending into the surrounding hillside instead of an abrupt cliff-behind-the-cliff.
const CLIFF_DRESSING_RAISE_FADE_DISTANCE := 12.0
## Lateral (side-to-side, along the mesh's own width) softness for the raise, analogous to
## CLIFF_DRESSING_FLATTEN_SOFTNESS but wider -- this is meant to read as a natural rise in
## the hillside, not a tight shelf, so its edges blend more gradually than the flattened
## low-side footprint does. This is the FLOOR of the lateral blend, used for short models;
## see CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS_MAX below for how tall models widen past it.
const CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS := 4.0
## 2026-09-18 round 2 ("mountain face is just a cube"): a fixed 4.0-unit lateral blend looks
## fine for a short rock face but reads as a hard box edge for a tall model like mountainside
## (real top-profile height 10+), where the plateau height right at the mesh's own edge is
## still most of that climb -- dropping it to natural ground in only 4 units is a much
## steeper-than-CLIFF_DRESSING_RAISE_MAX_SLOPE wall, not a slope. Round 2 capped this at a
## single fixed constant sized to be safe even at the tightest legal CLIFF_DRESSING_SPACING
## (6.0), but that punished every isolated placement with no close neighbor just as tightly
## (round 3, "still too steep, should be a very gentle mound") -- _raise_terrain_behind_
## cliff_dressing now looks up each placement's ACTUAL nearest neighbor footprint and only
## falls back to this constant as a sanity ceiling when there is no qualifying neighbor at
## all, so this just needs to be generous enough for a real slope (max_climb/
## CLIFF_DRESSING_RAISE_MAX_SLOPE(0.6) for the tallest model, mountainside, reaches ~18)
## without letting one wildly-scaled outlier stretch the mound absurdly wide.
const CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS_MAX := 16.0
## 2026-09-18 round 7 ("if two cliffs are standing next to each there shouldn't be a gap
## between them"): rounds 1-6 all still faded a constrained side back down to whatever was
## already there (natural terrain), just over a shorter distance the closer the real neighbor
## sat -- which is exactly backwards for two placements meant to read as one continuous fault
## line. Two placements this close (real gap under this threshold) are neighbors on the SAME
## fault, not incidentally near each other, so the ground between them should read as one
## rising landform joining them, not two separate mounds with a valley between. A gap this
## small only ever shows up between genuinely adjacent placements (CLIFF_DRESSING_SPACING is
## 6.0, so real neighbors cluster near there); anything found further out by the neighbor scan
## is a coincidence of two unrelated faults sharing similar depth, not something to bridge to.
const CLIFF_DRESSING_RAISE_JOIN_THRESHOLD := 15.0
## How much of a genuinely adjacent neighbor's gap (see above) is left as an actual blend once
## joining kicks in -- small enough to avoid a hard vertex seam where the two placements' own
## raised plateaus meet, not sized for slope (there's no natural ground left in the gap to
## blend down TO any more, just two plateau heights meeting).
const CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH := 2.0
## 2026-09-18 round 17 ("left side has a steep wall that starts from the top of the mesh, and
## then 60-70% down the way a short, almost horizontal slope extends" -- confirmed via the
## per-entry debug coloring to be ONE mesh's own two sides): past the mesh's lateral edge the
## raise pass used _sample_cliff_top_profile's CLAMPED outermost slice as the plateau height.
## On a model whose silhouette tapers to a thin sliver at one end, that one slice is far lower
## than the rock's real shoulder right next to it -- so that whole flank sat at the sliver's
## height (the low shelf) with the mesh's own face towering above it (the wall), while the
## other side, whose outermost slice happened to be tall, looked right. The flank height is now
## the MAX of the profile over this fraction of the model's full width on that side, and the
## outermost band blends smoothly up to it so there's no step at the band's inner boundary.
const CLIFF_DRESSING_FLANK_BAND_FRACTION := 0.2
## 2026-09-18 round 22: how far inside a joined side's edge the raise weight blends from the
## front-gated weight to the join-gap weight (previously a hard switch at the edge line, which
## left a V-trench there).
const CLIFF_DRESSING_RAISE_JOIN_BLEND := 2.0
## 2026-09-18 round 20 ("can the side curves be a little random in terms of terrain, not the
## same smooth slope"): two noise layers on the raised slopes.
## EDGE_WARP -- low-frequency noise stretches/shrinks the lateral and far-fade falloff DISTANCES
## by up to this fraction, so the slope's outline meanders instead of tracing a clean curve.
## Multiplicative on distance-past-the-edge, so at the mesh edge itself (distance 0) nothing
## moves -- the ground still meets the rock exactly.
const CLIFF_DRESSING_RAISE_EDGE_WARP := 0.35
const CLIFF_DRESSING_RAISE_WARP_FREQUENCY := 0.06 ## ~16-unit features
## BUMP -- finer noise added to the blended height, sized as a fraction of the local climb
## (capped) and weighted by 4*w*(1-w): zero at full plateau and at natural ground (no seams at
## either end), strongest mid-slope.
const CLIFF_DRESSING_RAISE_BUMP_FRACTION := 0.12
const CLIFF_DRESSING_RAISE_BUMP_MAX := 1.2
const CLIFF_DRESSING_RAISE_BUMP_FREQUENCY := 0.18 ## ~5-unit features
## Maximum rise:run gradient the raised terrain is allowed to blend at, laterally and at its
## far/fade edge (2026-09-17, "gently ingrained" follow-up): CLIFF_DRESSING_RAISE_LATERAL_
## SOFTNESS/FADE_DISTANCE above are fixed widths sized for a modest climb -- fine for a short
## rock face, but a tall model (mountainside's real top profile can be 10+ units above the
## flattened low shelf) blending down over that same fixed few units reads as a near-vertical
## wall, not connected to the surrounding hillside (exactly the "right side doesn't connect"
## symptom, and what makes the whole landform read as a dropped-in cube rather than a rise in
## the terrain). 0.6 rise:run is roughly a 31-degree slope, a natural-looking talus/scree
## angle -- _raise_terrain_behind_cliff_dressing widens its lateral/fade distances per
## placement so the actual height it has to blend away never exceeds this gradient.
const CLIFF_DRESSING_RAISE_MAX_SLOPE := 0.6
## How many samples the cliff-dressing top-height profile takes across a model's own local-X
## range (2026-09-17, "match the elevation line"): see _compute_cliff_dressing_top_profile.
const CLIFF_DRESSING_TOP_PROFILE_SAMPLES := 25
## 2026-09-17 reorder: cliff dressing is now PLANNED (and its footprint flattened into the
## heightmap) BEFORE the road is routed, so the road avoidance responsibility flips direction
## from the old _cliff_placement_blocks_road (cliff placement reactively dodging an
## already-routed road) to this -- road pathfinding (_find_road_path) now treats each planned
## cliff-dressing footprint as real, solid terrain to route around, the same way it already
## treats a too-steep slope as impassable via ROAD_SLOPE_HARD_LIMIT. No parallel/perpendicular
## judgment call is needed any more: a fault running alongside where the road ends up is
## naturally just terrain beside the route, not an obstacle blocking it.
const CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN := 3.0 ## extra clearance (world units) added around each footprint so the road doesn't shave right past the mesh's edge
const ROAD_MESH_NODE_NAME := "RoadMesh" ## sibling MeshInstance3D holding the flat road-depth overlay mesh (parallax-mapped via StandardMaterial3D heightmap_enabled, no vertex displacement -- see _build_road_mesh), rebuilt fresh every run

## Extra rock meshes (stone_01/rock_07/rock_09), added purely for scatter
## variety -- registered as Terrain3DMeshAsset ids 2/3/4 in
## terrain_assets.tres by setup_rock_assets.gd, alongside Boulder01's
## existing id 1. ROCK_MESH_IDS is the pool every talus/erratic placement
## below now picks ONE id from at random (uniform) instead of always using
## BOULDER_MESH_ID -- see _scatter_boulders.
const ROCK_MESH_IDS: Array[int] = [BOULDER_MESH_ID, 2, 3, 4]
const ROCK_SCENE_PATHS := {
	1: BOULDER_SCENE_PATH,
	2: "res://assets/models/rocks/stone_01/stone_01_2k.glb",
	3: "res://assets/models/rocks/rock_07/rock_07_2k.glb",
	4: "res://assets/models/rocks/rock_09/rock_09_2k.glb",
}
## Poly Haven's boulder_01 was modeled/exported at genuine boulder scale
## (LOD0 mesh AABB ~1.83 units on its longest axis). stone_01/rock_07/
## rock_09 turned out to be modeled at a much smaller real-world scale
## (longest-axis AABB 0.15/0.32/0.14 units respectively -- checked via
## debug_print_mesh_sizes in setup_rock_assets.gd), which is what made them
## render "very very tiny" next to Boulder01. FIXED AT IMPORT TIME instead
## of here: each rock's .glb.import now sets nodes/root_scale (6.81/3.12/
## 6.91) with nodes/apply_root_scale=true, baking the size fix directly
## into the imported mesh geometry (now ~1.0 unit on its longest axis for
## all three, a bit smaller than Boulder01's ~1.83 so it still reads as the
## standout large rock) -- confirmed via debug_print_mesh_sizes. A prior
## version of this file applied the same normalization again here, as an
## extra per-instance scale multiplier -- that's gone now that the meshes
## themselves are the right size, since keeping both would double-scale.
## ROCK_BASE_SCALE stays at 1.0 for every id so BOULDER_SCALE_MIN/MAX's
## existing random roll (see _scatter_boulders) is the only scale variation
## applied at scatter time, same as Boulder01 always had.
const ROCK_BASE_SCALE := {
	1: 1.0,
	2: 1.0,
	3: 1.0,
	4: 1.0,
}

## -- Scree layer scattering (2026-09-21) --
## A dense, collider-free debris carpet at the SAME cliff feet the boulder
## pass reads, layered UNDER the boulders as the correlated finer tier the
## terrain field notes call for (gravel + fist-sized chips vs the sparser
## ~1 m boulders). Reuses _scatter_boulders' exact masks -- cliff features,
## cliff/outcrop keep-outs, road weight, slope normal -- but with its own much
## higher density, tighter foot band, gentler slope tolerance, a gravel/fist
## sub-pool split, and NO per-instance collision (scree is cosmetic; the
## terrain collider already carries the ground). See _scatter_scree.
## Meshes registered by setup_scree_assets.gd as Terrain3DMeshAsset ids 5-13:
##   fist tier   = namaqualand_rocks_01  a-d -> ids 5-8   (0.20-0.23 m)
##   gravel tier = namaqualand_stones_01 a-e -> ids 9-13  (0.04-0.15 m)
const SCREE_FIST_MESH_IDS: Array[int] = [5, 6, 7, 8]
const SCREE_GRAVEL_MESH_IDS: Array[int] = [9, 10, 11, 12, 13]
const SCREE_MESH_IDS: Array[int] = [5, 6, 7, 8, 9, 10, 11, 12, 13]
const SCREE_GRAVEL_FRACTION := 0.72 ## share drawn from the small gravel pool; the rest are the larger chips. Real talus is mostly fine debris with a scatter of bigger blocks.
const SCREE_MIN_PER_FEATURE := 12
const SCREE_MAX_PER_FEATURE := 260 ## before length/step scaling -- a dense carpet, not a token few (contrast BOULDER_MAX_PER_FEATURE = 6)
const SCREE_PER_FEATURE_LENGTH_DIVISOR := 0.6 ## ~1.7 scree per world unit of cliff length before step scaling
const SCREE_FOOT_MARGIN_MIN := 0.0 ## scree banks right against the foot edge (vs boulders' 1.0 standoff)
const SCREE_FOOT_MARGIN_MAX := 3.0 ## and thins out by here -- a tighter band than the boulder talus (max 4.0)
const SCREE_LATERAL_JITTER := 1.2
const SCREE_END_INSET_FRACTION := 0.05 ## scree reaches closer to the cliff tips than boulders (0.15)
const SCREE_SCALE_MIN := 0.6
const SCREE_SCALE_MAX := 1.5
const SCREE_TALUS_DENSITY_EXPONENT := 2.6 ## even stronger near-face pile-up than boulders (2.2) -- a scree cone is densest right at the wall
const SCREE_EMBED_DEPTH := 0.012 ## small -- these stones are only 4-23 cm tall, so BOULDER_EMBED_DEPTH (0.05) would bury the smallest ones
const SCREE_MAX_SLOPE_NORMAL_Y := 0.62 ## scree lodges on the talus slope itself, so it tolerates steeper ground than boulders (0.85)
const SCREE_KEEPOUT_RADIUS := 0.12 ## tiny footprint -- scree packs tightly and may sit right against (but not inside) cliff/outcrop footprints
const SCREE_MAX_PLACEMENT_ATTEMPTS := 3
const SCREE_FOOT_MARGIN_STEP_BACK := 1.2 ## extra distance per retry when a spot is too steep / blocked

## A real talus/scree cone is thickest right at the base of the cliff and
## thins out fast with distance -- a concave-upward accumulation profile,
## not a uniform band. BOULDER_FOOT_MARGIN_MIN/MAX still bound how close and
## how far a talus boulder can land; this exponent biases the random roll
## inside that band toward the near (MIN) end. pow(u, exponent) with
## exponent > 1 pushes a uniform [0,1] roll down toward 0, so most boulders
## cluster near the face and only a thinning few reach the far edge of the
## band -- see _scatter_boulders.
const BOULDER_TALUS_DENSITY_EXPONENT := 2.2

## 2026-09-20 (terrain-field-notes.html review, items 1-3):
## 1. Keep-outs -- talus/erratics no longer land inside cliff-dressing meshes (their real scanned
##    footprint from the top profiles, since these GLBs aren't centred on their origin) or on
##    top of flat rock outcrops. A blocked talus spot retries one step farther from the face.
const BOULDER_KEEPOUT_MARGIN := 0.5 ## extra world-unit gap around cliff footprints / outcrops
const BOULDER_KEEPOUT_RADIUS := 0.9 ## rough footprint radius of a scale-1.0 rock, multiplied by the rock's own scale
## 2. Clumps with gaps ("nothing is placed alone") -- each fault gets a few rockfall centres,
##    biased to sit under the cliff meshes actually on that fault (the visible debris source),
##    and its boulders spread around those instead of uniformly along the whole line. Count also
##    scales with step height relative to this map's average step (taller face = more rockfall).
const BOULDER_CLUSTER_SPACING := 20.0 ## one extra rockfall centre per this many units of fault length
const BOULDER_MAX_CLUSTERS_PER_FEATURE := 3
const BOULDER_CLUSTER_SPREAD := 3.0 ## std-dev (world units, along the fault) of boulders around a centre
const BOULDER_CLUSTER_FACE_BIAS := 0.75 ## chance a centre is placed under a cliff mesh on this fault (when there is one)
const BOULDER_FACE_MATCH_DIST := 8.0 ## max perpendicular distance for a cliff mesh to count as "on" a fault
const BOULDER_STEP_FACTOR_MIN := 0.6
const BOULDER_STEP_FACTOR_MAX := 1.5
## 3. Size sorting -- on real talus the biggest blocks roll farthest. Each boulder's size is
##    rolled first; this is how strongly that size pulls it toward the far end of the talus band
##    (0 = size and distance independent, as before; 1 = distance fully set by size).
const BOULDER_SIZE_SORTING := 0.6

## Independent, sparse glacial-erratic boulders scattered across the open
## valley floor -- unrelated to any cliff feature, the way a retreating
## glacier drops the odd oversized boulder far from any rock face. Kept
## separate from the cliff-foot talus loop above: different placement zone
## (floor only), different (larger, since a lone erratic reads as a single
## dramatic rock rather than a pile of debris) scale range, and a stricter
## flatness requirement since the floor is meant to be genuinely walkable.
## Calibrated at a 256x256 map (matches FEATURE_DENSITY's own baseline),
## then scaled by actual map area at scatter time -- see _scatter_boulders.
## Flat constants here would mean the SAME 15-30 erratics regardless of
## whether the map is 256x256 or 1024x1024, so density (and the visual
## "how sparse does the floor feel") would silently collapse as the area
## grows. Scaling by area keeps erratics-per-square-unit constant instead,
## the same way FEATURE_DENSITY already keeps cliff-feature density constant.
const ERRATIC_DENSITY_BASE_AREA := 256.0 * 256.0
const ERRATIC_COUNT_MIN_BASE := 15 ## count at ERRATIC_DENSITY_BASE_AREA
const ERRATIC_COUNT_MAX_BASE := 30 ## count at ERRATIC_DENSITY_BASE_AREA
const ERRATIC_SCALE_MIN := 0.9
const ERRATIC_SCALE_MAX := 2.2
const ERRATIC_MAX_SLOPE_NORMAL_Y := 0.92 ## stricter than BOULDER_MAX_SLOPE_NORMAL_Y -- erratics sit on genuinely flat floor, not a cliff-foot runout
const ERRATIC_MAX_PLACEMENT_ATTEMPTS := 6
## -- Flat rock outcrops (2026-09-20) --
## Large scanned rock slabs (currently just mountainside, pulled out of CLIFF_DRESSING_DEFS)
## laid FLAT on the valley floor and scattered randomly like the glacial erratics -- not tied
## to any fault line, no terrain raise/flatten around them. Too big and too custom (own
## material, trimesh collision) for Terrain3D's instancer, so each one is a real node under
## OUTCROP_NODE_NAME, same as CliffDressing. See _scatter_outcrops.
const OUTCROP_NODE_NAME := "RockOutcrops"
const OUTCROP_DEFS := [
	{"name": "mountainside", "glb": "res://assets/models/cliffs/mountainside/mountainside_2k.glb", "diff": "res://assets/models/cliffs/mountainside/textures/mountainside_diff_2k.jpg", "nor": "res://assets/models/cliffs/mountainside/textures/mountainside_nor_gl_2k.exr", "rough": "res://assets/models/cliffs/mountainside/textures/mountainside_rough_2k.exr"},
]
const OUTCROP_COUNT_MIN_BASE := 1 ## per ERRATIC_DENSITY_BASE_AREA (256x256), scaled by real map area like erratics
const OUTCROP_COUNT_MAX_BASE := 3
const OUTCROP_SCALE_MIN := 0.6
const OUTCROP_SCALE_MAX := 1.0
const OUTCROP_SINK_FRACTION := 0.1 ## sink this fraction of the laid-flat slab's own thickness below its lowest ground contact (round 2: 0.25 -> 0.1 now that _fit_terrain_to_outcrops raises the ground to meet the rest of the contour)
const OUTCROP_UNDERSIDE_CELL := 0.25 ## model units per cell of each outcrop's underside grid -- see _load_outcrop_models
const OUTCROP_FIT_CLEARANCE := 0.08 ## terrain under the rock stops this far BELOW its underside (never above -- see _fit_terrain_to_outcrops)
const OUTCROP_RIM_TUCK := 0.35 ## round 3: ground at the rock's outline rises this far ABOVE its local underside, so the lip tucks into the soil instead of hovering
const OUTCROP_RIM_INSET := 0.85 ## round 4: the rim the terrain aims at is pulled this far (world units, whole pixels) INSIDE the rock's real outline; the ring in between gets full rim height so soil covers the lip. Terrain only -- never moves the mesh. 0 = old behaviour
const OUTCROP_BANK_SLOPE := 0.35 ## round 3: target rise/run of the soil bank -- bank width = rim lift / this, clamped below
const OUTCROP_FIT_FADE_MIN := 4.0 ## narrowest soil bank (world units)
const OUTCROP_FIT_FADE_MAX := 12.0 ## widest soil bank; also used for outcrop spacing + the road obstacle radius
const OUTCROP_BANK_SMOOTH_PASSES := 4 ## round 5: 3x3 relaxation passes over the raised soil bank ONLY, after every outcrop has been fitted. The IDW blend in pass 3 is peaky near rim pixels and switches formula at the footprint outline, which left faceted creases that read as choppy edges under a low sun. 0 = old behaviour
const OUTCROP_BANK_SMOOTH_STRENGTH := 0.65 ## how far each bank pixel moves toward its 3x3 mean per pass (0..1)
const OUTCROP_MAX_SLOPE_NORMAL_Y := 0.9
const OUTCROP_MAX_GROUND_SPREAD := 2.5 ## reject spots where the ground under the footprint varies more than this (world units) -- keeps the slab on genuinely flat floor
const OUTCROP_CLEARANCE := 4.0 ## extra gap kept from cliff-dressing placements and other outcrops
const OUTCROP_MAX_PLACEMENT_ATTEMPTS := 16
const ERRATIC_REACH := 3.0 ## rough footprint radius used only to keep candidates off the very map edge (see _clamp_range_for_reach) -- erratics don't overlap-check against cliff features or each other, since real-world erratics are scattered independently of one another

## -- Control-map texture ids --
## These MUST match the Terrain3DTextureAsset `id` values set up by
## res://tools/assign_flat_textures.gd's TEXTURES_BY_ID (Ground/Road,
## real 1k PBR textures under res://textures/source/) -- that's what's
## actually rendered per pixel; changing one without the other just
## repaints which id points at which texture, or breaks it. Run
## assign_flat_textures.gd's fix_textures() via call_method(runtime:false)
## on the EDITOR process, never via run_scene/Play mode -- see that
## script's own header comment for why. (setup_terrain_textures.gd was an
## earlier, now-deleted flat-color placeholder version of this -- if you
## see old references to it, they're stale.)
## id 0 renamed GRASS_TEXTURE_ID -> GROUND_TEXTURE_ID (2026-09-16) -- the
## texture it points at has always been ambientCG's Ground106 (bare dirt),
## never actual grass, so the identifier now matches what's really shown.
const GROUND_TEXTURE_ID := 0
const ROAD_TEXTURE_ID := 1

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
const ROAD_EDGE_NOISE_STRENGTH := 0.6 ## world units (2026-09-16: 0.6 -> 1.8 -> 0.9 when the road was halved -> 1.7 here, since even 0.9 combined with a tight 6-unit wavelength still read as essentially straight. Needed ROAD_HALF_WIDTH widened alongside this -- see that constant's own note -- to keep painted_half_width's worst case safely inside the grading corridor without also widening the visible road surface itself (ROAD_TEXTURE_HALF_WIDTH is unchanged).

## -- Road --
## A single route from the center of the north edge to the center of the
## south edge -- the two SHORT edges (each AREA_WIDTH long), so the road
## travels the map's LONG axis (AREA_LENGTH) rather than cutting across its
## short one. Found with A* pathfinding over a coarse grid rather than a
## blind straight line: each grid step's cost is penalized by how steep the
## terrain is there (squared, so mild slopes barely matter but a cliff face
## is effectively a wall), which makes the path bend around cliffs/ridges
## instead of climbing straight through them. The resulting grid-resolution
## waypoints are then smoothed with Catmull-Rom interpolation so the route
## reads as a curved road rather than a jagged staircase of 45-degree turns.
## Heights inside ROAD_HALF_WIDTH of the smoothed path get pulled toward a
## heavily-blurred copy of the terrain, which grades the corridor (smooths
## it flat enough to walk/drive) while still following the underlying slope,
## rather than cutting a dead-flat shelf through a hillside. The control map
## gets painted with ROAD_TEXTURE_ID within the narrower
## ROAD_TEXTURE_HALF_WIDTH, so there's a ground shoulder between the visible
## road and the graded edge of the corridor.
const ROAD_HALF_WIDTH := 6.0 ## world units, half-width of the graded corridor (2026-09-16: 6.0 -> 3.0 when the road was halved, -> 4.0 here -- widened again, NOT to make the visible road wider (ROAD_TEXTURE_HALF_WIDTH stays 2.0), but to give ROAD_EDGE_NOISE_STRENGTH's bigger amplitude enough shoulder room that the jittered painted edge can't reach past the graded corridor and paint onto rough, ungraded terrain)
const ROAD_TEXTURE_HALF_WIDTH := 3.0 ## world units, half-width of the painted road surface -- kept at 2.0 even though ROAD_HALF_WIDTH grew, so the visible road itself stays the width it was set to when halved; only the ground shoulder around it got wider
const ROAD_TEXTURE_BLEND_WIDTH := 1.5 ## world units, width of the control-map cross-fade band just inside the (jittered) painted edge -- see _pack_control_blend()/_generate_road()'s road_blend array. Without this, every painted pixel used base==overlay (a no-op blend), so the road/ground boundary was a razor-sharp texture swap no matter how much the edge itself was jittered; this band is what actually softens it.
const ROAD_EDGE_SOFTNESS := 2.5 ## half-width, in units, of the grading blend at the corridor's edge
const ROAD_SMOOTH_PASSES := 4 ## extra box-blur passes (on a separate copy) used as the "graded" target the corridor blends toward
const ROAD_SMOOTH_RADIUS := 3

## -- Road pathfinding (A*) --
const ROAD_PATH_GRID_STEP := 4.0 ## world units between pathfinding grid nodes -- coarser than the 1-unit heightmap for speed, smoothed back out afterward
const ROAD_SLOPE_PENALTY := 7.2 ## how strongly a steep step is penalized vs. a flat one of the same length -- higher pushes the route further out of its way to avoid slopes (2026-09-16: +5%, per the road-snaking analysis -- makes existing modest terrain variation costly enough to detour around a bit more readily)
const ROAD_SLOPE_HARD_LIMIT := 2.0 ## height change per grid step (in world units) beyond which that step is forbidden outright, not just costly -- keeps the router from ever routing straight up a near-vertical cliff face even if it's the shortest path (2026-09-16: -5%, tightened alongside ROAD_SLOPE_PENALTY -- slightly more terrain now counts as "too steep" outright, forcing more genuine detours)
const ROAD_PATH_SUBDIVISIONS := 8 ## Catmull-Rom subdivisions per grid segment when smoothing the coarse A* path into a curve

## -- Road depth mesh (2026-09-16, third attempt) -- a FLAT overlay ribbon
## (no vertex displacement/bump noise, unlike the reverted second attempt)
## that follows the same centerline+graded terrain height, textured with a
## StandardMaterial3D using Godot's built-in heightmap_enabled parallax
## (Poly Haven concrete_rock_path maps) -- see CLAUDE.md for why this
## replaces both the fragment-shader-on-Terrain3D and displaced-geometry
## attempts.
const ROAD_MESH_COLUMNS := 7 ## vertices across the ribbon's width per row
const ROAD_MESH_SEGMENT_LENGTH := 1.0 ## target world-space spacing between resampled rows along the path
const ROAD_MESH_LIFT := 0.03 ## small lift above the sampled terrain height to avoid shadow-map z-fighting with the terrain surface directly underneath
const ROAD_TEXTURE_TILE_LENGTH := 4.0 ## world units one texture tile covers, both along and across the ribbon
const ROAD_BUMP_AMPLITUDE := 0.035 ## small real vertex-height variation (2026-09-17) -- parallax alone reads as flat from a near-overhead FPS angle (its apparent offset scales with view angle from the surface normal, which is small looking mostly straight down), so real geometry is what actually gives a visible silhouette. Kept small, and shadow casting is disabled on this mesh (see _build_road_mesh) specifically so this doesn't repeat the second attempt's harsh self-shadowing.
const ROAD_BUMP_FREQUENCY := 0.35

const ROAD_GOAL_BAND_FRACTION := 0.33 ## (2026-09-16) the road's start stays pinned to the exact center of the north edge, but the south-edge exit is no longer forced to that same X column -- pinning both ends to the same column makes a straight line the crow-flies shortest path, so A* had no reason to bend the route unless real terrain slope forced it, which rarely happened. The exit X is instead picked randomly within this fraction of AREA_WIDTH, centered on the map's midline (0.33 => the exit lands somewhere in the central 33% of the south edge). This forces genuine diagonal travel across the grid even on a flat map, which the Catmull-Rom smoothing then turns into a natural-looking curve rather than a jittered straight line.

## -- Road "meander" (cosmetic S-curve pull, 2026-09-16) --
## Even at aggressive ROAD_SLOPE_PENALTY/ROAD_SLOPE_HARD_LIMIT/FEATURE_DENSITY
## values (tested up to 2x), the road stayed close to straight -- the valley
## floor (VALLEY_FLOOR_WIDTH_FRACTION) the road actually travels through is
## deliberately flat, and ROAD_GOAL_BAND_FRACTION's diagonal offset alone
## isn't enough real slope to make the pathfinder detour meaningfully more
## than once. Cranking terrain roughness further to force more bends fights
## the valley's own design (flat, walkable floor) instead of fixing the
## actual problem: there just isn't enough genuine terrain reason to curve.
## So this fakes it instead of trying to manufacture more real slope: the
## pathfinder gets pulled toward a wandering sine-wave PREFERRED centerline
## (interpolated between the real, fixed start/goal columns) as an EXTRA
## soft cost term, on top of -- not instead of -- real slope avoidance. A
## genuine cliff still hard-blocks a step (ROAD_SLOPE_HARD_LIMIT) regardless
## of what the preferred centerline wants; this only shapes the pathfinder's
## preference among still-viable cells. See _find_road_path's `preferred_x`.
const ROAD_MEANDER_AMPLITUDE_FRACTION := 0.18 ## how far, as a fraction of AREA_WIDTH, the preferred centerline can wander from the straight line between the fixed start/exit columns. Purely cosmetic -- real terrain can still push the actual route further than this.
const ROAD_MEANDER_CYCLES := 2.2 ## how many full left-right wander cycles the preferred centerline completes over the road's full north-to-south length. Fractional on purpose, so the wander pattern doesn't land symmetrically with the map's own north/south layout.
const ROAD_MEANDER_COST_WEIGHT := 0.35 ## how strongly the pathfinder is pulled toward the wandering preferred centerline, relative to the distance-based cost each grid step already has. Too high overrides genuine slope avoidance (defeats ROAD_SLOPE_PENALTY entirely); too low and flat terrain wins again, which is the whole problem this exists to work around.

const DATA_DIRECTORY := "res://terrain_data" ## the LIVE surface main.tscn reads
const TEST_DATA_DIRECTORY := "res://terrain_data_test" ## isolated -- res://scenes/terrain_preview.tscn reads this one

## Where (if anywhere) this run's heightmap gets written:
##   NONE -- diagnostics only (console print), nothing touches disk. Fastest
##           loop for pure number-tuning.
##   TEST -- writes to TEST_DATA_DIRECTORY, a directory nothing else reads
##           except terrain_preview.tscn. Always safe regardless of
##           AREA_SIZE, since that directory never holds stale data at a
##           different size/position to clash with (each run replaces the
##           whole thing). This is the default: run this scene, then run
##           terrain_preview.tscn and fly over the result with WASD+mouse.
##   LIVE -- writes to DATA_DIRECTORY, the actual surface main.tscn loads.
##           main.tscn and terrain_preview.tscn were merged into one scene
##           (main.tscn is now the only thing reading DATA_DIRECTORY, and
##           each run replaces that directory's contents in place), so
##           there's no longer a risk of a small run leaving a partial
##           patch inside separately-sized existing data -- any AREA_WIDTH/
##           AREA_LENGTH is safe here now.
enum WriteTarget { NONE, TEST, LIVE }
const WRITE_TARGET := WriteTarget.LIVE

## Derives one integer seed per pipeline sub-system from a single master
## seed, in a fixed order, so the mapping from master seed -> individual
## seeds never changes between runs. Keyed by name rather than index so
## callers don't need to remember an order.
func _derive_seeds(master_seed: int) -> Dictionary:
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

func _ready() -> void:
	# Whole-_ready() timing (2026-09-16): the earlier per-stage prints only
	# covered _build_heightmap (noise/erosion/smoothing/road) -- this covers
	# the REST of _ready() too (Terrain3D import, boulder scattering, player
	# placement), to account for the full splash-screen-to-playable gap,
	# not just the CPU-side heightmap math.
	var t_ready_start := Time.get_ticks_msec()
	# Time.get_ticks_msec() is measured from process start (engine boot), not
	# from anywhere in this script -- printing the raw value here (not an
	# elapsed delta) answers "how much of the splash-to-playable gap happened
	# BEFORE this script's _ready() even started running" (engine boot,
	# Vulkan init, loading the GLB meshes/textures/shaders this scene needs,
	# other autoloads/_ready() calls, etc.) -- a category of cost this
	# script's own timers can never see, since it hasn't run yet.
	print("TERRAIN_GEN: WorldGenerator._ready() started at t=%.2fs since process start" % (t_ready_start / 1000.0))
	# -1 means "randomize": roll a fresh seed via randi() this run rather than
	# reusing MASTER_SEED literally. Always printed either way, so whatever
	# came out (random or pinned) is copy-pasteable back into MASTER_SEED to
	# reproduce this exact map later.
	var resolved_seed := randi() if MASTER_SEED < 0 else MASTER_SEED
	print("TERRAIN_GEN: building %dx%d heightmap (master_seed=%d)..." % [AREA_WIDTH, AREA_LENGTH, resolved_seed])
	var t_start := Time.get_ticks_msec() # temporary timing probe -- answering "is runtime-per-session generation viable" needs a real number, not a guess
	var maps := _build_heightmap(resolved_seed)
	print("TERRAIN_GEN: heightmap build took %d ms (noise+erosion+smoothing+features+road, no I/O)" % (Time.get_ticks_msec() - t_start))

	# -- RUNTIME roguelike generation --
	# This script now lives attached to a "WorldGenerator" node placed as a
	# SIBLING of the real Terrain3D inside main.tscn, so _ready() runs
	# automatically the moment a player presses Play -- no editor-only tool
	# scripts, no manual steps. It writes straight into that already-in-tree
	# Terrain3D and builds real boulder collider nodes directly, rather than
	# creating a throwaway Terrain3D and round-tripping through disk (the
	# old design-time-authoring-tool approach) or leaving a JSON side
	# channel for a separate editor script to pick up later. A roguelike
	# needs a fresh map every playthrough, not a map saved once at design
	# time, so nothing here touches DATA_DIRECTORY/save_directory anymore --
	# WRITE_TARGET/DATA_DIRECTORY/TEST_DATA_DIRECTORY above are now unused,
	# kept only as a record of the old on-disk layout.
	var terrain: Terrain3D = get_parent().get_node_or_null("Terrain3D")
	if terrain == null:
		push_error("TERRAIN_GEN: no sibling Terrain3D node found under %s -- WorldGenerator must be a direct child of the same parent as the live Terrain3D" % get_parent().name)
		return

	var data: Terrain3DData = terrain.get_data()

	# Terrain3D auto-loads whatever's on disk at terrain.data_directory when
	# it enters the tree (that's still there as a static fallback/editor
	# preview), so clear any regions that brought in before importing this
	# run's fresh heightmap -- otherwise a previous playthrough's (or the
	# editor's last saved) terrain would still be sitting underneath.
	for region_location in data.get_region_locations().duplicate():
		data.remove_regionl(region_location, false)

	var t_ready_stage := Time.get_ticks_msec()
	var half_width := AREA_WIDTH * 0.5
	var half_length := AREA_LENGTH * 0.5
	var import_position := Vector3(-half_width, 0, -half_length)
	var images: Array[Image] = [maps.height, maps.control, maps.color] # [HEIGHT, CONTROL, COLOR]
	data.import_images(images, import_position, 0.0, 1.0)
	data.calc_height_range(true)

	var height_range: Vector2 = data.get_height_range()
	print("TERRAIN_GEN: imported. region_count=%d height_range=%s" % [data.get_region_count(), height_range])
	print("TERRAIN_GEN: Terrain3D import+height_range (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Terrain3DData.import_images()'s `global_position` argument does NOT
	# behave like a simple "center of the whole image, expand symmetrically
	# by half-width/half-length" the way it first appeared to (that WAS true
	# for a 256x256 single-region import, purely because with exactly one
	# region needed per axis the two models happen to agree). Once an axis
	# spans MORE than one REGION_SIZE tile, Terrain3D instead anchors via
	# floor(import_position/region_size) per axis and extends the needed
	# tiles toward +X/+Z from there -- so a taller/wider map does NOT grow
	# symmetrically outward from import_position; it only grows in the
	# positive direction, leaving the corner in a different place than the
	# old -width/-length formula assumed. That mismatch is exactly what
	# silently spawned the player mid-map once AREA_LENGTH (512) exceeded
	# REGION_SIZE (256): the analytic formula and Terrain3D's real placement
	# quietly disagreed. Rather than re-deriving (and re-breaking) that
	# arithmetic, heightmap_corner is now read back from where Terrain3D
	# ACTUALLY put the regions, which is correct regardless of how many
	# regions any given AREA_WIDTH/AREA_LENGTH needs.
	var region_size: int = terrain.get_region_size()
	var region_locations: Array = data.get_region_locations()
	var min_region_x: int = region_locations[0].x
	var min_region_z: int = region_locations[0].y
	for loc in region_locations:
		min_region_x = mini(min_region_x, loc.x)
		min_region_z = mini(min_region_z, loc.y)
	var heightmap_corner := Vector3(min_region_x * region_size, 0, min_region_z * region_size)

	# 2026-09-18 debug scaffolding -- see _raise_debug_points' own comment near the top of the
	# file. heightmap_corner is only known here, so the actual box-spawning is deferred to now.
	if RAISE_DEBUG_SHOW_SURFACE:
		_spawn_raise_debug_boxes(heightmap_corner)

	var boulder_rng := RandomNumberGenerator.new()
	# Independent stream from the main pipeline's _derive_seeds -- purely
	# cosmetic scattering, doesn't need to be in that fixed derivation order.
	boulder_rng.seed = resolved_seed ^ 0x424F554C # 'BOUL' salt
	_scatter_boulders(terrain, maps.heights, AREA_WIDTH, AREA_LENGTH, maps.cliff_features, heightmap_corner, boulder_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: boulder scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Scree: dense collider-free debris carpet over the SAME cliff-foot masks,
	# layered under the boulders just scattered above -- see _scatter_scree.
	var scree_rng := RandomNumberGenerator.new()
	scree_rng.seed = resolved_seed ^ 0x53435245 # 'SCRE' salt -- own cosmetic stream
	_scatter_scree(terrain, maps.heights, AREA_WIDTH, AREA_LENGTH, maps.cliff_features, heightmap_corner, scree_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: scree scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = resolved_seed ^ 0x54524545 # 'TREE' salt -- own cosmetic stream
	_scatter_trees(terrain, maps.heights, AREA_WIDTH, AREA_LENGTH, heightmap_corner, tree_rng, maps.road_weight, maps.road_path, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: tree scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Planned + terrain-fitted in _build_heightmap (round 2) -- instancing only here.
	_place_outcrops(maps.outcrop_plan, maps.outcrop_models, heightmap_corner)
	print("TERRAIN_GEN: outcrop placement (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	_build_road_mesh(maps.heights, AREA_WIDTH, AREA_LENGTH, maps.road_path, heightmap_corner, resolved_seed)
	print("TERRAIN_GEN: road mesh build (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# 2026-09-17 reorder: placement is already decided (maps.cliff_dressing_plan, computed
	# inside _build_heightmap before Terrain3D import so the heightmap could be flattened to
	# match each mesh's footprint -- see _plan_cliff_dressing) -- this call only instances it.
	_dress_cliff_faces(maps.cliff_dressing_plan, heightmap_corner, data, maps.cliff_dressing_top_profiles)
	print("TERRAIN_GEN: cliff face dressing (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Move the Player to this run's actual generated spawn point and face it
	# toward the exit -- a scene-baked Player transform (main.tscn's old
	# approach) goes stale the moment terrain params change (AREA_LENGTH,
	# ROAD_GOAL_BAND_FRACTION's random exit column, etc.), which is exactly
	# what silently broke when AREA_LENGTH was doubled: the spawn XZ didn't
	# move, but "forward" for a hand-placed rotation has no reason to still
	# point at where the (now much longer) map's content actually is. Doing
	# this here, every run, means it can never go stale again.
	var player: Node3D = get_parent().get_node_or_null("Player")
	if player == null:
		push_warning("TERRAIN_GEN: no sibling Player node found -- skipping spawn placement")
	else:
		# spawn_pixel/exit_pixel are (px, height, pz) in heightmap-pixel space --
		# only heightmap_corner (now read back from Terrain3D's real region
		# placement, see above) can correctly turn those into world positions.
		var spawn_world: Vector3 = heightmap_corner + Vector3(maps.spawn_pixel.x, maps.spawn_pixel.y, maps.spawn_pixel.z)
		var exit_world: Vector3 = heightmap_corner + Vector3(maps.exit_pixel.x, maps.exit_pixel.y, maps.exit_pixel.z)
		player.global_position = spawn_world
		var facing: Vector3 = exit_world - spawn_world
		facing.y = 0.0 # look_at with a tilted target would pitch/roll the body itself, not just yaw it
		if facing.length_squared() > 0.0001:
			player.look_at(player.global_position + facing, Vector3.UP)
		print("TERRAIN_GEN: player spawned at %s facing exit at %s" % [player.global_position, exit_world])
	print("TERRAIN_GEN: player placement (%.3fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))

	print("TERRAIN_GEN: done (runtime -- nothing written to disk)")
	print("TERRAIN_GEN: _ready() TOTAL (%.2fs) -- this is the actual splash-to-playable gap this script controls" % ((Time.get_ticks_msec() - t_ready_start) / 1000.0))

	# 2026-09-21 startup-time probe (keep until the F6-to-playable investigation is done):
	# _ready() TOTAL only covers this script's own CPU work. Whatever happens AFTER it --
	# deferred add_child of the cliff/boulder/road nodes, physics broadphase for their
	# collision, and GPU pipeline/shader compilation for everything visible on the first
	# frame -- is invisible to it. These absolute timestamps (since process start, same
	# clock as the "_ready() started at" line) bracket that remaining gap.
	var t_ready_end := Time.get_ticks_msec()
	print("TERRAIN_GEN_STARTUP: _ready() finished at t=%.2fs since process start | pipelines so far: %s" % [t_ready_end / 1000.0, _pipeline_counts_str()])
	await RenderingServer.frame_post_draw
	var t_first_draw := Time.get_ticks_msec()
	print("TERRAIN_GEN_STARTUP: first frame drawn at t=%.2fs since process start (+%.2fs after _ready) | pipelines so far: %s | physics step time %.1f ms" % [t_first_draw / 1000.0, (t_first_draw - t_ready_end) / 1000.0, _pipeline_counts_str(), Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	for i in 3:
		await RenderingServer.frame_post_draw
	var t_settled := Time.get_ticks_msec()
	print("TERRAIN_GEN_STARTUP: 4th frame drawn at t=%.2fs since process start (frames 2-4 took %.2fs -- a big number here means shader compile stalls spilling past frame 1) | pipelines so far: %s" % [t_settled / 1000.0, (t_settled - t_first_draw) / 1000.0, _pipeline_counts_str()])

## 2026-09-21 startup-time probe: cumulative GPU pipeline compilations by source. mesh/surface
## are compiled when materials/meshes load; draw/specialization are compiled on demand while
## rendering -- a large jump in those between "_ready finished" and "first frame drawn" means
## the first-frame stall is shader compilation rather than physics.
func _pipeline_counts_str() -> String:
	return "canvas=%d mesh=%d surface=%d draw=%d specialization=%d" % [
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_CANVAS)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_MESH)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SURFACE)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_DRAW)),
		int(Performance.get_monitor(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)),
	]

## Builds a per-pixel obstacle flag (2026-09-17 reorder) from an already-computed cliff-
## dressing plan, so _find_road_path can treat each planned mesh's rotated footprint as
## impassable terrain -- the same role _cliff_placement_blocks_road used to play in reverse
## (back when the road existed first and cliff placement dodged it). Reuses the exact same
## rotated-rectangle math as _flatten_terrain_for_cliff_dressing (half_x/half_z footprint
## from def.real_size/def.depth * scale_jitter, projected onto the mesh's own local basis),
## but as a hard boolean flag rather than a soft height blend, padded by
## CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN so the road can't shave right past the mesh's edge.
func _build_cliff_dressing_obstacle_mask(plan: Array[Dictionary], width: int, length: int) -> PackedByteArray:
	var obstacle := PackedByteArray()
	obstacle.resize(width * length)

	var defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		defs_by_name[def.name] = def

	for entry in plan:
		var def = defs_by_name.get(entry.def_name)
		if def == null:
			continue
		var px: float = entry.px
		var pz: float = entry.pz
		var face_angle: float = entry.face_angle
		var scale_jitter: float = entry.scale_jitter

		var cos_a := cos(face_angle)
		var sin_a := sin(face_angle)
		var axis_local_x := Vector2(cos_a, -sin_a)
		var axis_local_z := Vector2(sin_a, cos_a)

		var half_x: float = def.real_size * scale_jitter * 0.5 + CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
		var half_z: float = def.depth * scale_jitter * 0.5 + CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
		# Front/low side (local_z >= 0, the side the mesh's own footprint faces -- see
		# _flatten_terrain_for_cliff_dressing) keeps the original symmetric-looking half_z bound.
		# The behind side (local_z < 0) now also has real raised ground on it, from
		# _raise_terrain_behind_cliff_dressing's ramp + plateau (2026-09-17) -- extend the obstacle
		# there so the road doesn't get routed up onto/through that new landform.
		var half_z_behind: float = half_z + CLIFF_DRESSING_RAISE_RAMP_DISTANCE + CLIFF_DRESSING_RAISE_PLATEAU_DEPTH
		var reach := sqrt(half_x * half_x + half_z_behind * half_z_behind)

		var min_px := clampi(int(floor(px - reach)), 0, width - 1)
		var max_px := clampi(int(ceil(px + reach)), 0, width - 1)
		var min_pz := clampi(int(floor(pz - reach)), 0, length - 1)
		var max_pz := clampi(int(ceil(pz + reach)), 0, length - 1)

		for qz in range(min_pz, max_pz + 1):
			for qx in range(min_px, max_px + 1):
				var delta := Vector2(qx - px, qz - pz)
				var local_x := delta.dot(axis_local_x)
				var local_z := delta.dot(axis_local_z)
				var local_half_z := half_z if local_z >= 0.0 else half_z_behind
				if absf(local_x) <= half_x and absf(local_z) <= local_half_z:
					obstacle[qz * width + qx] = 1
	return obstacle

## Plans cliff-face dressing placements (2026-09-17 reorder): walks each single-sided-step
## fault-line feature (ESCARPMENT/TERRACE/GENTLE_RISE -- identified by feature.has("step_height"),
## same subset _scatter_boulders reads; V_RAVINE and KNOLL are skipped, same as there) and
## decides, for every placement along it, which model to use and where/how to orient it --
## the same geometry decisions _dress_cliff_faces used to make inline, just computed HERE,
## inside _build_heightmap, BEFORE the heightmap is baked into height_image and imported into
## Terrain3D. That ordering is what lets _flatten_terrain_for_cliff_dressing (below) carve the
## plain `heights` array to match each mesh's footprint -- doing this after Terrain3D import
## would mean rewriting live Terrain3D region data instead of a plain array. Mesh instancing
## itself still happens later, in _dress_cliff_faces, once Terrain3D and heightmap_corner exist.
func _plan_cliff_dressing(cliff_features: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	# 2026-09-17: tracks how many times each CLIFF_DRESSING_DEFS model has been placed so
	# far across the WHOLE map (declared here, above the per-feature loop, so it balances
	# globally rather than resetting per fault) -- see the least-used-first selection below.
	var dressing_usage_count: Dictionary = {}
	for feature in cliff_features:
		# Only single-sided-step archetypes have an actual face to dress.
		if not feature.has("step_height"):
			continue
		var half_len: float = feature.half_len
		var axis_x: float = feature.axis_x
		var axis_z: float = feature.axis_z
		var perp_x: float = feature.perp_x
		var perp_z: float = feature.perp_z
		var step_height: float = feature.step_height
		var center: Vector2 = feature.center
		var curve_amplitude: float = feature.curve_amplitude
		var curve_frequency: float = feature.curve_frequency
		var curve_phase: float = feature.curve_phase
		var curve_frequency2: float = feature.curve_frequency2
		var curve_phase2: float = feature.curve_phase2
		var curve_weight2: float = feature.curve_weight2

		# Low side sign: same meaning as _scatter_boulders' identical local -- the side of
		# the fault that does NOT get the step_height boost, i.e. the base of the drop, which
		# is where a cliff face's visible mass actually belongs (the high side is the top of
		# the plateau, already flat ground).
		var low_side_sign := -1.0 if step_height > 0.0 else 1.0
		var usable_half_len := half_len * (1.0 - BOULDER_END_INSET_FRACTION)
		var cursor := -usable_half_len

		while cursor < usable_half_len - 0.5:
			var remaining := usable_half_len - cursor
			# 2026-09-17: was "prefer the largest model that still fits" -- confirmed via a
			# temporary debug print that this greedy rule starved rock_face_02 and
			# namaqualand_cliff_01 entirely (14 of 18 picks in one run went to
			# namaqualand_cliff_02 alone), because each big pick advances `remaining` by a
			# large chunk (real_size + CLIFF_DRESSING_SPACING) that usually jumps straight over
			# the narrow bands where the mid-sized models would have won. User asked for
			# roughly equal usage of all 5 models instead, so: among every model that fits the
			# remaining span, pick whichever has been placed FEWEST times so far across the
			# whole map (ties broken randomly) -- this converges toward equal counts instead of
			# always favoring one size class. Falls back to the smallest model available so
			# short remaining spans still get dressed, same as before.
			var fitting: Array = []
			for def in CLIFF_DRESSING_DEFS:
				if def.real_size * 0.5 <= remaining:
					fitting.append(def)
			if fitting.is_empty():
				var smallest = CLIFF_DRESSING_DEFS[0]
				for def in CLIFF_DRESSING_DEFS:
					if def.real_size < smallest.real_size:
						smallest = def
				fitting = [smallest]
			var min_usage: int = 999999
			for def in fitting:
				min_usage = mini(min_usage, dressing_usage_count.get(def.name, 0))
			var least_used: Array = []
			for def in fitting:
				if dressing_usage_count.get(def.name, 0) == min_usage:
					least_used.append(def)
			var chosen = least_used[rng.randi() % least_used.size()]
			dressing_usage_count[chosen.name] = dressing_usage_count.get(chosen.name, 0) + 1

			var t: float = cursor + chosen.real_size * 0.5
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)

			var px := clampf(center.x + t * axis_x + curve_offset * perp_x, 0.0, float(width - 1))
			var pz := clampf(center.y + t * axis_z + curve_offset * perp_z, 0.0, float(length - 1))

			# Front direction: toward the low side along the fault's perpendicular axis --
			# an approximation (the source meshes carry no metadata on which local axis is
			# their "face"). Computed here (before the yaw jitter that's added to face_angle
			# below) because it's also needed to find where to sample terrain height for
			# the mesh's vertical anchor -- see CLIFF_DRESSING_FOOT_SAMPLE_OFFSET.
			var face_dir_x := perp_x * low_side_sign
			var face_dir_z := perp_z * low_side_sign

			# No road-avoidance check here any more (2026-09-17 reorder) -- cliff dressing is
			# now planned BEFORE the road exists, so there is nothing yet to avoid. The road
			# instead routes around these planned footprints -- see CLIFF_DRESSING_ROAD_OBSTACLE_
			# MARGIN and _build_cliff_dressing_obstacle_mask.

			# Vertical anchor: sampled at the low-side FOOT of the drop, offset from the fault
			# line itself, instead of ON the line (px, pz). The line is the CENTER of the
			# face's smoothstep transition (see FEATURE_EDGE_SOFTNESS / _place_line_feature),
			# so sampling exactly there bakes in ~half the full step height rather than the
			# true low-side floor height. Horizontal placement (px, pz) is unaffected -- only
			# where we look UP the terrain to decide how far down the mesh's base belongs.
			var foot_a_px := clampf(px + face_dir_x * CLIFF_DRESSING_FOOT_SAMPLE_OFFSET, 0.0, float(width - 1))
			var foot_a_pz := clampf(pz + face_dir_z * CLIFF_DRESSING_FOOT_SAMPLE_OFFSET, 0.0, float(length - 1))
			var foot_b_px := clampf(px - face_dir_x * CLIFF_DRESSING_FOOT_SAMPLE_OFFSET, 0.0, float(width - 1))
			var foot_b_pz := clampf(pz - face_dir_z * CLIFF_DRESSING_FOOT_SAMPLE_OFFSET, 0.0, float(length - 1))
			var foot_a_height := _sample_height_bilinear(heights, width, length, foot_a_px, foot_a_pz)
			var foot_b_height := _sample_height_bilinear(heights, width, length, foot_b_px, foot_b_pz)

			# Ground-truth low-side check (2026-09-17): the fault's own step_height is what
			# DEFINES face_dir/low_side_sign above, but that step gets ADDED on top of whatever
			# macro terrain already existed there (_place_line_feature does heights[idx] +=
			# local_height * face * ..., never an absolute set) -- so on top of, say, the
			# valley wall's own ~16-unit macro slope (VALLEY_LEFT/RIGHT_WALL_HEIGHT), a small
			# 3-6 unit ESCARPMENT step can be completely swamped, and the fault's theoretical
			# low side is no longer the side that's actually lower once real terrain is taken
			# into account. Trusting the fault's own polarity there produced cliff meshes
			# facing backwards and flattened onto an artificially raised pad (the foot sample
			# landing uphill instead of downhill). Comparing the two candidate foot heights
			# directly in the ALREADY-CARVED heightmap and keeping whichever side is actually
			# lower fixes this at the source, regardless of why the terrain looks the way it
			# does there -- most placements agree with the fault's own guess and nothing
			# changes; this only kicks in where a bigger surrounding feature dominates.
			var foot_px := foot_a_px
			var foot_pz := foot_a_pz
			var height := foot_a_height
			if foot_b_height < foot_a_height:
				face_dir_x = -face_dir_x
				face_dir_z = -face_dir_z
				foot_px = foot_b_px
				foot_pz = foot_b_pz
				height = foot_b_height

			var scale_jitter := rng.randf_range(CLIFF_DRESSING_SCALE_MIN, CLIFF_DRESSING_SCALE_MAX)
			# atan2(face_dir_x, face_dir_z), NOT the Node3D-forward-vector-derived
			# atan2(-face_dir_x, -face_dir_z) -- confirmed in-game (screenshots, green/red
			# face_dir markers) to be the orientation that actually faces the source GLBs'
			# detailed rock surface toward the open/low side. See the 2026-09-17 history on
			# this line before changing it again -- ground truth from looking at it beat the
			# abstract Node3D-forward-vector math here.
			var face_angle := atan2(face_dir_x, face_dir_z) + rng.randf_range(-CLIFF_DRESSING_YAW_JITTER, CLIFF_DRESSING_YAW_JITTER)

			plan.append({
				"def_name": chosen.name,
				"px": px,
				"pz": pz,
				"face_angle": face_angle,
				"scale_jitter": scale_jitter,
				"face_dir_x": face_dir_x,
				"face_dir_z": face_dir_z,
				"height": height,
			})

			cursor += chosen.real_size + CLIFF_DRESSING_SPACING
	return plan

## Flattens the heightmap under each PLANNED cliff-face mesh's own footprint (option 1 of the
## terrain-clipping fixes discussed 2026-09-17: "the terrain clips through the cliff face").
## A placement's height is sampled once, at ITS foot offset (CLIFF_DRESSING_FOOT_SAMPLE_OFFSET)
## -- but nothing previously stopped the surrounding noise/erosion terrain from rising back
## above that single sampled height somewhere else across the mesh's own width/depth, which is
## exactly what let a stray erosion peak poke through/in front of a placed cliff face. Carving
## this into `heights` HERE (called from _build_heightmap right after _plan_cliff_dressing,
## before height_image is assembled and Terrain3D imports it) bakes the fix into the terrain
## itself -- no live Terrain3D region data to rewrite after the fact, and boulder scattering /
## road routing / collision all see the same corrected heightmap everything else builds on.
func _flatten_terrain_for_cliff_dressing(plan: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int) -> void:
	var defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		defs_by_name[def.name] = def

	for entry in plan:
		var def = defs_by_name.get(entry.def_name)
		if def == null:
			continue
		var px: float = entry.px
		var pz: float = entry.pz
		var face_angle: float = entry.face_angle
		var scale_jitter: float = entry.scale_jitter
		var target_height: float = entry.height

		# Local basis for the mesh's own rotated footprint -- matches Godot's Y-axis
		# rotation convention (rotation.y = face_angle is exactly what mesh_root gets in
		# _dress_cliff_faces), including the yaw jitter already baked into face_angle, so
		# this footprint matches the real mesh's real orientation, not just its pre-jitter
		# fault-aligned direction.
		var cos_a := cos(face_angle)
		var sin_a := sin(face_angle)
		var axis_local_x := Vector2(cos_a, -sin_a) # local +X (real_size/width) in world XZ
		var axis_local_z := Vector2(sin_a, cos_a) # local +Z (depth/thickness) in world XZ

		var half_x: float = def.real_size * scale_jitter * 0.5
		var half_z: float = def.depth * scale_jitter * 0.5

		# 2026-09-18 round 5 ("left side is not 31 degrees"): sample the REAL, still-untouched
		# heightmap just past each of the footprint's 4 sides before writing anything, so a
		# placement sitting where the natural terrain drops away sharply from target_height gets
		# a wider blend instead of the same fixed 2.5 units every time -- same slope-based idea
		# as _raise_terrain_behind_cliff_dressing's fix, applied to the flatten pass that actually
		# shapes the mesh's visible sides/front (raise never touches that area at all).
		var probe_offsets: Array[Vector2] = [
			Vector2(half_x + CLIFF_DRESSING_FLATTEN_SOFTNESS, 0.0),
			Vector2(-half_x - CLIFF_DRESSING_FLATTEN_SOFTNESS, 0.0),
			Vector2(0.0, half_z + CLIFF_DRESSING_FLATTEN_SOFTNESS),
			Vector2(0.0, -half_z - CLIFF_DRESSING_FLATTEN_SOFTNESS),
		]
		var max_height_gap := 0.0
		for probe: Vector2 in probe_offsets:
			var probe_world: Vector2 = Vector2(px, pz) + probe.x * axis_local_x + probe.y * axis_local_z
			var probe_qx := clampi(int(round(probe_world.x)), 0, width - 1)
			var probe_qz := clampi(int(round(probe_world.y)), 0, length - 1)
			var probe_height := heights[probe_qz * width + probe_qx]
			max_height_gap = maxf(max_height_gap, absf(probe_height - target_height))
		var softness := clampf(max_height_gap / CLIFF_DRESSING_RAISE_MAX_SLOPE, CLIFF_DRESSING_FLATTEN_SOFTNESS, CLIFF_DRESSING_FLATTEN_SOFTNESS_MAX)
		var reach := sqrt(half_x * half_x + half_z * half_z) + softness

		var min_px := clampi(int(floor(px - reach)), 0, width - 1)
		var max_px := clampi(int(ceil(px + reach)), 0, width - 1)
		var min_pz := clampi(int(floor(pz - reach)), 0, length - 1)
		var max_pz := clampi(int(ceil(pz + reach)), 0, length - 1)

		for qz in range(min_pz, max_pz + 1):
			for qx in range(min_px, max_px + 1):
				var delta := Vector2(qx - px, qz - pz)
				var local_x := delta.dot(axis_local_x)
				var local_z := delta.dot(axis_local_z)
				var dist_x := maxf(0.0, absf(local_x) - half_x)
				var dist_z := maxf(0.0, absf(local_z) - half_z)
				var outside_dist := Vector2(dist_x, dist_z).length()
				if outside_dist >= softness:
					continue
				var weight := 1.0 - smoothstep(0.0, softness, outside_dist)
				var idx := qz * width + qx
				heights[idx] = lerpf(heights[idx], target_height, weight)

## Recursively gathers every MeshInstance3D's vertices under `node`, transformed into `node`'s
## own root local space (2026-09-17, "match the elevation line"): each node's own `transform`
## (local to ITS parent) is folded into `parent_transform` on the way down, so a multi-part
## model (mountainside is 5 separate MeshInstance3D nodes -- see _add_cliff_collision_recursive's
## comment) still comes back as one consistent set of vertices in the top-level root's space,
## the same space _dress_cliff_faces places mesh_root's scale/rotation/position onto.
func _collect_mesh_vertices_recursive(node: Node, parent_transform: Transform3D, out_vertices: PackedVector3Array) -> void:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		if mesh_inst.mesh:
			for surface_idx in mesh_inst.mesh.get_surface_count():
				var arrays := mesh_inst.mesh.surface_get_arrays(surface_idx)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts:
					out_vertices.append(local_transform * v)
	for child in node.get_children():
		_collect_mesh_vertices_recursive(child, local_transform, out_vertices)


## Builds a height-vs-local-X "skyline" profile for one cliff dressing model (2026-09-17,
## the "match the elevation line" follow-up to the plateau raise below): a single flat
## plateau height ignored how much a real rock formation's top edge rises and falls across
## its own width (tall on one end, low on the other in practice). This walks the model's own
## GLB geometry in the SAME local space _dress_cliff_faces places mesh_root in (before that
## instance's own scale_jitter/rotation/position are applied), buckets every vertex by its
## local X position into CLIFF_DRESSING_TOP_PROFILE_SAMPLES samples spanning the model's own
## local X range, and keeps the highest local Y seen in each bucket -- the model's real
## top-of-silhouette height at that slice, not one flat bounding-box number. A bucket with no
## vertex (a gap thinner than one sample) is filled by linearly interpolating between its
## nearest valid neighbors -- the extremes always have data, since whichever vertex achieved
## the model's own x_min/x_max necessarily lands in bucket 0 / sample_count-1. Computed once
## per model (5 models total, cached by _build_cliff_dressing_top_profiles), not once per
## placement.
func _compute_cliff_dressing_top_profile(def: Dictionary) -> Dictionary:
	var fallback := {"x_min": -def.real_size * 0.5, "x_max": def.real_size * 0.5, "heights": PackedFloat32Array([def.height, def.height]), "y_min": 0.0, "y_max": def.height, "z_min": -def.depth * 0.5, "z_max": def.depth * 0.5}
	var scene: PackedScene = load(def.glb)
	if scene == null:
		push_warning("TERRAIN_GEN: could not load %s for top-profile sampling -- falling back to flat height" % def.glb)
		return fallback
	var root := scene.instantiate()
	if root == null:
		return fallback
	# 2026-09-17: confirmed (by a since-removed diagnostic print) that every cliff dressing
	# model's root node has an identity transform on instantiation, so scanning vertices
	# with Transform3D.IDENTITY as the starting parent_transform below correctly matches
	# the local space mesh_root actually uses at placement (its own transform is set fresh
	# by _dress_cliff_faces, discarding whatever the scene's root was authored with).
	var vertices := PackedVector3Array()
	_collect_mesh_vertices_recursive(root, Transform3D.IDENTITY, vertices)
	root.free()
	if vertices.is_empty():
		push_warning("TERRAIN_GEN: no mesh geometry found in %s for top-profile sampling -- falling back to flat height" % def.glb)
		return fallback

	var x_min := vertices[0].x
	var x_max := vertices[0].x
	# Full AABB (2026-09-17, "scan it the same way" -- backing-volume fix): these Poly Haven
	# cliff scans are thin, one-sided displacement shells, not closed volumes (see
	# _dress_cliff_faces' CULL_DISABLED comment) -- a multi-part model like mountainside (5
	# separate MeshInstance3D pieces) can have real seam gaps between its own pieces, which
	# show as a hole straight through to the skybox no amount of terrain-height tuning can
	# fix (the gap is IN the mesh's own front-facing geometry, not at its terrain footprint
	# edge). y/z extents captured here size a solid backing volume placed just behind the
	# real mesh in _dress_cliff_faces, so any such seam gap reveals rock instead of void.
	var y_min := vertices[0].y
	var y_max := vertices[0].y
	var z_min := vertices[0].z
	var z_max := vertices[0].z
	for v in vertices:
		x_min = minf(x_min, v.x)
		x_max = maxf(x_max, v.x)
		y_min = minf(y_min, v.y)
		y_max = maxf(y_max, v.y)
		z_min = minf(z_min, v.z)
		z_max = maxf(z_max, v.z)

	var sample_count := CLIFF_DRESSING_TOP_PROFILE_SAMPLES
	var heights := PackedFloat32Array()
	heights.resize(sample_count)
	var has_data := PackedByteArray()
	has_data.resize(sample_count)
	for i in sample_count:
		heights[i] = -INF
		has_data[i] = 0

	var span := x_max - x_min
	for v in vertices:
		var t := 0.0 if span <= 0.0 else (v.x - x_min) / span
		var bucket := clampi(int(round(t * float(sample_count - 1))), 0, sample_count - 1)
		if v.y > heights[bucket]:
			heights[bucket] = v.y
		has_data[bucket] = 1

	var i := 0
	while i < sample_count:
		if has_data[i] == 1:
			i += 1
			continue
		var left := i - 1
		var right := i
		while right < sample_count and has_data[right] == 0:
			right += 1
		var left_h: float = heights[left] if left >= 0 else (heights[right] if right < sample_count else def.height)
		var right_h: float = heights[right] if right < sample_count else left_h
		for j in range(i, right):
			var frac := 0.5 if right == left else float(j - left) / float(right - left)
			heights[j] = lerpf(left_h, right_h, frac)
			has_data[j] = 1
		i = right

	return {"x_min": x_min, "x_max": x_max, "heights": heights, "y_min": y_min, "y_max": y_max, "z_min": z_min, "z_max": z_max}

## Builds the per-model top profiles used by _raise_terrain_behind_cliff_dressing, once per
## _build_heightmap run (5 models, not once per placement -- see
## _compute_cliff_dressing_top_profile's own comment).
func _build_cliff_dressing_top_profiles() -> Dictionary:
	var profiles := {}
	for def in CLIFF_DRESSING_DEFS:
		profiles[def.name] = _compute_cliff_dressing_top_profile(def)
	return profiles

## Samples a top profile (as returned by _compute_cliff_dressing_top_profile) at a given
## local-X position, clamping to the model's own sampled range and linearly interpolating
## between the two nearest samples.
func _sample_cliff_top_profile(profile: Dictionary, x: float) -> float:
	var heights: PackedFloat32Array = profile.get("heights", PackedFloat32Array())
	var n := heights.size()
	if n == 0:
		return 0.0
	if n == 1:
		return heights[0]
	var x_min: float = profile.get("x_min", 0.0)
	var x_max: float = profile.get("x_max", 0.0)
	var t := 0.0
	if x_max > x_min:
		t = clampf((x - x_min) / (x_max - x_min), 0.0, 1.0)
	var f := t * float(n - 1)
	var i0 := clampi(int(floor(f)), 0, n - 1)
	var i1 := clampi(i0 + 1, 0, n - 1)
	var frac := f - float(i0)
	return lerpf(heights[i0], heights[i1], frac)

## 2026-09-18 round 17 -- see CLIFF_DRESSING_FLANK_BAND_FRACTION's own comment. Max of the
## profile over the outer band on one side (left = low-X end), in the model's own unscaled
## local units, same as the profile itself.
func _cliff_profile_flank_height(profile: Dictionary, left_side: bool) -> float:
	var heights: PackedFloat32Array = profile.get("heights", PackedFloat32Array())
	var n := heights.size()
	if n == 0:
		return 0.0
	var band_count := maxi(1, int(ceil(float(n) * CLIFF_DRESSING_FLANK_BAND_FRACTION)))
	var best := -INF
	for k in range(band_count):
		var i := k if left_side else n - 1 - k
		best = maxf(best, heights[i])
	return best

## Same as _sample_cliff_top_profile, except that within the outer band on each side the height
## smoothly rises to that side's flank height (never lowered), and past the model's own X
## range it IS the flank height -- instead of the raw outermost slice.
## 2026-09-18 round 22 ("standing on stitch, again only appears on mountainside mesh" -- a
## front-to-back trench ~1.2 units inside mountainside's left edge, behind the mesh): round 17
## smoothstep-lerped from the raw profile up to the flank height across the band -- but
## mountainside's profile drops steeply INSIDE its left band (10.0 -> 7.9 -> 4.9), and mid-band
## the lerp hadn't caught up with that drop yet, so the result dipped ~1 unit below both sides.
## Now: within the outer band, the height is the running MAX of the profile from x out to the
## band's inner boundary -- continuous, never below the raw profile, never decreasing towards
## the edge (so it can't dip), and equal to the band's max at the edge. Past the model's own X
## range it holds that edge value. flank_left/flank_right are kept in the signature for the
## existing callers but no longer needed.
func _sample_cliff_top_profile_flanked(profile: Dictionary, x: float, _flank_left: float, _flank_right: float) -> float:
	var base := _sample_cliff_top_profile(profile, x)
	var heights: PackedFloat32Array = profile.get("heights", PackedFloat32Array())
	var n := heights.size()
	var x_min: float = profile.get("x_min", 0.0)
	var x_max: float = profile.get("x_max", 0.0)
	var width := x_max - x_min
	if width <= 0.0 or n < 2:
		return base
	var band := CLIFF_DRESSING_FLANK_BAND_FRACTION * width
	var step := width / float(n - 1)
	if x <= x_min + band:
		var inner := x_min + band
		var result := maxf(base, _sample_cliff_top_profile(profile, inner))
		var xc := maxf(x, x_min)
		result = maxf(result, _sample_cliff_top_profile(profile, xc))
		for i in range(n):
			var xi := x_min + step * float(i)
			if xi >= xc and xi <= inner:
				result = maxf(result, heights[i])
		return result
	if x >= x_max - band:
		var inner := x_max - band
		var result := maxf(base, _sample_cliff_top_profile(profile, inner))
		var xc := minf(x, x_max)
		result = maxf(result, _sample_cliff_top_profile(profile, xc))
		for i in range(n):
			var xi := x_min + step * float(i)
			if xi <= xc and xi >= inner:
				result = maxf(result, heights[i])
		return result
	return base


## Raises the terrain BEHIND each planned cliff-face mesh up toward the mesh's own visible
## height (2026-09-17, the "turn the magenta boxes into terrain" follow-up to option 1 above):
## _flatten_terrain_for_cliff_dressing only ever levels the LOW side the mesh's own footprint
## sits on -- it says nothing about what's behind the face, so that ground was left as
## whatever the fault's own (much smaller) step_height + noise + erosion happened to produce,
## almost always far short of the tall GLB rock mesh's actual visible height. The magenta
## DebugCube in _dress_cliff_faces already visualized this exact mismatch (drawn at the
## mesh's real height, from the same low-side base) but never affected the terrain itself.
## This carves the same idea into `heights` for real: a ramp rising from the already-
## flattened low shelf up to the mesh's visible top height, held flat for a stretch, then
## faded back down to the untouched natural terrain at the far edge -- deliberately NOT a
## uniform box raise, which would leave vertical walls on the back/sides and read as a
## floating mesa instead of "the ground rises to meet this rock face."
## 2026-09-18 debug scaffolding -- see _raise_debug_heights' own comment near the top of the
## file. Converts the full-resolution grid _raise_terrain_behind_cliff_dressing recorded
## (instead of writing into the real heightmap) into a continuous, semi-transparent yellow
## surface -- so it reads as "what the raised terrain would actually look like", not just
## scattered sample points. Every 2x2 block of pixels that were ALL touched by the raise pass
## (no RAISE_DEBUG_UNSET corner) becomes one quad; a block with any untouched corner is left
## as a gap, so the surface's own edge shows exactly where the raise pass's effect stops.
## Rebuilt fresh every run, same as CliffDressing/BoulderColliders/RoadMesh.
func _spawn_raise_debug_boxes(heightmap_corner: Vector3) -> void:
	var parent := get_parent()
	var old_container := parent.get_node_or_null("RaiseDebugBoxes")
	if old_container:
		old_container.queue_free()
	if _raise_debug_heights.is_empty():
		print("TERRAIN_GEN_DEBUG: _raise_debug_heights is empty -- nothing to visualize")
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quad_count := 0
	# 2026-09-18 round 16 -- color each quad by whichever plan entry actually won the max at
	# its "anchor" corner (h00), so overlapping placements' contributions are visually
	# distinguishable instead of blurring into one flat yellow blob (see
	# _raise_debug_entry_index's own comment near the top of the file for why this was needed --
	# the last two fixes were misattributed to the wrong mesh because of exactly this ambiguity).
	# A stable golden-angle hue spread keeps adjacent entry_index values visually distinct.
	for qz in range(AREA_LENGTH - 1):
		for qx in range(AREA_WIDTH - 1):
			var idx00 := qz * AREA_WIDTH + qx
			var idx10 := qz * AREA_WIDTH + (qx + 1)
			var idx01 := (qz + 1) * AREA_WIDTH + qx
			var idx11 := (qz + 1) * AREA_WIDTH + (qx + 1)
			var h00: float = _raise_debug_heights[idx00]
			var h10: float = _raise_debug_heights[idx10]
			var h01: float = _raise_debug_heights[idx01]
			var h11: float = _raise_debug_heights[idx11]
			if h00 <= RAISE_DEBUG_UNSET or h10 <= RAISE_DEBUG_UNSET or h01 <= RAISE_DEBUG_UNSET or h11 <= RAISE_DEBUG_UNSET:
				continue
			var p00 := heightmap_corner + Vector3(qx, h00, qz)
			var p10 := heightmap_corner + Vector3(qx + 1, h10, qz)
			var p01 := heightmap_corner + Vector3(qx, h01, qz + 1)
			var p11 := heightmap_corner + Vector3(qx + 1, h11, qz + 1)
			var winning_entry: int = _raise_debug_entry_index[idx00]
			var quad_color := Color.from_hsv(fposmod(winning_entry * 0.61803399, 1.0), 0.65, 1.0, 0.6) if winning_entry >= 0 else Color(1.0, 0.9, 0.0, 0.6)
			st.set_color(quad_color)
			st.add_vertex(p00)
			st.set_color(quad_color)
			st.add_vertex(p10)
			st.set_color(quad_color)
			st.add_vertex(p11)
			st.set_color(quad_color)
			st.add_vertex(p00)
			st.set_color(quad_color)
			st.add_vertex(p11)
			st.set_color(quad_color)
			st.add_vertex(p01)
			quad_count += 1
	if quad_count == 0:
		print("TERRAIN_GEN_DEBUG: raise pass touched no pixels -- nothing to visualize")
		return

	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)

	var inst := MeshInstance3D.new()
	inst.name = "RaiseDebugBoxes"
	inst.mesh = mesh
	parent.add_child.call_deferred(inst)
	print("TERRAIN_GEN_DEBUG: spawned yellow raise-debug surface (%d quads)" % quad_count)

# 2026-09-18 round 15b -- see join_edge_height_left's own comment inside
# _raise_terrain_behind_cliff_dressing. facing_right_edge picks which of the neighbor's own
# two edges to sample: true when WE sit to the neighbor's right (so its RIGHT edge is the one
# facing us), false when we sit to its left.
func _sample_neighbor_facing_plateau_height(other: Dictionary, other_half_x: float, facing_right_edge: bool, top_profiles: Dictionary, defs_by_name: Dictionary) -> float:
	var other_def = defs_by_name.get(other.def_name)
	if other_def == null:
		return NAN
	var other_scale: float = other.scale_jitter
	if other_scale <= 0.0:
		return NAN
	var other_origin_y: float = other.height - CLIFF_DRESSING_EMBED_DEPTH * other_scale
	var other_profile: Dictionary = top_profiles.get(other.def_name, {})
	var signed_half_x := other_half_x if facing_right_edge else -other_half_x
	var local_x_unscaled := signed_half_x / other_scale
	# round 17: same flank-aware sampling as the entry's own sides, so a join seam compares like
	# with like.
	var edge_top := _sample_cliff_top_profile_flanked(other_profile, local_x_unscaled, _cliff_profile_flank_height(other_profile, true), _cliff_profile_flank_height(other_profile, false))
	return other_origin_y + edge_top * other_scale

func _raise_terrain_behind_cliff_dressing(plan: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, top_profiles: Dictionary, noise_seed: int) -> void:
	# 2026-09-18 round 20 -- see CLIFF_DRESSING_RAISE_EDGE_WARP / _BUMP_* comments.
	var raise_warp_noise := FastNoiseLite.new()
	raise_warp_noise.seed = noise_seed
	raise_warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	raise_warp_noise.frequency = CLIFF_DRESSING_RAISE_WARP_FREQUENCY
	raise_warp_noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	var raise_bump_noise := FastNoiseLite.new()
	raise_bump_noise.seed = noise_seed + 1
	raise_bump_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	raise_bump_noise.frequency = CLIFF_DRESSING_RAISE_BUMP_FREQUENCY
	raise_bump_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	raise_bump_noise.fractal_octaves = 2
	# 2026-09-18 debug scaffolding -- see _raise_debug_heights' own comment near the top of the
	# file. Same size/layout as `heights` itself, sentinel-filled so the surface builder later
	# knows exactly which pixels this pass would have touched.
	_raise_debug_heights = PackedFloat32Array()
	_raise_debug_heights.resize(width * length)
	for i in _raise_debug_heights.size():
		_raise_debug_heights[i] = RAISE_DEBUG_UNSET
	_raise_debug_entry_index = PackedInt32Array()
	_raise_debug_entry_index.resize(width * length)
	for i in _raise_debug_entry_index.size():
		_raise_debug_entry_index[i] = -1
	var defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		defs_by_name[def.name] = def

	# 2026-09-18 round 3 ("still too steep, should be a very gentle mound"): round 2 capped
	# EVERY placement's lateral softness at a single fixed CLIFF_DRESSING_RAISE_LATERAL_
	# SOFTNESS_MAX sized to be safe even for two placements sitting the minimum
	# CLIFF_DRESSING_SPACING apart -- but that punishes an isolated mountainside with no
	# close neighbor at all, capping its mound just as tight as if one were 6 units away.
	# Precomputing every placement's real footprint half-extents up front lets the loop
	# below look up how much room ACTUALLY exists next to each one and only cap as tightly
	# as that placement's real neighbors require -- an isolated placement gets the full,
	# properly gentle slope; a tightly-packed one still gets the old safe cap.
	var all_half_x: PackedFloat32Array = PackedFloat32Array()
	var all_half_z: PackedFloat32Array = PackedFloat32Array()
	all_half_x.resize(plan.size())
	all_half_z.resize(plan.size())
	for i in range(plan.size()):
		var pre_entry = plan[i]
		var pre_def = defs_by_name.get(pre_entry.def_name)
		if pre_def == null:
			continue
		var pre_scale: float = pre_entry.scale_jitter
		var pre_half_x: float = pre_def.real_size * pre_scale * 0.5
		var pre_profile: Dictionary = top_profiles.get(pre_entry.def_name, {})
		var pre_x_min: float = pre_profile.get("x_min", -pre_half_x)
		var pre_x_max: float = pre_profile.get("x_max", pre_half_x)
		pre_half_x = maxf(pre_half_x, maxf(absf(pre_x_min), absf(pre_x_max)) * pre_scale)
		all_half_x[i] = pre_half_x
		all_half_z[i] = pre_def.depth * pre_scale * 0.5

	for entry_index in range(plan.size()):
		var entry = plan[entry_index]
		var def = defs_by_name.get(entry.def_name)
		if def == null:
			continue
		var px: float = entry.px
		var pz: float = entry.pz
		var face_angle: float = entry.face_angle
		var scale_jitter: float = entry.scale_jitter
		var low_height: float = entry.height

		# Same rotated local basis as _flatten_terrain_for_cliff_dressing -- local +Z
		# (axis_local_z) matches the mesh's own face_dir (front/open/low side), so "behind"
		# is the -local_z direction.
		var cos_a := cos(face_angle)
		var sin_a := sin(face_angle)
		var axis_local_x := Vector2(cos_a, -sin_a)
		var axis_local_z := Vector2(sin_a, cos_a)

		var half_x: float = def.real_size * scale_jitter * 0.5
		var half_z: float = def.depth * scale_jitter * 0.5

		# origin_y is where the mesh's own local (0,0,0) sits in world space -- exactly
		# mesh_root.position.y in _dress_cliff_faces. Sampling the model's own top profile
		# (2026-09-17, "match the elevation line") and scaling it by scale_jitter reconstructs
		# the real mesh's actual world-space top height at any point along its width, instead
		# of the single flat bounding-box number (def.height) used before.
		var origin_y: float = low_height - CLIFF_DRESSING_EMBED_DEPTH * scale_jitter
		var top_profile: Dictionary = top_profiles.get(entry.def_name, {})

		# def.real_size is a hand-authored placeholder, tuned for placement spacing rather than
		# as an exact bounding box -- if the model's REAL geometry (especially a multi-part one
		# like mountainside's 5 separate MeshInstance3D pieces) extends further sideways than
		# that number assumes, everything past half_x was never touched by the loop below at
		# all (outside its own `reach` bound), leaving a hard, completely untouched boundary --
		# not a too-steep blend, a "we never got here" gap (2026-09-17 fix, the actual cause of
		# the still-visible disconnected edge after the slope-widening pass above). The top
		# profile's x_min/x_max come from the model's own real vertices, so widen half_x to
		# whichever is bigger instead of trusting the hand-authored number alone.
		var profile_x_min: float = top_profile.get("x_min", -half_x)
		var profile_x_max: float = top_profile.get("x_max", half_x)
		var profile_half_x := maxf(absf(profile_x_min), absf(profile_x_max)) * scale_jitter
		half_x = maxf(half_x, profile_half_x)

		var profile_heights: PackedFloat32Array = top_profile.get("heights", PackedFloat32Array())
		var max_local_top := 0.0
		for sample in profile_heights:
			max_local_top = maxf(max_local_top, sample)
		# Worst-case climb this placement's raised ground has to blend away anywhere along its
		# width -- used below to widen the lateral/fade aprons on tall models (2026-09-17,
		# "gently ingrained" -- see CLIFF_DRESSING_RAISE_MAX_SLOPE's own comment for why a fixed
		# width isn't enough).
		var max_climb: float = maxf(0.0, max_local_top * scale_jitter - CLIFF_DRESSING_EMBED_DEPTH * scale_jitter)
		var slope_distance := max_climb / CLIFF_DRESSING_RAISE_MAX_SLOPE

		var ramp_distance := CLIFF_DRESSING_RAISE_RAMP_DISTANCE
		var plateau_depth := CLIFF_DRESSING_RAISE_PLATEAU_DEPTH
		var fade_distance := maxf(CLIFF_DRESSING_RAISE_FADE_DISTANCE, slope_distance)
		# 2026-09-18 round 1: this used to widen SIDEWAYS by the same slope_distance as the
		# behind-the-mesh fade above -- confirmed via a temporary bright-magenta debug material
		# that tall models (mountainside, height 10.52, scale up to 1.2x) were burying whole
		# NEIGHBORING placements under raised terrain: max_climb/CLIFF_DRESSING_RAISE_MAX_SLOPE
		# (0.6) can reach ~18 units, but CLIFF_DRESSING_SPACING between two placements along the
		# same fault is only 6 -- so the lateral falloff routinely reached 3x past the
		# neighboring placement's own footprint and overwrote its visible front face with THIS
		# model's raised plateau height. Pinning it to a fixed constant stopped that, but it
		# also flattened the deliberate slope for tall models into a hard box edge (round 2,
		# "mountain face is just a cube") -- the plateau height right at the mesh's own edge is
		# still most of a tall model's climb, so a few units to fall back to natural ground is
		# far steeper than CLIFF_DRESSING_RAISE_MAX_SLOPE. Round 3 ("still too steep, should be
		# a very gentle mound"): a single fixed cap safe for the tightest legal spacing punishes
		# every isolated placement too, so look up the ACTUAL nearest neighbor's footprint
		# (precomputed above) instead of assuming the worst case every time.
		# 2026-09-18 round 4 ("only works on the right side, left is still a steep wall"): round 3
		# computed ONE lateral_softness per placement from the profile's single worst-case
		# max_climb -- but a mesh like mountainside isn't symmetric, its real top profile climbs
		# to a different height at its left edge than its right edge. Giving both sides the same
		# blend width means the side whose real edge sits higher above the flattened low shelf
		# falls back to natural ground over the same distance as the lower side, so it reads far
		# steeper. Sample each side's real edge height separately and give each its own softness
		# (and its own neighbor budget -- a placement can have a close neighbor on only one side).
		# 2026-09-18 round 17 -- see CLIFF_DRESSING_FLANK_BAND_FRACTION's own comment.
		var flank_top_left := _cliff_profile_flank_height(top_profile, true)
		var flank_top_right := _cliff_profile_flank_height(top_profile, false)
		var edge_top_left := _sample_cliff_top_profile_flanked(top_profile, -half_x / scale_jitter, flank_top_left, flank_top_right)
		var edge_top_right := _sample_cliff_top_profile_flanked(top_profile, half_x / scale_jitter, flank_top_left, flank_top_right)
		# 2026-09-18 round 9 ("why does one side produce a gentle slope and the other does not",
		# on a placement with NO neighbors at all): climb here used to be measured against the
		# mesh's own embedded base (origin_y), as "how far this edge's real height sits above
		# CLIFF_DRESSING_EMBED_DEPTH" -- but that's only a fair proxy for "how much height needs
		# to blend away" when the low-side foot sample happens to match the natural terrain right
		# beside the mesh. It doesn't on uneven ground, and namaqualand_cliff_01's own left edge
		# profile height (1.46) sits BELOW CLIFF_DRESSING_EMBED_DEPTH (1.5) for every scale, so
		# that side always computed climb=0 and fell back to the 4.0 floor width regardless of
		# the REAL gap to natural terrain -- exactly a wall when that real gap happened to be
		# large. Sample the actual (already flatten-adjusted) heightmap just past each edge, the
		# same way the round-5 flatten fix does, and measure the real gap to THAT instead.
		var plateau_edge_left: float = origin_y + edge_top_left * scale_jitter
		var plateau_edge_right: float = origin_y + edge_top_right * scale_jitter
		# 2026-09-18 round 10 ("left side is wall, right is slope", no neighbors): a probe only 1.0
		# unit past half_x still sits inside _flatten_terrain_for_cliff_dressing's own dynamic
		# softness zone (up to CLIFF_DRESSING_FLATTEN_SOFTNESS_MAX = 10.0), so it just re-reads the
		# flatten pass's own forced-low target height back -- mathematically identical to the old
		# broken embed-depth-relative formula. Probe well past that zone so we sample genuinely
		# undisturbed natural terrain instead.
		var natural_probe_dist := CLIFF_DRESSING_FLATTEN_SOFTNESS_MAX + 5.0
		var probe_left_world: Vector2 = Vector2(px, pz) + (-(half_x + natural_probe_dist)) * axis_local_x
		var probe_right_world: Vector2 = Vector2(px, pz) + (half_x + natural_probe_dist) * axis_local_x
		var probe_left_qx := clampi(int(round(probe_left_world.x)), 0, width - 1)
		var probe_left_qz := clampi(int(round(probe_left_world.y)), 0, length - 1)
		var probe_right_qx := clampi(int(round(probe_right_world.x)), 0, width - 1)
		var probe_right_qz := clampi(int(round(probe_right_world.y)), 0, length - 1)
		var natural_left: float = heights[probe_left_qz * width + probe_left_qx]
		var natural_right: float = heights[probe_right_qz * width + probe_right_qx]
		var climb_left: float = maxf(0.0, plateau_edge_left - natural_left)
		var climb_right: float = maxf(0.0, plateau_edge_right - natural_right)
		var slope_distance_left := climb_left / CLIFF_DRESSING_RAISE_MAX_SLOPE
		var slope_distance_right := climb_right / CLIFF_DRESSING_RAISE_MAX_SLOPE

		var nearest_gap_left := INF
		var nearest_gap_right := INF
		# 2026-09-18 round 15b ("that didn't do anything" -- widening the join seam by THIS
		# mesh's own slope_distance_left/right had no effect because slope_distance is derived
		# from climb_left/right, which is measured against a NATURAL-ground probe -- meaningless
		# for a genuinely joined pair, where the round-7 comment itself says "there's no natural
		# ground left in the gap to blend down TO any more, just two plateau heights meeting".
		# For mountainside/namaqualand_cliff_01, climb_left came back 0.00 (see the round11 log),
		# so the round-15 widening silently no-opped. Sample the NEIGHBOR's own real top profile
		# at its near edge instead, so the seam can be sized off the actual height difference
		# between the two plateaus meeting there, not a proxy that doesn't apply to this case.
		var join_edge_height_left := NAN
		var join_edge_height_right := NAN
		for j in range(plan.size()):
			if j == entry_index:
				continue
			var other = plan[j]
			var delta_other := Vector2(other.px - px, other.pz - pz)
			var other_local_x := delta_other.dot(axis_local_x)
			var other_local_z := delta_other.dot(axis_local_z)
			# Only a neighbor close enough along this mesh's own front-back axis for a sideways
			# raise to ever reach its footprint at all can constrain us -- one on a different
			# fault line entirely, far in front or behind, doesn't limit this mound.
			var z_clearance := absf(other_local_z) - half_z - all_half_z[j]
			if z_clearance > 0.0:
				continue
			var gap := absf(other_local_x) - half_x - all_half_x[j]
			if other_local_x < 0.0:
				if gap < nearest_gap_left:
					nearest_gap_left = gap
					# Neighbor sits to our left, so (assuming the same near-parallel fault-line
					# orientation round 7 already assumes) we're on ITS right -- sample its own
					# profile at its right edge.
					join_edge_height_left = _sample_neighbor_facing_plateau_height(other, all_half_x[j], true, top_profiles, defs_by_name)
			else:
				if gap < nearest_gap_right:
					nearest_gap_right = gap
					join_edge_height_right = _sample_neighbor_facing_plateau_height(other, all_half_x[j], false, top_profiles, defs_by_name)
		# Leave a 1-unit safety margin short of touching the neighbor's real footprint, and
		# never cap below the LATERAL_SOFTNESS floor even if placements sit right at the legal
		# minimum spacing. With no qualifying neighbor on that side at all, fall back to the
		# sanity-ceiling constant so an isolated tall mesh still gets a bounded (if generous)
		# mound rather than an unbounded one from a runaway slope_distance.
		# 2026-09-18 round 7 ("gap between adjacent cliffs"): a genuinely adjacent neighbor (gap
		# under the join threshold) gets bridged instead of faded to -- extend the full-height
		# plateau almost all the way across the real gap (effective_edge), leaving only a small
		# seam width to blend the last bit so the two plateaus don't meet at a hard vertex. A
		# neighbor beyond the threshold is treated as unrelated (a different fault happening to
		# share similar depth) and keeps the old fade-to-natural behavior.
		var effective_edge_left := half_x
		var lateral_softness_left: float
		if nearest_gap_left < CLIFF_DRESSING_RAISE_JOIN_THRESHOLD:
			# 2026-09-18 round 15 ("left side has a steep wall that starts from the top of the mesh,
			# and then 60-70% down the way a short, almost horizontal slope extends" -- mountainside,
			# joined to namaqualand_cliff_01 on this side): the fixed JOIN_SEAM_WIDTH (2.0) assumes
			# both joined plateaus sit at roughly the same height, so a narrow seam is enough to hide
			# the vertex where they meet. mountainside is much taller than namaqualand here, so
			# forcing that whole height difference to blend across a fixed 2 units reads as a near-
			# vertical wall, and the max-combination with namaqualand's OWN (also narrow) join
			# contribution shows through as a short flat shelf partway down. Widen the seam by this
			# mesh's own climb (slope_distance_left, already computed above) same as the non-join
			# branch below does, capped so it never eats past the real gap to the neighbor.
			var height_diff_left := absf(plateau_edge_left - join_edge_height_left) if not is_nan(join_edge_height_left) else slope_distance_left * CLIFF_DRESSING_RAISE_MAX_SLOPE
			var join_softness_left := clampf(maxf(CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, height_diff_left / CLIFF_DRESSING_RAISE_MAX_SLOPE), CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, maxf(CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, nearest_gap_left))
			effective_edge_left = half_x + maxf(0.0, nearest_gap_left - join_softness_left)
			lateral_softness_left = join_softness_left
		else:
			var lateral_cap_left := CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS_MAX
			if nearest_gap_left < INF:
				lateral_cap_left = maxf(CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS, nearest_gap_left - 1.0)
			# 2026-09-18 round 12 ("namaqualand 01 and mountainside still not behaving correctly",
			# confirmed against the live mountainside instance the player was standing next to --
			# climb_left=0.00, lateral_softness_left stuck at the 4.0 floor): a near-zero climb only
			# means natural terrain recovers to plateau height somewhere between the mesh edge and
			# natural_probe_dist (15 units) -- it says nothing about the ground in between, which the
			# flatten pass may have carved down within its own (up to 10-unit) softness zone. Flooring
			# the blend at a flat 4.0 left that carved-low ring exposed with nothing bridging it back
			# up to the real terrain -- exactly the "wall" symptom. Floor the blend at however far we
			# actually verified is undisturbed natural ground instead, unless a real neighbor sits
			# closer and should still win.
			var lateral_floor_left := minf(natural_probe_dist, lateral_cap_left)
			lateral_softness_left = clampf(maxf(lateral_floor_left, slope_distance_left), lateral_floor_left, lateral_cap_left)
		var effective_edge_right := half_x
		var lateral_softness_right: float
		if nearest_gap_right < CLIFF_DRESSING_RAISE_JOIN_THRESHOLD:
			# 2026-09-18 round 15 -- see join_softness_left's own comment above, mirrored for the
			# right side.
			var height_diff_right := absf(plateau_edge_right - join_edge_height_right) if not is_nan(join_edge_height_right) else slope_distance_right * CLIFF_DRESSING_RAISE_MAX_SLOPE
			var join_softness_right := clampf(maxf(CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, height_diff_right / CLIFF_DRESSING_RAISE_MAX_SLOPE), CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, maxf(CLIFF_DRESSING_RAISE_JOIN_SEAM_WIDTH, nearest_gap_right))
			effective_edge_right = half_x + maxf(0.0, nearest_gap_right - join_softness_right)
			lateral_softness_right = join_softness_right
		else:
			var lateral_cap_right := CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS_MAX
			if nearest_gap_right < INF:
				lateral_cap_right = maxf(CLIFF_DRESSING_RAISE_LATERAL_SOFTNESS, nearest_gap_right - 1.0)
			var lateral_floor_right := minf(natural_probe_dist, lateral_cap_right)
			lateral_softness_right = clampf(maxf(lateral_floor_right, slope_distance_right), lateral_floor_right, lateral_cap_right)
		# 2026-09-18 round 14 ("it's not a jumbled mess anymore, but there's still a gap between
		# two items" -- namaqualand_cliff_01 and mountainside, a genuinely JOIN-bridged pair):
		# the lateral (X) extension above already closes the sideways gap correctly, but the
		# front-face depth carve-out below (`d_behind <= -inner_ramp: continue`) is evaluated in
		# THIS entry's own rotated local-Z frame regardless of X position -- at the bridge point
		# roughly between the two mesh centers, both entries' own frames place it in their front
		# half, so both independently contribute zero depth there even though they're supposed to
		# be meeting in the middle. Round 13 tried fixing this by giving EVERY lateral pixel full
		# depth + a forward ramp, but that also applied to isolated meshes with no real neighbor
		# to bridge to, producing an unwanted forward-projecting apron (reverted per Kirill:
		# "that extends the existing terrain forward, not fix the terrain to the sides"). Scope it
		# down to ONLY the side that's actually join-bridging.
		var joined_left := nearest_gap_left < CLIFF_DRESSING_RAISE_JOIN_THRESHOLD
		var joined_right := nearest_gap_right < CLIFF_DRESSING_RAISE_JOIN_THRESHOLD
		var behind_reach := half_z + ramp_distance + plateau_depth + fade_distance
		var reach := behind_reach + maxf(effective_edge_left + lateral_softness_left, effective_edge_right + lateral_softness_right) # generous square bound -- exact shaping happens per-pixel below

		var min_px := clampi(int(floor(px - reach)), 0, width - 1)
		var max_px := clampi(int(ceil(px + reach)), 0, width - 1)
		var min_pz := clampi(int(floor(pz - reach)), 0, length - 1)
		var max_pz := clampi(int(ceil(pz + reach)), 0, length - 1)

		# The ramp (2026-09-17 gap fix) now climbs INSIDE the back half of the mesh's own
		# footprint instead of outside it. Originally the ramp started at weight 0 right at
		# the footprint's back edge and only reached full plateau height ramp_distance units
		# further out -- so the ground for that whole stretch sat near the flattened low
		# height while the mesh's own tall geometry was already right there, reading as a
		# visible gap between the mesh and the raised ground behind it. Capping the ramp to
		# half_z keeps it from eating into the front (visible-face) half of the footprint.
		var inner_ramp := minf(ramp_distance, half_z)

		for qz in range(min_pz, max_pz + 1):
			for qx in range(min_px, max_px + 1):
				var delta := Vector2(qx - px, qz - pz)
				var local_x := delta.dot(axis_local_x)
				var local_z := delta.dot(axis_local_z)
				# 0 right at the back edge of the mesh's own footprint, negative = inside the
				# footprint (towards its back half), positive = truly behind the mesh.
				var d_behind := -local_z - half_z
				# round 20: per-pixel distance warps (world-grid sampled, so overlapping placements
				# see the same noise and still combine cleanly). Offset second sample decorrelates them.
				var fade_warp := 1.0 + CLIFF_DRESSING_RAISE_EDGE_WARP * raise_warp_noise.get_noise_2d(qx, qz)
				var lateral_warp := 1.0 + CLIFF_DRESSING_RAISE_EDGE_WARP * raise_warp_noise.get_noise_2d(qx + 5000.0, qz - 5000.0)

				# 2026-09-18 round 14 -- see joined_left/joined_right's own comment above. A pixel
				# laterally within the mesh's own footprint width keeps the original front-face-gated
				# behavior untouched (isolated flanks still fall back to natural ground exactly as
				# before). A pixel outside that width, on a side that's genuinely join-bridging to a
				# close neighbor, instead gets full depth coverage across the mesh's own depth plus a
				# short forward ramp -- so the two neighboring mounds actually meet at the seam instead
				# of both fading to zero there.
				var side_joined := joined_left if local_x < 0.0 else joined_right
				# 2026-09-18 round 22: the trench scan (round 21) found 4-6 unit V-trenches on every
				# joined side, just INSIDE the mesh's width at mid-depth -- this used to hard-switch
				# at |local_x| == half_x from the front-gated weight (~0 at mid-depth) to the join
				# weight (1.0). Now both are computed and blended over the last
				# CLIFF_DRESSING_RAISE_JOIN_BLEND units inside the edge; outside the mesh's width it's
				# exactly the join weight as before, and non-joined sides are unchanged.
				var w_gated := 0.0
				if d_behind > -inner_ramp:
					if d_behind <= 0.0:
						w_gated = smoothstep(-inner_ramp, 0.0, d_behind)
					elif d_behind <= plateau_depth:
						w_gated = 1.0
					else:
						w_gated = 1.0 - smoothstep(0.0, fade_distance, (d_behind - plateau_depth) * fade_warp)
				var depth_weight := w_gated
				if side_joined:
					var depth_weight_gated := w_gated
					depth_weight = 0.0
					# 2026-09-18 round 18 ("while filling the gap the debug surface 'spills' forward
					# as well"): round 14 gave join-gap pixels full height right up to the front-face
					# line and then a further ramp_distance-long ramp PAST it, which read as a plane
					# sticking out in front of the two meshes. Keep full height over the back half of
					# the gap only, fade out across the front half, and stop exactly at the front-face
					# line -- nothing past it.
					if local_z >= half_z:
						depth_weight = 0.0
					elif d_behind > plateau_depth:
						depth_weight = 1.0 - smoothstep(0.0, fade_distance, (d_behind - plateau_depth) * fade_warp)
					elif local_z <= 0.0:
						depth_weight = 1.0
					else:
						depth_weight = 1.0 - smoothstep(0.0, half_z, local_z)
					# round 22 blend -- 0 = front-gated weight, 1 = join weight (reached AT the edge).
					var join_t := smoothstep(half_x - CLIFF_DRESSING_RAISE_JOIN_BLEND, half_x, absf(local_x))
					depth_weight = lerpf(depth_weight_gated, depth_weight, join_t)
				if depth_weight <= 0.0:
					continue

				var side_effective_edge := effective_edge_left if local_x < 0.0 else effective_edge_right
				var side_lateral_softness := lateral_softness_left if local_x < 0.0 else lateral_softness_right
				var lateral_outside := maxf(0.0, absf(local_x) - side_effective_edge) * lateral_warp # round 20
				var lateral_weight := 1.0 - smoothstep(0.0, side_lateral_softness, lateral_outside)
				if lateral_weight <= 0.0:
					continue

				# Undo the uniform scale_jitter to get back into the model's own unscaled local
				# space (the same space _compute_cliff_dressing_top_profile sampled), look up
				# the real top height at this X slice, then rescale back into world units.
				var mesh_local_x := local_x / scale_jitter
				var top_local_y := _sample_cliff_top_profile_flanked(top_profile, mesh_local_x, flank_top_left, flank_top_right) # round 17
				# + TOP_LIFT: deliberate overlap so ground and rock don't meet at a knife-edge --
				# see CLIFF_DRESSING_RAISE_TOP_LIFT's own comment for why and how to tune it.
				var plateau_height := origin_y + top_local_y * scale_jitter + CLIFF_DRESSING_RAISE_TOP_LIFT

				var idx := qz * width + qx
				# 2026-09-18 debug (Kirill: "comment temporarily the script generating the terrain,
				# instead of that, generate yellow debug boxes, with the same logic"): same exact
				# weight/height computation as before, just recorded for visualization instead of
				# written into the real heightmap, so we can see the shape of this logic's effect
				# without another guess-and-regenerate round trip. Restore the commented line and
				# delete the debug recording once the shape is confirmed correct.
				var raise_w := depth_weight * lateral_weight
				var blended_height := lerpf(heights[idx], plateau_height, raise_w)
				# round 20: mid-slope bumps -- zero at w=0 (natural ground) and w=1 (plateau).
				var bump_amp := minf(CLIFF_DRESSING_RAISE_BUMP_MAX, absf(plateau_height - heights[idx]) * CLIFF_DRESSING_RAISE_BUMP_FRACTION)
				blended_height += raise_bump_noise.get_noise_2d(qx, qz) * bump_amp * 4.0 * raise_w * (1.0 - raise_w)
				# heights[idx] = blended_height
				# 2026-09-18 debug hypothesis test (Kirill, standing between mountainside and
				# namaqualand_cliff_01: "ideally it would have to be following the pink line,
				# instead of how it is now" -- the yellow surface showed jagged, disconnected,
				# overlapping facets instead of one smooth ridge): each plan entry is processed as
				# its own independent pass over the SAME shared heights/heights-debug array, and a
				# pixel where two nearby placements' reach overlaps (exactly the region between two
				# neighbors the JOIN logic above is meant to bridge) previously just got
				# unconditionally overwritten by whichever entry happened to run LAST in the plan
				# array -- an arbitrary seam at that boundary, with each side's own independently-
				# sampled top-profile height, not one shared ridge. Taking the max of what's already
				# there instead makes overlapping placements combine by "tallest wins" rather than
				# "processed-last wins", which should read as one continuous mound between them
				# instead of a jagged patchwork. Testing this via the debug surface before touching
				# real terrain.
				if _raise_debug_heights[idx] <= RAISE_DEBUG_UNSET + 1.0 or blended_height > _raise_debug_heights[idx]:
					_raise_debug_heights[idx] = blended_height
					_raise_debug_entry_index[idx] = entry_index

	# 2026-09-18 round 19 (Kirill: "ok, looks good, let's make the debug panels into terrain
	# now"): commit the previewed surface into the real heightmap. Applied once, AFTER every
	# entry has been accumulated, so the result is exactly the approved preview -- writing inside
	# the loop instead would make later entries blend from terrain earlier entries had already
	# raised, which isn't what the preview showed.
	for i in range(_raise_debug_heights.size()):
		if _raise_debug_heights[i] > RAISE_DEBUG_UNSET + 1.0:
			heights[i] = _raise_debug_heights[i]

## Instances one or more of the 5 large cliff-face meshes (CLIFF_DRESSING_DEFS) from a plan
## already computed by _plan_cliff_dressing (inside _build_heightmap, before Terrain3D import
## -- see that function's comment for why placement decisions live there now). This function
## does the mesh-instancing side only: loading scenes/materials, positioning/rotating/scaling
## each planned instance, applying collision, and spawning the same debug markers as before.
func _dress_cliff_faces(plan: Array[Dictionary], import_position: Vector3, data: Terrain3DData, top_profiles: Dictionary) -> void:
	# 2026-09-21 startup-time probe: splits this function's total into asset loading vs.
	# per-placement instancing vs. trimesh collision building.
	var t_dress_start := Time.get_ticks_msec()
	var parent := get_parent()
	var old_container := parent.get_node_or_null(CLIFF_DRESSING_NODE_NAME)
	if old_container:
		old_container.queue_free()
	var container := Node3D.new()
	container.name = CLIFF_DRESSING_NODE_NAME
	# Deferred for the same reason as BoulderColliders/RoadMesh -- this runs while the scene
	# tree is still propagating NOTIFICATION_READY to Main's other children.
	parent.add_child.call_deferred(container)

	# One shared material per model (StandardMaterial3D from its own diff/nor_gl/rough source
	# textures), built once and reused across every placed instance of that model -- same idea
	# as setup_rock_assets.gd's per-rock material, just built at runtime instead of saved as a
	# .tres, since these aren't registered as Terrain3DMeshAssets/scattered via the instancer.
	var materials: Dictionary = {}
	var scenes: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		var scene: PackedScene = load(def.glb)
		if not scene:
			push_warning("TERRAIN_GEN: could not load cliff dressing mesh %s -- skipping this model" % def.glb)
			continue
		scenes[def.name] = scene
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = load(def.diff)
		mat.normal_enabled = true
		mat.normal_texture = load(def.nor)
		mat.roughness_texture = load(def.rough)
		# Double-sided: these Poly Haven cliff scans are thin, one-sided displacement
		# shells, not closed volumes -- with the default CULL_BACK, viewing one from
		# behind or through a gap in the shell rendered nothing (sky/terrain showing
		# through). This doesn't fix a wrong facing guess or an undersized fault -- it
		# only stops the see-through gaps.
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		materials[def.name] = mat

	if scenes.is_empty():
		push_warning("TERRAIN_GEN: no cliff dressing meshes loaded -- skipping cliff face dressing entirely")
		return
	print("TERRAIN_GEN_STARTUP:   cliff dressing GLB+texture load (%.3fs)" % ((Time.get_ticks_msec() - t_dress_start) / 1000.0))
	var t_instancing_ms := 0
	var t_collision_ms := 0

	# NOTE (2026-09-17): three attempts at patching the cliff face mesh itself all produced a
	# visible box (full-AABB backing box; a per-piece-pair box; a thin frame around the whole
	# silhouette's edges). Per user feedback, this was the wrong side of the problem entirely --
	# the visible gap is between the mesh and the TERRAIN it sits on, not a hole inside the mesh
	# geometry, so it should be fixed by raising terrain to meet the mesh, not by adding more
	# mesh. See _raise_terrain_behind_cliff_dressing / _flatten_terrain_for_cliff_dressing in
	# _build_heightmap for the terrain-side fix. Nothing here touches the mesh anymore.

	var defs_by_name: Dictionary = {}
	# Debug-only: spawn a parallelepiped behind each placed cliff face, sized to that
	# model's own real width/height/depth (CLIFF_DRESSING_DEFS) and offset opposite the
	# mesh's own facing direction -- a cheap, ground-truth visual marker for both where
	# this generator THINKS the fault's high/back side is AND how much space the actual
	# mesh needs. One box mesh built per model (not per instance) since every instance of
	# the same model shares real dimensions; each spawned instance still gets its own
	# scale/rotation to match its own placement.
	for def in CLIFF_DRESSING_DEFS:
		defs_by_name[def.name] = def

	# 2026-09-18: removed the magenta DebugCube (debug_box_meshes/debug_cube_material) --
	# Kirill: "can we remove the magenta boxes, not needed anymore". It was a per-model
	# bounding-box marker placed behind each cliff face for comparing against the real mesh's
	# visible height. 2026-09-20: the green EdgeFrame debug outline and the blue base-gap
	# fill (terrain lift + remaining-gap count) were removed too -- base gaps are now fixed
	# in the meshes themselves (e.g. namaqualand_cliff_02_FILL).

	# Debug-only: rotation-agnostic ground truth for face_dir -- two small, solid,
	# unshaded spheres (a sphere looks identical from every angle, so unlike the rotated
	# debug box or the real mesh, there's no ambiguity about which local axis is "front")
	# marking the exact start and end of the face_dir vector this generator computed for
	# each placement. GREEN = the mesh's own position. RED = 6 units further in face_dir,
	# i.e. where the generator THINKS the low/open side is.
	# 2026-09-18: removed the green/red FaceDirStart/FaceDirEnd debug spheres (Kirill: "can we
	# remove the green and red debug dots on in front/back of cliff mesh?") -- they marked each
	# placement's mesh-root position (green) and a point 6 units along its face_dir (red), used
	# earlier to sanity-check face_dir orientation. No longer needed.
	var placed_count := 0
	var collider_count := 0
	for entry in plan:
		var def_name: String = entry.def_name
		if not scenes.has(def_name):
			continue
		var chosen = defs_by_name[def_name]
		var px: float = entry.px
		var pz: float = entry.pz
		var face_angle: float = entry.face_angle
		var scale_jitter: float = entry.scale_jitter
		var face_dir_x: float = entry.face_dir_x
		var face_dir_z: float = entry.face_dir_z
		var height: float = entry.height

		var t_inst := Time.get_ticks_msec()
		var scene: PackedScene = scenes[def_name]
		var instance := scene.instantiate()
		var mesh_root := instance as Node3D
		if mesh_root == null:
			push_warning("TERRAIN_GEN: cliff dressing scene %s has no Node3D root -- skipping this instance" % chosen.glb)
			instance.free()
		else:
			mesh_root.scale = Vector3.ONE * scale_jitter
			mesh_root.rotation = Vector3(0.0, face_angle, 0.0)
			mesh_root.position = Vector3(import_position.x + px, height - CLIFF_DRESSING_EMBED_DEPTH * scale_jitter, import_position.z + pz)
			container.add_child.call_deferred(mesh_root)
			_apply_cliff_material_recursive(mesh_root, materials[def_name])
			_apply_cliff_lod_ranges(mesh_root)
			var t_col := Time.get_ticks_msec()
			t_instancing_ms += t_col - t_inst
			if not DEBUG_SKIP_CLIFF_COLLISION:
				collider_count += _add_cliff_collision_recursive(mesh_root)
			t_collision_ms += Time.get_ticks_msec() - t_col
			placed_count += 1

	print("TERRAIN_GEN: dressed %d cliff-face mesh(es) (%d collision shape(s)) from %d planned placement(s)" % [placed_count, collider_count, plan.size()])
	print("TERRAIN_GEN_STARTUP:   cliff instancing+materials (%.3fs), trimesh collision (%.3fs, %d unique shape(s): %d loaded from disk cache, %d freshly baked)" % [t_instancing_ms / 1000.0, t_collision_ms / 1000.0, _cliff_trimesh_cache.size(), _cliff_trimesh_disk_hits, _cliff_trimesh_disk_bakes])

## Recursively applies `mat` as the material_override on every MeshInstance3D under `node`
## -- the cliff GLBs were exported with export_materials="NONE" (see
## export_cliffs_to_glb.ps1, matching the existing rock/boulder prop pipeline), so they have
## no material of their own and would otherwise render pink/unshaded.
func _apply_cliff_material_recursive(node: Node, mat: Material) -> void:
	if node is MeshInstance3D:
		var use_mat: Material = mat
		# Hand-built repair surfaces authored in the raw .blend -- _FILL (the base skirt),
		# _PATCH (top-edge gaps, 2026-09-20) and _PATCH2 (cliff_01's second top gap, 2026-09-21).
		# Each has its own UV layout and a baked <model>_<kind>_diff.png, so the rock's atlas
		# material would be scrambled on them -- swap in a derived material pointing at that bake.
		# "patch2" is listed before "patch" purely defensively: ends_with("_PATCH") is already
		# false for "_PATCH2", so the two never collide, but the longer suffix leading keeps it
		# obvious that adding a "_PATCH10" later would need the same care.
		var node_name := String(node.name)
		for kind in ["fill", "patch2", "patch"]:
			if node_name.ends_with("_" + kind.to_upper()):
				var repair_mat := _get_cliff_repair_material(mat, kind)
				if repair_mat:
					use_mat = repair_mat
				break
		(node as MeshInstance3D).material_override = use_mat
	for child in node.get_children():
		_apply_cliff_material_recursive(child, mat)

var _cliff_repair_material_cache: Dictionary = {}

## Builds (once per rock material + kind) a copy of the rock material whose albedo is the
## baked repair texture sitting next to the rock's diffuse ("..._diff_2k.jpg" ->
## "..._<kind>_diff.png", kind = "fill" or "patch"). Normal/roughness maps are dropped because
## they're laid out for the rock's UV atlas, not the repair surface's. Returns null (caller
## keeps the rock material) if that bake doesn't exist.
func _get_cliff_repair_material(mat: Material, kind: String) -> Material:
	var cache_key := "%s|%s" % [mat.get_instance_id(), kind]
	if _cliff_repair_material_cache.has(cache_key):
		return _cliff_repair_material_cache[cache_key]
	var result: Material = null
	var base := mat as StandardMaterial3D
	if base and base.albedo_texture:
		var tex_path := base.albedo_texture.resource_path.replace("_diff_2k.jpg", "_%s_diff.png" % kind)
		if tex_path != base.albedo_texture.resource_path and ResourceLoader.exists(tex_path):
			var repair := base.duplicate() as StandardMaterial3D
			repair.albedo_texture = load(tex_path)
			repair.normal_enabled = false
			repair.normal_texture = null
			repair.roughness_texture = null
			repair.roughness = 0.9
			result = repair
			print("TERRAIN_GEN: cliff %s material built from %s" % [kind, tex_path])
		else:
			push_warning("TERRAIN_GEN: _%s mesh found but no texture at %s -- using rock material" % [kind.to_upper(), tex_path])
	_cliff_repair_material_cache[cache_key] = result
	return result

## Recursively adds a StaticBody3D+CollisionShape3D (concave trimesh, not the convex hulls
## _scatter_boulders uses for its small rounded rocks) as a CHILD of every MeshInstance3D
## found under `node`. Trimesh instead of convex: these are large static cliff faces, often
## with overhangs/concavities a convex hull would flatten out into a blocky wrong shape --
## unlike a small boulder, an inaccurate hull here would be walked-into/climbed-on
## noticeably. Being a child of the SAME MeshInstance3D its shape is built from means the
## collider automatically inherits that node's part of the transform stack (and, through it,
## the placed instance's own scale/rotation/position set in _dress_cliff_faces) with no
## manual transform math needed here. Returns how many collision shapes were added, so the
## caller can report a real total instead of assuming one collider per model (mountainside,
## for example, is 5 separate MeshInstance3D nodes).
## 2026-09-21 startup-time fix: one trimesh shape per unique Mesh resource. Every placed
## instance of the same GLB shares the same Mesh resources, and the shape is built in the
## mesh's own local space (each instance's scale/rotation/position comes from the parent
## MeshInstance3D's transform, not the shape), so building it once and reusing it is
## identical in behavior -- it just skips rebuilding the same high-poly scan's collision
## for every placement (previously 132 builds from ~12 unique meshes).
var _cliff_trimesh_cache: Dictionary = {}

## 2026-09-21 startup-time fix, step 2: persist each unique trimesh to user:// so later
## runs load it instead of rebuilding it. Keyed by the mesh's source file path (the GLB it
## was imported from) plus that file's modification time -- re-exporting a cliff GLB
## changes the mtime, so its shapes are automatically rebaked on the next run and
## collision can never silently drift from the visible mesh. Meshes with no resource_path
## fall back to a plain in-memory build.
const CLIFF_TRIMESH_DISK_CACHE_DIR := "user://cliff_collision_cache"
## 2026-09-21 TEMPORARY A/B test: true = skip creating cliff-face collision entirely, to measure
## how much of the first-frame stall is physics setup vs shader compilation. Cliffs become
## walk-through while this is on. Set back to false (or delete) after the comparison run.
const DEBUG_SKIP_CLIFF_COLLISION := false

## 2026-09-21 startup-time fix, step 3: cliff collision is built from a SIMPLIFIED copy of each
## scan mesh instead of every original triangle -- the A/B test showed full-detail cliff
## collision cost ~0.5s of physics setup on the first frame. Visuals are untouched (only the
## invisible collision is simplified). Uses Godot's own LOD simplifier (ImporterMesh.generate_lods)
## and keeps the coarsest LOD that still retains at least this fraction of the original
## triangles. Raise it if the player visibly floats above / sinks into rock; lower it for speed.
const CLIFF_COLLISION_TARGET_RATIO := 0.25
## Bump whenever the bake logic or the ratio above changes, so cached shapes on disk from the
## previous logic are ignored and rebaked instead of silently reused.
const CLIFF_COLLISION_BAKE_VERSION := 3

## 2026-09-21 startup-time fix, step 4: the cliff GLBs ship their own LOD chain as sibling
## MeshInstance3Ds (<name>_LOD0.._LOD3, each ~half the triangles of the previous). Collision
## used to be built for EVERY one of them -- four near-identical, slightly different rock
## surfaces stacked in the same spot, which both multiplied physics cost and snagged the
## player between disagreeing layers (the STUCK logs hitting _LOD1/_LOD2/_LOD3 colliders).
## Now only ONE level per LOD group gets a collider: this one, or the nearest available level
## below it if a model has fewer. Non-LOD pieces (_FILL/_PATCH repair surfaces etc.) are
## unaffected. Raise toward 0 for more accurate collision, higher for cheaper.
const CLIFF_COLLISION_LOD := 2

## Returns n for a node named "<anything>_LOD<n>", or -1 if it isn't part of an LOD chain.
func _cliff_lod_index(node_name: String) -> int:
	var at := node_name.rfind("_LOD")
	if at < 0:
		return -1
	var digits := node_name.substr(at + 4)
	return digits.to_int() if digits.is_valid_int() else -1

## True if this MeshInstance3D should get a collider: always for non-LOD pieces; for an LOD
## chain, only for the single chosen level among its same-named siblings.
func _should_add_cliff_collision(node: Node) -> bool:
	var name_str := String(node.name)
	var lod := _cliff_lod_index(name_str)
	if lod < 0 or node.get_parent() == null:
		return true
	var base := name_str.substr(0, name_str.rfind("_LOD"))
	var chosen := -1
	var lowest := 1 << 30
	for sibling in node.get_parent().get_children():
		var s_name := String(sibling.name)
		var s_lod := _cliff_lod_index(s_name)
		if s_lod < 0 or not (sibling is MeshInstance3D) or s_name.substr(0, s_name.rfind("_LOD")) != base:
			continue
		lowest = mini(lowest, s_lod)
		if s_lod <= CLIFF_COLLISION_LOD and s_lod > chosen:
			chosen = s_lod
	if chosen < 0:
		chosen = lowest
	return lod == chosen

func _build_simplified_cliff_trimesh(mesh: Mesh) -> ConcavePolygonShape3D:
	var im := ImporterMesh.from_mesh(mesh)
	if im == null:
		return null
	im.generate_lods(25.0, 60.0, [])
	var faces := PackedVector3Array()
	var tris_before := 0
	var tris_after := 0
	for s in im.get_surface_count():
		if im.get_surface_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := im.get_surface_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base_idx := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			base_idx = arrays[Mesh.ARRAY_INDEX]
		if base_idx.is_empty():
			base_idx.resize(verts.size())
			for i in verts.size():
				base_idx[i] = i
		# Coarsest LOD that still keeps >= TARGET_RATIO of this surface's triangles; if the
		# simplifier produced nothing coarse enough-but-not-too-coarse, keep full detail.
		var min_indices := int(base_idx.size() * CLIFF_COLLISION_TARGET_RATIO)
		var chosen := base_idx
		for l in im.get_surface_lod_count(s):
			var lod_idx := im.get_surface_lod_indices(s, l)
			if lod_idx.size() >= 3 and lod_idx.size() >= min_indices and lod_idx.size() < chosen.size():
				chosen = lod_idx
		tris_before += base_idx.size() / 3
		tris_after += chosen.size() / 3
		for i in chosen:
			faces.append(verts[i])
	if faces.is_empty():
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	print("TERRAIN_GEN_STARTUP_DEBUG simplified cliff collision -- %s: %d -> %d triangles (%.0f%%)" % [mesh.resource_path, tris_before, tris_after, 100.0 * tris_after / maxf(1.0, tris_before)])
	return shape
var _cliff_trimesh_disk_hits := 0
var _cliff_trimesh_disk_bakes := 0

func _load_or_bake_cliff_trimesh(mesh: Mesh, simplify: bool = true) -> Shape3D:
	var res_path := mesh.resource_path
	if res_path.is_empty():
		return mesh.create_trimesh_shape()
	var source_file := res_path.get_slice("::", 0)
	var mtime := FileAccess.get_modified_time(source_file)
	var cache_file := "%s/%s_%d_v%d.res" % [CLIFF_TRIMESH_DISK_CACHE_DIR, res_path.md5_text(), mtime, CLIFF_COLLISION_BAKE_VERSION]
	if ResourceLoader.exists(cache_file):
		var cached := ResourceLoader.load(cache_file, "", ResourceLoader.CACHE_MODE_IGNORE) as Shape3D
		if cached:
			_cliff_trimesh_disk_hits += 1
			return cached
	var shape: Shape3D = _build_simplified_cliff_trimesh(mesh) if simplify else null
	if shape == null:
		shape = mesh.create_trimesh_shape()
	if shape:
		# Diagnostic (keep until Kirill confirms the disk cache hits on repeat runs): why did
		# this key miss? Compare these values across two consecutive runs.
		print("TERRAIN_GEN_STARTUP_DEBUG trimesh bake -- res_path=%s source_file=%s mtime=%d cache_file=%s existed=%s" % [res_path, source_file, mtime, cache_file, str(ResourceLoader.exists(cache_file))])
		DirAccess.make_dir_recursive_absolute(CLIFF_TRIMESH_DISK_CACHE_DIR)
		var err := ResourceSaver.save(shape, cache_file)
		if err != OK:
			push_warning("TERRAIN_GEN: could not save baked cliff collision to %s (error %d) -- will rebuild next run" % [cache_file, err])
		_cliff_trimesh_disk_bakes += 1
	return shape

func _add_cliff_collision_recursive(node: Node) -> int:
	var added := 0
	if node is MeshInstance3D and _should_add_cliff_collision(node):
		var mesh_inst: MeshInstance3D = node
		if mesh_inst.mesh:
			var shape: Shape3D = _cliff_trimesh_cache.get(mesh_inst.mesh)
			if shape == null:
				# An artist-made LOD is already low-poly -- use it as-is; only non-LOD pieces
				# (full scans, _FILL/_PATCH repair surfaces) go through the runtime simplifier.
				shape = _load_or_bake_cliff_trimesh(mesh_inst.mesh, _cliff_lod_index(String(node.name)) < 0)
				if shape:
					_cliff_trimesh_cache[mesh_inst.mesh] = shape
			if shape:
				var body := StaticBody3D.new()
				body.name = "Collision"
				var col := CollisionShape3D.new()
				col.name = "CollisionShape3D"
				col.shape = shape
				body.add_child(col)
				mesh_inst.add_child(body)
				added += 1
			else:
				push_warning("TERRAIN_GEN: could not build a trimesh collision shape from cliff dressing mesh instance %s -- it will render but have no collision" % mesh_inst.name)
	for child in node.get_children():
		added += _add_cliff_collision_recursive(child)
	return added

## 2026-09-24 GPU fix: the cliff/outcrop GLBs ship their LOD chain as sibling MeshInstance3Ds
## (<n>_LOD0.._LOD3) and nothing switched between them -- every placed cliff drew ALL levels
## on top of each other (cliff_02: ~364k tris instead of 194k near / 24k far, shadows too).
## Each LOD node now gets a distance band via visibility ranges so exactly one draws.
## CLIFF_LOD_END[n] = where LOD n hands over to LOD n+1; a model's coarsest available
## level always extends to infinity. No fade (fading forces the transparent pipeline);
## the margin is hysteresis only. Collision (on one LOD, see _should_add_cliff_collision)
## is unaffected -- visibility ranges don't touch physics.
const CLIFF_LOD_END: Array[float] = [40.0, 90.0, 180.0]
const CLIFF_LOD_MARGIN := 4.0

func _apply_cliff_lod_ranges(node: Node) -> int:
	var set_count := 0
	if node is MeshInstance3D:
		var lod := _cliff_lod_index(String(node.name))
		if lod >= 0 and node.get_parent() != null:
			var base := String(node.name).substr(0, String(node.name).rfind("_LOD"))
			var last := lod
			for sibling in node.get_parent().get_children():
				var s_name := String(sibling.name)
				var s_lod := _cliff_lod_index(s_name)
				if s_lod >= 0 and sibling is MeshInstance3D and s_name.substr(0, s_name.rfind("_LOD")) == base:
					last = maxi(last, s_lod)
			var gi := node as GeometryInstance3D
			gi.visibility_range_begin = 0.0 if lod == 0 else CLIFF_LOD_END[mini(lod, CLIFF_LOD_END.size()) - 1]
			gi.visibility_range_end = 0.0 if (lod >= last or lod >= CLIFF_LOD_END.size()) else CLIFF_LOD_END[lod]
			gi.visibility_range_begin_margin = CLIFF_LOD_MARGIN if lod > 0 else 0.0
			gi.visibility_range_end_margin = CLIFF_LOD_MARGIN if gi.visibility_range_end > 0.0 else 0.0
			gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			set_count += 1
	for child in node.get_children():
		set_count += _apply_cliff_lod_ranges(child)
	return set_count

## Returns {height, wall_t} for a given heightmap-pixel X position -- the
## valley's cross-section only depends on X, since its axis runs straight
## along Z (see the VALLEY_* consts' comment above). `height` is the macro
## valley elevation at this X, BEFORE any noise is added. `wall_t` is 0.0
## anywhere on the flat floor and smoothly ramps to 1.0 at the rim; callers
## use it to damp down noise amplitude on the steep walls (VALLEY_WALL_
## NOISE_DAMPING) so noise reads as texture riding on the wall rather than
## fighting the shape that's supposed to define the map.
func _valley_profile(px: float, width: int) -> Dictionary:
	var x_norm := px / float(maxi(width - 1, 1))
	var floor_half := VALLEY_FLOOR_WIDTH_FRACTION * 0.5
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
func _build_heightmap(master_seed: int = MASTER_SEED) -> Dictionary:
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
	valley_height.resize(AREA_WIDTH)
	valley_noise_scale.resize(AREA_WIDTH)
	for px in AREA_WIDTH:
		var valley := _valley_profile(px, AREA_WIDTH)
		valley_height[px] = valley.height
		valley_noise_scale[px] = lerpf(1.0, VALLEY_WALL_NOISE_DAMPING, valley.wall_t)
	print("TERRAIN_GEN: valley cross-section (pre-noise) left_rim=%.2f floor=%.2f right_rim=%.2f" \
		% [valley_height[0], valley_height[int(AREA_WIDTH * 0.5)], valley_height[AREA_WIDTH - 1]])

	var heights := PackedFloat32Array()
	heights.resize(AREA_WIDTH * AREA_LENGTH)
	for pz in AREA_LENGTH:
		for px in AREA_WIDTH:
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
			heights[pz * AREA_WIDTH + px] = height
	print("TERRAIN_GEN: base noise+valley heightmap done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	var erosion_iterations := maxi(200, int(AREA_WIDTH * AREA_LENGTH * EROSION_DENSITY))
	print("TERRAIN_GEN: eroding (%d droplets)..." % erosion_iterations)
	var erosion_rng := RandomNumberGenerator.new()
	erosion_rng.seed = seeds.erosion
	_erode(heights, AREA_WIDTH, AREA_LENGTH, erosion_rng, erosion_iterations)
	print("TERRAIN_GEN: erosion done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	if SMOOTH_PASSES > 0:
		print("TERRAIN_GEN: smoothing (%d pass(es))..." % SMOOTH_PASSES)
		_smooth(heights, AREA_WIDTH, AREA_LENGTH, SMOOTH_PASSES, SMOOTH_RADIUS)
		print("TERRAIN_GEN: smoothing done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
		t_stage = Time.get_ticks_msec()

	var feature_count := maxi(1, int(AREA_WIDTH * AREA_LENGTH * FEATURE_DENSITY))
	print("TERRAIN_GEN: adding %d cliff/ledge feature(s)..." % feature_count)
	var feature_rng := RandomNumberGenerator.new()
	feature_rng.seed = seeds.features
	var cliff_features := _add_cliff_features(heights, AREA_WIDTH, AREA_LENGTH, feature_rng, feature_count)
	print("TERRAIN_GEN: cliff features done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# Second, much lighter erosion pass -- runs AFTER carving so the crisp
	# features get real runoff/edge detail instead of none at all, but at
	# a fraction of the main pass's droplet count so it doesn't undo their
	# hand-tuned EDGE_SOFTNESS shaping. Continues erosion_rng's own sequence
	# rather than reseeding, so it's still fully deterministic per-seed.
	var post_feature_erosion_iterations := maxi(50, int(erosion_iterations * POST_FEATURE_EROSION_FRACTION))
	print("TERRAIN_GEN: post-feature erosion (%d droplets)..." % post_feature_erosion_iterations)
	_erode(heights, AREA_WIDTH, AREA_LENGTH, erosion_rng, post_feature_erosion_iterations)
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
	var cliff_dressing_plan := _plan_cliff_dressing(cliff_features, heights, AREA_WIDTH, AREA_LENGTH, cliff_dressing_rng)
	_flatten_terrain_for_cliff_dressing(cliff_dressing_plan, heights, AREA_WIDTH, AREA_LENGTH)
	var cliff_dressing_top_profiles := _build_cliff_dressing_top_profiles()
	_raise_terrain_behind_cliff_dressing(cliff_dressing_plan, heights, AREA_WIDTH, AREA_LENGTH, cliff_dressing_top_profiles, master_seed ^ 0x52414953) # 'RAIS' salt, round 20
	var cliff_obstacle_mask := _build_cliff_dressing_obstacle_mask(cliff_dressing_plan, AREA_WIDTH, AREA_LENGTH)
	print("TERRAIN_GEN: cliff dressing planned + terrain flattened/raised to match (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# 2026-09-20 round 2: flat rock outcrops (mountainside) -- planned and the terrain conformed
	# to each one's real underside HERE, before road routing + Terrain3D import, same reasoning
	# as cliff dressing above. Instanced later in _ready (_place_outcrops).
	var outcrop_models := _load_outcrop_models()
	var outcrop_rng := RandomNumberGenerator.new()
	outcrop_rng.seed = master_seed ^ 0x4F555443 # 'OUTC' salt
	var outcrop_plan := _plan_outcrops(outcrop_models, heights, AREA_WIDTH, AREA_LENGTH, outcrop_rng, cliff_dressing_plan)
	_fit_terrain_to_outcrops(outcrop_plan, outcrop_models, heights, AREA_WIDTH, AREA_LENGTH)
	_add_outcrops_to_obstacle_mask(outcrop_plan, cliff_obstacle_mask, AREA_WIDTH, AREA_LENGTH)
	print("TERRAIN_GEN: outcrops planned + terrain fitted (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	# Control map: defaults to ground everywhere; the road step below paints
	# over it where it runs. Built as plain ints (packed base/overlay/blend)
	# rather than floats, since that's what the road step naturally produces --
	# converted to the Image's float-encoded form only once, at the end.
	var control := PackedInt32Array()
	control.resize(AREA_WIDTH * AREA_LENGTH)
	var ground_packed := _pack_control(GROUND_TEXTURE_ID)
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
	var road_result := _generate_road(heights, control, AREA_WIDTH, AREA_LENGTH, road_rng, edge_noise, cliff_obstacle_mask)
	var road_weight: PackedFloat32Array = road_result.weight
	print("TERRAIN_GEN: road routing done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	_print_roughness_stats(heights, AREA_WIDTH, AREA_LENGTH)

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
	var height_image := Image.create_from_data(AREA_WIDTH, AREA_LENGTH, false, Image.FORMAT_RF, heights.to_byte_array())
	var control_image := Image.create(AREA_WIDTH, AREA_LENGTH, false, Image.FORMAT_RF)
	for pz in AREA_LENGTH:
		for px in AREA_WIDTH:
			var idx := pz * AREA_WIDTH + px
			control_image.set_pixel(px, pz, Color(Terrain3DUtil.as_float(control[idx]), 0.0, 0.0))
	print("TERRAIN_GEN: height/control image assembly done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	t_stage = Time.get_ticks_msec()

	print("TERRAIN_GEN: building macro color-variation map...")
	var color_image := _build_color_map(seeds, AREA_WIDTH, AREA_LENGTH)
	print("TERRAIN_GEN: color map done (%.2fs)" % ((Time.get_ticks_msec() - t_stage) / 1000.0))
	print("TERRAIN_GEN: _build_heightmap TOTAL (%.2fs)" % ((Time.get_ticks_msec() - t_start) / 1000.0))
	return {"height": height_image, "control": control_image, "color": color_image, "cliff_features": cliff_features, "cliff_dressing_plan": cliff_dressing_plan, "cliff_dressing_top_profiles": cliff_dressing_top_profiles, "outcrop_plan": outcrop_plan, "outcrop_models": outcrop_models, "heights": heights, "road_weight": road_weight, "spawn_pixel": road_result.spawn_pixel, "exit_pixel": road_result.exit_pixel, "road_path": road_result.path}

## Builds the terrain's color map: a full-resolution RGBA image Terrain3D
## multiplies directly into every pixel's albedo (alpha nudges roughness
## around its neutral 0.5). See the MACRO_* constants' comment above for
## why this exists -- it's what keeps the same ground texture from looking
## identical patch to patch across the whole visible map.
func _build_color_map(seeds: Dictionary, width: int, length: int) -> Image:
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
func _pack_control(texture_id: int) -> int:
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
func _pack_control_blend(base_id: int, overlay_id: int, blend_frac: float) -> int:
	var blend_byte := clampi(int(round(clampf(blend_frac, 0.0, 1.0) * 255.0)), 0, 255)
	return Terrain3DUtil.enc_base(base_id) | Terrain3DUtil.enc_overlay(overlay_id) | Terrain3DUtil.enc_blend(blend_byte)

## Simplified hydraulic erosion: simulates EROSION_ITERATIONS water droplets,
## each starting at a random point and flowing downhill for up to
## MAX_DROPLET_LIFETIME steps. A droplet erodes material when it's moving
## fast down a steep slope (more than it can carry, i.e. over its sediment
## capacity) and deposits when it slows down or the ground flattens out --
## which is what turns raw noise into believable valleys, ridgelines, and
## alluvial fans instead of just "noise with jitter". Operates directly on
## the flat heights array (no erosion-radius brush, just bilinear point
## sampling/deposit) to stay fast enough to run synchronously at this
## resolution.
func _erode(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, iterations: int) -> void:
	for iter in iterations:
		var pos_x := rng.randf_range(0.0, width - 1.001)
		var pos_z := rng.randf_range(0.0, length - 1.001)
		var dir_x := 0.0
		var dir_z := 0.0
		var speed := INITIAL_SPEED
		var water := INITIAL_WATER_VOLUME
		var sediment := 0.0

		for step in MAX_DROPLET_LIFETIME:
			var node_x := int(pos_x)
			var node_z := int(pos_z)
			var cell_x := pos_x - node_x
			var cell_z := pos_z - node_z
			var node_x1 := mini(node_x + 1, width - 1)
			var node_z1 := mini(node_z + 1, length - 1)

			var h_nw := heights[node_z * width + node_x]
			var h_ne := heights[node_z * width + node_x1]
			var h_sw := heights[node_z1 * width + node_x]
			var h_se := heights[node_z1 * width + node_x1]

			var gradient_x := (h_ne - h_nw) * (1.0 - cell_z) + (h_se - h_sw) * cell_z
			var gradient_z := (h_sw - h_nw) * (1.0 - cell_x) + (h_se - h_ne) * cell_x
			var old_height := h_nw * (1 - cell_x) * (1 - cell_z) \
				+ h_ne * cell_x * (1 - cell_z) \
				+ h_sw * (1 - cell_x) * cell_z \
				+ h_se * cell_x * cell_z

			dir_x = dir_x * INERTIA - gradient_x * (1.0 - INERTIA)
			dir_z = dir_z * INERTIA - gradient_z * (1.0 - INERTIA)
			var dir_len := sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len < 0.0001:
				# Flat spot / directionless: pick a random escape direction
				# instead of stalling the droplet in place forever.
				var ang := rng.randf_range(0.0, TAU)
				dir_x = cos(ang)
				dir_z = sin(ang)
				dir_len = 1.0
			dir_x /= dir_len
			dir_z /= dir_len

			var new_x := pos_x + dir_x
			var new_z := pos_z + dir_z
			if new_x < 0.0 or new_x >= width - 1 or new_z < 0.0 or new_z >= length - 1:
				break

			var new_node_x := int(new_x)
			var new_node_z := int(new_z)
			var new_cell_x := new_x - new_node_x
			var new_cell_z := new_z - new_node_z
			var new_node_x1 := mini(new_node_x + 1, width - 1)
			var new_node_z1 := mini(new_node_z + 1, length - 1)
			var n_h_nw := heights[new_node_z * width + new_node_x]
			var n_h_ne := heights[new_node_z * width + new_node_x1]
			var n_h_sw := heights[new_node_z1 * width + new_node_x]
			var n_h_se := heights[new_node_z1 * width + new_node_x1]
			var new_height := n_h_nw * (1 - new_cell_x) * (1 - new_cell_z) \
				+ n_h_ne * new_cell_x * (1 - new_cell_z) \
				+ n_h_sw * (1 - new_cell_x) * new_cell_z \
				+ n_h_se * new_cell_x * new_cell_z

			var height_diff := new_height - old_height
			var capacity := maxf(-height_diff, MIN_SEDIMENT_CAPACITY) * speed * water * SEDIMENT_CAPACITY_FACTOR

			if sediment > capacity or height_diff > 0.0:
				# Moving uphill, or carrying more than it can hold: drop sediment.
				var deposit_amount := minf(height_diff, sediment) if height_diff > 0.0 else (sediment - capacity) * DEPOSIT_SPEED
				sediment -= deposit_amount
				heights[node_z * width + node_x] += deposit_amount * (1 - cell_x) * (1 - cell_z)
				heights[node_z * width + node_x1] += deposit_amount * cell_x * (1 - cell_z)
				heights[node_z1 * width + node_x] += deposit_amount * (1 - cell_x) * cell_z
				heights[node_z1 * width + node_x1] += deposit_amount * cell_x * cell_z
			else:
				# Steep and fast: pick up sediment, capped by what's actually there.
				var erode_amount := minf((capacity - sediment) * ERODE_SPEED, -height_diff)
				sediment += erode_amount
				heights[node_z * width + node_x] -= erode_amount * (1 - cell_x) * (1 - cell_z)
				heights[node_z * width + node_x1] -= erode_amount * cell_x * (1 - cell_z)
				heights[node_z1 * width + node_x] -= erode_amount * (1 - cell_x) * cell_z
				heights[node_z1 * width + node_x1] -= erode_amount * cell_x * cell_z

			speed = sqrt(maxf(0.0, speed * speed + height_diff * -GRAVITY))
			water *= (1.0 - EVAPORATE_SPEED)
			pos_x = new_x
			pos_z = new_z
			if water < 0.001:
				break

## Prints min/max height and the average absolute height difference
## between horizontally/vertically adjacent pixels ("roughness") plus the
## single sharpest jump found -- the number to actually watch when tuning
## for "smoother". A gentle rolling hill has an average adjacent delta of a
## few hundredths to low tenths of a unit at 1 vertex/unit spacing; the
## first (too jagged) pass was landing well above 1.0 in places. Printed
## regardless of APPLY_TO_TERRAIN so tuning never needs to touch the live
## terrain to see whether a change helped.
func _print_roughness_stats(heights: PackedFloat32Array, width: int, length: int) -> void:
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

## Scatters `count` short "fault line" cliffs/ledges across the heightmap.
## Each one picks a random center, a random orientation, and a random
## length/step height, then adds a smoothstep-shaped height offset across a
## band perpendicular to that orientation -- everything on one side of the
## line ends up `step_height` higher than the other, with a soft transition
## (FEATURE_EDGE_SOFTNESS) across the face and a fade-out (FEATURE_END_FALLOFF)
## at both tips so it blends into the surrounding terrain instead of just
## stopping. Deliberately short and modest in height -- meant to read as a
## local landmark (a low rock cut, a bank by a stream) you'd naturally walk
## around, not a wall that blocks movement.
func _add_cliff_features(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, count: int) -> Array[Dictionary]:
	# Each placed feature's center AND its actual reach (how far its footprint
	# extends from that center) -- checking center distance alone isn't
	# enough, since two centers can be far apart while their elongated bands
	# still point straight at each other and touch (or cross) at the tips.
	# Requiring center_distance >= reach_a + reach_b + FEATURE_MIN_GAP
	# guarantees the footprints themselves never overlap, regardless of
	# orientation, which is what actually prevents two independent steps from
	# summing into a sharp unnatural "corner". See _find_feature_center.
	var placed: Array[Dictionary] = []
	# One shared noise field for the edge-jitter effect below -- every feature
	# samples the SAME field (there's no reason to allocate a new generator
	# per feature), but each feature reads from a different, far-apart offset
	# into it (derived from rng below) so their jitter patterns don't repeat.
	var edge_jitter := FastNoiseLite.new()
	edge_jitter.seed = rng.randi()
	edge_jitter.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	edge_jitter.frequency = FEATURE_EDGE_NOISE_FREQUENCY

	for i in count:
		# Zone first (which part of the valley cross-section the center gets
		# drawn from), THEN an archetype weighted for that zone -- this is
		# what makes escarpments/ravines land on the walls and knolls/gentle
		# rises land on the floor, instead of any shape being equally likely
		# anywhere on the map.
		var zone: String = _weighted_pick(rng, ZONE_PICK_WEIGHTS)
		var archetype: int = _weighted_pick(rng, ZONE_ARCHETYPE_WEIGHTS[zone])
		if archetype == FeatureArchetype.KNOLL:
			_place_knoll(heights, width, length, rng, zone, edge_jitter, placed)
		else:
			_place_line_feature(heights, width, length, rng, zone, archetype, edge_jitter, placed)

	return placed

## Weighted random pick from a {key: weight} Dictionary -- weights don't
## need to sum to 1, they're normalized against their own total. Falls back
## to the last key on a float-precision edge case so this never returns
## null.
func _weighted_pick(rng: RandomNumberGenerator, weights: Dictionary):
	var total := 0.0
	for w in weights.values():
		total += w
	if total <= 0.0:
		return weights.keys()[0]
	var roll := rng.randf_range(0.0, total)
	var acc := 0.0
	for key in weights.keys():
		acc += weights[key]
		if roll <= acc:
			return key
	return weights.keys()[weights.size() - 1]

## Pixel-space X range a candidate feature center can be drawn from for the
## given valley zone ("floor", "wall", "transition") -- derived from the
## same VALLEY_FLOOR_WIDTH_FRACTION/ZONE_TRANSITION_WALL_T boundaries
## _valley_profile uses, so feature placement and the macro shape always
## agree on where the floor/wall/rim actually are. "wall" and "transition"
## each straddle both sides of the (asymmetric) valley -- this picks one
## side at random per call, so left/right get roughly equal shares of
## wall/transition features over many calls despite the height asymmetry.
func _zone_pixel_range(zone: String, width: int, rng: RandomNumberGenerator) -> Vector2:
	var w := float(width)
	var floor_half := VALLEY_FLOOR_WIDTH_FRACTION * 0.5
	var floor_lo := (0.5 - floor_half) * w
	var floor_hi := (0.5 + floor_half) * w
	var edge_margin := 4.0 ## keep clear of the absolute map edge
	var left_wall_lo := floor_lo * (1.0 - ZONE_TRANSITION_WALL_T)
	var right_wall_hi := floor_hi + ZONE_TRANSITION_WALL_T * (w - floor_hi)
	match zone:
		"wall":
			if rng.randf() < 0.5:
				return Vector2(maxf(left_wall_lo, edge_margin), floor_lo)
			else:
				return Vector2(floor_hi, minf(right_wall_hi, w - 1.0 - edge_margin))
		"transition":
			if rng.randf() < 0.5:
				return Vector2(edge_margin, maxf(left_wall_lo, edge_margin + 1.0))
			else:
				return Vector2(minf(right_wall_hi, w - 1.0 - edge_margin - 1.0), w - 1.0 - edge_margin)
		_: # "floor"
			return Vector2(floor_lo, floor_hi)

## Pulls a candidate range [lo,hi] inward by `reach` on each side so that a
## center drawn from the result can never place a feature's footprint past
## [0, max_index] -- without this, a zone-restricted range (see
## _zone_pixel_range) can sit close enough to the map edge that a large
## feature's footprint gets clipped by the heightmap boundary instead of
## blending into unmodified terrain the way it does everywhere else. If the
## zone's own band is narrower than the feature needs (a big feature in a
## tight wall/transition band), this collapses to the one point that's
## still fully contained rather than letting it clip.
func _clamp_range_for_reach(lo: float, hi: float, reach: float, max_index: float) -> Vector2:
	var safe_lo := maxf(lo, reach)
	var safe_hi := minf(hi, max_index - reach)
	if safe_lo > safe_hi:
		var mid := clampf((lo + hi) * 0.5, reach, max_index - reach)
		return Vector2(mid, mid)
	return Vector2(safe_lo, safe_hi)

## Rejection-samples a candidate center within [x_lo,x_hi]x[z_lo,z_hi] that
## clears every already-placed feature's own footprint (reach) by at least
## FEATURE_MIN_GAP, trying up to 30 times -- see _add_cliff_features' reach
## comment for why center-distance alone isn't the right check. Returns the
## center, or null if no clear spot was found in 30 attempts (the caller
## skips this feature rather than force an overlapping placement -- see the
## old "two cliffs crossing" artifact this originally fixed).
func _find_feature_center(rng: RandomNumberGenerator, placed: Array[Dictionary], reach: float, x_lo: float, x_hi: float, z_lo: float, z_hi: float):
	for attempt in 30:
		var center_x := rng.randf_range(x_lo, x_hi) if x_hi > x_lo else (x_lo + x_hi) * 0.5
		var center_z := rng.randf_range(z_lo, z_hi)
		var far_enough := true
		for p in placed:
			var required: float = reach + p.reach + FEATURE_MIN_GAP
			if Vector2(center_x, center_z).distance_to(p.center) < required:
				far_enough = false
				break
		if far_enough:
			return Vector2(center_x, center_z)
	return null

## Places one line-based feature (ESCARPMENT, V_RAVINE, TERRACE, or
## GENTLE_RISE) -- an elongated band across the heightmap, using the same
## "fault line" framework the original single-archetype generator used
## (axis + perpendicular offset + two-harmonic sine wander + end falloff +
## simplex edge jitter), but with per-archetype parameter ranges and, for
## V_RAVINE, a different cross-section formula (a symmetric cut with a
## floor and two walls, instead of a one-sided step). Appends the placed
## feature's data to `placed` in place; does nothing if no non-overlapping
## spot is found.
func _place_line_feature(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, zone: String, archetype: int, edge_jitter: FastNoiseLite, placed: Array[Dictionary]) -> void:
	var angle := rng.randf_range(0.0, TAU)
	var axis_x := cos(angle)
	var axis_z := sin(angle)
	var perp_x := -axis_z
	var perp_z := axis_x

	var half_len := 0.0
	var edge_softness := 0.0
	var plateau_width := 0.0
	var step_height := 0.0 ## unused (stays 0) for V_RAVINE, which uses ravine_half_width/depth instead
	var ravine_half_width := 0.0
	var depth := 0.0
	var wander_fraction := FEATURE_CURVE_AMPLITUDE_FRACTION

	match archetype:
		FeatureArchetype.ESCARPMENT:
			half_len = rng.randf_range(ESCARPMENT_LENGTH_MIN, ESCARPMENT_LENGTH_MAX) * 0.5
			step_height = rng.randf_range(ESCARPMENT_STEP_MIN, ESCARPMENT_STEP_MAX) * (1.0 if rng.randf() < 0.5 else -1.0)
			edge_softness = ESCARPMENT_EDGE_SOFTNESS
			plateau_width = ESCARPMENT_PLATEAU_WIDTH
			wander_fraction = ESCARPMENT_WANDER_FRACTION
		FeatureArchetype.TERRACE:
			half_len = rng.randf_range(TERRACE_LENGTH_MIN, TERRACE_LENGTH_MAX) * 0.5
			step_height = rng.randf_range(TERRACE_STEP_MIN, TERRACE_STEP_MAX) * (1.0 if rng.randf() < 0.5 else -1.0)
			edge_softness = TERRACE_EDGE_SOFTNESS
			plateau_width = TERRACE_PLATEAU_WIDTH
			wander_fraction = TERRACE_WANDER_FRACTION
		FeatureArchetype.GENTLE_RISE:
			half_len = rng.randf_range(GENTLE_RISE_LENGTH_MIN, GENTLE_RISE_LENGTH_MAX) * 0.5
			step_height = rng.randf_range(GENTLE_RISE_STEP_MIN, GENTLE_RISE_STEP_MAX) * (1.0 if rng.randf() < 0.5 else -1.0)
			edge_softness = GENTLE_RISE_EDGE_SOFTNESS
			plateau_width = GENTLE_RISE_PLATEAU_WIDTH
			wander_fraction = GENTLE_RISE_WANDER_FRACTION
		FeatureArchetype.V_RAVINE:
			half_len = rng.randf_range(V_RAVINE_LENGTH_MIN, V_RAVINE_LENGTH_MAX) * 0.5
			ravine_half_width = rng.randf_range(V_RAVINE_WIDTH_MIN, V_RAVINE_WIDTH_MAX) * 0.5
			depth = rng.randf_range(V_RAVINE_DEPTH_MIN, V_RAVINE_DEPTH_MAX)
			edge_softness = V_RAVINE_EDGE_SOFTNESS
			wander_fraction = V_RAVINE_WANDER_FRACTION
		_:
			return # unreachable -- KNOLL is routed to _place_knoll instead

	var curve_amplitude := half_len * wander_fraction
	var curve_frequency := rng.randf_range(FEATURE_CURVE_FREQ_MIN, FEATURE_CURVE_FREQ_MAX)
	var curve_phase := rng.randf_range(0.0, TAU)
	var curve_frequency2 := rng.randf_range(FEATURE_CURVE_FREQ2_MIN, FEATURE_CURVE_FREQ2_MAX)
	var curve_phase2 := rng.randf_range(0.0, TAU)
	var curve_weight2 := rng.randf_range(FEATURE_CURVE_WEIGHT2_MIN, FEATURE_CURVE_WEIGHT2_MAX)
	var height_variation := absf(step_height) * FEATURE_HEIGHT_VARIATION_FRACTION
	var height_frequency := rng.randf_range(FEATURE_HEIGHT_FREQ_MIN, FEATURE_HEIGHT_FREQ_MAX)
	var height_phase := rng.randf_range(0.0, TAU)
	var height_frequency2 := rng.randf_range(FEATURE_HEIGHT_FREQ2_MIN, FEATURE_HEIGHT_FREQ2_MAX)
	var height_phase2 := rng.randf_range(0.0, TAU)
	var height_weight2 := rng.randf_range(FEATURE_HEIGHT_WEIGHT2_MIN, FEATURE_HEIGHT_WEIGHT2_MAX)

	# Offset into the shared noise field so each feature's edge jitter is
	# uncorrelated with the others' (world position alone would make two
	# nearby, similarly-angled features sample near-identical noise).
	var jitter_offset_x := rng.randf_range(-10000.0, 10000.0)
	var jitter_offset_z := rng.randf_range(-10000.0, 10000.0)

	# reach includes the curve margin (and, for a ravine, its own half-width)
	# so the bounding box and the footprint-separation check both account for
	# the full extent of what actually gets carved, not just the centerline.
	var reach := half_len + FEATURE_END_FALLOFF + curve_amplitude + (ravine_half_width if archetype == FeatureArchetype.V_RAVINE else 0.0)

	var x_range := _zone_pixel_range(zone, width, rng)
	var x_clamped := _clamp_range_for_reach(x_range.x, x_range.y, reach, float(width - 1))
	var x_lo := minf(x_clamped.x, x_clamped.y)
	var x_hi := maxf(x_clamped.x, x_clamped.y)
	var z_clamped := _clamp_range_for_reach(length * 0.1, length * 0.9, reach, float(length - 1))
	var z_lo := minf(z_clamped.x, z_clamped.y)
	var z_hi := maxf(z_clamped.x, z_clamped.y)

	var center = _find_feature_center(rng, placed, reach, x_lo, x_hi, z_lo, z_hi)
	if center == null:
		print("TERRAIN_GEN: skipped a %s feature -- no non-overlapping spot found after 30 attempts in zone '%s'" % [FeatureArchetype.keys()[archetype], zone])
		return
	var center_x: float = center.x
	var center_z: float = center.y

	var feature := {
		"archetype": archetype, "zone": zone, "center": Vector2(center_x, center_z), "reach": reach,
		"axis_x": axis_x, "axis_z": axis_z, "perp_x": perp_x, "perp_z": perp_z, "half_len": half_len,
		"edge_softness": edge_softness, "curve_amplitude": curve_amplitude, "curve_frequency": curve_frequency,
		"curve_phase": curve_phase, "curve_frequency2": curve_frequency2, "curve_phase2": curve_phase2,
		"curve_weight2": curve_weight2,
	}
	if archetype == FeatureArchetype.V_RAVINE:
		feature["ravine_half_width"] = ravine_half_width
		feature["depth"] = depth
	else:
		feature["step_height"] = step_height
		feature["plateau_width"] = plateau_width
	placed.append(feature)

	var min_px := clampi(int(center_x - reach), 0, width - 1)
	var max_px := clampi(int(center_x + reach), 0, width - 1)
	var min_pz := clampi(int(center_z - reach), 0, length - 1)
	var max_pz := clampi(int(center_z + reach), 0, length - 1)

	for pz in range(min_pz, max_pz + 1):
		for px in range(min_px, max_px + 1):
			var dx := px - center_x
			var dz := pz - center_z
			# Position along the line's own axis, and perpendicular distance
			# (which side of the fault the pixel falls on).
			var t := dx * axis_x + dz * axis_z
			var d := dx * perp_x + dz * perp_z
			if absf(t) > reach:
				continue

			var end_fade := 1.0
			if absf(t) > half_len:
				end_fade = clampf(1.0 - (absf(t) - half_len) / FEATURE_END_FALLOFF, 0.0, 1.0)

			# Sideways wander, both a smooth sine of position along the line
			# (normalized to -1..1 across its own half-length) -- shifts the
			# face/ravine left/right gradually along its length instead of
			# staying constant, which is what read as an artificial
			# ruler-straight cut.
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)

			# Small simplex jitter added directly to the perpendicular distance,
			# on top of the analytic curve_offset above -- the sine wander bends
			# the fault line as a whole, but every point along it was still an
			# exact, perfectly smooth function of t, so the edge itself always
			# read as artificially clean. This breaks that up at a finer scale.
			var edge_jitter_amount := edge_jitter.get_noise_2d(px + jitter_offset_x, pz + jitter_offset_z) * FEATURE_EDGE_NOISE_AMPLITUDE
			var d_eff := d - curve_offset + edge_jitter_amount

			var idx := pz * width + px
			if archetype == FeatureArchetype.V_RAVINE:
				# Symmetric cross-section: a flat-ish floor at the centerline
				# (the innermost 30% of the half-width), then both walls rise
				# via smoothstep back up to unmodified terrain at the ravine's
				# own edge -- unlike every other archetype here, this has NO
				# one-sided "face"/"plateau", it's symmetric around d=0.
				var abs_d := absf(d_eff)
				var inner := ravine_half_width * 0.3
				var wall_t := 0.0
				if abs_d > inner:
					wall_t = smoothstep(0.0, 1.0, clampf((abs_d - inner) / maxf(ravine_half_width - inner, 0.001), 0.0, 1.0))
				var depth_factor := -(1.0 - wall_t) # -1 at the ravine floor, 0 past its rim
				heights[idx] += depth * depth_factor * end_fade
			else:
				# Height modulation: a smooth sine ripple of the step height
				# along the line's length (same two-harmonic blend as the wander).
				var local_height := step_height + height_variation * lerpf(sin(normalized_t * PI * height_frequency + height_phase), sin(normalized_t * PI * height_frequency2 + height_phase2), height_weight2)
				# Smooth step across the cliff/terrace/rise face itself: 0 on
				# one side, 1 on the other, blending over edge_softness*2 units.
				var face := smoothstep(-edge_softness, edge_softness, d_eff)
				# Fades the plateau itself back to 0 beyond plateau_width so
				# each feature is a proper finite, elongated ledge that blends
				# into the surrounding terrain on every side, instead of a
				# round blob covering most of the loop's bounding box.
				var lateral_falloff := 1.0 - smoothstep(plateau_width - FEATURE_END_FALLOFF, plateau_width, abs(d_eff))
				heights[idx] += local_height * face * end_fade * lateral_falloff

## Places one KNOLL/mound feature -- a round, radial footprint (not a fault
## line at all), small, and either a positive mound or a shallow negative
## hollow. Reads as a small landmark on otherwise-open ground; mostly rolled
## on the valley floor (see ZONE_ARCHETYPE_WEIGHTS). Appends the placed
## feature's data to `placed` in place; does nothing if no non-overlapping
## spot is found.
func _place_knoll(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, zone: String, edge_jitter: FastNoiseLite, placed: Array[Dictionary]) -> void:
	var radius := rng.randf_range(KNOLL_RADIUS_MIN, KNOLL_RADIUS_MAX)
	var knoll_height := rng.randf_range(KNOLL_HEIGHT_MIN, KNOLL_HEIGHT_MAX) * (1.0 if rng.randf() < 0.7 else -1.0) # mounds more common than hollows

	# Irregular footprint instead of a perfect circle: a random rotation +
	# elliptical squash (aspect) elongates it, two angular sine harmonics
	# wobble the edge on top of that, and simplex edge jitter (the same
	# field _place_line_feature uses) breaks up what's left of the smooth
	# analytic curve -- without this every knoll was the exact same disc
	# just resized, which is what read as "stamped" once several were on
	# screen together.
	var rotation := rng.randf_range(0.0, TAU)
	var aspect := rng.randf_range(KNOLL_ASPECT_MIN, KNOLL_ASPECT_MAX)
	var wobble_freq1 := rng.randf_range(KNOLL_WOBBLE_FREQ1_MIN, KNOLL_WOBBLE_FREQ1_MAX)
	var wobble_phase1 := rng.randf_range(0.0, TAU)
	var wobble_amp1 := rng.randf_range(KNOLL_WOBBLE_AMP1_MIN, KNOLL_WOBBLE_AMP1_MAX)
	var wobble_freq2 := rng.randf_range(KNOLL_WOBBLE_FREQ2_MIN, KNOLL_WOBBLE_FREQ2_MAX)
	var wobble_phase2 := rng.randf_range(0.0, TAU)
	var wobble_amp2 := rng.randf_range(KNOLL_WOBBLE_AMP2_MIN, KNOLL_WOBBLE_AMP2_MAX)
	var jitter_offset_x := rng.randf_range(-10000.0, 10000.0)
	var jitter_offset_z := rng.randf_range(-10000.0, 10000.0)

	# reach uses the WORST-CASE (max-amplitude) wobble constants, not this
	# feature's own rolled amplitudes, so the bounding box and the overlap
	# check are always big enough regardless of what got rolled.
	var reach := radius * (1.0 + KNOLL_WOBBLE_AMP1_MAX + KNOLL_WOBBLE_AMP2_MAX) + KNOLL_EDGE_SOFTNESS

	var x_range := _zone_pixel_range(zone, width, rng)
	var x_clamped := _clamp_range_for_reach(x_range.x, x_range.y, reach, float(width - 1))
	var x_lo := minf(x_clamped.x, x_clamped.y)
	var x_hi := maxf(x_clamped.x, x_clamped.y)
	var z_clamped := _clamp_range_for_reach(length * 0.1, length * 0.9, reach, float(length - 1))
	var z_lo := minf(z_clamped.x, z_clamped.y)
	var z_hi := maxf(z_clamped.x, z_clamped.y)

	var center = _find_feature_center(rng, placed, reach, x_lo, x_hi, z_lo, z_hi)
	if center == null:
		print("TERRAIN_GEN: skipped a knoll feature -- no non-overlapping spot found after 30 attempts in zone '%s'" % zone)
		return
	var center_x: float = center.x
	var center_z: float = center.y

	placed.append({"archetype": FeatureArchetype.KNOLL, "zone": zone, "center": Vector2(center_x, center_z), "reach": reach, "radius": radius, "knoll_height": knoll_height})

	var min_px := clampi(int(center_x - reach), 0, width - 1)
	var max_px := clampi(int(center_x + reach), 0, width - 1)
	var min_pz := clampi(int(center_z - reach), 0, length - 1)
	var max_pz := clampi(int(center_z + reach), 0, length - 1)

	var cos_r := cos(rotation)
	var sin_r := sin(rotation)

	for pz in range(min_pz, max_pz + 1):
		for px in range(min_px, max_px + 1):
			var dx := px - center_x
			var dz := pz - center_z
			if Vector2(dx, dz).length() > reach:
				continue

			# Rotate into the knoll's own frame, then squash the local Z axis
			# by `aspect` to elongate it into an ellipse rather than a circle.
			var lx := dx * cos_r + dz * sin_r
			var lz := -dx * sin_r + dz * cos_r
			var ellip_dist := sqrt(lx * lx + (lz / aspect) * (lz / aspect))

			# Angular wobble: the effective radius itself varies with direction
			# around the knoll (two blended sine harmonics), so the edge bulges
			# and pinches instead of tracing a perfect ellipse either.
			var angle := atan2(lz, lx)
			var wobble := 1.0 + wobble_amp1 * sin(angle * wobble_freq1 + wobble_phase1) + wobble_amp2 * sin(angle * wobble_freq2 + wobble_phase2)
			var effective_radius := radius * wobble

			# Small simplex jitter directly on the distance, same idea as the
			# cliff-face edge jitter -- breaks up the last bit of analytic
			# smoothness right at the edge.
			var edge_jitter_amount := edge_jitter.get_noise_2d(px + jitter_offset_x, pz + jitter_offset_z) * (KNOLL_EDGE_SOFTNESS * 0.5)

			var t := 1.0 - smoothstep(effective_radius - KNOLL_EDGE_SOFTNESS, effective_radius + KNOLL_EDGE_SOFTNESS, ellip_dist + edge_jitter_amount)
			heights[pz * width + px] += knoll_height * t

## Bilinear height sample directly from the flat heights array -- used by
## _scatter_boulders so boulder placement matches the exact same data that
## became the height image, with no round-trip through Terrain3DData.
func _sample_height_bilinear(heights: PackedFloat32Array, width: int, length: int, px: float, pz: float) -> float:
	var x0 := clampi(int(floor(px)), 0, width - 1)
	var x1 := clampi(x0 + 1, 0, width - 1)
	var z0 := clampi(int(floor(pz)), 0, length - 1)
	var z1 := clampi(z0 + 1, 0, length - 1)
	var fx := clampf(px - x0, 0.0, 1.0)
	var fz := clampf(pz - z0, 0.0, 1.0)
	var h00 := heights[z0 * width + x0]
	var h10 := heights[z0 * width + x1]
	var h01 := heights[z1 * width + x0]
	var h11 := heights[z1 * width + x1]
	return lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fz)

## Surface normal via central differences -- same rise/run formula
## _paint_slope_rock uses for its slope check, just turned into a full
## normal vector instead of a scalar slope, so scattered boulders rest
## tilted to match the ground they're placed on.
func _sample_normal(heights: PackedFloat32Array, width: int, length: int, px: float, pz: float) -> Vector3:
	var cx := clampi(int(round(px)), 0, width - 1)
	var cz := clampi(int(round(pz)), 0, length - 1)
	var x0 := maxi(cx - 1, 0)
	var x1 := mini(cx + 1, width - 1)
	var z0 := maxi(cz - 1, 0)
	var z1 := mini(cz + 1, length - 1)
	var dx := (heights[cz * width + x1] - heights[cz * width + x0]) / float(maxi(x1 - x0, 1)) / VERTEX_SPACING
	var dz := (heights[z1 * width + cx] - heights[z0 * width + cx]) / float(maxi(z1 - z0, 1)) / VERTEX_SPACING
	return Vector3(-dx, 1.0, -dz).normalized()

## Resamples a polyline at uniform world-space arc-length spacing, regardless
## of how unevenly its source points (Catmull-Rom subdivisions bunch up on
## tight curves) are distributed. Used by _build_road_mesh so mesh rows land
## at consistent intervals along the road no matter how the path curves.
func _resample_path(path: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var result := PackedVector2Array()
	if path.size() < 2:
		return result
	result.append(path[0])
	var carry := 0.0
	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg_len := a.distance_to(b)
		if seg_len <= 0.00001:
			continue
		var dist_along := spacing - carry
		while dist_along < seg_len:
			result.append(a.lerp(b, dist_along / seg_len))
			dist_along += spacing
		carry = dist_along - seg_len
	var last: Vector2 = path[path.size() - 1]
	if result[result.size() - 1].distance_to(last) > 0.001:
		result.append(last)
	return result

## Smooths a resampled path laterally (simple windowed moving average, several
## passes) purely for mesh-building purposes -- does NOT touch the original
## `path`/texture-painting data. Needed because a tight bend in the raw
## Catmull-Rom path can have a local curve radius smaller than
## ROAD_TEXTURE_HALF_WIDTH; offsetting by a fixed half-width on the inside of
## such a bend overshoots past the curve's own radius and folds the ribbon
## over itself (self-intersecting/degenerate quads), which shows up as dark
## slit artifacts right where the road turns. Flattening the curvature here
## first keeps every local bend's radius comfortably above the offset amount.
func _smooth_path_for_mesh(path: PackedVector2Array, passes: int, window: int) -> PackedVector2Array:
	var result := path.duplicate()
	for _p in passes:
		var smoothed := result.duplicate()
		for i in range(result.size()):
			var lo := maxi(i - window, 0)
			var hi := mini(i + window, result.size() - 1)
			var sum := Vector2.ZERO
			var count := 0
			for j in range(lo, hi + 1):
				sum += result[j]
				count += 1
			smoothed[i] = sum / count
		result = smoothed
	return result

## Builds a FLAT overlay ribbon mesh along the road centerline -- no vertex
## displacement/bump noise (see the reverted second attempt in CLAUDE.md for
## why that caused harsh self-shadowing at grazing sun angles). Each row's
## height comes straight from the same (already road-graded) `heights` data
## the terrain itself uses, lifted by ROAD_MESH_LIFT to avoid z-fighting, so
## the mesh reads as "the same ground, just with a proper depth-mapped
## material" rather than a separate raised surface. Depth comes entirely
## from the material's built-in heightmap parallax (see the StandardMaterial3D
## setup below), not from geometry.
func _build_road_mesh(heights: PackedFloat32Array, width: int, length: int, path: PackedVector2Array, heightmap_corner: Vector3, seed_value: int) -> void:
	if path.size() < 2:
		print("TERRAIN_GEN: _build_road_mesh -- no road path, skipping")
		return
	var bump_noise := FastNoiseLite.new()
	bump_noise.seed = seed_value ^ 0x524F4144 # 'ROAD' salt
	bump_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	bump_noise.frequency = ROAD_BUMP_FREQUENCY
	var resampled := _resample_path(path, ROAD_MESH_SEGMENT_LENGTH)
	if resampled.size() < 2:
		print("TERRAIN_GEN: _build_road_mesh -- resampled path too short, skipping")
		return
	# See _smooth_path_for_mesh's comment -- prevents self-intersecting
	# geometry on tight bends without affecting the actual gameplay path.
	resampled = _smooth_path_for_mesh(resampled, 3, 4)

	var half_columns := (ROAD_MESH_COLUMNS - 1) / 2.0
	# One row of world-space positions per resampled path point, spanning
	# ROAD_MESH_COLUMNS samples across ROAD_TEXTURE_HALF_WIDTH*2.
	var rows: Array[PackedVector3Array] = []
	var row_uvs: Array[PackedVector2Array] = []
	var accumulated_length := 0.0
	for i in resampled.size():
		var point: Vector2 = resampled[i]
		var prev: Vector2 = resampled[maxi(i - 1, 0)]
		var next: Vector2 = resampled[mini(i + 1, resampled.size() - 1)]
		var tangent := (next - prev)
		if tangent.length_squared() < 0.00001:
			tangent = Vector2(0, 1)
		tangent = tangent.normalized()
		var perp := Vector2(-tangent.y, tangent.x)

		if i > 0:
			accumulated_length += point.distance_to(resampled[i - 1])

		var row_positions := PackedVector3Array()
		var row_uv := PackedVector2Array()
		for c in ROAD_MESH_COLUMNS:
			var offset := (c - half_columns) / half_columns * ROAD_TEXTURE_HALF_WIDTH
			var sample_px: float = point.x + perp.x * offset
			var sample_pz: float = point.y + perp.y * offset
			sample_px = clampf(sample_px, 0.0, float(width - 1))
			sample_pz = clampf(sample_pz, 0.0, float(length - 1))
			var h := _sample_height_bilinear(heights, width, length, sample_px, sample_pz)
			var world_x := heightmap_corner.x + sample_px
			var world_z := heightmap_corner.z + sample_pz
			var bump := bump_noise.get_noise_2d(world_x, world_z) * ROAD_BUMP_AMPLITUDE
			row_positions.append(Vector3(world_x, h + ROAD_MESH_LIFT + bump, world_z))
			row_uv.append(Vector2(offset / ROAD_TEXTURE_TILE_LENGTH, accumulated_length / ROAD_TEXTURE_TILE_LENGTH))
		rows.append(row_positions)
		row_uvs.append(row_uv)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Accumulate smooth per-vertex normals from adjacent quad faces before
	# committing -- SurfaceTool's own generate_normals() would work off the
	# per-triangle set only after add_vertex, so this hand-rolled pass mirrors
	# the same approach validated in the (reverted) second attempt: normals
	# via cross products of quad edge vectors, which analytically always face
	# +Y for this ribbon's winding.
	var vertex_count := resampled.size() * ROAD_MESH_COLUMNS
	var normals := PackedVector3Array()
	normals.resize(vertex_count)
	for i in vertex_count:
		normals[i] = Vector3.ZERO

	for r in range(rows.size() - 1):
		for c in range(ROAD_MESH_COLUMNS - 1):
			var i00 := r * ROAD_MESH_COLUMNS + c
			var i10 := r * ROAD_MESH_COLUMNS + c + 1
			var i01 := (r + 1) * ROAD_MESH_COLUMNS + c
			var i11 := (r + 1) * ROAD_MESH_COLUMNS + c + 1
			var p00: Vector3 = rows[r][c]
			var p10: Vector3 = rows[r][c + 1]
			var p01: Vector3 = rows[r + 1][c]
			var p11: Vector3 = rows[r + 1][c + 1]
			var n1 := (p10 - p00).cross(p01 - p00).normalized()
			var n2 := (p11 - p10).cross(p01 - p10).normalized()
			normals[i00] += n1
			normals[i10] += n1 + n2
			normals[i01] += n1 + n2
			normals[i11] += n2
	for i in vertex_count:
		if normals[i].length_squared() > 0.00001:
			normals[i] = normals[i].normalized()
		else:
			normals[i] = Vector3.UP

	for r in range(rows.size() - 1):
		for c in range(ROAD_MESH_COLUMNS - 1):
			var i00 := r * ROAD_MESH_COLUMNS + c
			var i10 := r * ROAD_MESH_COLUMNS + c + 1
			var i01 := (r + 1) * ROAD_MESH_COLUMNS + c
			var i11 := (r + 1) * ROAD_MESH_COLUMNS + c + 1
			var a: Vector3 = rows[r][c]
			var b: Vector3 = rows[r][c + 1]
			var cc: Vector3 = rows[r + 1][c]
			var d: Vector3 = rows[r + 1][c + 1]
			var uv_a: Vector2 = row_uvs[r][c]
			var uv_b: Vector2 = row_uvs[r][c + 1]
			var uv_c: Vector2 = row_uvs[r + 1][c]
			var uv_d: Vector2 = row_uvs[r + 1][c + 1]
			st.set_normal(normals[i00]); st.set_uv(uv_a); st.add_vertex(a)
			st.set_normal(normals[i10]); st.set_uv(uv_b); st.add_vertex(b)
			st.set_normal(normals[i01]); st.set_uv(uv_c); st.add_vertex(cc)
			st.set_normal(normals[i10]); st.set_uv(uv_b); st.add_vertex(b)
			st.set_normal(normals[i11]); st.set_uv(uv_d); st.add_vertex(d)
			st.set_normal(normals[i01]); st.set_uv(uv_c); st.add_vertex(cc)

	# Required for correct normal-mapped/parallax lighting -- omitting this
	# was the root cause of the garbage tangent-space lighting artifact hit
	# in the second attempt.
	st.generate_tangents()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load("res://textures/source/road_px_diff_1k.png")
	mat.normal_enabled = true
	mat.normal_texture = load("res://textures/source/road_px_nor_gl_1k.png")
	var arm: Texture2D = load("res://textures/source/road_px_arm_1k.png")
	mat.ao_enabled = true
	mat.ao_texture = arm
	mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.roughness_texture = arm
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	# Concrete/rock isn't metallic -- leaving this at 0 (rather than driving it
	# from the arm map's blue channel) plus a lower non-metal specular
	# reflectance avoids a bright specular hotspot where the moon light
	# catches a low-roughness patch of the source texture at a sharp angle
	# (seen as a gray/white streak crossing the road at a slope break).
	mat.metallic = 0.0
	mat.metallic_specular = 0.3
	# Godot's built-in parallax occlusion mapping -- fakes depth via a
	# view-dependent UV offset from the height map, entirely in the shader.
	# No vertices move, so unlike the second attempt there is no extra
	# geometric relief for directional light to self-shadow harshly at
	# grazing angles. 0.04 (simple, non-deep parallax) read as basically flat
	# from typical FPS camera angles looking down at the ground -- bumped the
	# scale and switched to deep (layered/raymarched) parallax for a much
	# more convincing occlusion silhouette at the stone-block edges; this is
	# still a pure shader-space offset with no extra geometry, so it doesn't
	# reintroduce the self-shadowing problem from the second attempt.
	mat.heightmap_enabled = true
	mat.heightmap_texture = load("res://textures/source/road_px_disp_1k.png")
	mat.heightmap_scale = 0.15
	mat.heightmap_deep_parallax = true
	mat.heightmap_min_layers = 8
	mat.heightmap_max_layers = 32
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = ROAD_MESH_NODE_NAME
	mesh_instance.mesh = mesh
	mesh_instance.material_override = mat
	# The small ROAD_BUMP_AMPLITUDE relief above is enough to break the
	# top-down silhouette flatness, but letting it cast shadows is exactly
	# what made the second (reverted) attempt look awful -- small bumps under
	# a low/grazing light cast disproportionately long, hard-edged shadows on
	# themselves. Disabling shadow casting keeps the real depth cue without
	# reintroducing that problem.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var parent := get_parent()
	var old_mesh := parent.get_node_or_null(ROAD_MESH_NODE_NAME)
	if old_mesh:
		old_mesh.queue_free()
	parent.add_child.call_deferred(mesh_instance)
	print("TERRAIN_GEN: _build_road_mesh -- %d rows x %d columns" % [rows.size(), ROAD_MESH_COLUMNS])

## Scatters Boulder01 instances along the low side of each cliff feature's
## foot, using the exact fault-line data _add_cliff_features computed for
## carving the heightmap -- so boulders end up exactly where the cliff
## actually is. Must run AFTER data.import_images() (regions need to exist
## before the instancer can attach transforms to them) and BEFORE
## data.save_directory() -- instancer data is part of each region's own
## saved resource, same as the height/control/color maps.
## -- Canopy (tree) layer scattering (2026-09-21) --
## The first vegetation layer: full conifer trees (fir + pine, 3 variants each,
## Terrain3DMeshAsset ids 14-19 -- see setup_tree_assets.gd) scattered on the
## valley FLOOR + gentle slopes in irregular clumped stands, NOT along cliff
## feet like the boulder/scree talus. Placement template is the glacial-erratic
## floor loop in _scatter_boulders (floor zone via _zone_pixel_range + reach
## clamp), NOT the talus loop. Trees stay UPRIGHT (random yaw + a few degrees of
## lean only -- never normal-aligned like rocks), cluster around a handful of
## stand centres with gaussian falloff (a few lone outliers between stands),
## reuse the same road_weight / slope-normal / cliff-outcrop keep-out rejects,
## and leave deliberate clearings so the route stays legible. Unlike scree,
## trees DO get collision -- a simple upright trunk cylinder on EVERY tree (not the
## full mesh hull). Road-range gating was removed because off-road trees the player
## walked up to had no collision; Jolt handles a few hundred cylinders trivially.
## Tree set (Terrain3D mesh asset ids -- see setup_tree_assets.gd PACK_TREES).
## 2026-09-24: the old Poly Haven fir/pine assets (were 14-19) were removed and the
## Fab pack trees renumbered from 20-33 to 14-27. Keep in sync with PACK_TREES.
const TREE_IDS_FAB_PACK: Array[int] = [14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]  ## Fab vegetation pack (Kirill's cleaned selection): 8 pines + 6 deciduous (1.9-11.3k tris)
const TREE_MESH_IDS: Array[int] = TREE_IDS_FAB_PACK
const TREE_REACH := 4.0 ## canopy footprint radius (~6-7 m wide trees) kept off the map edge, same role as ERRATIC_REACH
## Stand counts calibrated at 256x256 and scaled by real map area (like ERRATIC/OUTCROP) so stand density stays constant as AREA_* change.
const TREE_DENSITY_BASE_AREA := 256.0 * 256.0
const TREE_STAND_COUNT_MIN_BASE := 17
const TREE_STAND_COUNT_MAX_BASE := 26
const TREE_PER_STAND_MIN := 12
const TREE_PER_STAND_MAX := 32
const TREE_STAND_SPREAD := 18.0 ## std-dev (world units) of trees scattered around a stand centre
const TREE_LONE_COUNT_MIN_BASE := 12 ## a few lone outliers between stands, per base area
const TREE_LONE_COUNT_MAX_BASE := 24
const TREE_MAX_SLOPE_NORMAL_Y := 0.80 ## trees only on floor + gentle slopes -- flatter requirement than scree (0.62); steeper than this = no tree
const TREE_MAX_PLACEMENT_ATTEMPTS := 6
const TREE_SCALE_MIN := 0.85
const TREE_SCALE_MAX := 1.25
const TREE_EMBED_DEPTH := 0.20 ## sink the base slightly so the trunk root meets the ground rather than floating on uneven terrain
const TREE_LEAN_MAX_DEG := 4.0 ## max random lean off vertical -- a touch of wind-bent character, never a full ground-align
const TREE_KEEPOUT_RADIUS := 1.2 ## trunk footprint radius for cliff-mesh / outcrop keep-outs (so trunks never spawn inside rock)
const TREE_STAND_LOWGROUND_SAMPLES := 1 ## pick each stand centre as the lowest of this many floor candidates -- a cheap "wetter, lower ground" density bias with no moisture map
## Where trees may go, as fractions of the map (clump centres, lone trees and each tree's
## jitter are all clamped to this). 2026-09-24: trees used to reuse the valley "floor"
## zone (x 22.5%-77.5%) + a hard-coded z 10%-90%, which left flat, walkable wall-zone
## terraces permanently bare. Now a wide band; TREE_MAX_SLOPE_NORMAL_Y is what keeps
## trunks off genuinely steep wall faces. Counts scale with the WHOLE map area, so a wider
## band spreads the same trees thinner -- raise TREE_STAND_COUNT_* to compensate.
const TREE_X_BAND_MIN := 0.03
const TREE_X_BAND_MAX := 0.97
const TREE_Z_BAND_MIN := 0.02
const TREE_Z_BAND_MAX := 0.98
## Clump-centre spacing (2026-09-24): each stand centre is the best of this many random
## candidates, keeping the one farthest from the stands already placed. 1 = pure random
## (clumps bunch up and leave big voids), ~6 = evenly spread but still irregular,
## 15+ = close to a regular pattern. Costs nothing at runtime, same tree count.
const TREE_STAND_SPACING_CANDIDATES := 6
## Colliders: every tree gets a StaticBody trunk cylinder (see _place_one_tree), sized by the constants below.
const TREE_COLLIDER_CONTAINER_NAME := "TreeColliders"
const TREE_TRUNK_RADIUS := 0.28 ## base trunk collider radius at scale 1.0 (scaled per instance)
const TREE_TRUNK_HEIGHT := 6.0 ## upright cylinder height at scale 1.0 -- the player-blocking lower trunk, not the whole tree
## DEBUG (2026-09-24, "why no trees here" probe): the data _scatter_trees used, kept so
## debug_tree_probe() can re-run the exact placement checks at any spot (PerfDebug key T).
## ~1 MB (height + road maps). Remove with debug_tree_probe once no longer needed.
var _tree_debug: Dictionary = {}

## Footprints (px, pz, radius -- pixel space) of every boulder/erratic placed by
## _scatter_boulders this run. _scatter_trees adds these to its keep-outs so tree
## trunks never grow through a rock. Rebuilt every run.
var _rock_keep_circles: Array[Vector3] = []

func _scatter_boulders(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, cliff_features: Array[Dictionary], import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	# Clear any previous run's instances first -- this script regenerates
	# the live Terrain3D every time it runs (see _ready), so without this,
	# re-running would just keep piling more boulders on top of the old set.
	# Clears every rock mesh id in the pool, not just Boulder01's -- see
	# ROCK_MESH_IDS.
	for mesh_id in ROCK_MESH_IDS:
		instancer.clear_by_mesh(mesh_id)
	_rock_keep_circles.clear()

	# Runtime collider container: a plain Node3D under the same parent as
	# this generator/Terrain3D, holding one StaticBody3D+CollisionShape3D
	# per boulder, built directly in the live tree -- no JSON side channel
	# and no separate editor-process script needed anymore.
	var parent := get_parent()
	var old_container := parent.get_node_or_null(BOULDER_COLLIDER_CONTAINER_NAME)
	if old_container:
		old_container.queue_free()
	var collider_container := Node3D.new()
	collider_container.name = BOULDER_COLLIDER_CONTAINER_NAME
	# Deferred: this script's own _ready() runs while the scene tree is
	# still propagating NOTIFICATION_READY to Main's other children (the
	# "Parent node is busy setting up children" failure otherwise), so the
	# container is built off-tree (all its boulder children added below)
	# and only attached to Main once that initial setup finishes.
	parent.add_child.call_deferred(collider_container)

	# One convex collision shape per mesh id in the pool -- each rock is a
	# different mesh, so (unlike the old single-Boulder01 version) a single
	# shared shape no longer applies to every scattered instance.
	var rock_shapes: Dictionary = {}
	for mesh_id in ROCK_MESH_IDS:
		var scene: PackedScene = load(ROCK_SCENE_PATHS[mesh_id])
		if scene:
			var sample := scene.instantiate()
			var lod0: MeshInstance3D = sample.find_child("*LOD0*", true, false)
			if lod0 and lod0.mesh:
				# simplify=true: the 2k meshes would otherwise give 300-500-point hulls; the
				# simplified hull is ~32 points and matches the rock's size within ~1-3%.
				rock_shapes[mesh_id] = lod0.mesh.create_convex_shape(true, true)
			sample.free()
		if not rock_shapes.has(mesh_id):
			push_warning("TERRAIN_GEN: could not build a collision shape from %s (mesh id %d) -- these rocks will render but have no collision" % [ROCK_SCENE_PATHS[mesh_id], mesh_id])

	# Per-mesh-id batches -- Terrain3DInstancer.add_transforms takes one mesh
	# id per call, so instances using different rock meshes can't share one
	# transforms array the way the old single-mesh version did.
	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for mesh_id in ROCK_MESH_IDS:
		transforms_by_mesh[mesh_id] = [] as Array[Transform3D]
		colors_by_mesh[mesh_id] = PackedColorArray()
	var collider_count := 0
	var talus_total := 0
	var erratic_total := 0

	# Item 1: keep-out zones. Cliff meshes as rotated boxes in each model's own scanned local
	# bounds (top profiles' x/z min/max, scaled) -- same local axes _build_cliff_dressing_
	# obstacle_mask uses for face_angle. Outcrops as circles (their bounding radius).
	var keep_rects: Array[Dictionary] = []
	var cliff_defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		cliff_defs_by_name[def.name] = def
	for entry in cliff_plan:
		var cdef = cliff_defs_by_name.get(entry.def_name)
		if cdef == null:
			continue
		var prof: Dictionary = cliff_top_profiles.get(entry.def_name, {})
		var sj: float = entry.scale_jitter
		var fa: float = entry.face_angle
		keep_rects.append({
			"c": Vector2(entry.px, entry.pz),
			"ax": Vector2(cos(fa), -sin(fa)),
			"az": Vector2(sin(fa), cos(fa)),
			"x0": float(prof.get("x_min", -cdef.real_size * 0.5)) * sj,
			"x1": float(prof.get("x_max", cdef.real_size * 0.5)) * sj,
			"z0": float(prof.get("z_min", -cdef.depth * 0.5)) * sj,
			"z1": float(prof.get("z_max", cdef.depth * 0.5)) * sj,
		})
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	var keepout_rejects := 0
	var cluster_total := 0
	var face_cluster_total := 0

	# Item 2: this map's average step height, so a fault's boulder count scales with how tall
	# its face is RELATIVE to the others (self-calibrating -- no absolute height constant).
	var step_sum := 0.0
	var step_n := 0
	for f in cliff_features:
		if f.has("step_height"):
			step_sum += absf(float(f.step_height))
			step_n += 1
	var mean_step := step_sum / float(step_n) if step_n > 0 else 1.0

	for feature in cliff_features:
		# Only the single-sided-step archetypes (ESCARPMENT/TERRACE/GENTLE_RISE)
		# get cliff-foot talus here -- V_RAVINE (symmetric, two walls, no one
		# "low side") and KNOLL (radial, not a fault line at all) don't fit
		# this foot-of-the-face placement at all. Proper talus for those (plus
		# the concave-upward accumulation profile and independent floor-
		# scattered glacial erratics) is a separate, dedicated rework -- see
		# the task list -- not a gap introduced here.
		if not feature.has("step_height"):
			continue
		var half_len: float = feature.half_len
		var axis_x: float = feature.axis_x
		var axis_z: float = feature.axis_z
		var perp_x: float = feature.perp_x
		var perp_z: float = feature.perp_z
		var step_height: float = feature.step_height
		var center: Vector2 = feature.center
		var curve_amplitude: float = feature.curve_amplitude
		var curve_frequency: float = feature.curve_frequency
		var curve_phase: float = feature.curve_phase
		var curve_frequency2: float = feature.curve_frequency2
		var curve_phase2: float = feature.curve_phase2
		var curve_weight2: float = feature.curve_weight2
		var edge_softness: float = feature.edge_softness

		# The face's "low" side is whichever side of d=0 does NOT get the
		# step_height boost added in _add_cliff_features -- see that
		# function's `face`/`local_height` comment. Boulders belong at the
		# foot of the drop, i.e. just past the face on that low side.
		var low_side_sign := -1.0 if step_height > 0.0 else 1.0

		var length_units := half_len * 2.0
		# Item 2: count scales with this face's height relative to the map's average step.
		var step_factor := clampf(absf(step_height) / maxf(mean_step, 0.001), BOULDER_STEP_FACTOR_MIN, BOULDER_STEP_FACTOR_MAX)
		var count_cap := maxi(BOULDER_MIN_PER_FEATURE, int(round(BOULDER_MAX_PER_FEATURE * step_factor)))
		var count := clampi(BOULDER_MIN_PER_FEATURE + int(length_units / BOULDER_PER_FEATURE_LENGTH_DIVISOR * step_factor), BOULDER_MIN_PER_FEATURE, count_cap)
		var usable_half_len := half_len * (1.0 - BOULDER_END_INSET_FRACTION)

		# Item 2: rockfall centres along this fault, biased under the cliff meshes sitting on it.
		var axis_v := Vector2(axis_x, axis_z)
		var perp_v := Vector2(perp_x, perp_z)
		var face_ts: Array[float] = []
		for kr in keep_rects:
			var rel: Vector2 = kr.c - center
			var t_e := rel.dot(axis_v)
			if absf(t_e) <= half_len and absf(rel.dot(perp_v)) <= BOULDER_FACE_MATCH_DIST:
				face_ts.append(t_e)
		var cluster_count := clampi(1 + int(length_units / BOULDER_CLUSTER_SPACING), 1, BOULDER_MAX_CLUSTERS_PER_FEATURE)
		var cluster_ts: Array[float] = []
		for c in cluster_count:
			var t0 := 0.0
			if not face_ts.is_empty() and rng.randf() < BOULDER_CLUSTER_FACE_BIAS:
				t0 = face_ts[rng.randi() % face_ts.size()] + rng.randf_range(-BOULDER_CLUSTER_SPREAD, BOULDER_CLUSTER_SPREAD)
				face_cluster_total += 1
			else:
				t0 = rng.randf_range(-usable_half_len, usable_half_len)
			cluster_ts.append(clampf(t0, -usable_half_len, usable_half_len))
		cluster_total += cluster_count

		for i in count:
			var t := clampf(rng.randfn(cluster_ts[rng.randi() % cluster_ts.size()], BOULDER_CLUSTER_SPREAD), -usable_half_len, usable_half_len)
			# Item 3: size first -- it steers both this boulder's scale and how far out it lands.
			var size_u := rng.randf()
			var size_scale := lerpf(BOULDER_SCALE_MIN, BOULDER_SCALE_MAX, size_u)
			# Same curve_offset formula _add_cliff_features itself uses to bend
			# the fault line -- without this, a fixed straight-line `d` offset
			# can still land ON the (curved) face instead of past it, which is
			# what was placing boulders half-buried into the cliff.
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)
			var lateral_jitter := rng.randf_range(-BOULDER_LATERAL_JITTER, BOULDER_LATERAL_JITTER)

			# Retry farther from the face if the sampled spot is still steep, OR
			# still inside the road's graded corridor (road_weight > 0 -- see
			# _generate_road) -- guards against curve wobble near the tips,
			# ordinary rolling terrain slope near the foot, AND a cliff foot that
			# happens to sit where the road grading flattened/regraded it, rather
			# than trusting a single fixed offset to always land on flat,
			# road-free ground. Candidate XZ is clamped into the actual generated
			# heightmap bounds ([0,width-1]x[0,length-1]) BEFORE sampling --
			# without this, a foot offset that pushes past the map edge (more
			# likely now that features get placed close to the wall/rim, near
			# the edge) would sample _sample_height_bilinear's internal edge
			# clamp for height while the boulder's WORLD position still sits
			# beyond the actual terrain region -- exactly what was placing
			# boulders floating in empty space past the generated ground.
			var px := 0.0
			var pz := 0.0
			var height := 0.0
			var normal := Vector3.UP
			var found_clear_spot := false
			for attempt in BOULDER_MAX_PLACEMENT_ATTEMPTS:
				# Concave-upward talus accumulation: bias the roll toward the near
				# (MIN) end of the band so boulders pile up close to the face and
				# thin out with distance, instead of scattering evenly across the
				# whole band -- see BOULDER_TALUS_DENSITY_EXPONENT.
				# Item 3: bigger rocks pulled toward the far end of the band (fall sorting).
				var talus_t := lerpf(pow(rng.randf(), BOULDER_TALUS_DENSITY_EXPONENT), size_u, BOULDER_SIZE_SORTING)
				var margin := edge_softness + BOULDER_FOOT_MARGIN_MIN + attempt * BOULDER_FOOT_MARGIN_STEP_BACK \
					+ talus_t * (BOULDER_FOOT_MARGIN_MAX - BOULDER_FOOT_MARGIN_MIN)
				var d := low_side_sign * margin + curve_offset + lateral_jitter
				px = clampf(center.x + t * axis_x + d * perp_x, 0.0, float(width - 1))
				pz = clampf(center.y + t * axis_z + d * perp_z, 0.0, float(length - 1))
				height = _sample_height_bilinear(heights, width, length, px, pz)
				normal = _sample_normal(heights, width, length, px, pz)
				var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
				var on_road := road_weight[sample_idx] > 0.0
				if normal.y >= BOULDER_MAX_SLOPE_NORMAL_Y and not on_road:
					if _boulder_blocked(px, pz, BOULDER_KEEPOUT_RADIUS * size_scale, keep_rects, keep_circles):
						keepout_rejects += 1 # item 1: inside a cliff mesh / outcrop -- retry farther out
					else:
						found_clear_spot = true
						break
				# else: loop retries one step farther out.

			if not found_clear_spot:
				# Never found a spot that's both flat enough and clear of the
				# road within BOULDER_MAX_PLACEMENT_ATTEMPTS -- skip this one
				# boulder rather than force it onto the road or a steep face.
				continue

			var boulder_pos := Vector3(import_position.x + px, height - BOULDER_EMBED_DEPTH, import_position.z + pz)
			var align := Quaternion(Vector3.UP, normal)
			var spin := Quaternion(normal, rng.randf_range(0.0, TAU))
			var mesh_id: int = ROCK_MESH_IDS[rng.randi() % ROCK_MESH_IDS.size()]
			var boulder_scale: float = size_scale * float(ROCK_BASE_SCALE[mesh_id]) # item 3: size rolled up front
			var boulder_basis := Basis(spin * align).scaled(Vector3.ONE * boulder_scale)

			transforms_by_mesh[mesh_id].append(Transform3D(boulder_basis, boulder_pos))
			_rock_keep_circles.append(Vector3(px, pz, BOULDER_KEEPOUT_RADIUS * boulder_scale))
			colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
			talus_total += 1

			var shape: Shape3D = rock_shapes.get(mesh_id)
			if shape:
				var body := StaticBody3D.new()
				body.name = "Boulder%d" % collider_count
				collider_container.add_child(body)
				body.transform = Transform3D(boulder_basis, boulder_pos)

				var col := CollisionShape3D.new()
				col.name = "CollisionShape3D"
				col.shape = shape
				body.add_child(col)

				collider_count += 1

	var talus_count := talus_total

	# Independent glacial-erratic scatter -- unrelated to any cliff feature
	# (see ERRATIC_* consts above). Candidates are drawn straight from the
	# valley floor zone, reusing _zone_pixel_range/_clamp_range_for_reach the
	# same way feature placement keeps footprints off the map edge, then
	# rejected/retried if too steep or on the road -- same idea as the talus
	# loop above, but with its own looser attempt budget, stricter flatness
	# requirement, and bigger scale range (a lone erratic reads as one
	# dramatic dropped boulder, not a pile of cliff debris).
	# Scale the base 256x256-calibrated count range by actual map area so
	# erratic density (not just a flat headcount) stays constant as
	# AREA_WIDTH/AREA_LENGTH change -- same reasoning as FEATURE_DENSITY.
	var erratic_area_scale := (float(width) * float(length)) / ERRATIC_DENSITY_BASE_AREA
	var erratic_count_min := maxi(1, int(round(ERRATIC_COUNT_MIN_BASE * erratic_area_scale)))
	var erratic_count_max := maxi(erratic_count_min, int(round(ERRATIC_COUNT_MAX_BASE * erratic_area_scale)))
	var erratic_roll_count := rng.randi_range(erratic_count_min, erratic_count_max)
	var floor_x_range := _zone_pixel_range("floor", width, rng)
	var floor_x := _clamp_range_for_reach(floor_x_range.x, floor_x_range.y, ERRATIC_REACH, float(width - 1))
	var floor_z := _clamp_range_for_reach(float(length) * 0.05, float(length) * 0.95, ERRATIC_REACH, float(length - 1))

	for i in erratic_roll_count:
		var found_clear_spot := false
		var px := 0.0
		var pz := 0.0
		var height := 0.0
		var normal := Vector3.UP
		for attempt in ERRATIC_MAX_PLACEMENT_ATTEMPTS:
			px = rng.randf_range(minf(floor_x.x, floor_x.y), maxf(floor_x.x, floor_x.y))
			pz = rng.randf_range(minf(floor_z.x, floor_z.y), maxf(floor_z.x, floor_z.y))
			height = _sample_height_bilinear(heights, width, length, px, pz)
			normal = _sample_normal(heights, width, length, px, pz)
			var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
			var on_road := road_weight[sample_idx] > 0.0
			if normal.y >= ERRATIC_MAX_SLOPE_NORMAL_Y and not on_road:
				# item 1: erratic scale isn't rolled yet -- check against the largest it can be
				if _boulder_blocked(px, pz, BOULDER_KEEPOUT_RADIUS * ERRATIC_SCALE_MAX, keep_rects, keep_circles):
					keepout_rejects += 1
				else:
					found_clear_spot = true
					break

		if not found_clear_spot:
			continue

		var erratic_pos := Vector3(import_position.x + px, height - BOULDER_EMBED_DEPTH, import_position.z + pz)
		var erratic_align := Quaternion(Vector3.UP, normal)
		var erratic_spin := Quaternion(normal, rng.randf_range(0.0, TAU))
		var mesh_id: int = ROCK_MESH_IDS[rng.randi() % ROCK_MESH_IDS.size()]
		var erratic_scale: float = rng.randf_range(ERRATIC_SCALE_MIN, ERRATIC_SCALE_MAX) * float(ROCK_BASE_SCALE[mesh_id])
		var erratic_basis := Basis(erratic_spin * erratic_align).scaled(Vector3.ONE * erratic_scale)

		transforms_by_mesh[mesh_id].append(Transform3D(erratic_basis, erratic_pos))
		_rock_keep_circles.append(Vector3(px, pz, BOULDER_KEEPOUT_RADIUS * erratic_scale))
		colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
		erratic_total += 1

		var shape: Shape3D = rock_shapes.get(mesh_id)
		if shape:
			var body := StaticBody3D.new()
			body.name = "Boulder%d" % collider_count
			collider_container.add_child(body)
			body.transform = Transform3D(erratic_basis, erratic_pos)

			var col := CollisionShape3D.new()
			col.name = "CollisionShape3D"
			col.shape = shape
			body.add_child(col)

			collider_count += 1

	var erratic_count := erratic_total
	var total_count := talus_count + erratic_count

	if total_count == 0:
		print("TERRAIN_GEN: no boulders scattered (no cliff features placed, no erratics found a clear spot)")
		return

	for mesh_id in ROCK_MESH_IDS:
		if not transforms_by_mesh[mesh_id].is_empty():
			instancer.add_transforms(mesh_id, transforms_by_mesh[mesh_id], colors_by_mesh[mesh_id], true)

	print("TERRAIN_GEN: scattered %d talus boulder(s) + %d glacial erratic(s) = %d total (%d with collision) along %d cliff feature(s)" % [talus_count, erratic_count, total_count, collider_count, cliff_features.size()])
	print("TERRAIN_GEN_DEBUG boulders -- %d rockfall centre(s) (%d under a cliff mesh), %d spot(s) rejected by cliff/outcrop keep-outs, mean step %.2f" % [cluster_total, face_cluster_total, keepout_rejects, mean_step])

## Scree layer -- a dense, collider-free debris carpet at each cliff foot,
## layered under the boulders. Deliberately mirrors _scatter_boulders' talus
## loop (same cliff_features fault data, same keep-out rects/circles, same
## road_weight + slope-normal rejection, same ground-aligned + random-yaw
## basis and height-embed) so scree lands exactly where the boulders' talus
## does -- only far denser, in a tighter near-face band, tolerating steeper
## ground, drawn from the fist/gravel scree pools, and with NO StaticBody
## colliders built (scree is cosmetic; the terrain collider carries the
## ground). Same timing contract as _scatter_boulders: after import_images(),
## before save_directory().
func _scatter_scree(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, cliff_features: Array[Dictionary], import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	for mesh_id in SCREE_MESH_IDS:
		instancer.clear_by_mesh(mesh_id)

	# Keep-outs: identical construction to _scatter_boulders (cliff meshes as
	# rotated boxes in their own scanned local bounds, outcrops as circles).
	var keep_rects: Array[Dictionary] = []
	var cliff_defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		cliff_defs_by_name[def.name] = def
	for entry in cliff_plan:
		var cdef = cliff_defs_by_name.get(entry.def_name)
		if cdef == null:
			continue
		var prof: Dictionary = cliff_top_profiles.get(entry.def_name, {})
		var sj: float = entry.scale_jitter
		var fa: float = entry.face_angle
		keep_rects.append({
			"c": Vector2(entry.px, entry.pz),
			"ax": Vector2(cos(fa), -sin(fa)),
			"az": Vector2(sin(fa), cos(fa)),
			"x0": float(prof.get("x_min", -cdef.real_size * 0.5)) * sj,
			"x1": float(prof.get("x_max", cdef.real_size * 0.5)) * sj,
			"z0": float(prof.get("z_min", -cdef.depth * 0.5)) * sj,
			"z1": float(prof.get("z_max", cdef.depth * 0.5)) * sj,
		})
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))

	# Same self-calibrating mean step height as the boulder pass.
	var step_sum := 0.0
	var step_n := 0
	for f in cliff_features:
		if f.has("step_height"):
			step_sum += absf(float(f.step_height))
			step_n += 1
	var mean_step := step_sum / float(step_n) if step_n > 0 else 1.0

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for mesh_id in SCREE_MESH_IDS:
		transforms_by_mesh[mesh_id] = [] as Array[Transform3D]
		colors_by_mesh[mesh_id] = PackedColorArray()
	var scree_total := 0

	for feature in cliff_features:
		# Same archetype subset as _scatter_boulders (single-sided step faces only).
		if not feature.has("step_height"):
			continue
		var half_len: float = feature.half_len
		var axis_x: float = feature.axis_x
		var axis_z: float = feature.axis_z
		var perp_x: float = feature.perp_x
		var perp_z: float = feature.perp_z
		var step_height: float = feature.step_height
		var center: Vector2 = feature.center
		var curve_amplitude: float = feature.curve_amplitude
		var curve_frequency: float = feature.curve_frequency
		var curve_phase: float = feature.curve_phase
		var curve_frequency2: float = feature.curve_frequency2
		var curve_phase2: float = feature.curve_phase2
		var curve_weight2: float = feature.curve_weight2
		var edge_softness: float = feature.edge_softness

		var low_side_sign := -1.0 if step_height > 0.0 else 1.0
		var length_units := half_len * 2.0
		var step_factor := clampf(absf(step_height) / maxf(mean_step, 0.001), BOULDER_STEP_FACTOR_MIN, BOULDER_STEP_FACTOR_MAX)
		var count_cap := maxi(SCREE_MIN_PER_FEATURE, int(round(SCREE_MAX_PER_FEATURE * step_factor)))
		var count := clampi(SCREE_MIN_PER_FEATURE + int(length_units / SCREE_PER_FEATURE_LENGTH_DIVISOR * step_factor), SCREE_MIN_PER_FEATURE, count_cap)
		var usable_half_len := half_len * (1.0 - SCREE_END_INSET_FRACTION)

		for i in count:
			var t := rng.randf_range(-usable_half_len, usable_half_len)
			var size_u := rng.randf()
			var size_scale := lerpf(SCREE_SCALE_MIN, SCREE_SCALE_MAX, size_u)
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)
			var lateral_jitter := rng.randf_range(-SCREE_LATERAL_JITTER, SCREE_LATERAL_JITTER)

			var px := 0.0
			var pz := 0.0
			var height := 0.0
			var normal := Vector3.UP
			var found_clear_spot := false
			for attempt in SCREE_MAX_PLACEMENT_ATTEMPTS:
				# Concave-upward pile-up, even stronger than the boulder talus.
				var talus_t := pow(rng.randf(), SCREE_TALUS_DENSITY_EXPONENT)
				var margin := edge_softness + SCREE_FOOT_MARGIN_MIN + attempt * SCREE_FOOT_MARGIN_STEP_BACK \
					+ talus_t * (SCREE_FOOT_MARGIN_MAX - SCREE_FOOT_MARGIN_MIN)
				var d := low_side_sign * margin + curve_offset + lateral_jitter
				px = clampf(center.x + t * axis_x + d * perp_x, 0.0, float(width - 1))
				pz = clampf(center.y + t * axis_z + d * perp_z, 0.0, float(length - 1))
				height = _sample_height_bilinear(heights, width, length, px, pz)
				normal = _sample_normal(heights, width, length, px, pz)
				var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
				var on_road := road_weight[sample_idx] > 0.0
				if normal.y >= SCREE_MAX_SLOPE_NORMAL_Y and not on_road:
					if not _boulder_blocked(px, pz, SCREE_KEEPOUT_RADIUS * size_scale, keep_rects, keep_circles):
						found_clear_spot = true
						break
				# else: retry one step farther out.

			if not found_clear_spot:
				continue

			var pos := Vector3(import_position.x + px, height - SCREE_EMBED_DEPTH, import_position.z + pz)
			var align := Quaternion(Vector3.UP, normal)
			var spin := Quaternion(normal, rng.randf_range(0.0, TAU))
			# Weighted pool pick: mostly fine gravel, a scatter of larger chips.
			var mesh_id: int
			if rng.randf() < SCREE_GRAVEL_FRACTION:
				mesh_id = SCREE_GRAVEL_MESH_IDS[rng.randi() % SCREE_GRAVEL_MESH_IDS.size()]
			else:
				mesh_id = SCREE_FIST_MESH_IDS[rng.randi() % SCREE_FIST_MESH_IDS.size()]
			var basis := Basis(spin * align).scaled(Vector3.ONE * size_scale)
			transforms_by_mesh[mesh_id].append(Transform3D(basis, pos))
			colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
			scree_total += 1

	for mesh_id in SCREE_MESH_IDS:
		if not transforms_by_mesh[mesh_id].is_empty():
			instancer.add_transforms(mesh_id, transforms_by_mesh[mesh_id], colors_by_mesh[mesh_id], true)

	print("TERRAIN_GEN: scattered %d scree stone(s) across %d cliff feature(s)" % [scree_total, cliff_features.size()])

## Canopy tree scatter -- see the TREE_* const block for the design. Floor-based
## clumped stands, upright, gameplay-range trunk colliders. Same timing contract
## as _scatter_boulders/_scatter_scree: after import_images(), before anything
## reads the finished Terrain3D.
func _scatter_trees(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, road_path: PackedVector2Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	# Only scatter tree ids actually registered as mesh assets -- lets the canopy
	# work with however many variants are imported so far (e.g. fir only, before
	# pine is exported) instead of erroring on a missing id.
	var assets: Terrain3DAssets = terrain.get_assets()
	var active_ids: Array[int] = []
	for id in TREE_MESH_IDS:
		if assets and assets.get_mesh_asset(id) != null:
			active_ids.append(id)
	# Clear this run's tree instances before re-scattering.
	for id in TREE_IDS_FAB_PACK:
		instancer.clear_by_mesh(id)
	if active_ids.is_empty():
		print("TERRAIN_GEN: no tree mesh assets registered (ids %s) -- skipping canopy scatter" % str(TREE_MESH_IDS))
		return

	# Runtime trunk-collider container -- same off-tree deferred-attach pattern as
	# the boulder colliders (avoids "parent busy setting up children").
	var parent := get_parent()
	var old_container := parent.get_node_or_null(TREE_COLLIDER_CONTAINER_NAME)
	if old_container:
		old_container.queue_free()
	var collider_container := Node3D.new()
	collider_container.name = TREE_COLLIDER_CONTAINER_NAME
	parent.add_child.call_deferred(collider_container)

	# Keep-outs: identical construction to _scatter_boulders / _scatter_scree.
	var keep_rects: Array[Dictionary] = []
	var cliff_defs_by_name: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		cliff_defs_by_name[def.name] = def
	for entry in cliff_plan:
		var cdef = cliff_defs_by_name.get(entry.def_name)
		if cdef == null:
			continue
		var prof: Dictionary = cliff_top_profiles.get(entry.def_name, {})
		var sj: float = entry.scale_jitter
		var fa: float = entry.face_angle
		keep_rects.append({
			"c": Vector2(entry.px, entry.pz),
			"ax": Vector2(cos(fa), -sin(fa)),
			"az": Vector2(sin(fa), cos(fa)),
			"x0": float(prof.get("x_min", -cdef.real_size * 0.5)) * sj,
			"x1": float(prof.get("x_max", cdef.real_size * 0.5)) * sj,
			"z0": float(prof.get("z_min", -cdef.depth * 0.5)) * sj,
			"z1": float(prof.get("z_max", cdef.depth * 0.5)) * sj,
		})
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	# Boulders/erratics placed earlier this run (see _rock_keep_circles) -- no trunks through rocks.
	keep_circles.append_array(_rock_keep_circles)

	# Tree band (see TREE_X_BAND_* / TREE_Z_BAND_*), pulled in by TREE_REACH at the map edges.
	var floor_x := _clamp_range_for_reach(float(width) * TREE_X_BAND_MIN, float(width) * TREE_X_BAND_MAX, TREE_REACH, float(width - 1))
	var floor_z := _clamp_range_for_reach(float(length) * TREE_Z_BAND_MIN, float(length) * TREE_Z_BAND_MAX, TREE_REACH, float(length - 1))
	var fx_lo := minf(floor_x.x, floor_x.y)
	var fx_hi := maxf(floor_x.x, floor_x.y)
	var fz_lo := minf(floor_z.x, floor_z.y)
	var fz_hi := maxf(floor_z.x, floor_z.y)

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for id in active_ids:
		transforms_by_mesh[id] = [] as Array[Transform3D]
		colors_by_mesh[id] = PackedColorArray()

	var area_scale := (float(width) * float(length)) / TREE_DENSITY_BASE_AREA
	var stand_count := maxi(1, int(round(rng.randf_range(TREE_STAND_COUNT_MIN_BASE, TREE_STAND_COUNT_MAX_BASE) * area_scale)))
	var lone_count := maxi(0, int(round(rng.randf_range(TREE_LONE_COUNT_MIN_BASE, TREE_LONE_COUNT_MAX_BASE) * area_scale)))
	var tree_total := 0

	# Stand centres: each is the best of TREE_STAND_SPACING_CANDIDATES candidates -- the one
	# farthest from the stands already placed (evens out coverage, fewer big random voids).
	# Each candidate itself is still the lowest of TREE_STAND_LOWGROUND_SAMPLES points.
	# SPACING_CANDIDATES = 1 reproduces the old pure-random layout exactly (same rng draws).
	var stand_centres: Array[Vector2] = []
	for s in stand_count:
		var pick := Vector2.ZERO
		var pick_gap := -1.0
		for c in maxi(TREE_STAND_SPACING_CANDIDATES, 1):
			var best := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
			var best_h := _sample_height_bilinear(heights, width, length, best.x, best.y)
			for extra in (TREE_STAND_LOWGROUND_SAMPLES - 1):
				var cand := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
				var ch := _sample_height_bilinear(heights, width, length, cand.x, cand.y)
				if ch < best_h:
					best = cand
					best_h = ch
			# distance to the nearest stand placed so far (first stand: any candidate is fine)
			var gap := INF
			for sc in stand_centres:
				gap = minf(gap, best.distance_to(sc))
			if gap > pick_gap:
				pick = best
				pick_gap = gap
		stand_centres.append(pick)

	# DEBUG: keep what the placement checks use, for debug_tree_probe() (PerfDebug key T).
	_tree_debug = {
		"heights": heights, "width": width, "length": length, "import_position": import_position,
		"road_weight": road_weight, "keep_rects": keep_rects, "keep_circles": keep_circles,
		"fx_lo": fx_lo, "fx_hi": fx_hi, "fz_lo": fz_lo, "fz_hi": fz_hi,
		"stand_centres": stand_centres, "lone_count": lone_count,
	}

	for centre in stand_centres:
		var per := rng.randi_range(TREE_PER_STAND_MIN, TREE_PER_STAND_MAX)
		for i in per:
			var target := Vector2(rng.randfn(centre.x, TREE_STAND_SPREAD), rng.randfn(centre.y, TREE_STAND_SPREAD))
			if _place_one_tree(target, heights, width, length, import_position, rng, road_weight, keep_rects, keep_circles, fx_lo, fx_hi, fz_lo, fz_hi, active_ids, transforms_by_mesh, colors_by_mesh, road_path, collider_container):
				tree_total += 1

	for i in lone_count:
		var target := Vector2(rng.randf_range(fx_lo, fx_hi), rng.randf_range(fz_lo, fz_hi))
		if _place_one_tree(target, heights, width, length, import_position, rng, road_weight, keep_rects, keep_circles, fx_lo, fx_hi, fz_lo, fz_hi, active_ids, transforms_by_mesh, colors_by_mesh, road_path, collider_container):
			tree_total += 1

	for id in active_ids:
		if not transforms_by_mesh[id].is_empty():
			instancer.add_transforms(id, transforms_by_mesh[id], colors_by_mesh[id], true)

	print("TERRAIN_GEN: scattered %d tree(s) across %d stand(s) + %d lone (%d with trunk colliders, %d variant id(s) active)" % [tree_total, stand_count, lone_count, collider_container.get_child_count(), active_ids.size()])

## Places one upright tree at (or near) `target` pixel spot: retries a few times
## on steep / on-road / keep-out-blocked ground, and on success appends an
## upright (yaw + tiny lean, never normal-aligned) transform to the per-mesh
## batch and builds a StaticBody trunk cylinder (every tree). Returns true if a
## tree was placed. (Mutates transforms_by_mesh / colors_by_mesh /
## collider_container by reference.) `road_path` is currently unused -- kept
## in the signature from the removed road-range collider gate.
func _place_one_tree(target: Vector2, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, keep_rects: Array[Dictionary], keep_circles: Array[Vector3], fx_lo: float, fx_hi: float, fz_lo: float, fz_hi: float, active_ids: Array[int], transforms_by_mesh: Dictionary, colors_by_mesh: Dictionary, road_path: PackedVector2Array, collider_container: Node3D) -> bool:
	var scale := rng.randf_range(TREE_SCALE_MIN, TREE_SCALE_MAX)
	var px := 0.0
	var pz := 0.0
	var height := 0.0
	var normal := Vector3.UP
	var found := false
	for attempt in TREE_MAX_PLACEMENT_ATTEMPTS:
		var jx := 0.0 if attempt == 0 else rng.randf_range(-TREE_STAND_SPREAD, TREE_STAND_SPREAD)
		var jz := 0.0 if attempt == 0 else rng.randf_range(-TREE_STAND_SPREAD, TREE_STAND_SPREAD)
		px = clampf(target.x + jx, fx_lo, fx_hi)
		pz = clampf(target.y + jz, fz_lo, fz_hi)
		height = _sample_height_bilinear(heights, width, length, px, pz)
		normal = _sample_normal(heights, width, length, px, pz)
		var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
		var on_road := road_weight[sample_idx] > 0.0
		if normal.y >= TREE_MAX_SLOPE_NORMAL_Y and not on_road:
			if not _boulder_blocked(px, pz, TREE_KEEPOUT_RADIUS * scale, keep_rects, keep_circles):
				found = true
				break
	if not found:
		return false

	var tree_pos := Vector3(import_position.x + px, height - TREE_EMBED_DEPTH, import_position.z + pz)
	# Upright: random yaw + a tiny lean, never normal-aligned.
	var yaw := rng.randf() * TAU
	var basis := Basis(Vector3.UP, yaw)
	var lean := deg_to_rad(rng.randf_range(0.0, TREE_LEAN_MAX_DEG))
	if lean > 0.0001:
		var la := rng.randf() * TAU
		var lean_axis := Vector3(cos(la), 0.0, sin(la))
		basis = Basis(lean_axis, lean) * basis
	var mesh_id: int = active_ids[rng.randi() % active_ids.size()]
	var tree_basis := basis.scaled(Vector3.ONE * scale)
	transforms_by_mesh[mesh_id].append(Transform3D(tree_basis, tree_pos))
	colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))

	# Every tree gets a trunk collider -- a StaticBody + upright cylinder is
	# cheap (Jolt handles a few hundred trivially), and gating by road distance
	# left trees the player walks up to off-road with no collision. Collide all.
	var body := StaticBody3D.new()
	body.name = "Tree%d" % collider_container.get_child_count()
	collider_container.add_child(body)
	body.transform = Transform3D(Basis(), tree_pos) # upright, unscaled
	var cyl := CylinderShape3D.new()
	cyl.radius = TREE_TRUNK_RADIUS * scale
	cyl.height = TREE_TRUNK_HEIGHT * scale
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = cyl
	col.position = Vector3(0.0, cyl.height * 0.5, 0.0)
	body.add_child(col)
	return true

## DEBUG (2026-09-24): re-runs _place_one_tree's checks at a world position and says
## which pass/fail, plus where the nearest stand centres are. Called by PerfDebug key T.
func debug_tree_probe(world_pos: Vector3) -> String:
	if _tree_debug.is_empty():
		return "[TreeProbe] no tree scatter data (did _scatter_trees run this session?)"
	var d := _tree_debug
	var heights: PackedFloat32Array = d.heights
	var width: int = d.width
	var length: int = d.length
	var imp: Vector3 = d.import_position
	var road_weight: PackedFloat32Array = d.road_weight
	var keep_rects: Array[Dictionary] = d.keep_rects
	var keep_circles: Array[Vector3] = d.keep_circles
	var px := world_pos.x - imp.x
	var pz := world_pos.z - imp.z
	var lines: Array[String] = []
	lines.append("[TreeProbe] world (%.1f, %.1f) -> pixel (%.1f, %.1f)" % [world_pos.x, world_pos.z, px, pz])
	var fails: Array[String] = []

	var in_x: bool = px >= d.fx_lo and px <= d.fx_hi
	var in_z: bool = pz >= d.fz_lo and pz <= d.fz_hi
	lines.append("  zone x (TREE_X_BAND %.0f%%-%.0f%%) %.1f..%.1f: %s" % [TREE_X_BAND_MIN * 100.0, TREE_X_BAND_MAX * 100.0, d.fx_lo, d.fx_hi, "PASS" if in_x else "FAIL -- outside the tree band (x)"])
	lines.append("  zone z (TREE_Z_BAND %.0f%%-%.0f%%) %.1f..%.1f: %s" % [TREE_Z_BAND_MIN * 100.0, TREE_Z_BAND_MAX * 100.0, d.fz_lo, d.fz_hi, "PASS" if in_z else "FAIL -- outside the tree band (z)"])
	if not in_x: fails.append("zone x")
	if not in_z: fails.append("zone z")

	var cpx := clampf(px, 0.0, float(width - 1))
	var cpz := clampf(pz, 0.0, float(length - 1))
	var h := _sample_height_bilinear(heights, width, length, cpx, cpz)
	var n := _sample_normal(heights, width, length, cpx, cpz)
	var slope_ok := n.y >= TREE_MAX_SLOPE_NORMAL_Y
	lines.append("  slope: normal.y %.3f (%.1f deg), need >= %.2f (%.1f deg max): %s" % [n.y, rad_to_deg(acos(clampf(n.y, -1.0, 1.0))), TREE_MAX_SLOPE_NORMAL_Y, rad_to_deg(acos(TREE_MAX_SLOPE_NORMAL_Y)), "PASS" if slope_ok else "FAIL -- too steep"])
	if not slope_ok: fails.append("slope")

	var idx := clampi(int(round(cpz)), 0, length - 1) * width + clampi(int(round(cpx)), 0, width - 1)
	var on_road := road_weight[idx] > 0.0
	lines.append("  road: weight %.2f: %s" % [road_weight[idx], "FAIL -- on the road" if on_road else "PASS"])
	if on_road: fails.append("road")

	var blocked := _boulder_blocked(cpx, cpz, TREE_KEEPOUT_RADIUS, keep_rects, keep_circles)
	lines.append("  rock keep-outs (cliffs / outcrops / boulders, scale 1.0): %s" % ["FAIL -- inside a keep-out" if blocked else "PASS"])
	if blocked: fails.append("keep-out")

	var centres: Array[Vector2] = d.stand_centres
	var nearest := INF
	var close := 0
	for c in centres:
		var dist := Vector2(px, pz).distance_to(c)
		nearest = minf(nearest, dist)
		if dist <= TREE_STAND_SPREAD * 2.0:
			close += 1
	lines.append("  stands: %d total, nearest centre %.1f m away, %d within %.0f m (2x spread); %d lone trees map-wide; ground height here %.1f" % [centres.size(), nearest, close, TREE_STAND_SPREAD * 2.0, d.lone_count, h])

	if fails.is_empty():
		if close == 0:
			lines.append("  VERDICT: a tree COULD grow here, but no stand was aimed nearby -- empty by chance (only lone trees could land here)")
		else:
			lines.append("  VERDICT: a tree could grow here and a stand is nearby -- nearby trees likely failed their own spot checks")
	else:
		lines.append("  VERDICT: no tree can grow at this exact spot -- failing: %s" % ", ".join(fails))
	return "\n".join(lines)

## Item 1 keep-out test (pixel space): true if a rock of `radius` at (px, pz) overlaps a cliff
## mesh's rotated local footprint (+ BOULDER_KEEPOUT_MARGIN) or an outcrop's bounding circle.
func _boulder_blocked(px: float, pz: float, radius: float, keep_rects: Array[Dictionary], keep_circles: Array[Vector3]) -> bool:
	var p := Vector2(px, pz)
	var pad := radius + BOULDER_KEEPOUT_MARGIN
	for kr in keep_rects:
		var d: Vector2 = p - kr.c
		var lx := d.dot(kr.ax)
		var lz := d.dot(kr.az)
		if lx >= float(kr.x0) - pad and lx <= float(kr.x1) + pad and lz >= float(kr.z0) - pad and lz <= float(kr.z1) + pad:
			return true
	for kc in keep_circles:
		if p.distance_to(Vector2(kc.x, kc.y)) < kc.z + pad:
			return true
	return false

## Sums every vertex normal under `node` (same transform folding as
## _collect_mesh_vertices_recursive) -- a scanned rock shell's summed normal points out of its
## textured face, which is how _scatter_outcrops knows which side to lay facing up.
func _sum_mesh_normals_recursive(node: Node, parent_transform: Transform3D) -> Vector3:
	var local_transform := parent_transform
	if node is Node3D:
		local_transform = parent_transform * (node as Node3D).transform
	var total := Vector3.ZERO
	if node is MeshInstance3D:
		var mesh_inst: MeshInstance3D = node
		if mesh_inst.mesh:
			for surface_idx in mesh_inst.mesh.get_surface_count():
				var arrays := mesh_inst.mesh.surface_get_arrays(surface_idx)
				var normals = arrays[Mesh.ARRAY_NORMAL]
				if normals is PackedVector3Array:
					for n in normals:
						total += local_transform.basis * n
	for child in node.get_children():
		total += _sum_mesh_normals_recursive(child, local_transform)
	return total

## 2026-09-20 (Kirill: mountainside "looks very out of place" as a cliff face -> "out of cliff
## system, random along with boulders"). Lays each OUTCROP_DEFS model FLAT -- rotated so its
## textured face (summed vertex normal) points straight up and the open back of the scan faces
## the ground -- then scatters a few across the valley floor like the glacial erratics in
## _scatter_boulders: random floor spot, random yaw/scale, rejected if too steep, too uneven
## under the footprint, on the road, or too close to a cliff-dressing placement / another
## outcrop. Seated on the LOWEST ground under its footprint (so no edge floats) and sunk by
## OUTCROP_SINK_FRACTION of its own thickness. (Round 1 left the terrain untouched -- round 2
## below conforms it to the rock.)
## 2026-09-20 round 2 ("the mesh's contour is uneven so there again are gaps between the mesh
## and the ground"): split into plan -> fit terrain -> instance, same shape as the cliff system,
## so the heightmap can be conformed to each rock BEFORE Terrain3D imports it and before the
## road is routed (outcrops go into the road obstacle mask instead of dodging road_weight).
##
## Loads each OUTCROP_DEFS model once: its laid-flat rotation, bounds, and an UNDERSIDE GRID --
## lowest laid-flat vertex Y per OUTCROP_UNDERSIDE_CELL cell (INF = no geometry). Unlike the
## standing cliff shells (where round 25's per-cell "lowest vertex" was a patch of face halfway
## up), a slab lying flat really does have its ground contact as its lowest geometry per cell.
func _load_outcrop_models() -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	for def in OUTCROP_DEFS:
		var scene: PackedScene = load(def.glb)
		if scene == null:
			push_warning("TERRAIN_GEN: could not load outcrop mesh %s -- skipping it" % def.glb)
			continue
		var sample := scene.instantiate()
		var verts := PackedVector3Array()
		_collect_mesh_vertices_recursive(sample, Transform3D.IDENTITY, verts)
		var face_dir := _sum_mesh_normals_recursive(sample, Transform3D.IDENTITY)
		sample.free()
		if verts.is_empty():
			continue
		face_dir = face_dir.normalized() if face_dir.length_squared() > 0.000001 else Vector3.BACK
		var lay_flat := Basis(Quaternion(face_dir, Vector3.UP))
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		var flat_verts := PackedVector3Array()
		flat_verts.resize(verts.size())
		for vi in verts.size():
			var tv := lay_flat * verts[vi]
			flat_verts[vi] = tv
			lo = lo.min(tv)
			hi = hi.max(tv)
		var nx := maxi(1, int(ceil((hi.x - lo.x) / OUTCROP_UNDERSIDE_CELL)))
		var nz := maxi(1, int(ceil((hi.z - lo.z) / OUTCROP_UNDERSIDE_CELL)))
		var under := PackedFloat32Array()
		under.resize(nx * nz)
		under.fill(INF)
		for tv in flat_verts:
			var cx := clampi(int((tv.x - lo.x) / OUTCROP_UNDERSIDE_CELL), 0, nx - 1)
			var cz := clampi(int((tv.z - lo.z) / OUTCROP_UNDERSIDE_CELL), 0, nz - 1)
			var ci := cz * nx + cx
			if tv.y < under[ci]:
				under[ci] = tv.y
		var filled := 0
		for u in under:
			if u < INF:
				filled += 1
		models.append({"def": def, "scene": scene, "lay_flat": lay_flat, "lo": lo, "hi": hi, "under": under, "nx": nx, "nz": nz})
		print("TERRAIN_GEN_DEBUG outcrop %s: face_dir=%s laid-flat size=%s underside grid %dx%d (%d%% filled)" % [def.name, face_dir, hi - lo, nx, nz, int(100.0 * filled / float(nx * nz))])
	return models

## Picks outcrop spots (pixel space) on the valley floor: random floor spot, yaw, scale;
## rejected if too steep, too uneven under the footprint, off the map, or too close to a
## cliff-dressing placement / another outcrop. Seat height = lowest ground under the
## footprint, minus OUTCROP_SINK_FRACTION of the slab's thickness; _fit_terrain_to_outcrops
## then raises the ground up to the rock wherever it still falls short.
func _plan_outcrops(models: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, cliff_plan: Array[Dictionary]) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	if models.is_empty():
		return plan

	# Cliff-dressing placements as keep-out circles (pixel space: x, z, radius).
	var cliff_sizes: Dictionary = {}
	for def in CLIFF_DRESSING_DEFS:
		cliff_sizes[def.name] = def.real_size
	var keep_out: Array[Vector3] = []
	for entry in cliff_plan:
		var r := float(cliff_sizes.get(entry.def_name, 10.0)) * 0.5 * float(entry.scale_jitter)
		keep_out.append(Vector3(entry.px, entry.pz, r))

	var area_scale := (float(width) * float(length)) / ERRATIC_DENSITY_BASE_AREA
	var count_min := maxi(1, int(round(OUTCROP_COUNT_MIN_BASE * area_scale)))
	var count_max := maxi(count_min, int(round(OUTCROP_COUNT_MAX_BASE * area_scale)))
	var roll_count := rng.randi_range(count_min, count_max)
	var floor_x_range := _zone_pixel_range("floor", width, rng)

	for i in roll_count:
		var model_idx := rng.randi() % models.size()
		var model: Dictionary = models[model_idx]
		var lo: Vector3 = model.lo
		var hi: Vector3 = model.hi
		for attempt in OUTCROP_MAX_PLACEMENT_ATTEMPTS:
			var s := rng.randf_range(OUTCROP_SCALE_MIN, OUTCROP_SCALE_MAX)
			var yaw := rng.randf_range(0.0, TAU)
			var yaw_basis := Basis(Vector3.UP, yaw)
			var radius := Vector2(maxf(absf(lo.x), absf(hi.x)), maxf(absf(lo.z), absf(hi.z))).length() * s
			var fx := _clamp_range_for_reach(floor_x_range.x, floor_x_range.y, radius + OUTCROP_FIT_FADE_MAX, float(width - 1))
			var fz := _clamp_range_for_reach(float(length) * 0.1, float(length) * 0.9, radius + OUTCROP_FIT_FADE_MAX, float(length - 1))
			var px := rng.randf_range(minf(fx.x, fx.y), maxf(fx.x, fx.y))
			var pz := rng.randf_range(minf(fz.x, fz.y), maxf(fz.x, fz.y))

			var blocked := false
			for k in keep_out:
				if Vector2(px - k.x, pz - k.y).length() < radius + k.z + OUTCROP_CLEARANCE:
					blocked = true
					break
			if blocked:
				continue
			if _sample_normal(heights, width, length, px, pz).y < OUTCROP_MAX_SLOPE_NORMAL_Y:
				continue

			# 5x5 grid over the rotated footprint: lowest/highest ground.
			var min_h := INF
			var max_h := -INF
			var ok := true
			for gz in 5:
				for gx in 5:
					var local := Vector3(lerpf(lo.x, hi.x, gx / 4.0), 0.0, lerpf(lo.z, hi.z, gz / 4.0)) * s
					var w := yaw_basis * local
					var sx := px + w.x
					var sz := pz + w.z
					if sx < 0.0 or sz < 0.0 or sx > float(width - 1) or sz > float(length - 1):
						ok = false
						break
					var h := _sample_height_bilinear(heights, width, length, sx, sz)
					min_h = minf(min_h, h)
					max_h = maxf(max_h, h)
				if not ok:
					break
			if not ok or max_h - min_h > OUTCROP_MAX_GROUND_SPREAD:
				continue

			var thickness := (hi.y - lo.y) * s
			var y := min_h - lo.y * s - thickness * OUTCROP_SINK_FRACTION
			plan.append({"model": model_idx, "px": px, "pz": pz, "yaw": yaw, "scale": s, "y": y, "radius": radius})
			keep_out.append(Vector3(px, pz, radius))
			break

	print("TERRAIN_GEN: planned %d/%d flat rock outcrop(s)" % [plan.size(), roll_count])
	return plan

## Raise-only: conforms the heightmap to each planned outcrop's real underside so its uneven
## contour meets the ground everywhere. Under the rock, each terrain pixel is lifted to just
## BELOW the lowest underside within ~0.75 pixel of it (OUTCROP_FIT_CLEARANCE below it) --
## below, not above, because a scanned shell's underside may be the very same surface as its
## textured face, so overlapping it would bury the face. MIN over the neighbourhood so the
## linearly-interpolated terrain between heightmap vertices never pokes up through the rock.
## Around the rock, a soil bank fades from the rim's target height back to natural ground over
## OUTCROP_FIT_FADE. Footprint pixels only ever take their OWN target (never a neighbour's
## fade), so the bank can't push terrain up through the slab either.
## Round 3 ("there is some terrain generated, but it doesn't reach the mesh, and it's spiky, I'd
## rather it be gentle"): round 2 took, per pixel, the MAX of a separate fade cone thrown out by
## every footprint pixel (-> star/ridge spikes), and aimed below the MIN underside nearby minus a
## clearance (-> fell short of the visible, often curled-up lip). Now edge-driven + smooth:
##   RIM   -- footprint pixels touching a non-footprint pixel. Target = local (mean) underside
##            + OUTCROP_RIM_TUCK, so the lip tucks INTO the ground; smoothed along the outline
##            (never lowered below its own target, so it always reaches).
##   BANK  -- outside the rock: inverse-distance-weighted blend of the NEAREST rim targets
##            (smooth, no per-pixel max), eased to natural ground with smoothstep over a width
##            that grows with the climb (lift / OUTCROP_BANK_SLOPE, clamped FADE_MIN..MAX).
##   UNDER -- inside the rock: the same smooth blend, capped at the MIN underside nearby minus
##            OUTCROP_FIT_CLEARANCE so it can never poke up through the slab.
## Raise-only throughout.
func _fit_terrain_to_outcrops(plan: Array[Dictionary], models: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int) -> void:
	var total_rim := 0
	var total_raised := 0
	var max_lift_all := 0.0
	var max_fade_used := 0.0
	# Round 5: pixels the smoothing pass must NOT touch (any outcrop's real footprint, incl. the
	# inset ring that climbs over the lip -- moving those re-opens the gaps rounds 3/4 closed),
	# and the raised bank pixels outside every footprint, which are the ones that may be relaxed.
	var pinned: Dictionary = {}
	var bank: Dictionary = {}
	for entry in plan:
		var m: Dictionary = models[entry.model]
		var s: float = entry.scale
		var px: float = entry.px
		var pz: float = entry.pz
		var seat_y: float = entry.y
		var r: float = entry.radius
		var inv_yaw := Basis(Vector3.UP, float(entry.yaw)).inverse()
		var lo: Vector3 = m.lo
		var nx: int = m.nx
		var nz: int = m.nz
		var under: PackedFloat32Array = m.under
		var reach_cells := maxi(0, int(ceil(0.75 / (s * OUTCROP_UNDERSIDE_CELL))))

		# Pass 1: footprint pixels -- cap (min underside nearby) and surface (mean underside nearby).
		var fp_cap: Dictionary = {} # idx -> max allowed terrain height under the rock
		var fp_surf: Dictionary = {} # idx -> mean underside height (world)
		var min_qx := clampi(int(floor(px - r)), 0, width - 1)
		var max_qx := clampi(int(ceil(px + r)), 0, width - 1)
		var min_qz := clampi(int(floor(pz - r)), 0, length - 1)
		var max_qz := clampi(int(ceil(pz + r)), 0, length - 1)
		for qz in range(min_qz, max_qz + 1):
			for qx in range(min_qx, max_qx + 1):
				var local := inv_yaw * Vector3(qx - px, 0.0, qz - pz) / s
				var cx := int(floor((local.x - lo.x) / OUTCROP_UNDERSIDE_CELL))
				var cz := int(floor((local.z - lo.z) / OUTCROP_UNDERSIDE_CELL))
				if cx < -reach_cells or cz < -reach_cells or cx >= nx + reach_cells or cz >= nz + reach_cells:
					continue
				var u_min := INF
				var u_sum := 0.0
				var u_n := 0
				for dz in range(-reach_cells, reach_cells + 1):
					var cj := cz + dz
					if cj < 0 or cj >= nz:
						continue
					for dx in range(-reach_cells, reach_cells + 1):
						var ci := cx + dx
						if ci < 0 or ci >= nx:
							continue
						var u := under[cj * nx + ci]
						if u < INF:
							u_min = minf(u_min, u)
							u_sum += u
							u_n += 1
				if u_n == 0:
					continue
				var idx := qz * width + qx
				fp_cap[idx] = seat_y + u_min * s - OUTCROP_FIT_CLEARANCE
				fp_surf[idx] = seat_y + (u_sum / float(u_n)) * s
		if fp_cap.is_empty():
			continue
		for pidx in fp_cap:
			pinned[pidx] = true

		# Round 4 ("even when the edge is as tall as the mesh itself there are still gaps in some
		# places"): erode the footprint inward by OUTCROP_RIM_INSET px -> `core`. The rim is taken
		# on the core's outline, and the RING between core and the real outline gets the full rim
		# height with no cap, so soil climbs over the rock's outer lip. Terrain only -- the mesh's
		# placement was fixed in _plan_outcrops and is never moved by this.
		var core: Dictionary = fp_cap.duplicate()
		for step in int(ceil(OUTCROP_RIM_INSET)):
			var drop: Array[int] = []
			for cidx in core:
				var cx0: int = cidx % width
				var cz0: int = cidx / width
				for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var ax: int = cx0 + n.x
					var az: int = cz0 + n.y
					if ax < 0 or az < 0 or ax >= width or az >= length or not core.has(az * width + ax):
						drop.append(cidx)
						break
			if drop.size() >= core.size():
				break # never erode the footprint away entirely
			for cidx in drop:
				core.erase(cidx)

		# Pass 2: rim pixels + their tuck targets (on the eroded core's outline).
		var rim: Array[Vector3] = [] # (qx, qz, target)
		for idx in core:
			var qx: int = idx % width
			var qz: int = idx / width
			var is_rim := false
			for n in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var ax: int = qx + n.x
				var az: int = qz + n.y
				if ax < 0 or az < 0 or ax >= width or az >= length or not core.has(az * width + ax):
					is_rim = true
					break
			if is_rim:
				rim.append(Vector3(qx, qz, float(fp_surf[idx]) + OUTCROP_RIM_TUCK))
		if rim.is_empty():
			continue
		# Smooth rim targets along the outline (within 2 px), never below their own target.
		var rim_smoothed: Array[Vector3] = []
		for a in rim:
			var sum := 0.0
			var n := 0
			for b in rim:
				if absf(a.x - b.x) <= 2.0 and absf(a.y - b.y) <= 2.0:
					sum += b.z
					n += 1
			rim_smoothed.append(Vector3(a.x, a.y, maxf(a.z, sum / float(n))))
		rim = rim_smoothed
		total_rim += rim.size()

		# Bank width from how far the rim has to climb above the natural ground under it.
		var max_lift := 0.0
		for rp in rim:
			max_lift = maxf(max_lift, rp.z - heights[int(rp.y) * width + int(rp.x)])
		max_lift_all = maxf(max_lift_all, max_lift)
		var fade := clampf(max_lift / OUTCROP_BANK_SLOPE, OUTCROP_FIT_FADE_MIN, OUTCROP_FIT_FADE_MAX)
		max_fade_used = maxf(max_fade_used, fade)

		# Pass 3: smooth blended target everywhere in range; apply after the scan.
		var min_bx := clampi(int(floor(px - r - fade)), 0, width - 1)
		var max_bx := clampi(int(ceil(px + r + fade)), 0, width - 1)
		var min_bz := clampi(int(floor(pz - r - fade)), 0, length - 1)
		var max_bz := clampi(int(ceil(pz + r + fade)), 0, length - 1)
		var new_heights: Dictionary = {}
		for qz in range(min_bz, max_bz + 1):
			for qx in range(min_bx, max_bx + 1):
				var idx := qz * width + qx
				var h := heights[idx]
				# nearest rim distance, then IDW over rim points within (nearest + 3 px)
				var d_near := INF
				for rp in rim:
					d_near = minf(d_near, Vector2(qx - rp.x, qz - rp.y).length())
				var in_fp := fp_cap.has(idx)
				var in_core := core.has(idx)
				# outside the real outline, fade from the REAL edge (core rim is ~inset further in)
				var d_out := maxf(0.0, d_near - OUTCROP_RIM_INSET)
				if not in_fp and d_out >= fade:
					continue
				var wsum := 0.0
				var tsum := 0.0
				for rp in rim:
					var d := Vector2(qx - rp.x, qz - rp.y).length()
					if d > d_near + 3.0:
						continue
					var w := 1.0 / (d * d + 0.5)
					wsum += w
					tsum += w * rp.z
				var blend_t := tsum / wsum
				var t := h
				if in_core:
					var is_rim_px := d_near < 0.01
					t = blend_t if is_rim_px else minf(blend_t, float(fp_cap[idx]))
				elif in_fp:
					t = blend_t # inset ring: full rim height over the lip, no cap
				else:
					t = lerpf(h, blend_t, 1.0 - smoothstep(0.0, fade, d_out))
				if t > h:
					new_heights[idx] = t
		for idx in new_heights:
			heights[idx] = new_heights[idx]
			if not fp_cap.has(idx):
				bank[idx] = true
		total_raised += new_heights.size()
	# Round 5: relax the raised soil bank only. Pass 3's IDW blend is peaky right next to rim
	# pixels and changes formula at the footprint outline, so the bank came out faceted and those
	# facets read as hard, choppy edges once a low sun casts across them. Footprint pixels stay
	# pinned, so the rock's contact with the ground is untouched -- only the soil skirt is eased.
	var smoothed_px := 0
	if OUTCROP_BANK_SMOOTH_PASSES > 0 and not bank.is_empty():
		var targets: Array[int] = []
		for bidx in bank:
			if not pinned.has(bidx):
				targets.append(bidx)
		for _pass in OUTCROP_BANK_SMOOTH_PASSES:
			var snapshot: Dictionary = {}
			for bidx in targets:
				snapshot[bidx] = heights[bidx]
			for bidx in targets:
				var bx: int = bidx % width
				var bz: int = bidx / width
				var sum := 0.0
				var n := 0
				for dz in range(-1, 2):
					var az := bz + dz
					if az < 0 or az >= length:
						continue
					for dx in range(-1, 2):
						var ax := bx + dx
						if ax < 0 or ax >= width:
							continue
						var aidx := az * width + ax
						sum += float(snapshot[aidx]) if snapshot.has(aidx) else heights[aidx]
						n += 1
				heights[bidx] = lerpf(float(snapshot[bidx]), sum / float(n), OUTCROP_BANK_SMOOTH_STRENGTH)
		smoothed_px = targets.size()
	print("TERRAIN_GEN_DEBUG outcrop fit round3 -- %d rim px, raised %d px, max rim lift %.2f, widest bank %.1f" % [total_rim, total_raised, max_lift_all, max_fade_used])
	print("TERRAIN_GEN_DEBUG outcrop bank smooth round5 -- %d bank px relaxed (%d pinned footprint px), %d passes @ %.2f" % [smoothed_px, pinned.size(), OUTCROP_BANK_SMOOTH_PASSES, OUTCROP_BANK_SMOOTH_STRENGTH])

## Marks each outcrop's footprint + soil bank (+ the cliff road margin) as a road obstacle, so
## _generate_road routes around it the same way it routes around cliff dressing.
func _add_outcrops_to_obstacle_mask(plan: Array[Dictionary], obstacle: PackedByteArray, width: int, length: int) -> void:
	for entry in plan:
		var px: float = entry.px
		var pz: float = entry.pz
		var reach: float = float(entry.radius) + OUTCROP_FIT_FADE_MAX + CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
		for qz in range(clampi(int(floor(pz - reach)), 0, length - 1), clampi(int(ceil(pz + reach)), 0, length - 1) + 1):
			for qx in range(clampi(int(floor(px - reach)), 0, width - 1), clampi(int(ceil(px + reach)), 0, width - 1) + 1):
				if Vector2(qx - px, qz - pz).length() <= reach:
					obstacle[qz * width + qx] = 1

## Instances the planned outcrops (after Terrain3D import, when heightmap_corner is known):
## own rock material, full trimesh collision, under OUTCROP_NODE_NAME.
func _place_outcrops(plan: Array[Dictionary], models: Array[Dictionary], import_position: Vector3) -> void:
	var parent := get_parent()
	var old_container := parent.get_node_or_null(OUTCROP_NODE_NAME)
	if old_container:
		old_container.queue_free()
	var container := Node3D.new()
	container.name = OUTCROP_NODE_NAME
	parent.add_child.call_deferred(container)

	var mats: Dictionary = {}
	var placed := 0
	var collider_count := 0
	for entry in plan:
		var m: Dictionary = models[entry.model]
		if not mats.has(entry.model):
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = load(m.def.diff)
			mat.normal_enabled = true
			mat.normal_texture = load(m.def.nor)
			mat.roughness_texture = load(m.def.rough)
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED # thin one-sided scan shell, same as cliff dressing
			mats[entry.model] = mat
		var instance := (m.scene as PackedScene).instantiate()
		var mesh_root := instance as Node3D
		if mesh_root == null:
			instance.free()
			continue
		var s: float = entry.scale
		var basis := (Basis(Vector3.UP, float(entry.yaw)) * (m.lay_flat as Basis)).scaled(Vector3.ONE * s)
		mesh_root.transform = Transform3D(basis, Vector3(import_position.x + float(entry.px), float(entry.y), import_position.z + float(entry.pz)))
		mesh_root.name = "%s_%d" % [m.def.name, placed]
		container.add_child.call_deferred(mesh_root)
		_apply_cliff_material_recursive(mesh_root, mats[entry.model])
		_apply_cliff_lod_ranges(mesh_root)
		collider_count += _add_cliff_collision_recursive(mesh_root)
		placed += 1
	print("TERRAIN_GEN: placed %d flat rock outcrop(s) (%d collision shape(s))" % [placed, collider_count])

## Road: a route from the center of the north edge to the center of the
## south edge -- the two SHORT edges (each AREA_WIDTH long), so the road
## travels the map's LONG axis (AREA_LENGTH) rather than cutting across its
## short one. Found via _find_road_path (A* over a coarse grid, penalized by
## terrain steepness so it bends around cliffs/ridges) and smoothed into a
## curve by _catmull_rom_smooth. Grades the corridor by blending each pixel
## toward a heavily-blurred copy of the terrain (weighted by distance from
## the path, so it fades smoothly rather than cutting a flat shelf), and
## paints the control map with ROAD_TEXTURE_ID within a narrower band so
## there's a ground shoulder between the visible road surface and the edge
## of the graded corridor.
##
## Rasterized segment-by-segment (each segment only touches the small
## rectangle of pixels around it) rather than pixel-by-pixel scanning every
## segment -- with a winding multi-segment path that's the difference
## between roughly width*length work and roughly path_length*corridor_width
## work, which matters a lot once the path isn't just one straight line.
## Returns the per-pixel road grading weight (0 = untouched terrain, up to 1
## at the corridor's center) -- callers that need to avoid the road (e.g.
## _scatter_boulders, so rocks don't get placed in/right next to the road)
## use this instead of re-deriving the path themselves. Always sized
## width*length, including the early-return "no path found" case below, so
## callers never need to special-case a missing road.
func _generate_road(heights: PackedFloat32Array, control: PackedInt32Array, width: int, length: int, rng: RandomNumberGenerator, edge_noise: FastNoiseLite, cliff_obstacle_mask: PackedByteArray) -> Dictionary:
	# The south edge (pz = length-1) is where the player actually spawns --
	# see the spawn_world comment below -- so it stays pinned dead-center.
	# The north edge (the far exit) is randomized instead, within the
	# central ROAD_GOAL_BAND_FRACTION (see that constant's comment).
	# randf_range(-0.5, 0.5) * band_width spans the full band symmetrically
	# around the midline.
	var t_road_stage := Time.get_ticks_msec() ## fine-grained sub-timing (2026-09-16) -- see _build_heightmap's coarser per-stage prints
	var start_x := width * 0.5 + rng.randf_range(-0.5, 0.5) * (width * ROAD_GOAL_BAND_FRACTION)
	# Per-seed phase for the cosmetic meander wave (see ROAD_MEANDER_* above) --
	# without this, every playthrough's S-curve would wander through the exact
	# same left-right pattern, just with a different start_x.
	var meander_phase := rng.randf_range(0.0, TAU)
	var raw_path := _find_road_path(heights, width, length, start_x, meander_phase, cliff_obstacle_mask)
	print("TERRAIN_GEN:   pathfinding (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()
	if raw_path.size() < 2:
		print("TERRAIN_GEN: road pathfinding produced no usable path, skipping road")
		var empty_weight := PackedFloat32Array()
		empty_weight.resize(width * length)
		# Spawn/exit still need SOMETHING valid even with no road -- fall back
		# to dead-center-to-dead-center (the pre-goal-band-decoupling shape)
		# rather than leaving the caller (which repositions the Player) with
		# nothing to work with.
		var fallback_spawn_height: float = heights[(length - 1) * width + int(width * 0.5)]
		var fallback_exit_height: float = heights[0 * width + int(width * 0.5)]
		return {
			"weight": empty_weight,
			"spawn_pixel": Vector3(width * 0.5, fallback_spawn_height, length - 1),
			"exit_pixel": Vector3(width * 0.5, fallback_exit_height, 0),
			"path": PackedVector2Array(),
		}

	# Force the endpoints to the exact intended X -- the A* grid resolution
	# (ROAD_PATH_GRID_STEP) can land a node a couple of units off from the
	# true target column, and the route itself should start/end exactly there
	# regardless. The exit (north) uses the same start_x that drove the
	# pathfinding above; the spawn (south) is always dead-center.
	raw_path[0] = Vector2(start_x, 0.0)
	raw_path[raw_path.size() - 1] = Vector2(width * 0.5, length - 1.0)

	var path := _catmull_rom_smooth(raw_path, ROAD_PATH_SUBDIVISIONS)
	print("TERRAIN_GEN:   catmull-rom smoothing (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	# Lightweight permanent meander sanity check (2026-09-16, replaces a
	# heavier temporary reversal-counting diagnostic used to verify the
	# ROAD_MEANDER_* feature -- see that constant's comment and the
	# centripetal-vs-uniform Catmull-Rom comment above _catmull_rom_smooth
	# for what that investigation found): just the path's lateral span, as a
	# quick "did the road actually wander this run" signal without needing a
	# screenshot.
	var min_x := path[0].x
	var max_x := path[0].x
	for point in path:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
	print("TERRAIN_GEN:   path lateral span=%.1f (x_range=[%.1f, %.1f])" % [max_x - min_x, min_x, max_x])

	# The "graded" target the corridor blends toward -- a separate heavily-
	# blurred COPY of heights, so the road follows the terrain's overall
	# slope instead of becoming a dead-flat plane cutting through it.
	var blurred := heights.duplicate()
	_smooth(blurred, width, length, ROAD_SMOOTH_PASSES, ROAD_SMOOTH_RADIUS)
	print("TERRAIN_GEN:   graded-target blur (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	# Highest grading weight seen so far per pixel (multiple nearby segments
	# can overlap the same pixel on a tight curve -- take the strongest
	# effect rather than letting a later segment weaken an earlier one), and
	# the strongest road TEXTURE blend fraction seen (0.0 = pure ground,
	# 1.0 = pure road) -- see _pack_control_blend()'s own comment for why
	# this replaced a binary "painted or not" flag.
	var road_weight := PackedFloat32Array()
	road_weight.resize(width * length)
	var road_blend := PackedFloat32Array()
	road_blend.resize(width * length)

	for i in range(path.size() - 1):
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg := b - a
		var seg_len_sq := seg.length_squared()

		var min_px := clampi(int(floor(minf(a.x, b.x) - ROAD_HALF_WIDTH)), 0, width - 1)
		var max_px := clampi(int(ceil(maxf(a.x, b.x) + ROAD_HALF_WIDTH)), 0, width - 1)
		var min_pz := clampi(int(floor(minf(a.y, b.y) - ROAD_HALF_WIDTH)), 0, length - 1)
		var max_pz := clampi(int(ceil(maxf(a.y, b.y) + ROAD_HALF_WIDTH)), 0, length - 1)

		for pz in range(min_pz, max_pz + 1):
			for px in range(min_px, max_px + 1):
				var point := Vector2(px, pz)
				var t := 0.0
				if seg_len_sq > 0.00001:
					t = clampf((point - a).dot(seg) / seg_len_sq, 0.0, 1.0)
				var closest := a + seg * t
				var d := point.distance_to(closest)
				if d > ROAD_HALF_WIDTH:
					continue

				var idx := pz * width + px
				var grade_weight := 1.0 - smoothstep(ROAD_HALF_WIDTH - ROAD_EDGE_SOFTNESS, ROAD_HALF_WIDTH, d)
				if grade_weight > road_weight[idx]:
					road_weight[idx] = grade_weight
				# Jitter only the painted-texture edge, not the graded corridor
				# width above -- the corridor shape is what actually governs
				# walkability/grading, and keeping it a clean offset from the
				# smoothed path avoids any risk of an ungraded bump right at the
				# road's own edge. The paint edge is purely cosmetic, so it can
				# wobble freely to break up the razor-straight shoulder line.
				var painted_half_width := ROAD_TEXTURE_HALF_WIDTH + edge_noise.get_noise_2d(px, pz) * ROAD_EDGE_NOISE_STRENGTH
				# Cross-fade band: 1.0 (pure road) once d is ROAD_TEXTURE_BLEND_WIDTH
				# or more inside the jittered edge, ramping smoothly down to 0.0
				# (pure ground) exactly at the edge itself and beyond -- see
				# ROAD_TEXTURE_BLEND_WIDTH's own comment. smoothstep's built-in
				# clamping means no extra "if d > painted_half_width" guard is
				# needed here the way the old binary flag required.
				var blend_frac := 1.0 - smoothstep(painted_half_width - ROAD_TEXTURE_BLEND_WIDTH, painted_half_width, d)
				if blend_frac > road_blend[idx]:
					road_blend[idx] = blend_frac
	print("TERRAIN_GEN:   segment rasterization (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))
	t_road_stage = Time.get_ticks_msec()

	for idx in road_weight.size():
		if road_weight[idx] > 0.0:
			heights[idx] = lerpf(heights[idx], blurred[idx], road_weight[idx])
		if road_blend[idx] > 0.0:
			control[idx] = _pack_control_blend(GROUND_TEXTURE_ID, ROAD_TEXTURE_ID, road_blend[idx])
	print("TERRAIN_GEN:   apply grading+control (%.3fs)" % ((Time.get_ticks_msec() - t_road_stage) / 1000.0))

	# The player spawns on the SOUTH edge (heightmap pixel (width/2, length-1),
	# forced above), which is always dead-center regardless of seed -- only
	# the north-edge exit (start_x) moves.
	#
	# IMPORTANT: this only hands back PIXEL coordinates (+ height), not world
	# positions -- converting to world space requires heightmap_corner, which
	# isn't knowable until AFTER Terrain3DData.import_images() actually places
	# the region(s) in _ready() (see that function's heightmap_corner comment:
	# turns out Terrain3D doesn't symmetrically center a multi-region import
	# the way a naive position-minus-half-size formula assumes -- it anchors
	# via floor(position/region_size) per axis and extends toward +X/+Z from
	# there, so a length that spans more than one REGION_SIZE tile can leave
	# the corner somewhere other than -length. Building a world Vector3 HERE,
	# before import has even happened, produced exactly that silent "spawns
	# in the middle of the map" bug once AREA_LENGTH grew past REGION_SIZE.
	var spawn_px := int(width * 0.5)
	var spawn_height: float = heights[(length - 1) * width + spawn_px]
	var spawn_pixel := Vector3(spawn_px, spawn_height, length - 1)

	# The exit (north edge, pz = 0) moves per-seed within ROAD_GOAL_BAND_FRACTION.
	var exit_px := clampi(int(round(start_x)), 0, width - 1)
	var exit_height: float = heights[0 * width + exit_px]
	var exit_pixel := Vector3(exit_px, exit_height, 0)
	# `path` (the smoothed centerline, pixel/heightmap-space XZ) is handed
	# back so _build_road_mesh can walk the exact same curve the texture
	# painting above rasterized -- see that function's own comment for why a
	# separate flat overlay mesh (not the painted texture itself) is what
	# carries the parallax material.
	return {"weight": road_weight, "spawn_pixel": spawn_pixel, "exit_pixel": exit_pixel, "path": path}

## Finds a route from the center of the north edge to the center of the south
## edge using A* over a coarse grid (spacing ROAD_PATH_GRID_STEP), where the
## cost of a step is its distance scaled up by how steep the terrain is
## there (squared, so mild slopes barely matter but steep ones are strongly
## avoided) and any step steeper than ROAD_SLOPE_HARD_LIMIT per grid step is
## forbidden outright -- that's what makes the route bend around a cliff
## instead of climbing straight through it, without needing to know
## anything about where the cliff features specifically were placed (their
## own steepness is enough). Returns grid-resolution waypoints in heightmap
## pixel coordinates; _catmull_rom_smooth turns those into an actual curve.
func _find_road_path(heights: PackedFloat32Array, width: int, length: int, start_x: float, meander_phase: float, cliff_obstacle_mask: PackedByteArray) -> PackedVector2Array:
	var cols := int(ceil(width / ROAD_PATH_GRID_STEP)) + 1
	var rows := int(ceil(length / ROAD_PATH_GRID_STEP)) + 1

	var sample_height := func(gx: int, gz: int) -> float:
		var px := clampi(int(round(gx * ROAD_PATH_GRID_STEP)), 0, width - 1)
		var pz := clampi(int(round(gz * ROAD_PATH_GRID_STEP)), 0, length - 1)
		return heights[pz * width + px]

	# 2026-09-17 reorder: cliff-dressing footprints are now planned/flattened into `heights`
	# BEFORE road routing runs, so they no longer show up as a slope discontinuity
	# ROAD_SLOPE_HARD_LIMIT would catch on its own (the flatten blend smooths right over that
	# edge). This explicit obstacle check is what makes A* actually route around them instead
	# of happily paving straight across a flattened cliff-mesh footprint.
	var is_obstructed := func(gx: int, gz: int) -> bool:
		if cliff_obstacle_mask.is_empty():
			return false
		var px := clampi(int(round(gx * ROAD_PATH_GRID_STEP)), 0, width - 1)
		var pz := clampi(int(round(gz * ROAD_PATH_GRID_STEP)), 0, length - 1)
		return cliff_obstacle_mask[pz * width + px] != 0

	# North/south edges (the SHORT ones, each AREA_WIDTH long) are what the
	# road connects -- it travels the LONG axis (AREA_LENGTH, north to south)
	# rather than cutting across the short one. Swapping this would connect
	# the two long west/east edges instead, which is backwards.
	# The goal (south edge, where the player spawns -- see _generate_road's
	# spawn_world comment) stays pinned to the map's center column, but the
	# start (north edge) column comes from start_x (see ROAD_GOAL_BAND_FRACTION)
	# so the two ends don't share a column -- that's what actually forces the
	# route to travel diagonally instead of straight down the map.
	var mid_col := int(round((cols - 1) * 0.5))
	var start_col := clampi(int(round(start_x / ROAD_PATH_GRID_STEP)), 0, cols - 1)
	var start := Vector2i(start_col, 0)
	var goal := Vector2i(mid_col, rows - 1)

	# Cosmetic meander (see ROAD_MEANDER_* consts' comment): a wandering
	# PREFERRED column per row, tapered to exactly 0 deviation at gz=0 and
	# gz=rows-1 (`envelope`, a half-sine hump) so it never fights the hard-
	# forced start/goal columns above. `preferred_col` blends linearly between
	# those two real columns, then adds the sine wander on top, scaled by
	# ROAD_MEANDER_AMPLITUDE_FRACTION*cols so it stays proportional to the
	# grid regardless of map size.
	var preferred_col := func(gz: int) -> float:
		var t := float(gz) / float(maxi(rows - 1, 1))
		var baseline := lerpf(float(start_col), float(mid_col), t)
		var envelope := sin(PI * t) # 0 at t=0 and t=1, peaks at the midpoint
		var wander := ROAD_MEANDER_AMPLITUDE_FRACTION * cols * envelope * sin(t * TAU * ROAD_MEANDER_CYCLES + meander_phase)
		return baseline + wander

	var neighbor_offsets := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]

	# Binary min-heap of [f_score, Vector2i] open-set entries, ordered by
	# f_score (2026-09-16, replaced the old "linear-scan the whole open set
	# for the lowest f" approach). That old approach was O(V) PER POP and
	# therefore O(V^2) overall for V = cols*rows grid nodes -- fine at small
	# map sizes, but V scales with AREA_WIDTH*AREA_LENGTH, so the old cost
	# scaled with the SQUARE of map area. Per-stage timing (_build_heightmap)
	# confirmed this was the dominant remaining cost in road routing once the
	# _smooth() blur elsewhere was fixed to be separable (see that function's
	# comment) -- this is the other half of that fix.
	#
	# No decrease-key support: a node can be pushed more than once (once per
	# g_score improvement, same as the old open_set could hold a node whose
	# f_score had since improved elsewhere -- except the old code kept only
	# one entry per node via `in_open` and mutated its f_score in place).
	# Here, `closed` makes re-popping a stale, already-finalized duplicate a
	# cheap early-exit instead of reprocessing it -- standard technique for
	# an array-backed binary heap without an efficient decrease-key.
	var heap: Array = []
	var closed := {}
	var came_from := {}
	var g_score := {start: 0.0}

	var heap_push := func(f: float, node: Vector2i) -> void:
		heap.append([f, node])
		var i := heap.size() - 1
		while i > 0:
			var parent := (i - 1) / 2
			if heap[parent][0] <= heap[i][0]:
				break
			var tmp = heap[parent]
			heap[parent] = heap[i]
			heap[i] = tmp
			i = parent

	var heap_pop_min := func() -> Array:
		var top = heap[0]
		var last := heap.size() - 1
		heap[0] = heap[last]
		heap.remove_at(last)
		var i := 0
		var n := heap.size()
		while true:
			var left := i * 2 + 1
			var right := i * 2 + 2
			var smallest := i
			if left < n and heap[left][0] < heap[smallest][0]:
				smallest = left
			if right < n and heap[right][0] < heap[smallest][0]:
				smallest = right
			if smallest == i:
				break
			var tmp2 = heap[i]
			heap[i] = heap[smallest]
			heap[smallest] = tmp2
			i = smallest
		return top

	heap_push.call(Vector2(start).distance_to(Vector2(goal)) * ROAD_PATH_GRID_STEP, start)

	while not heap.is_empty():
		var top: Array = heap_pop_min.call()
		var current: Vector2i = top[1]
		if closed.has(current):
			continue # stale duplicate -- a better route to this node was already finalized
		closed[current] = true

		if current == goal:
			var path_nodes: Array[Vector2i] = [current]
			while came_from.has(current):
				current = came_from[current]
				path_nodes.push_front(current)
			var path := PackedVector2Array()
			for node in path_nodes:
				path.append(Vector2(node.x * ROAD_PATH_GRID_STEP, node.y * ROAD_PATH_GRID_STEP))
			return path

		var current_height: float = sample_height.call(current.x, current.y)

		for offset in neighbor_offsets:
			var neighbor: Vector2i = current + offset
			if neighbor.x < 0 or neighbor.x >= cols or neighbor.y < 0 or neighbor.y >= rows:
				continue
			if closed.has(neighbor):
				continue

			if is_obstructed.call(neighbor.x, neighbor.y):
				continue # planted cliff-dressing footprint -- solid terrain, never route through it

			var neighbor_height: float = sample_height.call(neighbor.x, neighbor.y)
			var height_delta := absf(neighbor_height - current_height)
			if height_delta > ROAD_SLOPE_HARD_LIMIT:
				continue # too steep to ever route through, no matter the cost

			var step_distance: float = ROAD_PATH_GRID_STEP * Vector2(offset).length()
			var slope := height_delta / step_distance
			var move_cost := step_distance * (1.0 + ROAD_SLOPE_PENALTY * slope * slope)

			# Cosmetic meander pull (see ROAD_MEANDER_* consts): an EXTRA soft
			# cost for straying from the wandering preferred column at this row,
			# on top of the real slope cost above -- never overrides the hard
			# slope-limit `continue` above, only shapes preference among cells
			# that were already going to be considered.
			var lateral_deviation := absf(float(neighbor.x) - preferred_col.call(neighbor.y))
			move_cost += ROAD_MEANDER_COST_WEIGHT * lateral_deviation * step_distance

			var tentative_g: float = g_score.get(current, INF) + move_cost
			if tentative_g < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				var f := tentative_g + Vector2(neighbor).distance_to(Vector2(goal)) * ROAD_PATH_GRID_STEP
				heap_push.call(f, neighbor)

	# No route found at all (e.g. a wall of ROAD_SLOPE_HARD_LIMIT-steep terrain
	# spans the whole map) -- fall back to a straight line rather than no road.
	push_warning("TERRAIN_GEN: road pathfinding found no route from north to south edge -- falling back to a straight line")
	var fallback := PackedVector2Array()
	fallback.append(Vector2(start_col * ROAD_PATH_GRID_STEP, 0.0))
	fallback.append(Vector2(mid_col * ROAD_PATH_GRID_STEP, (rows - 1) * ROAD_PATH_GRID_STEP))
	return fallback

## CENTRIPETAL Catmull-Rom spline through `points` (2026-09-16, replaced a
## UNIFORM-parameterization version), resampled at `subdivisions` steps per
## input segment. Turns the blocky grid-resolution A* waypoints (which only
## ever step in 8 fixed directions) into a road that actually curves.
##
## Uniform Catmull-Rom (parameter t running 0..1 per segment regardless of
## how far apart the actual points are) is well known to overshoot/ring when
## the control polygon has real curvature with UNEVENLY spaced points --
## exactly what the road-meander feature (see ROAD_MEANDER_* above)
## introduced. Confirmed via a temporary diagnostic: the raw A* path (before
## this function) had only 6 direction reversals for a deliberate ~2.2-cycle
## S-curve, but the OLD uniform-parameterized smoothed output had 55 --
## i.e. this function was manufacturing ~50 spurious wiggles the pathfinder
## never asked for, on top of the intended curve. Before the meander
## feature, the raw path was close enough to a straight line that this
## defect had nothing to amplify and went unnoticed.
##
## Centripetal parameterization (alpha=0.5, the Barry-Goldman formulation)
## spaces each segment's local parameter by the SQUARE ROOT of the actual
## distance between points instead of a fixed 1.0 per segment -- this is
## the standard, well-documented fix for uniform Catmull-Rom's overshoot/
## self-intersection on non-uniformly-spaced control points. `epsilon`
## guards the (rare) case of two coincident points, which would otherwise
## divide by zero.
func _catmull_rom_smooth(points: PackedVector2Array, subdivisions: int) -> PackedVector2Array:
	var n := points.size()
	if n < 2:
		return points
	var alpha := 0.5
	var epsilon := 0.0001
	var result := PackedVector2Array()
	for i in range(n - 1):
		var p0: Vector2 = points[maxi(i - 1, 0)]
		var p1: Vector2 = points[i]
		var p2: Vector2 = points[i + 1]
		var p3: Vector2 = points[mini(i + 2, n - 1)]

		var t0 := 0.0
		var t1 := t0 + pow(maxf(p1.distance_to(p0), epsilon), alpha)
		var t2 := t1 + pow(maxf(p2.distance_to(p1), epsilon), alpha)
		var t3 := t2 + pow(maxf(p3.distance_to(p2), epsilon), alpha)

		for s in subdivisions:
			var t := lerpf(t1, t2, float(s) / float(subdivisions))
			var a1 := p0 * (t1 - t) / (t1 - t0) + p1 * (t - t0) / (t1 - t0)
			var a2 := p1 * (t2 - t) / (t2 - t1) + p2 * (t - t1) / (t2 - t1)
			var a3 := p2 * (t3 - t) / (t3 - t2) + p3 * (t - t2) / (t3 - t2)
			var b1 := a1 * (t2 - t) / (t2 - t0) + a2 * (t - t0) / (t2 - t0)
			var b2 := a2 * (t3 - t) / (t3 - t1) + a3 * (t - t1) / (t3 - t1)
			var point := b1 * (t2 - t) / (t2 - t1) + b2 * (t - t1) / (t2 - t1)
			result.append(point)
	result.append(points[n - 1])
	return result

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
func _smooth(heights: PackedFloat32Array, width: int, length: int, passes: int, radius: int) -> void:
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
