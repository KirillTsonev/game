## Cliff-face mesh dressing, planning side: where each cliff mesh goes, the road obstacle
## mask, cliff top profiles, flattening/raising the heightmap to seat the meshes, and the
## raise-pass debug surface.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## CliffDressing.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name CliffDressing
extends RefCounted

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
static var _raise_debug_heights: PackedFloat32Array = PackedFloat32Array()
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
static var _raise_debug_entry_index: PackedInt32Array = PackedInt32Array()
const CLIFF_DRESSING_SCALE_MIN := 0.85 ## random scale jitter on top of the real-size placement below, for visual variety only -- not what makes these fit the terrain (that's the per-model real_size + placement spacing)
const CLIFF_DRESSING_SCALE_MAX := 1.2
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

## Builds a per-pixel obstacle flag (2026-09-17 reorder) from an already-computed cliff-
## dressing plan, so _find_road_path can treat each planned mesh's rotated footprint as
## impassable terrain -- the same role _cliff_placement_blocks_road used to play in reverse
## (back when the road existed first and cliff placement dodged it). Reuses the exact same
## rotated-rectangle math as _flatten_terrain_for_cliff_dressing (half_x/half_z footprint
## from def.real_size/def.depth * scale_jitter, projected onto the mesh's own local basis),
## but as a hard boolean flag rather than a soft height blend, padded by
## CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN so the road can't shave right past the mesh's edge.
static func build_cliff_dressing_obstacle_mask(plan: Array[Dictionary], width: int, length: int) -> PackedByteArray:
	var obstacle := PackedByteArray()
	obstacle.resize(width * length)

	var defs_by_name: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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

		var half_x: float = def.real_size * scale_jitter * 0.5 + TerrainConfig.CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
		var half_z: float = def.depth * scale_jitter * 0.5 + TerrainConfig.CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
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
static func plan_cliff_dressing(cliff_features: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator) -> Array[Dictionary]:
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
		var usable_half_len := half_len * (1.0 - TerrainConfig.BOULDER_END_INSET_FRACTION)
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
			for def in TerrainConfig.CLIFF_DRESSING_DEFS:
				if def.real_size * 0.5 <= remaining:
					fitting.append(def)
			if fitting.is_empty():
				var smallest = TerrainConfig.CLIFF_DRESSING_DEFS[0]
				for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
			var foot_a_height := TerrainUtil.sample_height_bilinear(heights, width, length, foot_a_px, foot_a_pz)
			var foot_b_height := TerrainUtil.sample_height_bilinear(heights, width, length, foot_b_px, foot_b_pz)

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
static func flatten_terrain_for_cliff_dressing(plan: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int) -> void:
	var defs_by_name: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
static func _compute_cliff_dressing_top_profile(def: Dictionary) -> Dictionary:
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
	TerrainUtil.collect_mesh_vertices_recursive(root, Transform3D.IDENTITY, vertices)
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
static func build_cliff_dressing_top_profiles() -> Dictionary:
	var profiles := {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		profiles[def.name] = _compute_cliff_dressing_top_profile(def)
	return profiles

## Samples a top profile (as returned by _compute_cliff_dressing_top_profile) at a given
## local-X position, clamping to the model's own sampled range and linearly interpolating
## between the two nearest samples.
static func _sample_cliff_top_profile(profile: Dictionary, x: float) -> float:
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
static func _cliff_profile_flank_height(profile: Dictionary, left_side: bool) -> float:
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
static func _sample_cliff_top_profile_flanked(profile: Dictionary, x: float, _flank_left: float, _flank_right: float) -> float:
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
static func spawn_raise_debug_boxes(parent_node: Node, heightmap_corner: Vector3) -> void:
	var parent := parent_node
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
	for qz in range(TerrainConfig.AREA_LENGTH - 1):
		for qx in range(TerrainConfig.AREA_WIDTH - 1):
			var idx00 := qz * TerrainConfig.AREA_WIDTH + qx
			var idx10 := qz * TerrainConfig.AREA_WIDTH + (qx + 1)
			var idx01 := (qz + 1) * TerrainConfig.AREA_WIDTH + qx
			var idx11 := (qz + 1) * TerrainConfig.AREA_WIDTH + (qx + 1)
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
static func _sample_neighbor_facing_plateau_height(other: Dictionary, other_half_x: float, facing_right_edge: bool, top_profiles: Dictionary, defs_by_name: Dictionary) -> float:
	var other_def = defs_by_name.get(other.def_name)
	if other_def == null:
		return NAN
	var other_scale: float = other.scale_jitter
	if other_scale <= 0.0:
		return NAN
	var other_origin_y: float = other.height - TerrainConfig.CLIFF_DRESSING_EMBED_DEPTH * other_scale
	var other_profile: Dictionary = top_profiles.get(other.def_name, {})
	var signed_half_x := other_half_x if facing_right_edge else -other_half_x
	var local_x_unscaled := signed_half_x / other_scale
	# round 17: same flank-aware sampling as the entry's own sides, so a join seam compares like
	# with like.
	var edge_top := _sample_cliff_top_profile_flanked(other_profile, local_x_unscaled, _cliff_profile_flank_height(other_profile, true), _cliff_profile_flank_height(other_profile, false))
	return other_origin_y + edge_top * other_scale

static func raise_terrain_behind_cliff_dressing(plan: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, top_profiles: Dictionary, noise_seed: int) -> void:
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
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
		var origin_y: float = low_height - TerrainConfig.CLIFF_DRESSING_EMBED_DEPTH * scale_jitter
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
		var max_climb: float = maxf(0.0, max_local_top * scale_jitter - TerrainConfig.CLIFF_DRESSING_EMBED_DEPTH * scale_jitter)
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

## Restores this module's static state (caches, debug buffers, counters) to its initial
## values. Called at the start of every WorldGenerator run so each run starts clean, the
## same as when these were per-instance member variables on WorldGenerator.
static func reset_run_state() -> void:
	_raise_debug_heights = PackedFloat32Array()
	_raise_debug_entry_index = PackedInt32Array()
