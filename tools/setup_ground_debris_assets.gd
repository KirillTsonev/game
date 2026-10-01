@tool
extends Node

## Setup for the deadfall props (Megascans stumps / fallen logs / branch, 2026-09-30), each in
## res://assets/models/ground_debris/<dir>/: <dir>.glb (LOD0-2 sibling nodes, no images -- built by
## tools/blender/import_megascans_glb.py) + textures/<dir>_{diff,nor_gl}_2k.jpg, <dir>_orm_2k.png.
##   configure_imports()  discard embedded images (rule 4, docs/adding_models.md), forced reimport
##   setup_materials()    <dir>_material.tres from the three textures (ORM read directly)
##   setup_mesh_assets()  Terrain3D mesh assets, ids 38-49, material override + LOD ranges
##   debug_print_sizes()  LOD0 AABB + tris per LOD, loaded from disk
## Run via call_method(runtime:false) on the EDITOR process (tools/setup_ground_debris_assets.tscn,
## node "."): Play mode's separate process would never touch the editor's live Terrain3DAssets.
## Placement: scripts/terrain/deadfall_scatter.gd (keep the ids in sync).

const ASSETS_PATH := "res://terrain_assets.tres"
const BASE := "res://assets/models/ground_debris/"

## ranges: one per LOD (LOD0, LOD1, LOD2); the last is the cull distance. Terrain3D measures them
## to each 32 m instancer cell's centre. No fade margin (fading drops shadows -- docs/vegetation.md),
## shadows on every LOD. Logs are big and stay visible far; the branch is small.
const DEBRIS := [
	{"id": 38, "dir": "stump_broken", "name": "StumpBroken", "ranges": [20.0, 50.0, 200.0]},  # 20.5k tris at LOD0
	{"id": 39, "dir": "stump_old", "name": "StumpOld", "ranges": [25.0, 60.0, 200.0]},
	{"id": 40, "dir": "stump_rotten_large", "name": "StumpRottenLarge", "ranges": [30.0, 70.0, 300.0]},
	{"id": 41, "dir": "stump_rotten_tall", "name": "StumpRottenTall", "ranges": [30.0, 70.0, 300.0]},
	{"id": 42, "dir": "log_fallen_nordic", "name": "LogFallenNordic", "ranges": [30.0, 70.0, 300.0]},
	{"id": 43, "dir": "log_fallen_large", "name": "LogFallenLarge", "ranges": [30.0, 70.0, 300.0]},
	{"id": 44, "dir": "branch_fallen", "name": "BranchFallen", "ranges": [15.0, 40.0, 120.0]},
	# 2026-09-30: small sticks scaled up to 0.6-0.9 m for branch-clump variety (the clumps of one
	# repeated branch read as a ribcage). The four debris-pack sticks share one folder + material
	# ("file" = glb name when it differs from the folder).
	{"id": 45, "dir": "stick_arbem", "name": "StickArbem", "ranges": [10.0, 25.0, 80.0]},
	{"id": 46, "dir": "sticks_debris", "file": "sticks_debris_a", "name": "StickDebrisA", "ranges": [10.0, 25.0, 80.0]},
	{"id": 47, "dir": "sticks_debris", "file": "sticks_debris_b", "name": "StickDebrisB", "ranges": [10.0, 25.0, 80.0]},
	{"id": 48, "dir": "sticks_debris", "file": "sticks_debris_c", "name": "StickDebrisC", "ranges": [10.0, 25.0, 80.0]},
	{"id": 49, "dir": "sticks_debris", "file": "sticks_debris_d", "name": "StickDebrisD", "ranges": [10.0, 25.0, 80.0]},
]

func _glb(e: Dictionary) -> String:
	return BASE + "%s/%s.glb" % [e.dir, e.get("file", e.dir)]

## Texture of one role (diff / orm / nor_gl) -- .jpg or .png, whichever the import wrote.
func _tex(dir: String, role: String) -> Texture2D:
	for ext in [".jpg", ".png"]:
		var path := BASE + "%s/textures/%s_%s_2k%s" % [dir, dir, role, ext]
		if ResourceLoader.exists(path):
			return load(path)
	return null

## The glbs hold no images, so this is only rule 4's safety setting -- nothing gets extracted next
## to them now or if a future export forgets export_image_format='NONE'.
func configure_imports() -> String:
	var out: Array[String] = []
	var paths := PackedStringArray()
	for e: Dictionary in DEBRIS:
		var cfg := ConfigFile.new()
		var err := cfg.load(_glb(e) + ".import")
		if err != OK:
			out.append("%s: could not read .import (err=%d)" % [e.dir, err])
			continue
		cfg.set_value("params", "gltf/embedded_image_handling", 0)
		err = cfg.save(_glb(e) + ".import")
		out.append("%s: embedded_image_handling=0 (save err=%d)" % [e.dir, err])
		paths.append(_glb(e))
	EditorInterface.get_resource_filesystem().reimport_files(paths)
	out.append("reimported %d files" % paths.size())
	return "\n".join(out)

## only_ids: limit to these DEBRIS ids; empty = all. (call_method sends ids as floats -> int().)
func setup_materials(only_ids: Array = []) -> String:
	var out: Array[String] = []
	var done: Array[String] = []  # one material per folder (the debris-pack sticks share one)
	for e: Dictionary in DEBRIS:
		if not only_ids.is_empty() and not only_ids.any(func(i): return int(i) == e.id):
			continue
		if done.has(e.dir):
			continue
		done.append(e.dir)
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = _tex(e.dir, "diff")
		mat.normal_enabled = true
		mat.normal_texture = _tex(e.dir, "nor_gl")  # OpenGL convention (glTF; stick_arbem's _N tested), no flip
		# Megascans ORM packing (glTF): R = AO, G = roughness, B = metallic. Wood is never metallic,
		# so metallic stays 0 and the B channel is unused.
		var orm := _tex(e.dir, "orm")
		mat.roughness = 1.0  # multiplier on the texture
		mat.roughness_texture = orm
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.ao_enabled = true
		mat.ao_texture = orm
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.metallic = 0.0
		for prop: String in ["albedo_texture", "normal_texture", "roughness_texture"]:
			if mat.get(prop) == null:
				push_error("setup_ground_debris_assets: %s failed to load for %s" % [prop, e.dir])
		var mat_path := BASE + "%s/%s_material.tres" % [e.dir, e.dir]
		out.append("saved %s (err=%d)" % [mat_path, ResourceSaver.save(mat, mat_path)])
	return "\n".join(out)

func setup_mesh_assets(only_ids: Array = []) -> String:
	# Plain load(): the editor keeps ONE live Terrain3DAssets instance (see setup_rock_assets.gd).
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var out: Array[String] = []
	for e: Dictionary in DEBRIS:
		if not only_ids.is_empty() and not only_ids.any(func(i): return int(i) == e.id):
			continue
		var a: Terrain3DMeshAsset = assets.get_mesh_asset(e.id)
		var is_new := a == null
		if is_new:
			a = Terrain3DMeshAsset.new()
			a.set_id(e.id)
		a.set_name(e.name)
		a.set_scene_file(ResourceLoader.load(_glb(e), "", ResourceLoader.CACHE_MODE_REPLACE))
		a.set_material_override(load(BASE + "%s/%s_material.tres" % [e.dir, e.dir]))
		a.set_height_offset(0.0)
		a.set_density(0.05)
		if is_new:
			assets.set_mesh_asset(e.id, a)
		var ranges: Array = e.ranges
		for i in ranges.size():
			a.set_lod_range(i, ranges[i])
		a.set_last_lod(mini(ranges.size(), a.get_lod_count()) - 1)
		a.set_last_shadow_lod(a.get_last_lod())
		a.set_cast_shadows(GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
		a.set_fade_margin(0.0)
		var got: Array[String] = []
		for i in a.get_lod_count():
			got.append("%.0f" % a.get_lod_range(i))
		out.append("id=%d %s (%s): lod_count=%d last_lod=%d last_shadow_lod=%d ranges %s" % [
			e.id, e.name, "created" if is_new else "updated", a.get_lod_count(), a.get_last_lod(), a.get_last_shadow_lod(), "/".join(got)])
	assets.update_mesh_list()
	out.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(out)

## LOD0 AABB (Godot axes: the logs lie along X) and tri count per LOD, loaded fresh from disk.
func debug_print_sizes() -> String:
	var out: Array[String] = []
	for e: Dictionary in DEBRIS:
		var scene: PackedScene = ResourceLoader.load(_glb(e), "", ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			out.append("%s: could not load %s" % [e.get("file", e.dir), _glb(e)])
			continue
		var s := scene.instantiate()
		var lods := s.find_children("*LOD*", "MeshInstance3D", true, false)
		lods.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
		var parts: Array[String] = []
		for mi: MeshInstance3D in lods:
			var tris := 0
			for si in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(si)
				tris += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if arr[Mesh.ARRAY_INDEX] != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			parts.append("%s %d" % [mi.name, tris])
		var aabb: AABB = (lods[0] as MeshInstance3D).mesh.get_aabb() if not lods.is_empty() else AABB()
		out.append("%s: LOD0 aabb pos %s size %s | %s" % [e.get("file", e.dir), aabb.position, aabb.size, ", ".join(parts)])
		s.free()
	return "\n".join(out)
