@tool
extends Node

## One-shot setup for the four rock props (Poly Haven CC0: boulder_01, stone_01,
## rock_07, rock_09), each in res://assets/models/rocks/<dir>/ with a 2k glb and
## textures/<dir>_{diff,nor_gl,rough}_2k. setup_materials() builds each rock's
## StandardMaterial3D from those textures; setup_mesh_assets() registers each as a
## Terrain3DMeshAsset (ids 1-4) with that material as override; configure_rock_lods()
## sets LOD distances. (2026-09-24: Boulder01, id 1, used to have its own
## setup_boulder_asset.gd -- merged in here as one more ROCKS row.)
## Run via call_method(runtime:false) on the EDITOR process (tools/setup_rock_assets.tscn,
## node "."): Play mode's separate process would never touch the editor's live
## Terrain3DAssets instance.

const ASSETS_PATH := "res://terrain_assets.tres"

const ROCKS := [  # 2026-09-24: "file" is the 2k glb -- what's registered live; the 1k glbs were deleted
	{"id": 1, "dir": "boulder_01", "file": "boulder_01_2k", "name": "Boulder01"},  # merged in from setup_boulder_asset.gd
	{"id": 2, "dir": "stone_01", "file": "stone_01_2k", "name": "Stone01"},
	{"id": 3, "dir": "rock_07", "file": "rock_07_2k", "name": "Rock07"},
	{"id": 4, "dir": "rock_09", "file": "rock_09_2k", "name": "Rock09"},
]

## Diagnostic only -- prints each rock's (and Boulder01's, for comparison)
## raw LOD0 mesh AABB size, to check whether "they appear very very tiny"
## is a real source-mesh scale mismatch (stone_01/rock_07/rock_09 modeled
## at a different real-world scale than boulder_01) rather than anything in
## the scatter logic's BOULDER_SCALE_MIN/MAX random multiplier, which is
## applied identically to every mesh id.
func debug_print_mesh_sizes() -> String:
	var results: Array[String] = []
	var entries := [
		{"name": "Boulder01", "path": "res://assets/models/rocks/boulder_01/boulder_01_2k.glb"},
		{"name": "Stone01", "path": "res://assets/models/rocks/stone_01/stone_01_2k.glb"},
		{"name": "Rock07", "path": "res://assets/models/rocks/rock_07/rock_07_2k.glb"},
		{"name": "Rock09", "path": "res://assets/models/rocks/rock_09/rock_09_2k.glb"},
	]
	for entry: Dictionary in entries:
		var scene: PackedScene = ResourceLoader.load(entry.path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			results.append("%s: could not load %s" % [entry.name, entry.path])
			continue
		var sample := scene.instantiate()
		var lod0: MeshInstance3D = sample.find_child("*LOD0*", true, false)
		if lod0 and lod0.mesh:
			var aabb := lod0.mesh.get_aabb()
			results.append("%s: mesh AABB size=%s (LOD0 node scale=%s)" % [entry.name, aabb.size, lod0.scale])
		else:
			results.append("%s: no LOD0 mesh found" % entry.name)
		sample.free()
	return "\n".join(results)

## Diagnostic: read back what's ACTUALLY stored in terrain_assets.tres for
## each mesh id, rather than assuming setup_mesh_assets() (which reported
## err=0 and "created") actually stuck. Checks for the specific failure
## mode that would explain "still tiny AND untextured" together: Terrain3D
## silently falling back to some placeholder when scene_file or
## material_override didn't resolve, instead of an honest load error.
func debug_print_mesh_assets() -> String:
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var results: Array[String] = []
	for id in [1, 2, 3, 4]:
		var ma: Terrain3DMeshAsset = assets.get_mesh_asset(id)
		if ma == null:
			results.append("id=%d: NO MESH ASSET REGISTERED" % id)
			continue
		var scene: PackedScene = ma.get_scene_file()
		var mat: Material = ma.get_material_override()
		results.append("id=%d name=%s scene_file=%s material_override=%s height_offset=%s density=%s" % [
			id, ma.get_name(),
			scene.resource_path if scene else "NULL",
			mat.resource_path if mat else "NULL",
			ma.get_height_offset(), ma.get_density(),
		])
	return "\n".join(results)

func force_reimport_rocks() -> String:
	# Same reasoning as assign_flat_textures.gd's force_reimport(): editing
	# a .glb.import sidecar's params directly (e.g. nodes/root_scale) and
	# calling rescan_filesystem does NOT trigger a real reimport -- scan()
	# only reimports when the SOURCE file's mtime changed, not when only the
	# .import params changed. EditorFileSystem.reimport_files() is the
	# actual API for forcing a reimport using whatever params are currently
	# saved in the .import file.
	var paths := [
		"res://assets/models/rocks/stone_01/stone_01_2k.glb",
		"res://assets/models/rocks/rock_07/rock_07_2k.glb",
		"res://assets/models/rocks/rock_09/rock_09_2k.glb",
	]
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray(paths))
	return "reimported: " + ", ".join(paths)

func setup_materials() -> String:
	var results: Array[String] = []
	for rock: Dictionary in ROCKS:
		var base := "res://assets/models/rocks/%s/" % rock.dir  # 2026-09-24: rocks moved into models/rocks/
		var mat := StandardMaterial3D.new()
		# NOTE: texture files are named after rock.dir ("stone_01_diff_1k.jpg"),
		# NOT rock.file ("stone_01_1k") -- rock.file is only the .glb filename
		# stem. Using rock.file here silently built a nonexistent path
		# ("stone_01_1k_diff_1k.jpg"), load() returned null, and a null
		# texture property doesn't get written to the saved .tres at all --
		# which is why the saved material looked "valid" (StandardMaterial3D,
		# no error) but rendered as flat untextured white in-game.
		# 2026-09-24: switched to the _2k texture set -- that's what the live materials use,
		# and the _1k originals were deleted. Rocks that ship a mask (textures/<dir>_mask_2k.png,
		# currently only stone_01) get it as ambient occlusion, matching the live material.
		mat.albedo_texture = load(base + "textures/%s_diff_2k.jpg" % rock.dir)
		# "_nor_gl" filenames are already OpenGL-convention (Y+), same as
		# Boulder01 -- no green-channel flip needed.
		mat.normal_enabled = true
		mat.normal_texture = load(base + "textures/%s_nor_gl_2k.exr" % rock.dir)
		mat.roughness_texture = load(base + "textures/%s_rough_2k.exr" % rock.dir)
		var mask_path := base + "textures/%s_mask_2k.png" % rock.dir
		if ResourceLoader.exists(mask_path):
			mat.ao_enabled = true
			mat.ao_texture = load(mask_path)
			mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		for tex_label: String in ["albedo_texture", "normal_texture", "roughness_texture"]:
			if mat.get(tex_label) == null:
				push_error("setup_rock_assets: %s failed to load for %s" % [tex_label, rock.dir])
		var mat_path := base + "%s_material.tres" % rock.dir
		var err := ResourceSaver.save(mat, mat_path)
		results.append("saved %s (err=%d)" % [mat_path, err])
	return "\n".join(results)

func setup_mesh_assets() -> String:
	# Plain load(), deliberately:
	# the editor keeps ONE canonical Terrain3DAssets instance alive
	# (Terrain3D's own dock holds it), and only mutating that same instance
	# actually sticks instead of getting silently overwritten.
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var results: Array[String] = []
	for rock: Dictionary in ROCKS:
		var base := "res://assets/models/rocks/%s/" % rock.dir  # 2026-09-24: rocks moved into models/rocks/
		var scene_path := base + "%s.glb" % rock.file
		var mat_path := base + "%s_material.tres" % rock.dir
		var mesh_asset: Terrain3DMeshAsset = assets.get_mesh_asset(rock.id)
		var is_new := mesh_asset == null
		if is_new:
			mesh_asset = Terrain3DMeshAsset.new()
			mesh_asset.set_id(rock.id)
		mesh_asset.set_name(rock.name)
		mesh_asset.set_scene_file(load(scene_path))
		mesh_asset.set_material_override(load(mat_path))
		mesh_asset.set_height_offset(0.0)
		mesh_asset.set_density(0.05)
		if is_new:
			assets.set_mesh_asset(rock.id, mesh_asset)
		results.append("mesh asset id=%d %s" % [rock.id, "created" if is_new else "updated"])
	assets.update_mesh_list()
	var err := assets.save(ASSETS_PATH)
	results.append("saved %s (err=%d)" % [ASSETS_PATH, err])
	return "\n".join(results)

## 2026-09-24 GPU tuning: Boulder01 (66k tris at LOD0) and Stone01 (53k) kept
## their heaviest LOD out to Terrain3D's default 60 m. Pull the LOD hand-offs in
## so a 2 m rock doesn't draw 66k tris at 50 m. Cull distance (last range, 380 m)
## is unchanged. Rock07 / Rock09 (12-15k at LOD0) are fine on the defaults.
## Run via call_method(runtime:false) on setup_rock_assets.tscn, node ".".
const ROCK_LOD_RANGES := {
	1: [22.0, 50.0, 120.0, 380.0],  # Boulder01
	2: [22.0, 50.0, 120.0, 380.0],  # Stone01
}

func configure_rock_lods() -> String:
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var results: Array[String] = []
	for id: int in ROCK_LOD_RANGES:
		var a: Terrain3DMeshAsset = assets.get_mesh_asset(id)
		if a == null:
			results.append("id=%d: not registered -- skipped" % id)
			continue
		var ranges: Array = ROCK_LOD_RANGES[id]
		var before := []
		for l in ranges.size():
			before.append("%.0f" % float(a.get("lod%d_range" % l)))
		for l in ranges.size():
			a.set("lod%d_range" % l, ranges[l])
		var after := []
		for l in ranges.size():
			after.append("%.0f" % float(a.get("lod%d_range" % l)))
		results.append("id=%d %s: lod ranges %s -> %s (last_lod=%d)" % [id, a.get_name(), "/".join(before), "/".join(after), a.get_last_lod()])
	assets.update_mesh_list()
	results.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(results)
