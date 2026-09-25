## Cliff-face mesh dressing, instancing side: spawning the planned meshes, repair materials,
## LOD ranges and cached trimesh collision. Also reused by outcrop placement.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## CliffInstancer.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name CliffInstancer
extends RefCounted

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

## Instances one or more of the 5 large cliff-face meshes (CLIFF_DRESSING_DEFS) from a plan
## already computed by _plan_cliff_dressing (inside _build_heightmap, before Terrain3D import
## -- see that function's comment for why placement decisions live there now). This function
## does the mesh-instancing side only: loading scenes/materials, positioning/rotating/scaling
## each planned instance, applying collision, and spawning the same debug markers as before.
static func dress_cliff_faces(parent_node: Node, plan: Array[Dictionary], import_position: Vector3, data: Terrain3DData, top_profiles: Dictionary) -> void:
	# 2026-09-21 startup-time probe: splits this function's total into asset loading vs.
	# per-placement instancing vs. trimesh collision building.
	var t_dress_start := Time.get_ticks_msec()
	var parent := parent_node
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
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
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
			mesh_root.position = Vector3(import_position.x + px, height - TerrainConfig.CLIFF_DRESSING_EMBED_DEPTH * scale_jitter, import_position.z + pz)
			container.add_child.call_deferred(mesh_root)
			apply_cliff_material_recursive(mesh_root, materials[def_name])
			apply_cliff_lod_ranges(mesh_root)
			var t_col := Time.get_ticks_msec()
			t_instancing_ms += t_col - t_inst
			if not DEBUG_SKIP_CLIFF_COLLISION:
				collider_count += add_cliff_collision_recursive(mesh_root)
			t_collision_ms += Time.get_ticks_msec() - t_col
			placed_count += 1

	print("TERRAIN_GEN: dressed %d cliff-face mesh(es) (%d collision shape(s)) from %d planned placement(s)" % [placed_count, collider_count, plan.size()])
	print("TERRAIN_GEN_STARTUP:   cliff instancing+materials (%.3fs), trimesh collision (%.3fs, %d unique shape(s): %d loaded from disk cache, %d freshly baked)" % [t_instancing_ms / 1000.0, t_collision_ms / 1000.0, _cliff_trimesh_cache.size(), _cliff_trimesh_disk_hits, _cliff_trimesh_disk_bakes])

## Recursively applies `mat` as the material_override on every MeshInstance3D under `node`
## -- the cliff GLBs were exported with export_materials="NONE" (see
## export_cliffs_to_glb.ps1, matching the existing rock/boulder prop pipeline), so they have
## no material of their own and would otherwise render pink/unshaded.
static func apply_cliff_material_recursive(node: Node, mat: Material) -> void:
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
		apply_cliff_material_recursive(child, mat)

static var _cliff_repair_material_cache: Dictionary = {}

## Builds (once per rock material + kind) a copy of the rock material whose albedo is the
## baked repair texture sitting next to the rock's diffuse ("..._diff_2k.jpg" ->
## "..._<kind>_diff.png", kind = "fill" or "patch"). Normal/roughness maps are dropped because
## they're laid out for the rock's UV atlas, not the repair surface's. Returns null (caller
## keeps the rock material) if that bake doesn't exist.
static func _get_cliff_repair_material(mat: Material, kind: String) -> Material:
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
static var _cliff_trimesh_cache: Dictionary = {}

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
static func _cliff_lod_index(node_name: String) -> int:
	var at := node_name.rfind("_LOD")
	if at < 0:
		return -1
	var digits := node_name.substr(at + 4)
	return digits.to_int() if digits.is_valid_int() else -1

## True if this MeshInstance3D should get a collider: always for non-LOD pieces; for an LOD
## chain, only for the single chosen level among its same-named siblings.
static func _should_add_cliff_collision(node: Node) -> bool:
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

static func _build_simplified_cliff_trimesh(mesh: Mesh) -> ConcavePolygonShape3D:
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
static var _cliff_trimesh_disk_hits := 0
static var _cliff_trimesh_disk_bakes := 0

static func _load_or_bake_cliff_trimesh(mesh: Mesh, simplify: bool = true) -> Shape3D:
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

static func add_cliff_collision_recursive(node: Node) -> int:
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
		added += add_cliff_collision_recursive(child)
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

static func apply_cliff_lod_ranges(node: Node) -> int:
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
		set_count += apply_cliff_lod_ranges(child)
	return set_count

## Restores this module's static state (caches, debug buffers, counters) to its initial
## values. Called at the start of every WorldGenerator run so each run starts clean, the
## same as when these were per-instance member variables on WorldGenerator.
static func reset_run_state() -> void:
	_cliff_repair_material_cache = {}
	_cliff_trimesh_cache = {}
	_cliff_trimesh_disk_hits = 0
	_cliff_trimesh_disk_bakes = 0
