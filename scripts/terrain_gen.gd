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
##   DeadfallScatter deadfall_scatter.gd stumps, fallen logs, branch clumps (uphill of rocks/trunks, in stands)
##   UnderstoryScatter understory_scatter.gd  shrubs + ferns, density from canopy + shaded cliff feet
##   SaplingScatter  sapling_scatter.gd  mid-storey saplings (scaled-down canopy trees) at grove edges
##   FlowerScatter   flower_scatter.gd   wood sorrel under canopy; poppies, dandelions, clover in the open
##   PlantField      plant_field.gd      (a node, like GrassField) GPU-culled drawing of plants handed over by the scatter modules
##   FoliageWind     foliage_wind.gd     the wind noise shared by grass and plants; switches the understory / flower sway on
##   WorldBounds     world_bounds.gd     invisible walls just inside the map's edges
##   TerrainUtil     terrain_util.gd     height/normal sampling, zone ranges, mesh helpers
## New system -> new module there (class_name + extends RefCounted + static funcs), called from
## _ready() below. Per-run mutable state = static vars reset in the module's reset_run_state().
extends Node3D

func _ready() -> void:
	# First: the models/textures the later stages need start loading on background threads now,
	# so they are ready by the time the heightmap build below is done.
	TerrainPreload.begin()
	# Per-run static state in the terrain modules (was member vars on this node).
	CliffDressing.reset_run_state()
	CliffInstancer.reset_run_state()
	RockScatter.reset_run_state()
	TreeScatter.reset_run_state()
	UnderstoryScatter.reset_run_state()
	SaplingScatter.reset_run_state()
	FlowerScatter.reset_run_state()
	PlantField.reset_run_state()
	FoliageWind.reset_run_state()
	DeadfallScatter.reset_run_state()
	GrassScatter.reset_run_state()
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
	startup_timings = {"ready_started_at_ms": t_ready_start, "stage_ms": {}}
	# -1 means "randomize": roll a fresh seed via randi() this run rather than
	# reusing MASTER_SEED literally. Always printed either way, so whatever
	# came out (random or pinned) is copy-pasteable back into MASTER_SEED to
	# reproduce this exact map later.
	var resolved_seed := randi() if TerrainConfig.MASTER_SEED < 0 else TerrainConfig.MASTER_SEED
	print("TERRAIN_GEN: building %dx%d heightmap (master_seed=%d)..." % [TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, resolved_seed])
	var terrain: Terrain3D = get_parent().get_node_or_null("Terrain3D")
	if terrain == null:
		push_error("TERRAIN_GEN: no sibling Terrain3D node found under %s -- WorldGenerator must be a direct child of the same parent as the live Terrain3D" % get_parent().name)
		LoadingScreen.end() # the boot scene may have put it up
		return
	var data: Terrain3DData = terrain.get_data()
	# Terrain3D auto-loads whatever's on disk at terrain.data_directory when
	# it enters the tree (that's still there as a static fallback/editor
	# preview), so clear any regions that brought in before importing this
	# run's fresh heightmap -- otherwise a previous playthrough's (or the
	# editor's last saved) terrain would still be sitting underneath.
	# Done before the first loading-screen frame is drawn, so that terrain never shows.
	for region_location in data.get_region_locations().duplicate():
		data.remove_regionl(region_location, false)

	# Loading screen (2026-10-05): this function hands control back to the engine before each
	# group of stages (_loading_step) so the bar can be redrawn. The player is switched off until
	# the world exists -- it would fall through the still-empty map otherwise.
	var player: Node3D = get_parent().get_node_or_null("Player")
	var player_process_mode := Node.PROCESS_MODE_INHERIT
	if player:
		player_process_mode = player.process_mode
		player.process_mode = Node.PROCESS_MODE_DISABLED
	LoadingScreen.begin() # no-op when the boot scene already started it
	_loading_from = LoadingScreen.progress
	await _loading_step(0)

	var t_start := Time.get_ticks_msec() # temporary timing probe -- answering "is runtime-per-session generation viable" needs a real number, not a guess
	var maps := TerrainHeightmap.build_heightmap(resolved_seed)
	_debug_maps = maps # 2026-09-29 DEBUG (landmark capture / listing)
	_debug_seed = resolved_seed
	print("TERRAIN_GEN: heightmap build took %d ms (noise+erosion+smoothing+features+road, no I/O)" % (Time.get_ticks_msec() - t_start))
	startup_timings.stage_ms["heightmap build"] = Time.get_ticks_msec() - t_start

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
	var t_ready_stage := Time.get_ticks_msec()
	var half_width := TerrainConfig.AREA_WIDTH * 0.5
	var half_length := TerrainConfig.AREA_LENGTH * 0.5
	var import_position := Vector3(-half_width, 0, -half_length)
	var images: Array[Image] = [maps.height, maps.control, maps.color] # [HEIGHT, CONTROL, COLOR]
	data.import_images(images, import_position, 0.0, 1.0)
	data.calc_height_range(true)

	var height_range: Vector2 = data.get_height_range()
	print("TERRAIN_GEN: imported. region_count=%d height_range=%s" % [data.get_region_count(), height_range])
	_log_stage("Terrain3D import+height_range", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()
	# Shadow-casting plants PlantField will draw: their instancer copies become shadow casters only.
	# Here, while the instancer is still empty -- each change makes Terrain3D rebuild its nodes.
	PlantField.claim_shadow_casters(terrain.get_assets(), FlowerScatter.POPPY_IDS + UnderstoryScatter.UNDERSTORY_MESH_IDS)
	# Ferns, lady ferns and elderberries cast their sun shadows from their reduced mesh (2026-10-06,
	# Kirill compared both in game: "no significant difference"). --plants-full-shadows starts the
	# game with the full meshes casting; PerfDebug O switches it in a running game.
	var reduced_shadow_ids: Array[int] = [UnderstoryScatter.FERN_ID, UnderstoryScatter.ELDERBERRY_A_ID, UnderstoryScatter.ELDERBERRY_B_ID]
	reduced_shadow_ids.append_array(UnderstoryScatter.LADY_FERN_IDS)
	PlantField.declare_reduced_shadows(terrain, reduced_shadow_ids, not ("--plants-full-shadows" in OS.get_cmdline_user_args()))
	# Understory and flowers sway in the grass's wind (--no-foliage-wind starts without it).
	FoliageWind.setup(terrain.get_assets())

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

	# 2026-09-28: world coordinates of each verticality knot (knots.gd), so they can be found in-game.
	for knot in maps.knots:
		var anchor_world: Vector3 = heightmap_corner + Vector3(knot.ax, 0.0, knot.az)
		var lvl_parts: Array[String] = []
		for lvl in knot.levels:
			lvl_parts.append("%s (%.0f, %.1f, %.0f)" % [lvl.name, heightmap_corner.x + float(lvl.px), float(lvl.h), heightmap_corner.z + float(lvl.pz)])
		print("TERRAIN_GEN: KNOT #%d %s world anchor (%.0f, %.0f) -- %s" % [int(knot.index), TerrainKnots.KNOT_TYPE_NAMES[int(knot.type)], anchor_world.x, anchor_world.z, ", ".join(lvl_parts)])
		for ramp in knot.get("ramp_paths", []):
			var rf: Vector2 = ramp.from
			var rt: Vector2 = ramp.to
			print("TERRAIN_GEN:   KNOT #%d ramp to %s: from (%.0f, %.1f, %.0f) up to (%.0f, %.1f, %.0f)" % [int(knot.index), ramp.level, heightmap_corner.x + rf.x, float(ramp.from_h), heightmap_corner.z + rf.y, heightmap_corner.x + rt.x, float(ramp.to_h), heightmap_corner.z + rt.y])

	# 2026-09-18 debug scaffolding -- see _raise_debug_points' own comment near the top of the
	# file. heightmap_corner is only known here, so the actual box-spawning is deferred to now.
	if CliffDressing.RAISE_DEBUG_SHOW_SURFACE:
		CliffDressing.spawn_raise_debug_boxes(get_parent(), heightmap_corner)
	# 2026-09-29 DEBUG (landmarks), DISABLED -- kept for future landmark work. Uncommenting this line
	# brings back BOTH debug tools from TerrainLandmarks.spawn_debug_overlay:
	#   - the "what gets copied" overlay: cyan = copied 1:1, orange = blend band, magenta poles =
	#     copied cliff meshes ("LM mesh #k"), yellow poles = copied cliff features
	#   - the beacon shape picker (scripts/debug/landmark_beacon_tool.gd): B place, X remove nearest,
	#     N save the copy shape into the landmark JSON (used by stamp() from the next run)
	# TerrainLandmarks.spawn_debug_overlay(get_parent(), heightmap_corner, maps)

	await _loading_step(1)
	t_ready_stage = Time.get_ticks_msec()
	var boulder_rng := RandomNumberGenerator.new()
	# Independent stream from the main pipeline's _derive_seeds -- purely
	# cosmetic scattering, doesn't need to be in that fixed derivation order.
	boulder_rng.seed = resolved_seed ^ 0x424F554C # 'BOUL' salt
	RockScatter.scatter_boulders(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.cliff_features, heightmap_corner, boulder_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan, maps.knots)
	_log_stage("boulder scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Scree: dense collider-free debris carpet over the SAME cliff-foot masks,
	# layered under the boulders just scattered above -- see _scatter_scree.
	var scree_rng := RandomNumberGenerator.new()
	scree_rng.seed = resolved_seed ^ 0x53435245 # 'SCRE' salt -- own cosmetic stream
	RockScatter.scatter_scree(terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.cliff_features, heightmap_corner, scree_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan, maps.knots)
	_log_stage("scree scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = resolved_seed ^ 0x54524545 # 'TREE' salt -- own cosmetic stream
	TreeScatter.scatter_trees(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, tree_rng, maps.road_weight, maps.road_path, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	_log_stage("tree scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Deadfall (stumps, logs, branch clumps): banked uphill of the larger rocks and of trunks, and
	# scattered through the stands -- reads rock_keep_circles + tree_points, so after both. Runs
	# before the understory/grass so they keep clear of it. Own cosmetic stream.
	await _loading_step(2)
	t_ready_stage = Time.get_ticks_msec()
	var deadfall_rng := RandomNumberGenerator.new()
	deadfall_rng.seed = resolved_seed ^ 0x44454144 # 'DEAD' salt
	DeadfallScatter.scatter_deadfall(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, deadfall_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan, maps.knots)
	_log_stage("deadfall scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Understory (shrubs + ferns): density reads the canopy just placed (TreeScatter.tree_points)
	# plus shaded cliff feet -- must run after trees + boulders. Own cosmetic stream.
	await _loading_step(3)
	t_ready_stage = Time.get_ticks_msec()
	var understory_rng := RandomNumberGenerator.new()
	understory_rng.seed = resolved_seed ^ 0x554E4452 # 'UNDR' salt
	UnderstoryScatter.scatter_understory(get_parent(), terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, understory_rng, maps.road_weight, maps.cliff_features, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	_log_stage("understory scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Saplings (mid-storey): scaled-down canopy trees at grove edges -- reads the canopy, the rock
	# keep-outs and the deadfall, so after all three. Own cosmetic stream.
	var sapling_rng := RandomNumberGenerator.new()
	sapling_rng.seed = resolved_seed ^ 0x5341504C # 'SAPL' salt
	SaplingScatter.scatter_saplings(terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, sapling_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	_log_stage("sapling scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Grass step 1: bake the groundcover density/dry/tall texture (no instances -- the GPU
	# renderer reads it). Reads rock_keep_circles + the canopy, so after boulders/trees. Own stream.
	await _loading_step(4)
	t_ready_stage = Time.get_ticks_msec()
	var grass_rng := RandomNumberGenerator.new()
	grass_rng.seed = resolved_seed ^ 0x47525353 # 'GRSS' salt
	GrassScatter.bake(get_parent(), maps, heightmap_corner, grass_rng)
	# Grass step 2: the player-following GPU renderer that reads that bake (added deferred).
	GrassField.spawn(get_parent())
	# Drifting clouds in the sky shader + the moonlight dimming under them (scripts/cloud_sky.gd).
	CloudSky.spawn(get_parent())
	_log_stage("grass density bake", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Flowers: wood sorrel under the canopy; poppies, dandelions and clover on open grassed ground --
	# reads the grass coverage just baked, so after it. Own cosmetic stream.
	var flower_rng := RandomNumberGenerator.new()
	flower_rng.seed = resolved_seed ^ 0x464C5752 # 'FLWR' salt
	FlowerScatter.scatter_flowers(terrain, maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, heightmap_corner, flower_rng, maps.road_weight, maps.cliff_dressing_plan, maps.cliff_dressing_top_profiles, maps.outcrop_plan)
	# The GPU-culled renderer for the plants the scatter stages handed to PlantField.submit().
	PlantField.spawn(get_parent())
	_log_stage("flower scattering", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Ground texturing (2026-09-27): rewrites the control map in place -- Grass texture from the
	# grass coverage bake, rock/scree rings around cliffs, road kept. Needs the bake, so here.
	await _loading_step(5)
	t_ready_stage = Time.get_ticks_msec()
	var paint_rng := RandomNumberGenerator.new()
	paint_rng.seed = resolved_seed ^ 0x50414E54 # 'PANT' salt
	TerrainGroundPaint.paint(get_parent(), terrain, maps, heightmap_corner, paint_rng)
	_log_stage("ground painting", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	await _loading_step(6)
	t_ready_stage = Time.get_ticks_msec()
	# Planned + terrain-fitted in _build_heightmap (round 2) -- instancing only here.
	TerrainOutcrops.place_outcrops(get_parent(), maps.outcrop_plan, maps.outcrop_models, heightmap_corner)
	_log_stage("outcrop placement", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	TerrainRoad.build_road_mesh(get_parent(), maps.heights, TerrainConfig.AREA_WIDTH, TerrainConfig.AREA_LENGTH, maps.road_path, heightmap_corner, resolved_seed)
	_log_stage("road mesh build", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# 2026-09-17 reorder: placement is already decided (maps.cliff_dressing_plan, computed
	# inside _build_heightmap before Terrain3D import so the heightmap could be flattened to
	# match each mesh's footprint -- see _plan_cliff_dressing) -- this call only instances it.
	CliffInstancer.dress_cliff_faces(get_parent(), maps.cliff_dressing_plan, heightmap_corner, data, maps.cliff_dressing_top_profiles)
	_log_stage("cliff face dressing", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

	# Invisible walls just inside the map's edges, so the player cannot walk off it.
	WorldBounds.build(get_parent(), heightmap_corner)

	# Move the Player to this run's actual generated spawn point and face it
	# toward the exit -- a scene-baked Player transform (main.tscn's old
	# approach) goes stale the moment terrain params change (AREA_LENGTH,
	# ROAD_GOAL_BAND_FRACTION's random exit column, etc.), which is exactly
	# what silently broke when AREA_LENGTH was doubled: the spawn XZ didn't
	# move, but "forward" for a hand-placed rotation has no reason to still
	# point at where the (now much longer) map's content actually is. Doing
	# this here, every run, means it can never go stale again.
	if player == null:
		push_warning("TERRAIN_GEN: no sibling Player node found -- skipping spawn placement")
	else:
		# spawn_pixel/exit_pixel are (px, height, pz) in heightmap-pixel space --
		# only heightmap_corner (now read back from Terrain3D's real region
		# placement, see above) can correctly turn those into world positions.
		var spawn_world: Vector3 = heightmap_corner + Vector3(maps.spawn_pixel.x, maps.spawn_pixel.y, maps.spawn_pixel.z)
		var exit_world: Vector3 = heightmap_corner + Vector3(maps.exit_pixel.x, maps.exit_pixel.y, maps.exit_pixel.z)
		# The road starts on the very edge of the map: the player starts just inside the walls.
		spawn_world = WorldBounds.clamp_inside(spawn_world, heightmap_corner)
		player.global_position = spawn_world
		var facing: Vector3 = exit_world - spawn_world
		facing.y = 0.0 # look_at with a tilted target would pitch/roll the body itself, not just yaw it
		if facing.length_squared() > 0.0001:
			player.look_at(player.global_position + facing, Vector3.UP)
		# Player._ready() used to run after this placement and do these two itself; with the
		# loading screen it has long since run (on the empty map), so repeat them here.
		if player.has_method("_snap_to_ground"):
			player.call("_snap_to_ground")
			player.set("last_safe_transform", player.global_transform)
		print("TERRAIN_GEN: player spawned at %s facing exit at %s" % [player.global_position, exit_world])
	_log_stage("player placement", t_ready_stage)
	TerrainPreload.finish()

	print("TERRAIN_GEN: done (runtime -- nothing written to disk)")
	print("TERRAIN_GEN: _ready() TOTAL (%.2fs) -- this is the actual splash-to-playable gap this script controls" % ((Time.get_ticks_msec() - t_ready_start) / 1000.0))

	# 2026-09-21 startup-time probe (keep until the F6-to-playable investigation is done):
	# _ready() TOTAL only covers this script's own CPU work. Whatever happens AFTER it --
	# deferred add_child of the cliff/boulder/road nodes, physics broadphase for their
	# collision, and GPU pipeline/shader compilation for everything visible on the first
	# frame -- is invisible to it. These absolute timestamps (since process start, same
	# clock as the "_ready() started at" line) bracket that remaining gap.
	var t_ready_end := Time.get_ticks_msec()
	startup_timings["ready_total_ms"] = t_ready_end - t_ready_start
	print("TERRAIN_GEN_STARTUP: _ready() finished at t=%.2fs since process start | pipelines so far: %s" % [t_ready_end / 1000.0, _pipeline_counts_str()])
	# The world is built: 3D rendering goes back on, but the loading screen stays up over the
	# first frames (the first one compiles the shader pipelines and takes ~0.3 s).
	LoadingScreen.set_progress(_loading_from + (1.0 - _loading_from) * _loading_fraction(LOADING_STEPS.size() - 1), LOADING_STEPS[-1][0])
	LoadingScreen.show_world()
	await RenderingServer.frame_post_draw
	var t_first_draw := Time.get_ticks_msec()
	print("TERRAIN_GEN_STARTUP: first frame drawn at t=%.2fs since process start (+%.2fs after _ready) | pipelines so far: %s | physics step time %.1f ms" % [t_first_draw / 1000.0, (t_first_draw - t_ready_end) / 1000.0, _pipeline_counts_str(), Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
	for i in 3:
		await RenderingServer.frame_post_draw
	var t_settled := Time.get_ticks_msec()
	startup_timings["first_frame_at_ms"] = t_first_draw
	startup_timings["pipelines_at_settle"] = _pipeline_counts_str()
	startup_timings["settled_at_ms"] = t_settled # PerfBench waits for this key before it starts
	print("TERRAIN_GEN_STARTUP: 4th frame drawn at t=%.2fs since process start (frames 2-4 took %.2fs -- a big number here means shader compile stalls spilling past frame 1) | pipelines so far: %s" % [t_settled / 1000.0, (t_settled - t_first_draw) / 1000.0, _pipeline_counts_str()])
	if player:
		player.process_mode = player_process_mode
	LoadingScreen.end()

## Loading-screen steps: [text shown while the step runs, its rough duration in ms]. The durations
## only set how far the bar moves per step (measured 2026-10-05); the last entry is the wait for
## the first drawn frames.
const LOADING_STEPS := [
	["Shaping the terrain", 2450],
	["Placing rocks and trees", 290],
	["Scattering deadfall", 410],
	["Growing the undergrowth", 410],
	["Growing grass and flowers", 380],
	["Painting the ground", 470],
	["Raising cliffs and outcrops", 240],
	["Finishing", 900],
]
var _loading_from := 0.0 ## bar position when generation started (the boot scene's share)

## Share of the generation work done before step `index` starts, 0..1.
func _loading_fraction(index: int) -> float:
	var before := 0.0
	var total := 0.0
	for i in LOADING_STEPS.size():
		total += float(LOADING_STEPS[i][1])
		if i < index:
			before += float(LOADING_STEPS[i][1])
	return before / total

## Shows step `index` on the loading screen and waits for one frame to be drawn, so the player
## sees it before the step's (blocking) work starts.
func _loading_step(index: int) -> void:
	LoadingScreen.set_progress(_loading_from + (1.0 - _loading_from) * _loading_fraction(index), LOADING_STEPS[index][0])
	await RenderingServer.frame_post_draw


## Startup timings of this run, in ms: "stage_ms" (one entry per _log_stage call) plus the absolute
## timestamps since process start. Read by the benchmark (scripts/debug/perf_bench.gd).
var startup_timings: Dictionary = {}

## Prints one _ready() stage's duration (measured from t_from) and keeps it in startup_timings.
func _log_stage(stage: String, t_from: int) -> void:
	var ms := Time.get_ticks_msec() - t_from
	startup_timings.stage_ms[stage] = ms
	print("TERRAIN_GEN: %s (%.2fs)" % [stage, ms / 1000.0])

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

## 2026-10-01 DEBUG: deadfall pieces near a world position (which model, scale, lean).
func debug_deadfall_probe(world_pos: Vector3, radius: float = 6.0) -> String:
	return DeadfallScatter.debug_probe(world_pos, radius)

## 2026-09-29 DEBUG (landmarks): this run's generated maps + seed, kept for the calls below.
var _debug_maps: Dictionary = {}
var _debug_seed := 0

## Lists cliff meshes / outcrops / features within `reach` m of a heightmap pixel.
func debug_landmark_list(center_px: Vector2, reach: float) -> String:
	return TerrainLandmarks.debug_list(_debug_maps, center_px, reach)

## Captures TerrainLandmarks.CENTER_PX / RADIUS from this run into the landmark data file.
func debug_landmark_capture() -> String:
	return TerrainLandmarks.capture(_debug_maps, _debug_seed)
