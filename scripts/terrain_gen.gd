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
##   TerrainHub      hub.gd              the fixed strip south of the map: raised village plateau + scarp with a trail down
##   TerrainCastle   castle.gd           the fixed block north of the map: the bay the valley ends in, with the castle in its far corner
##   WorldBounds     world_bounds.gd     invisible walls just inside the edges of map + hub
##   MountainWalls   mountain_walls.gd   mountain meshes beyond the map's edge, carrying the valley's slopes on up
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
	# DEBUG: --seed=<n> (user argument) builds that map, whatever MASTER_SEED says -- to look again
	# at something found on a random run, from a command line.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			resolved_seed = int(arg.trim_prefix("--seed="))
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
	# Snapped down to a region corner: Terrain3D 1.1 puts the image exactly at this position, where
	# 1.0.2 snapped it itself (unsnapped, the 768 m wide import took four regions across and the
	# whole map sat 64 m off).
	var import_region := float(terrain.get_region_size())
	var import_position := Vector3(floorf(-half_width / import_region) * import_region, 0, floorf(-half_length / import_region) * import_region)
	# The hub's fixed strip of ground goes in with the generated map, south (+Z) of it: Terrain3D
	# adds the extra regions toward +Z, so the generated map's corner stays where it was.
	maps["hub_heights"] = TerrainHub.build_heights(maps.heights)
	var images: Array[Image] = TerrainHub.join_images(maps, maps.hub_heights, terrain.get_region_size(), resolved_seed) # [HEIGHT, CONTROL, COLOR]
	data.import_images(images, import_position, 0.0, 1.0)
	data.calc_height_range(true)
	_apply_displacement(terrain)

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
	# The generated map's pixel (0, 0): past the mountain apron, which takes the import's first
	# APRON_WIDTH columns (MountainWalls.apron_maps), and past the castle end, which takes its first
	# TerrainCastle.LENGTH rows (TerrainCastle.build_maps).
	# 2026-10-09: and past MountainWalls.WEST_EXTRA more columns west of that apron (MAP_OFFSET_X
	# in all): holes, except where the village's shoulder stands.
	var heightmap_corner := Vector3(min_region_x * region_size + MountainWalls.MAP_OFFSET_X, 0, min_region_z * region_size + TerrainCastle.LENGTH)
	# The west strip must be a hole away from the village and ground under it.
	var strip_x := -float(MountainWalls.APRON_WIDTH) - float(MountainWalls.WEST_EXTRA) * 0.5
	print("TERRAIN_GEN: west strip check -- hole in it far from the village: %s (must be true), under the village: %s (must be false), just inside the map: %s (must be false)" % [
		data.get_control_hole(heightmap_corner + Vector3(strip_x, 0.0, TerrainConfig.AREA_LENGTH * 0.75)),
		data.get_control_hole(heightmap_corner + Vector3(TerrainCastle.VILLAGE_PX.x, 0.0, TerrainCastle.VILLAGE_PX.y)),
		data.get_control_hole(heightmap_corner + Vector3(TerrainConfig.AREA_WIDTH - 2.0, 0.0, 10.0))])

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
	# Here, a frame after _apply_displacement, so the shaders copied are the ones Terrain3D has
	# generated for the displacement settings (the function checks that displacement is in them).
	if PROJECTION_PER_PIXEL and DISPLACEMENT_TESSELLATION > 0:
		_apply_projection_override(terrain)
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

	# Boulders and scree along the mountain's foot line -- before the trees, which keep clear of rocks.
	var foot_rng := RandomNumberGenerator.new()
	foot_rng.seed = resolved_seed ^ 0x464F4F54 # 'FOOT' salt -- own cosmetic stream
	MountainWalls.scatter_foot_debris(get_parent(), terrain, maps, heightmap_corner, foot_rng)
	_log_stage("mountain foot debris", t_ready_stage)
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

	if not _road_displaced: # TRIAL: a displaced Road texture replaces the overlay (DISPLACEMENT_ROAD_SCALE)
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
	# The stand-ins for the castle and its bridge, at the valley's north end.
	TerrainCastle.spawn_placeholder(get_parent(), terrain, heightmap_corner)
	# The mountain walls that carry the valley's slopes on beyond the map's edge (scenery only).
	t_ready_stage = Time.get_ticks_msec()
	MountainWalls.build(get_parent(), maps, heightmap_corner, resolved_seed)
	# The mountain strips are fitted to maps.heights: the terrain actually drawn must agree with it
	# along both long edges, and step on smoothly 1 m outside them (the first metre of a strip
	# continues the map's own grade, so the step there is at most that grade's 1.3 m).
	var edge_mismatch := 0.0
	var edge_step := 0.0
	var last_px := TerrainConfig.AREA_WIDTH - 1
	for row in range(0, TerrainConfig.AREA_LENGTH, 8):
		for edge: Array in [[0, -1.0], [last_px, 1.0]]:
			var at_edge := float(maps.heights[row * TerrainConfig.AREA_WIDTH + int(edge[0])])
			edge_mismatch = maxf(edge_mismatch, absf(data.get_height(heightmap_corner + Vector3(float(edge[0]), 0.0, row)) - at_edge))
			edge_step = maxf(edge_step, absf(data.get_height(heightmap_corner + Vector3(float(edge[0]) + float(edge[1]), 0.0, row)) - at_edge))
	print("TERRAIN_GEN: mountain walls -- drawn terrain vs generated heights along both long edges: largest difference %.3f m (must be ~0); largest step onto the mountain strips %.2f m (must be under 1.4; up to TerrainCastle.MASSIF_EDGE_GRADE beside the village's shoulder)" % [edge_mismatch, edge_step])
	_log_stage("mountain walls", t_ready_stage)
	t_ready_stage = Time.get_ticks_msec()

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
		# 2026-10-06: the player starts on the hub's plateau, facing its drop-off and, beyond it, the
		# road's start (maps.spawn_pixel, the old start position on the generated map's south edge).
		var spawn_world: Vector3 = heightmap_corner + TerrainHub.spawn_pixel(maps.hub_heights)
		var exit_world: Vector3 = heightmap_corner + Vector3(maps.spawn_pixel.x, maps.spawn_pixel.y, maps.spawn_pixel.z)
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
		print("TERRAIN_GEN: player spawned at %s facing the road's start at %s" % [player.global_position, exit_world])
	_log_stage("player placement", t_ready_stage)
	TerrainPreload.finish()

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--debug-heights="):
			var box := arg.trim_prefix("--debug-heights=").split(",")
			if box.size() >= 4:
				print("TERRAIN_GEN_DEBUG " + debug_height_grid(int(box[0]), int(box[1]), int(box[2]), int(box[3]), int(box[4]) if box.size() > 4 else 1))
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

## Displacement (Terrain3D 1.1), on by default since 2026-10-09 (Kirill: "turn on displacement by
## default without needing to run separate scripts"). Set here at startup, not in main.tscn or
## terrain_assets.tres. The values are the ones Kirill tried and liked. TUNING.
const DISPLACEMENT_TESSELLATION := 3 ## 0 = off
const DISPLACEMENT_SCALE := 2.0
const DISPLACEMENT_TEXTURE_IDS: Array[int] = [2] ## RockFace: the mountain AND the walkable rock at cliffs
const DISPLACEMENT_TEXTURE_SCALE := 1.0
const DISPLACEMENT_TEXTURE_UV_SCALE := 0.15 ## about a 13 m tile; 0 = leave the textures' tile size as it is
const DISPLACEMENT_MESH_SIZE := 64 ## Terrain3D.mesh_size while displacement is on (48 in the scene); 0 = leave it
## TRIAL (2026-10-10): projection decided per PIXEL. Terrain3D decides per 1 m vertex whether a
## texture is laid from above or from the side (steeper than 45 deg), from a slope measured toward
## +X / +Z only; along every crease the four vertices round a pixel disagree, and the one that is
## wrong for the pixel smears its texture into stripes (Kirill's screenshots: a striped band at
## the foot and the lip of walls). With this on, the addon's own generated shaders -- the
## terrain's and the displacement buffer's -- are patched at startup so all four use the slope of
## the surface at the pixel (_apply_projection_override). false = the addon's shaders as they are.
const PROJECTION_PER_PIXEL := true
## Slopes (deg) between which the two ways of laying a texture are mixed: all from above below
## the first, all from the side above the second. A wider range hides the change better and
## costs two sets of texture reads on more of the ground.
## 2026-10-10: were 35 / 55 (and 15 / 75 below). Kirill compared a 40-50 deg slope with no
## projection: one coherent rock picture, against a patchwork here, where three differently laid
## copies of the 13 m rock tile were mixed. Laid from above, a texture is stretched 2x at 60 deg
## and 2.9x at 70; so slopes keep the one picture up to 50 deg and only near-walls change over.
const PROJECTION_BLEND_FLAT := 50.0
const PROJECTION_BLEND_STEEP := 70.0
## The mix follows a smoothed slope, so it has no lines at the 1 m cells' edges; these two keep it
## honest at a real crease, by the cell's exact slope (deg): flatter than the first, nothing is
## laid from the side (no stripes on the floor beside a wall); steeper than the second, nothing
## from above (none on the wall).
const PROJECTION_NO_SIDE_BELOW := 35.0
const PROJECTION_ALL_SIDE_FROM := 80.0
## How quickly a steep face turns from "laid along X" to "laid along Z" as it turns its heading
## (1 = a slow change, both drawn over most headings; larger = each face mostly one of them).
const PROJECTION_SIDE_SHARPNESS := 4.0
## TRIAL (2026-10-09, Kirill: "let's try displacement for the road texture"): the terrain's Road
## texture (id 1, a 2 m tile) displaced by this scale -- 0.3 is about 10 cm from the stones' tops
## to the joints. The offset puts the stones' TOPS on the collision surface (-0.5 = the whole
## relief below it), so the player walks on them. While it is on, the RoadMesh overlay (the flat
## parallax ribbon 3 cm above the ground, TerrainRoad.build_road_mesh) is NOT built -- the
## displaced ground would come through it -- and the Road texture's detiling is switched off (it
## turned every 1 m cell of the paving a different way; the overlay used to hide that). 0 = the
## road as it was, with its overlay.
const DISPLACEMENT_ROAD_SCALE := 1
const DISPLACEMENT_ROAD_OFFSET := -0.5
var _road_displaced := false
## TRIAL (2026-10-09, Kirill asked to see it): the PineLitter texture (id 8, the needle litter
## under the canopy; a tile of about 3 m) displaced by this scale -- 0.12 is about 3 cm up and
## 3 cm down (1.0 would be 25 cm). Plants and debris stand at the undisplaced height. 0 = flat.
const DISPLACEMENT_LITTER_SCALE := 1.2
## TRIAL (2026-10-10, Kirill: "let's do aerial rocks texture next"): the AerialRocks texture
## (id 4, the mossy rock ground at cliffs; a 1 m tile) displaced by this scale -- 1.0 is about
## 8 cm up and 8 cm down. 0 = flat.
const DISPLACEMENT_AERIAL_ROCKS_SCALE := 1.0
## TRIAL (2026-10-10, Kirill: "let's do coast sand rocks next"): the CoastSandRocks texture
## (id 3, where cliff meets grass; a 1 m tile) displaced by this scale -- 1.0 is about 8 cm up
## and 8 cm down. 0 = flat.
const DISPLACEMENT_COAST_SAND_ROCKS_SCALE := 1.0
## TRIAL (2026-10-10, Kirill: "let's do rock face, rocky trail, and rocky terrain also"): the two
## scree textures, RockyTrail (id 6) and RockyTerrain (id 7, scree with grass), both on a 1 m
## tile -- 1.0 is about 8 cm up and 8 cm down. 0 = flat. (RockFace was displaced already:
## DISPLACEMENT_TEXTURE_IDS above.)
const DISPLACEMENT_ROCKY_TRAIL_SCALE := 3.0
const DISPLACEMENT_ROCKY_TERRAIN_SCALE := 3.0
## The Ground (soil) and Grass textures stay flat: both were tried the same day at about 8 cm
## each way and removed again (Kirill: "grass is definitely off", then "remove soil too").

## DEBUG (PerfDebug F4): the displacement of the textures under trial off / on in the running
## game, to compare (not saved). Texture id -> the scale it has when on. RockFace, RockyTrail and
## RockyTerrain since 2026-10-10 (before them, one at a time: the pine litter, the aerial rocks,
## the coast sand rocks). To put other textures on the key, change this dictionary.
const DISPLACEMENT_TOGGLE := {
	2: DISPLACEMENT_TEXTURE_SCALE, # RockFace
	6: DISPLACEMENT_ROCKY_TRAIL_SCALE,
	7: DISPLACEMENT_ROCKY_TERRAIN_SCALE,
}
var _trial_displacement_on := true
func toggle_trial_displacement() -> String:
	var terrain: Terrain3D = get_parent().get_node_or_null("Terrain3D")
	if terrain == null or terrain.get_assets() == null:
		return "[WorldGenerator] displacement toggle: no Terrain3D"
	_trial_displacement_on = not _trial_displacement_on
	var names := PackedStringArray()
	for id: int in DISPLACEMENT_TOGGLE:
		var asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(id)
		if asset:
			asset.displacement_scale = float(DISPLACEMENT_TOGGLE[id]) if _trial_displacement_on else 0.0
			names.append(asset.name)
	return "[WorldGenerator] displacement of %s: %s" % [", ".join(names), "on" if _trial_displacement_on else "OFF"]

## Applies the displacement settings above (the DISPLACEMENT_* constants are the only way to
## change them: Kirill, 2026-10-09, "no more arguments, only variables"). A texture's relief is
## 0.04 x its scale x its tile size (the buffer shader), times the global scale. Projection is
## switched on with it: displaced faces are steep.
func _apply_displacement(terrain: Terrain3D) -> void:
	if DISPLACEMENT_TESSELLATION <= 0:
		return
	if DISPLACEMENT_MESH_SIZE > 0:
		terrain.mesh_size = DISPLACEMENT_MESH_SIZE
	terrain.tessellation_level = DISPLACEMENT_TESSELLATION
	terrain.displacement_scale = DISPLACEMENT_SCALE
	terrain.material.projection_enabled = true
	for id in DISPLACEMENT_TEXTURE_IDS:
		var texture_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(id)
		if texture_asset == null:
			continue
		texture_asset.displacement_scale = DISPLACEMENT_TEXTURE_SCALE
		if DISPLACEMENT_TEXTURE_UV_SCALE > 0.0:
			texture_asset.uv_scale = DISPLACEMENT_TEXTURE_UV_SCALE
		print("TERRAIN_GEN: displacement -- texture %d (%s): uv_scale %.2f, displacement scale %.2f, relief about +-%.2f m" % [id, texture_asset.name, texture_asset.uv_scale, texture_asset.displacement_scale, minf(texture_asset.displacement_scale * 0.04 / (0.5 * texture_asset.uv_scale), 1.0) * DISPLACEMENT_SCALE])
	var road_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(TerrainRoad.ROAD_TEXTURE_ID)
	if DISPLACEMENT_ROAD_SCALE > 0.0 and road_asset:
		_road_displaced = true
		road_asset.displacement_scale = DISPLACEMENT_ROAD_SCALE
		road_asset.displacement_offset = DISPLACEMENT_ROAD_OFFSET
		road_asset.detiling_rotation = 0.0
		road_asset.detiling_shift = 0.0
		print("TERRAIN_GEN: displacement -- road texture: scale %.2f, offset %.2f, about %.0f cm from the stones' tops to the joints at %.1f cm between vertices; no RoadMesh overlay, no detiling" % [DISPLACEMENT_ROAD_SCALE, DISPLACEMENT_ROAD_OFFSET, DISPLACEMENT_ROAD_SCALE * 0.04 / (0.5 * road_asset.uv_scale) * DISPLACEMENT_SCALE * 200.0, 100.0 / pow(2.0, DISPLACEMENT_TESSELLATION)])
	var litter_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(TerrainGroundPaint.PINE_LITTER_ID)
	if DISPLACEMENT_LITTER_SCALE > 0.0 and litter_asset:
		litter_asset.displacement_scale = DISPLACEMENT_LITTER_SCALE
		print("TERRAIN_GEN: displacement -- pine litter texture: uv_scale %.2f, scale %.2f, relief about +-%.1f cm" % [litter_asset.uv_scale, DISPLACEMENT_LITTER_SCALE, DISPLACEMENT_LITTER_SCALE * 0.04 / (0.5 * litter_asset.uv_scale) * DISPLACEMENT_SCALE * 100.0])
	var aerial_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(TerrainGroundPaint.AERIAL_ROCKS_ID)
	if DISPLACEMENT_AERIAL_ROCKS_SCALE > 0.0 and aerial_asset:
		aerial_asset.displacement_scale = DISPLACEMENT_AERIAL_ROCKS_SCALE
		print("TERRAIN_GEN: displacement -- aerial rocks texture: uv_scale %.2f, scale %.2f, relief about +-%.1f cm" % [aerial_asset.uv_scale, DISPLACEMENT_AERIAL_ROCKS_SCALE, DISPLACEMENT_AERIAL_ROCKS_SCALE * 0.04 / (0.5 * aerial_asset.uv_scale) * DISPLACEMENT_SCALE * 100.0])
	var coast_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(TerrainGroundPaint.COAST_SAND_ROCKS_ID)
	if DISPLACEMENT_COAST_SAND_ROCKS_SCALE > 0.0 and coast_asset:
		coast_asset.displacement_scale = DISPLACEMENT_COAST_SAND_ROCKS_SCALE
		print("TERRAIN_GEN: displacement -- coast sand rocks texture: uv_scale %.2f, scale %.2f, relief about +-%.1f cm" % [coast_asset.uv_scale, DISPLACEMENT_COAST_SAND_ROCKS_SCALE, DISPLACEMENT_COAST_SAND_ROCKS_SCALE * 0.04 / (0.5 * coast_asset.uv_scale) * DISPLACEMENT_SCALE * 100.0])
	for scree: Array in [[TerrainGroundPaint.ROCKY_TRAIL_ID, DISPLACEMENT_ROCKY_TRAIL_SCALE], [TerrainGroundPaint.ROCKY_TERRAIN_ID, DISPLACEMENT_ROCKY_TERRAIN_SCALE]]:
		var scree_asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(int(scree[0]))
		if float(scree[1]) > 0.0 and scree_asset:
			scree_asset.displacement_scale = float(scree[1])
			print("TERRAIN_GEN: displacement -- %s texture: uv_scale %.2f, scale %.2f, relief about +-%.1f cm" % [scree_asset.name, scree_asset.uv_scale, float(scree[1]), float(scree[1]) * 0.04 / (0.5 * scree_asset.uv_scale) * DISPLACEMENT_SCALE * 100.0])
	print("TERRAIN_GEN: displacement -- Terrain3D %s, tessellation %d, displacement scale %.2f, mesh_size %d" % [terrain.version, terrain.tessellation_level, terrain.displacement_scale, terrain.mesh_size])

## PROJECTION_PER_PIXEL: takes the two shaders Terrain3D has generated for the current settings
## and installs changed copies as shader overrides. In the copies every corner vertex's texture
## is laid by the slope of the surface AT THE PIXEL, not by the vertex's own, and in up to three
## ways mixed by smooth weights: from above (all of it where flatter than PROJECTION_BLEND_FLAT),
## from the side along X and from the side along Z (all side where steeper than
## PROJECTION_BLEND_STEEP, shared between the two by the face's heading). Each
## accumulate_material() call becomes three; one whose weight is about 0 is skipped.
## The weights follow a SMOOTH slope (central differences at the four vertices, interpolated),
## so they do not jump at the 1 m cells' edges; the cell's EXACT slope only limits them
## (PROJECTION_NO_SIDE_BELOW / PROJECTION_ALL_SIDE_FROM), which leaves a line at real creases.
## Tried first, the same day:
##   - the same three ways mixed by the exact slope alone: no stripes, but the slope jumps at
##     every cell edge and the lines showed on curved ground (Kirill: "still fairly visible");
##   - the three ways mixed by a SMOOTH slope (central differences at the four vertices,
##     interpolated): no lines, but beside a wall the flat floor counts as steep and the side
##     projection smears into stripes on it (Kirill: "stretching is back");
##   - a hard switch at 45 deg from the exact slope: no stripes, but a seam where the picture and
##     the displaced relief both jumped (Kirill: "a sharp angle and seam/crease at the bends");
##   - a blend of above / side, the side's direction still snapped to 45 deg steps of heading as
##     in the addon, from the exact slope of each 1 m cell: the slope jumps at every cell edge and
##     the direction at every step, so the ground showed as flat planes with hard edges (Kirill:
##     "you can clearly see geometric planes with angles").
## Patched from the addon's generated text, not from a copy kept in the project, so an addon
## update is picked up; if the text no longer has the expected lines, nothing is overridden and
## a warning says so. While an override is on, Terrain3D does not regenerate that shader when a
## material feature is switched.
func _apply_projection_override(terrain: Terrain3D) -> void:
	var mat: Terrain3DMaterial = terrain.material
	# The line where the calls begin (the generated text has no comments to anchor on).
	var anchor := "material mat = material("
	# One call: (1) up to its bilinear weight, (2) the corner, (3) up to the vertex normal, (4) the rest.
	var calls := RegEx.create_from_string("accumulate_material\\(([^;]*?)weights\\[(\\d)\\]([^;]*?)index_normal\\[\\d\\]([^;]*?)\\);")
	var three_calls := """if (px_wt > 0.004) {
		accumulate_material($1weights[$2] * px_wt$3px_n_top$4);
	}
	if (px_wx > 0.004) {
		accumulate_material($1weights[$2] * px_wx$3px_n_x$4);
	}
	if (px_wz > 0.004) {
		accumulate_material($1weights[$2] * px_wz$3px_n_z$4);
	}"""
	# The exact slope of the surface at the pixel: that of the bilinear height patch of its cell.
	# h[3], h[2], h[0], h[1] are the heights at the cell's corners (0,0), (1,0), (0,1), (1,1).
	# OPEN / CLOSE: the terrain shader has h[1] only where it blends four vertices (near the camera).
	# px_exact; and px_normal, the SMOOTH slope: central differences at the four corners (the
	# eight heights fetched are their outer neighbours), interpolated.
	var slope := """	vec3 px_normal = index_normal[3];
	vec3 px_exact = index_normal[3];
	OPEN
		px_exact = normalize(vec3(-mix(h[2] - h[3], h[1] - h[0], weight.y), _vertex_spacing, -mix(h[0] - h[3], h[1] - h[2], weight.x)));
		float px_xa = get_height(index_id, vec2(-1.0, 0.0));
		float px_xb = get_height(index_id, vec2(-1.0, 1.0));
		float px_za = get_height(index_id, vec2(0.0, -1.0));
		float px_zb = get_height(index_id, vec2(1.0, -1.0));
		float px_x2a = get_height(index_id, vec2(2.0, 0.0));
		float px_x2b = get_height(index_id, vec2(2.0, 1.0));
		float px_z2a = get_height(index_id, vec2(0.0, 2.0));
		float px_z2b = get_height(index_id, vec2(1.0, 2.0));
		float px_dx = mix(mix(h[2] - px_xa, px_x2a - h[3], weight.x), mix(h[1] - px_xb, px_x2b - h[0], weight.x), weight.y) * 0.5;
		float px_dz = mix(mix(h[0] - px_za, px_z2a - h[3], weight.y), mix(h[1] - px_zb, px_z2b - h[2], weight.y), weight.x) * 0.5;
		px_normal = normalize(vec3(-px_dx, _vertex_spacing, -px_dz));
	CLOSE
"""
	# The three weights, and a normal for each that makes the addon's projection code lay the
	# texture that way (it projects from the side where the normal's y is <= sqrt(0.5), along the
	# normal's heading).
	# The side's share follows the smooth slope, held inside what the exact slope allows: none
	# where the surface itself is nearly flat, all where it is nearly upright.
	var blend := """	float px_side = 1.0 - smoothstep(%f, %f, px_normal.y);
	px_side = clamp(px_side, 1.0 - smoothstep(%f, %f, px_exact.y), 1.0 - smoothstep(%f, %f, px_exact.y));
	vec2 px_a = pow(abs(px_normal.xz) + abs(px_exact.xz) * 0.02, vec2(%f));
	px_a /= px_a.x + px_a.y + 0.000001;
	float px_wt = 1.0 - px_side;
	float px_wx = px_side * px_a.x;
	float px_wz = px_side * px_a.y;
	vec3 px_n_top = vec3(0.0, 1.0, 0.0);
	vec3 px_n_x = vec3(px_normal.x < 0.0 ? -1.0 : 1.0, 0.0, 0.0);
	vec3 px_n_z = vec3(0.0, 0.0, px_normal.z < 0.0 ? -1.0 : 1.0);
""" % [cos(deg_to_rad(PROJECTION_BLEND_STEEP)), cos(deg_to_rad(PROJECTION_BLEND_FLAT)),
		cos(deg_to_rad(PROJECTION_ALL_SIDE_FROM)), cos(deg_to_rad(PROJECTION_BLEND_STEEP)),
		cos(deg_to_rad(PROJECTION_BLEND_FLAT)), cos(deg_to_rad(PROJECTION_NO_SIDE_BELOW)),
		PROJECTION_SIDE_SHARPNESS]
	var shaders: Array[Shader] = []
	for rid: RID in [mat.get_shader_rid(), mat.get_buffer_shader_rid()]:
		var code := RenderingServer.shader_get_code(rid) if rid.is_valid() else ""
		if code.count(anchor) != 1 or calls.search_all(code).size() != 4 or not code.contains("i_normal.y <= 0.7071067811865475"):
			push_warning("TERRAIN_GEN: projection per pixel NOT applied -- a generated Terrain3D shader does not look as expected (%d chars, anchor x%d, calls x%d)" % [code.length(), code.count(anchor), calls.search_all(code).size()])
			return
		if shaders.is_empty() and not code.contains("get_displacement("):
			push_warning("TERRAIN_GEN: projection per pixel NOT applied -- the terrain shader has no displacement in it yet")
			return
		var define := slope.replace("OPEN", "if (bilerp) {" if code.contains("bool bilerp") else "{").replace("CLOSE", "}")
		code = calls.sub(code, three_calls, true)
		code = code.insert(code.rfind("\n", code.find(anchor)) + 1, define + blend)
		var shader := Shader.new()
		shader.code = code
		shaders.append(shader)
	_projection_shaders = shaders
	mat.set_shader_override(shaders[0])
	mat.set_shader_override_enabled(true)
	mat.set_buffer_shader_override(shaders[1])
	mat.set_buffer_shader_override_enabled(true)
	print("TERRAIN_GEN: projection per pixel -- terrain shader and displacement buffer shader overridden (%d and %d chars), blended between %.0f and %.0f deg" % [shaders[0].code.length(), shaders[1].code.length(), PROJECTION_BLEND_FLAT, PROJECTION_BLEND_STEEP])

## DEBUG (PerfDebug F3; not saved): steps through the three ways the terrain's textures can be
## laid, to compare them on the same spot.
var _projection_shaders: Array[Shader] = [] ## the two patched shaders, kept to switch back to
var _projection_mode := 0
const PROJECTION_MODE_NAMES: Array[String] = [
	"NEW -- per pixel, three ways blended (the patched shaders)",
	"OLD -- Terrain3D's own shaders, projection ON (per vertex)",
	"OFF -- Terrain3D's own shaders, NO projection (everything laid from above)",
]
func cycle_projection_mode() -> String:
	var terrain: Terrain3D = get_parent().get_node_or_null("Terrain3D")
	if terrain == null or terrain.material == null:
		return "[WorldGenerator] projection: no Terrain3D"
	var mat: Terrain3DMaterial = terrain.material
	_projection_mode = (_projection_mode + 1) % 3
	if _projection_mode == 0 and _projection_shaders.is_empty():
		_projection_mode = 1 # the patch was not applied at startup: nothing to switch back to
	var patched := _projection_mode == 0
	if patched:
		mat.set_shader_override(_projection_shaders[0])
		mat.set_buffer_shader_override(_projection_shaders[1])
	mat.set_shader_override_enabled(patched)
	mat.set_buffer_shader_override_enabled(patched)
	mat.projection_enabled = _projection_mode != 2
	return "[WorldGenerator] terrain projection: %s" % PROJECTION_MODE_NAMES[_projection_mode]

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

## DEBUG: the generated heights (m) on a grid of heightmap pixels, one line per row -- for a spot
## where the ground and a mesh do not meet. Also printed at startup for the user argument
## --debug-heights=<px0>,<pz0>,<px1>,<pz1>,<step>.
func debug_height_grid(px0: int, pz0: int, px1: int, pz1: int, step: int = 1) -> String:
	var heights: PackedFloat32Array = _debug_maps.get("heights", PackedFloat32Array())
	var foot: PackedFloat32Array = _debug_maps.get("mountain_foot", PackedFloat32Array())
	var lines: Array[String] = ["heights, px %d..%d step %d (columns), pz %d..%d (rows); last column = the mountain's foot line" % [px0, px1, step, pz0, pz1]]
	for pz in range(clampi(pz0, 0, TerrainConfig.AREA_LENGTH - 1), clampi(pz1, 0, TerrainConfig.AREA_LENGTH - 1) + 1, step):
		var cells: Array[String] = []
		for px in range(clampi(px0, 0, TerrainConfig.AREA_WIDTH - 1), clampi(px1, 0, TerrainConfig.AREA_WIDTH - 1) + 1, step):
			cells.append("%5.1f" % heights[pz * TerrainConfig.AREA_WIDTH + px])
		lines.append("pz %4d: %s | foot %.1f" % [pz, " ".join(cells), foot[pz] if pz < foot.size() else -1.0])
	return "
".join(lines)

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
