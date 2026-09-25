## Understory scattering -- shrubs + ferns, the vegetation layer under the canopy (2026-09-25).
##
## Static-only module (see terrain_gen.gd's header table): never instantiated; call as
## UnderstoryScatter.scatter_understory(...). Must run AFTER TreeScatter.scatter_trees (reads
## TreeScatter.tree_points) and RockScatter.scatter_boulders (RockScatter.rock_keep_circles).
##
## Design (docs/vegetation.md "Understory"): density READS THE CANOPY -- that correlation is the
## realism. Three fields on a CELL-sized grid, built once per run:
##   canopy  -- every placed tree splats a gaussian "shade" blob; cover = 1 - exp(-gain * sum)
##              (dense grove ~0.9, lone tree ~0.3 at its foot, open ground 0);
##   cliff   -- shade band on the low side of each cliff foot whose face points AWAY from the
##              sun; band depth ~ cliff height / tan(sun elevation), like the real shadow;
##   moist   -- small low-ground bonus (1 - normalised height).
## Ferns need shade: p ~ smoothstep(max(canopy, cliff) + moisture) -- essentially none in open
## sun. Shrubs peak at grove EDGES (cover ~0.5), some under canopy, a sparse few in the open.
## Two noise layers: large-scale GLADES (forest-floor clearings) and small-scale CLUMPING.
## Candidates: one jittered spot per CANDIDATE_STEP cell; the cheap probability roll happens
## first, the costlier checks (slope, road, rock keep-outs, trunk ring) only for spots that pass.
## Rendering: Terrain3D instancer, mesh ids 28-32 (baked + registered by
## tools/setup_understory_assets.gd build_understory_assets(): draw distance 70 m, shadows to
## 35 m, no collision).
class_name UnderstoryScatter
extends RefCounted

## Terrain3D mesh asset ids -- keep in sync with UNDERSTORY_ASSETS in tools/setup_understory_assets.gd.
const FERN_ID := 28 ## fern_02 (LOD 440/264/88 tris)
const BROAD_FERN_ID := 29 ## bush_01 -- broad pinnate leaves, the large/broad fern variant
const BUSH02_GREEN_ID := 30 ## bush_02 with the green hue-shifted texture (orange version unused)
const BUSH04_ID := 31 ## grassy/spiky shrub
const BUSH05_ID := 32 ## rounded shrub on a woody stem
const UNDERSTORY_MESH_IDS: Array[int] = [FERN_ID, BROAD_FERN_ID, BUSH02_GREEN_ID, BUSH04_ID, BUSH05_ID]

## Species mix within each group: [id, weight, scale_min, scale_max].
const FERN_MIX := [[FERN_ID, 0.8, 0.8, 1.3], [BROAD_FERN_ID, 0.2, 0.65, 0.95]]
const SHRUB_MIX := [[BUSH04_ID, 0.4, 0.8, 1.2], [BUSH05_ID, 0.35, 0.8, 1.2], [BUSH02_GREEN_ID, 0.25, 0.75, 1.1]]

## -- Density fields --
const CELL := 2.0 ## m per density-grid cell
const CANOPY_SIGMA := 4.5 ## m, gaussian radius of one tree's shade at scale 1.0 (canopies ~6-7 m wide)
const CANOPY_GAIN := 0.9 ## cover = 1 - exp(-gain * summed gaussians); higher = cover saturates with fewer trees
const CLIFF_SHADE_MIN_BAND := 3.0 ## m, shortest shade band at a cliff foot
const CLIFF_SHADE_MAX_BAND := 12.0 ## m, longest (tall cliffs, low sun)
const CLIFF_SHADE_SIDE_LIT := 0.35 ## shade of a face lit side-on (sun parallel to it); facing away -> 1, facing the sun -> 0
const CLIFF_FULL_SHADE_HEIGHT := 4.0 ## m of cliff step for full-strength shade (lower steps shade proportionally less)
const MOISTURE_WEIGHT := 0.15 ## low-ground bonus added to the fern shade term

## -- Probabilities (per candidate spot) --
const CANDIDATE_STEP := 1.1 ## m, jittered candidate grid -- at most one plant per step x step cell
const FERN_MAX_P := 0.55 ## fern chance in full shade (before glade/clump noise)
const FERN_SHADE_LO := 0.15 ## shade below this -> no ferns
const FERN_SHADE_HI := 0.7 ## shade above this -> full FERN_MAX_P
const SHRUB_MAX_P := 0.22 ## shrub chance at the peak (grove edge, cover ~0.5)
const SHRUB_EDGE_WEIGHT := 0.8 ## share of the shrub term from the edge bump 4c(1-c)
const SHRUB_CANOPY_WEIGHT := 0.35 ## share from plain canopy cover (some shrubs under trees)
const SHRUB_OPEN_P := 0.012 ## shrub chance in the open (the sparse loners)

## -- Noise --
const GLADE_NOISE_FREQ := 0.02 ## ~50 m features: forest-floor clearings
const GLADE_LO := 0.30 ## noise (0..1) below this -> glade, nothing grows
const GLADE_HI := 0.55 ## above this -> full density
const CLUMP_NOISE_FREQ := 0.12 ## ~8 m features: plants gather in clumps
const CLUMP_MIN := 0.35 ## density multiplier between clumps (1.0 inside)

## -- Placement --
const MAX_SLOPE_NORMAL_Y := 0.72 ## ~44 deg max; a bit steeper than trees (0.80) -- ferns hug banks
const TRUNK_CLEAR_RADIUS := 0.9 ## m (x tree scale): bare ring around each trunk
const KEEPOUT_RADIUS := 0.4 ## m, plant footprint for the rock keep-out test
const EMBED := 0.04 ## m sunk into the ground
const LEAN_MAX_DEG := 6.0
const EDGE_MARGIN := 1.5 ## px kept off the heightmap border

## Last run's counts, for debugging / docs.
static var last_counts: Dictionary = {}

static func scatter_understory(parent_node: Node, terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_features: Array[Dictionary], cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary]) -> void:
	var t0 := Time.get_ticks_msec()
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	var assets: Terrain3DAssets = terrain.get_assets()
	var active: Dictionary = {}
	for id in UNDERSTORY_MESH_IDS:
		instancer.clear_by_mesh(id)
		active[id] = assets != null and assets.get_mesh_asset(id) != null
	if not active.values().has(true):
		print("TERRAIN_GEN: no understory mesh assets registered (ids %s) -- run build_understory_assets() in tools/setup_understory_assets.gd" % str(UNDERSTORY_MESH_IDS))
		return

	var gw := int(ceil(float(width) / CELL)) + 1
	var gl := int(ceil(float(length) / CELL)) + 1
	var canopy := _build_canopy_grid(gw, gl)
	var cliff := _build_cliff_shade_grid(gw, gl, cliff_features, _sun_to_dir(parent_node))
	var hmin := INF
	var hmax := -INF
	for h in heights:
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
	var hspan := maxf(hmax - hmin, 0.001)
	var trunk_grid := _build_trunk_grid()
	var keep_rects := _build_keep_rects(cliff_plan, cliff_top_profiles)
	var keep_circles: Array[Vector3] = []
	for oc in outcrop_plan:
		keep_circles.append(Vector3(oc.px, oc.pz, oc.radius))
	keep_circles.append_array(RockScatter.rock_keep_circles)
	var t_fields := Time.get_ticks_msec() - t0

	var glade_noise := FastNoiseLite.new()
	glade_noise.seed = rng.randi()
	glade_noise.frequency = GLADE_NOISE_FREQ
	var clump_noise := FastNoiseLite.new()
	clump_noise.seed = rng.randi()
	clump_noise.frequency = CLUMP_NOISE_FREQ

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for id in UNDERSTORY_MESH_IDS:
		transforms_by_mesh[id] = [] as Array[Transform3D]
		colors_by_mesh[id] = PackedColorArray()
	var counts := {"candidates": 0, "rolled": 0, "rej_slope": 0, "rej_road": 0, "rej_rock": 0, "rej_trunk": 0, "fern_group": 0, "shrub_group": 0}
	for id in UNDERSTORY_MESH_IDS:
		counts[id] = 0

	var steps_x := int((float(width - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	var steps_z := int((float(length - 1) - 2.0 * EDGE_MARGIN) / CANDIDATE_STEP)
	for iz in steps_z:
		for ix in steps_x:
			counts.candidates += 1
			var px := EDGE_MARGIN + (float(ix) + rng.randf()) * CANDIDATE_STEP
			var pz := EDGE_MARGIN + (float(iz) + rng.randf()) * CANDIDATE_STEP
			var c := _grid_sample(canopy, gw, gl, px, pz)
			var s := _grid_sample(cliff, gw, gl, px, pz)
			var h := TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
			var moist := 1.0 - (h - hmin) / hspan
			var shade := maxf(c, s) + MOISTURE_WEIGHT * moist
			var p_fern := FERN_MAX_P * smoothstep(FERN_SHADE_LO, FERN_SHADE_HI, shade)
			var p_shrub := SHRUB_OPEN_P + SHRUB_MAX_P * (SHRUB_EDGE_WEIGHT * 4.0 * c * (1.0 - c) + SHRUB_CANOPY_WEIGHT * c)
			var glade := smoothstep(GLADE_LO, GLADE_HI, glade_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			var clump := lerpf(CLUMP_MIN, 1.0, clump_noise.get_noise_2d(px, pz) * 0.5 + 0.5)
			var mod := glade * clump
			p_fern *= mod
			p_shrub *= mod
			var roll := rng.randf()
			var group: Array
			if roll < p_fern:
				group = FERN_MIX
			elif roll < p_fern + p_shrub:
				group = SHRUB_MIX
			else:
				continue
			counts.rolled += 1

			# Costlier checks only for spots that passed the roll.
			var normal := TerrainUtil.sample_normal(heights, width, length, px, pz)
			if normal.y < MAX_SLOPE_NORMAL_Y:
				counts.rej_slope += 1
				continue
			var idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
			if road_weight[idx] > 0.0:
				counts.rej_road += 1
				continue
			if RockScatter.boulder_blocked(px, pz, KEEPOUT_RADIUS, keep_rects, keep_circles):
				counts.rej_rock += 1
				continue
			if _near_trunk(trunk_grid, px, pz):
				counts.rej_trunk += 1
				continue

			var pick: Array = _pick_species(group, rng)
			var id: int = pick[0]
			if not active[id]:
				continue
			var scale := rng.randf_range(pick[2], pick[3])
			var basis := Basis(Vector3.UP, rng.randf() * TAU)
			var lean := deg_to_rad(rng.randf_range(0.0, LEAN_MAX_DEG))
			if lean > 0.0001:
				var la := rng.randf() * TAU
				basis = Basis(Vector3(cos(la), 0.0, sin(la)), lean) * basis
			var pos := Vector3(import_position.x + px, h - EMBED, import_position.z + pz)
			transforms_by_mesh[id].append(Transform3D(basis.scaled(Vector3.ONE * scale), pos))
			colors_by_mesh[id].append(Color.WHITE)
			counts[id] += 1
			counts["fern_group" if group == FERN_MIX else "shrub_group"] += 1

	for id in UNDERSTORY_MESH_IDS:
		if not (transforms_by_mesh[id] as Array).is_empty():
			instancer.add_transforms(id, transforms_by_mesh[id], colors_by_mesh[id], true)

	last_counts = counts
	var total: int = counts.fern_group + counts.shrub_group
	print("TERRAIN_GEN: understory -- %d plant(s): %d fern-group (fern %d, broad fern %d) + %d shrub(s) (bush04 %d, bush05 %d, bush02 green %d) from %d candidate spots (%.1f%%); rolled %d, rejected slope %d / road %d / rock %d / trunk %d; fields %d ms, total %d ms" % [
		total, counts.fern_group, counts[FERN_ID], counts[BROAD_FERN_ID], counts.shrub_group, counts[BUSH04_ID], counts[BUSH05_ID], counts[BUSH02_GREEN_ID],
		counts.candidates, 100.0 * total / maxf(1.0, counts.candidates), counts.rolled, counts.rej_slope, counts.rej_road, counts.rej_rock, counts.rej_trunk,
		t_fields, Time.get_ticks_msec() - t0])

## Canopy cover grid from TreeScatter.tree_points: summed gaussians -> 1 - exp(-gain * sum).
static func _build_canopy_grid(gw: int, gl: int) -> PackedFloat32Array:
	var sum := PackedFloat32Array()
	sum.resize(gw * gl)
	for tp in TreeScatter.tree_points:
		var sigma := CANOPY_SIGMA * tp.z
		var inv2s2 := 1.0 / (2.0 * sigma * sigma)
		var r := int(ceil(3.0 * sigma / CELL))
		var cx := int(round(tp.x / CELL))
		var cz := int(round(tp.y / CELL))
		for gz in range(maxi(0, cz - r), mini(gl - 1, cz + r) + 1):
			for gx in range(maxi(0, cx - r), mini(gw - 1, cx + r) + 1):
				var dx := gx * CELL - tp.x
				var dz := gz * CELL - tp.y
				sum[gz * gw + gx] += exp(-(dx * dx + dz * dz) * inv2s2)
	for i in sum.size():
		sum[i] = 1.0 - exp(-CANOPY_GAIN * sum[i])
	return sum

## Cliff-foot shade grid: for each single-sided cliff feature, a band on its low side, strength
## by how far the face points away from the sun and by the cliff's height, fading with distance.
static func _build_cliff_shade_grid(gw: int, gl: int, cliff_features: Array[Dictionary], to_sun: Vector3) -> PackedFloat32Array:
	var grid := PackedFloat32Array()
	grid.resize(gw * gl)
	var sun_h := Vector2(to_sun.x, to_sun.z)
	var sun_h_len := sun_h.length()
	var sun_elev := atan2(to_sun.y, maxf(sun_h_len, 0.0001))
	if sun_h_len > 0.0001:
		sun_h /= sun_h_len
	for f in cliff_features:
		if not f.has("step_height"):
			continue
		var step: float = f.step_height
		var low_side_sign := -1.0 if step > 0.0 else 1.0
		var perp := Vector2(f.perp_x, f.perp_z)
		var axis := Vector2(f.axis_x, f.axis_z)
		var face_out := (perp * low_side_sign).normalized()
		var facing := face_out.dot(sun_h) if sun_h_len > 0.0001 else 0.0
		var strength := clampf(CLIFF_SHADE_SIDE_LIT - facing, 0.0, 1.0) * clampf(absf(step) / CLIFF_FULL_SHADE_HEIGHT, 0.0, 1.0)
		if strength <= 0.01:
			continue
		var band := clampf(absf(step) / maxf(tan(sun_elev), 0.05), CLIFF_SHADE_MIN_BAND, CLIFF_SHADE_MAX_BAND)
		var half_len: float = f.half_len
		var center: Vector2 = f.center
		var t := -half_len
		while t <= half_len:
			var nt := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve := float(f.curve_amplitude) * lerpf(sin(nt * PI * float(f.curve_frequency) + float(f.curve_phase)), sin(nt * PI * float(f.curve_frequency2) + float(f.curve_phase2)), float(f.curve_weight2))
			var foot := center + axis * t + perp * (low_side_sign * float(f.edge_softness) + curve)
			var d := 0.0
			while d <= band:
				var p := foot + face_out * d
				var gx := int(round(p.x / CELL))
				var gz := int(round(p.y / CELL))
				if gx >= 0 and gx < gw and gz >= 0 and gz < gl:
					var v := strength * (1.0 - d / band)
					var gi := gz * gw + gx
					grid[gi] = maxf(grid[gi], v)
				d += CELL * 0.5
			t += CELL * 0.5
	return grid

## Direction TO the sun (world space), from the scene's DirectionalLight3D (light travels along
## its -Z). Falls back to straight up if there is no sun node.
static func _sun_to_dir(parent_node: Node) -> Vector3:
	var sun := parent_node.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun == null:
		return Vector3.UP
	return sun.global_transform.basis.z.normalized()

static func _grid_sample(grid: PackedFloat32Array, gw: int, gl: int, px: float, pz: float) -> float:
	var fx := clampf(px / CELL, 0.0, float(gw - 1))
	var fz := clampf(pz / CELL, 0.0, float(gl - 1))
	var x0 := int(fx)
	var z0 := int(fz)
	var x1 := mini(x0 + 1, gw - 1)
	var z1 := mini(z0 + 1, gl - 1)
	var tx := fx - x0
	var tz := fz - z0
	var a := lerpf(grid[z0 * gw + x0], grid[z0 * gw + x1], tx)
	var b := lerpf(grid[z1 * gw + x0], grid[z1 * gw + x1], tx)
	return lerpf(a, b, tz)

## Trunks bucketed in 4 m cells (TRUNK_CLEAR_RADIUS x max tree scale < 4 m, so 3x3 is enough).
static func _build_trunk_grid() -> Dictionary:
	var grid := {}
	for tp in TreeScatter.tree_points:
		var c := Vector2i(floori(tp.x / 4.0), floori(tp.y / 4.0))
		if not grid.has(c):
			grid[c] = []
		grid[c].append(tp)
	return grid

static func _near_trunk(grid: Dictionary, px: float, pz: float) -> bool:
	var c := Vector2i(floori(px / 4.0), floori(pz / 4.0))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			for tp in grid.get(Vector2i(c.x + dx, c.y + dz), []):
				var r: float = TRUNK_CLEAR_RADIUS * tp.z
				if (px - tp.x) * (px - tp.x) + (pz - tp.y) * (pz - tp.y) < r * r:
					return true
	return false

## Weighted pick from a *_MIX table -> the chosen [id, weight, scale_min, scale_max] row.
static func _pick_species(group: Array, rng: RandomNumberGenerator) -> Array:
	var total := 0.0
	for row in group:
		total += float(row[1])
	var r := rng.randf() * total
	for row in group:
		r -= float(row[1])
		if r <= 0.0:
			return row
	return group[group.size() - 1]

## Cliff meshes as rotated local boxes -- identical construction to TreeScatter / RockScatter.
static func _build_keep_rects(cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary) -> Array[Dictionary]:
	var keep_rects: Array[Dictionary] = []
	var cliff_defs_by_name: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
	return keep_rects

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	last_counts = {}
