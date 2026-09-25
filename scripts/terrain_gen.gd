## WorldGenerator (sibling of Terrain3D and Player in main.tscn): runs the terrain pipeline
## once per play session. This file is only the orchestrator -- each system lives in its own
## static-only module under scripts/terrain/ (split out 2026-09-25):
##   TerrainConfig   terrain_config.gd   shared constants (map size, MASTER_SEED, cliff defs, ids)
##   TerrainHeightmap heightmap.gd       build_heightmap(): noise, valley, smoothing, color/control maps
##   TerrainErosion  erosion.gd          droplet erosion
##   CliffFeatures   cliff_features.gd   escarpments, ravines, terraces, rises, knolls
##   CliffDressing   cliff_dressing.gd   cliff mesh planning + seating the heightmap to it
##   CliffInstancer  cliff_instancer.gd  cliff mesh instancing, materials, LODs, trimesh collision
##   TerrainRoad     road.gd             A* routing, grading, road ribbon mesh
##   TerrainOutcrops outcrops.gd         flat rock outcrops
##   RockScatter     rock_scatter.gd     boulders, erratics, scree
##   TreeScatter     tree_scatter.gd     trees + debug_tree_probe
##   UnderstoryScatter understory_scatter.gd  shrubs + ferns, density from canopy + shaded cliff feet
##   TerrainUtil     terrain_util.gd     height/normal sampling, zone ranges, mesh helpers
## New system -> new module there (class_name + extends RefCounted + static funcs), called from
## _ready() below. Per-run mutable state = static vars reset in the module's reset_run_state().
extends Node3D

func _ready() -> void:
	# Per-run static state in the terrain modules (was member vars on this node).
	CliffDressing.reset_run_state()
	CliffInstancer.reset_run_state()
	RockScatter.reset_run_state()
	TreeScatter.reset_run_state()
	UnderstoryScatter.reset_run_state()
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
	var resolved_seed := randi() if TerrainConfig.MASTER_SEED < 0 else TerrainConfig.MASTER_SEED
	print("TERRAIN_GEN: building %dx%d heightmap (master_seed=%d)..." % [TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, resolved_seed])
	var t_start := Time.get_ticks_msec() # temporary timing probe -- answering "is runtime-per-session generation viable" needs a real number, not a guess
	var maps := TerrainHeightmap.build_heightmap(resolved_seed)
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
	var half_width := TerrainConfig.AREA_WIDTH * 0.5
	var half_length := TerrainConfig.AREA_LENGTH * 0.5
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
	if CliffDressing.RAISE_DEBUG_SHOW_SURFACE:
		CliffDressing.spawn_raise_debug_boxes(get_parent(), heightmap_corner)

	var boulder_rng := RandomNumberGenerator.new()
	# Independent stream from the main pipeline's _derive_seeds -- purely
	# cosmetic scattering, doesn't need to be in that fixed derivation order.
	boulder_rng.seed = resolved_seed ^ 0x424F554C # 'BOUL' salt
	RockScatter.scatter_boulders(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.cliff_features, heightmap_corner, boulder_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: boulder scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Scree: dense collider-free debris carpet over the SAME cliff-foot masks,
	# layered under the boulders just scattered above -- see _scatter_scree.
	var scree_rng := RandomNumberGenerator.new()
	scree_rng.seed = resolved_seed ^ 0x53435245 # 'SCRE' salt -- own cosmetic stream
	RockScatter.scatter_scree(terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.cliff_features, heightmap_corner, scree_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: scree scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = resolved_seed ^ 0x54524545 # 'TREE' salt -- own cosmetic stream
	TreeScatter.scatter_trees(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, tree_rng, maps.road_weight, maps.road_path, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: tree scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Understory (shrubs + ferns): density reads the canopy just placed (TreeScatter.tree_points)
	# plus shaded cliff feet -- must run after trees + boulders. Own cosmetic stream.
	var understory_rng := RandomNumberGenerator.new()
	understory_rng.seed = resolved_seed ^ 0x554E4452 # 'UNDR' salt
	UnderstoryScatter.scatter_understory(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, understory_rng, maps.road_weight, maps.cliff_features, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	print("TERRAIN_GEN: understory scattering (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# Planned + terrain-fitted in _build_heightmap (round 2) -- instancing only here.
	TerrainOutcrops.place_outcrops(get_parent(), maps.outcrop_plan, maps.outcrop_models, heightmap_corner)
	print("TERRAIN_GEN: outcrop placement (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	TerrainRoad.build_road_mesh(get_parent(), maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.road_path, heightmap_corner, resolved_seed)
	print("TERRAIN_GEN: road mesh build (%.2fs)" % ((Time.get_ticks_msec() - t_ready_stage) / 1000.0))
	t_ready_stage = Time.get_ticks_msec()

	# 2026-09-17 reorder: placement is already decided (maps.cliff_dressing_plan, computed
	# inside _build_heightmap before Terrain3D import so the heightmap could be flattened to
	# match each mesh's footprint -- see _plan_cliff_dressing) -- this call only instances it.
	CliffInstancer.dress_cliff_faces(get_parent(), maps.cliff_dressing_plan, heightmap_corner, data, maps.cliff_dressing_top_profiles)
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

## PerfDebug (key T) calls this on the WorldGenerator node -- the probe itself now lives in
## TreeScatter alongside the placement checks it re-runs.
func debug_tree_probe(world_pos: Vector3) -> String:
	return TreeScatter.debug_tree_probe(world_pos)
