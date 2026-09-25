## Carved terrain features: escarpments, V-ravines, terraces, gentle rises and knolls.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## CliffFeatures.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name CliffFeatures
extends RefCounted

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
static func add_cliff_features(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, count: int) -> Array[Dictionary]:
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
static func _weighted_pick(rng: RandomNumberGenerator, weights: Dictionary):
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

## Rejection-samples a candidate center within [x_lo,x_hi]x[z_lo,z_hi] that
## clears every already-placed feature's own footprint (reach) by at least
## FEATURE_MIN_GAP, trying up to 30 times -- see _add_cliff_features' reach
## comment for why center-distance alone isn't the right check. Returns the
## center, or null if no clear spot was found in 30 attempts (the caller
## skips this feature rather than force an overlapping placement -- see the
## old "two cliffs crossing" artifact this originally fixed).
static func _find_feature_center(rng: RandomNumberGenerator, placed: Array[Dictionary], reach: float, x_lo: float, x_hi: float, z_lo: float, z_hi: float):
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
static func _place_line_feature(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, zone: String, archetype: int, edge_jitter: FastNoiseLite, placed: Array[Dictionary]) -> void:
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

	var x_range := TerrainUtil.zone_pixel_range(zone, width, rng)
	var x_clamped := TerrainUtil.clamp_range_for_reach(x_range.x, x_range.y, reach, float(width - 1))
	var x_lo := minf(x_clamped.x, x_clamped.y)
	var x_hi := maxf(x_clamped.x, x_clamped.y)
	var z_clamped := TerrainUtil.clamp_range_for_reach(length * 0.1, length * 0.9, reach, float(length - 1))
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
static func _place_knoll(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, zone: String, edge_jitter: FastNoiseLite, placed: Array[Dictionary]) -> void:
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

	var x_range := TerrainUtil.zone_pixel_range(zone, width, rng)
	var x_clamped := TerrainUtil.clamp_range_for_reach(x_range.x, x_range.y, reach, float(width - 1))
	var x_lo := minf(x_clamped.x, x_clamped.y)
	var x_hi := maxf(x_clamped.x, x_clamped.y)
	var z_clamped := TerrainUtil.clamp_range_for_reach(length * 0.1, length * 0.9, reach, float(length - 1))
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
