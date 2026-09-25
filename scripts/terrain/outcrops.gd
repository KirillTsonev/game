## Flat rock outcrops: model loading, placement planning, terrain fitting, instancing.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainOutcrops.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainOutcrops
extends RefCounted

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
static func load_outcrop_models() -> Array[Dictionary]:
	var models: Array[Dictionary] = []
	for def in OUTCROP_DEFS:
		var scene: PackedScene = load(def.glb)
		if scene == null:
			push_warning("TERRAIN_GEN: could not load outcrop mesh %s -- skipping it" % def.glb)
			continue
		var sample := scene.instantiate()
		var verts := PackedVector3Array()
		TerrainUtil.collect_mesh_vertices_recursive(sample, Transform3D.IDENTITY, verts)
		var face_dir := TerrainUtil.sum_mesh_normals_recursive(sample, Transform3D.IDENTITY)
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
static func plan_outcrops(models: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, cliff_plan: Array[Dictionary]) -> Array[Dictionary]:
	var plan: Array[Dictionary] = []
	if models.is_empty():
		return plan

	# Cliff-dressing placements as keep-out circles (pixel space: x, z, radius).
	var cliff_sizes: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		cliff_sizes[def.name] = def.real_size
	var keep_out: Array[Vector3] = []
	for entry in cliff_plan:
		var r := float(cliff_sizes.get(entry.def_name, 10.0)) * 0.5 * float(entry.scale_jitter)
		keep_out.append(Vector3(entry.px, entry.pz, r))

	var area_scale := (float(width) * float(length)) / TerrainConfig.ERRATIC_DENSITY_BASE_AREA
	var count_min := maxi(1, int(round(OUTCROP_COUNT_MIN_BASE * area_scale)))
	var count_max := maxi(count_min, int(round(OUTCROP_COUNT_MAX_BASE * area_scale)))
	var roll_count := rng.randi_range(count_min, count_max)
	var floor_x_range := TerrainUtil.zone_pixel_range("floor", width, rng)

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
			var fx := TerrainUtil.clamp_range_for_reach(floor_x_range.x, floor_x_range.y, radius + OUTCROP_FIT_FADE_MAX, float(width - 1))
			var fz := TerrainUtil.clamp_range_for_reach(float(length) * 0.1, float(length) * 0.9, radius + OUTCROP_FIT_FADE_MAX, float(length - 1))
			var px := rng.randf_range(minf(fx.x, fx.y), maxf(fx.x, fx.y))
			var pz := rng.randf_range(minf(fz.x, fz.y), maxf(fz.x, fz.y))

			var blocked := false
			for k in keep_out:
				if Vector2(px - k.x, pz - k.y).length() < radius + k.z + OUTCROP_CLEARANCE:
					blocked = true
					break
			if blocked:
				continue
			if TerrainUtil.sample_normal(heights, width, length, px, pz).y < OUTCROP_MAX_SLOPE_NORMAL_Y:
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
					var h := TerrainUtil.sample_height_bilinear(heights, width, length, sx, sz)
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
static func fit_terrain_to_outcrops(plan: Array[Dictionary], models: Array[Dictionary], heights: PackedFloat32Array, width: int, length: int) -> void:
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
static func add_outcrops_to_obstacle_mask(plan: Array[Dictionary], obstacle: PackedByteArray, width: int, length: int) -> void:
	for entry in plan:
		var px: float = entry.px
		var pz: float = entry.pz
		var reach: float = float(entry.radius) + OUTCROP_FIT_FADE_MAX + TerrainConfig.CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN
		for qz in range(clampi(int(floor(pz - reach)), 0, length - 1), clampi(int(ceil(pz + reach)), 0, length - 1) + 1):
			for qx in range(clampi(int(floor(px - reach)), 0, width - 1), clampi(int(ceil(px + reach)), 0, width - 1) + 1):
				if Vector2(qx - px, qz - pz).length() <= reach:
					obstacle[qz * width + qx] = 1

## Instances the planned outcrops (after Terrain3D import, when heightmap_corner is known):
## own rock material, full trimesh collision, under OUTCROP_NODE_NAME.
static func place_outcrops(parent_node: Node, plan: Array[Dictionary], models: Array[Dictionary], import_position: Vector3) -> void:
	var parent := parent_node
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
		CliffInstancer.apply_cliff_material_recursive(mesh_root, mats[entry.model])
		CliffInstancer.apply_cliff_lod_ranges(mesh_root)
		collider_count += CliffInstancer.add_cliff_collision_recursive(mesh_root)
		placed += 1
	print("TERRAIN_GEN: placed %d flat rock outcrop(s) (%d collision shape(s))" % [placed, collider_count])
