@tool
extends Node

## One-shot setup for the scatter rock props (Poly Haven CC0: boulder_01, stone_01,
## rock_07, rock_09, + namaqualand_boulder_02..06 since 2026-09-30), each in
## res://assets/models/rocks/<dir>/ with a 2k glb and
## textures/<dir>_{diff,nor_gl,rough}_2k. setup_materials() builds each rock's
## StandardMaterial3D from those textures; setup_mesh_assets() registers each as a
## Terrain3DMeshAsset (ids 1-4, 33-37) with that material as override; configure_rock_lods()
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
	# 2026-09-30: batch 2 (Poly Haven namaqualand boulders). Modeled at real metre scale
	# (1.2-3.1 m longest axis); root_scale in each .glb.import brings them to 1.0-1.75.
	{"id": 33, "dir": "namaqualand_boulder_02", "file": "namaqualand_boulder_02_2k", "name": "NamaBoulder02"},
	{"id": 34, "dir": "namaqualand_boulder_03", "file": "namaqualand_boulder_03_2k", "name": "NamaBoulder03"},
	{"id": 35, "dir": "namaqualand_boulder_04", "file": "namaqualand_boulder_04_2k", "name": "NamaBoulder04"},
	{"id": 36, "dir": "namaqualand_boulder_05", "file": "namaqualand_boulder_05_2k", "name": "NamaBoulder05"},
	{"id": 37, "dir": "namaqualand_boulder_06", "file": "namaqualand_boulder_06_2k", "name": "NamaBoulder06"},
]

## Diagnostic only -- prints each rock's (and Boulder01's, for comparison)
## raw LOD0 mesh AABB size, to check whether "they appear very very tiny"
## is a real source-mesh scale mismatch (stone_01/rock_07/rock_09 modeled
## at a different real-world scale than boulder_01) rather than anything in
## the scatter logic's BOULDER_SCALE_MIN/MAX random multiplier, which is
## applied identically to every mesh id.
func debug_print_mesh_sizes() -> String:
	var results: Array[String] = []
	for rock: Dictionary in ROCKS:
		var path := "res://assets/models/rocks/%s/%s.glb" % [rock.dir, rock.file]
		var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			results.append("%s: could not load %s" % [rock.name, path])
			continue
		var sample := scene.instantiate()
		var lod0: MeshInstance3D = sample.find_child("*LOD0*", true, false)
		if lod0 and lod0.mesh:
			var aabb := lod0.mesh.get_aabb()
			var lod_count := sample.find_children("*LOD*", "MeshInstance3D", true, false).size()
			results.append("%s: mesh AABB size=%s (LOD0 node scale=%s, %d LOD nodes)" % [rock.name, aabb.size, lod0.scale, lod_count])
		else:
			results.append("%s: no LOD0 mesh found" % rock.name)
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
	for rock: Dictionary in ROCKS:
		var id: int = rock.id
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
	# 2026-09-30: batch 2 boulders (root_scale + embedded_image_handling=0 set in their .import).
	var paths := [
		"res://assets/models/rocks/namaqualand_boulder_02/namaqualand_boulder_02_2k.glb",
		"res://assets/models/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.glb",
		"res://assets/models/rocks/namaqualand_boulder_04/namaqualand_boulder_04_2k.glb",
		"res://assets/models/rocks/namaqualand_boulder_05/namaqualand_boulder_05_2k.glb",
		"res://assets/models/rocks/namaqualand_boulder_06/namaqualand_boulder_06_2k.glb",
	]
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray(paths))
	return "reimported: " + ", ".join(paths)

## only_ids: limit to these ROCKS ids (e.g. [33, 34] for newly added rocks); empty = all.
func setup_materials(only_ids: Array = []) -> String:
	var results: Array[String] = []
	for rock: Dictionary in ROCKS:
		if not only_ids.is_empty() and not only_ids.any(func(i): return int(i) == rock.id):
			continue
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

func setup_mesh_assets(only_ids: Array = []) -> String:
	# Plain load(), deliberately:
	# the editor keeps ONE canonical Terrain3DAssets instance alive
	# (Terrain3D's own dock holds it), and only mutating that same instance
	# actually sticks instead of getting silently overwritten.
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var results: Array[String] = []
	for rock: Dictionary in ROCKS:
		if not only_ids.is_empty() and not only_ids.any(func(i): return int(i) == rock.id):
			continue
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
	# 2026-09-30 batch 2 -- LOD0 is 59k-109k tris on every one, so same pulled-in hand-offs.
	33: [22.0, 50.0, 120.0, 380.0],  # NamaBoulder02 (98k)
	34: [22.0, 50.0, 120.0, 380.0],  # NamaBoulder03 (65k)
	35: [22.0, 50.0, 120.0, 380.0],  # NamaBoulder04 (59k)
	36: [22.0, 50.0, 380.0],  # NamaBoulder05 (90k) -- only 3 LODs (LOD2 = 5.6k tris is the last)
	37: [22.0, 50.0, 120.0, 380.0],  # NamaBoulder06 (109k)
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

## 2026-10-02 HIGHLIGHT CAP: boulders AND scree render through
## shaders/rock/rock_highlight_cap.gdshader (see its header) -- the standard rock material with
## only the pale parts of the albedo darkened, so they stop blooming under the lantern.
## For every rock / scree mesh asset this builds a ShaderMaterial from the StandardMaterial3D
## setup_materials() saved (same textures and values), saves it beside it as
## <name>_capped_material.tres and makes it the mesh asset's override. The standard .tres stays
## the source of truth: after re-running setup_materials() / setup_mesh_assets() here or in
## setup_scree_assets.gd, run this again (they put the standard material back).
## Tuning: HIGHLIGHT_CAP_KNEE / _LIMIT below, then run this again (the values are saved in the
## capped materials; linear albedo luminance -- ordinary boulders average 0.10-0.14).
## Editor process only (a runtime set_material_override makes Terrain3D rebuild the asset
## thumbnail, which fails in Play mode with ~8 errors per asset).
## enable = false puts the standard materials back.
const HIGHLIGHT_CAP_KNEE := 0.08 ## below this nothing changes
const HIGHLIGHT_CAP_LIMIT := 0.1 ## brighter texels approach this, never pass it

## Inspector button: open tools/setup_rock_assets.tscn, select the root node, click it.
## The result is printed to the Output panel.
@export_tool_button("Apply highlight cap") var _highlight_cap_button: Callable = _run_highlight_cap

func _run_highlight_cap() -> void:
	print(setup_highlight_cap())

func setup_highlight_cap(enable: bool = true) -> String:
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var shader: Shader = load("res://shaders/rock/rock_highlight_cap.gdshader")
	var std_by_id := {} # mesh id -> standard material path
	for rock: Dictionary in ROCKS:
		std_by_id[rock.id] = "res://assets/models/rocks/%s/%s_material.tres" % [rock.dir, rock.dir]
	for id in RockScatter.SCREE_FIST_MESH_IDS:
		std_by_id[id] = RockScatter.SCREE_MATERIAL_PATHS[0]
	for id in RockScatter.SCREE_GRAVEL_MESH_IDS:
		std_by_id[id] = RockScatter.SCREE_MATERIAL_PATHS[1]
	var results: Array[String] = []
	var capped_by_path := {}
	for id: int in std_by_id:
		var std_path: String = std_by_id[id]
		var asset: Terrain3DMeshAsset = assets.get_mesh_asset(id)
		var src := load(std_path) as StandardMaterial3D
		if asset == null or src == null:
			results.append("id=%d: no mesh asset or no StandardMaterial3D at %s -- skipped" % [id, std_path])
			continue
		if not enable:
			asset.set_material_override(src)
			results.append("id=%d -> %s" % [id, std_path.get_file()])
			continue
		if not capped_by_path.has(std_path):
			var capped_path := std_path.replace("_material.tres", "_capped_material.tres")
			var sm := (load(capped_path) as ShaderMaterial) if ResourceLoader.exists(capped_path) else null
			if sm == null:
				sm = ShaderMaterial.new()
			sm.shader = shader
			sm.set_shader_parameter("albedo", src.albedo_color)
			sm.set_shader_parameter("texture_albedo", src.albedo_texture)
			sm.set_shader_parameter("texture_normal", src.normal_texture)
			sm.set_shader_parameter("normal_scale", src.normal_scale)
			sm.set_shader_parameter("texture_roughness", src.roughness_texture)
			sm.set_shader_parameter("roughness", src.roughness)
			sm.set_shader_parameter("specular", src.metallic_specular)
			sm.set_shader_parameter("texture_ao", src.ao_texture if src.ao_enabled else null)
			sm.set_shader_parameter("ao_light_affect", src.ao_light_affect if src.ao_enabled else 0.0)
			sm.set_shader_parameter("cap_knee", float(HIGHLIGHT_CAP_KNEE))
			sm.set_shader_parameter("cap_limit", float(HIGHLIGHT_CAP_LIMIT))
			var err := ResourceSaver.save(sm, capped_path)
			sm.take_over_path(capped_path) # so terrain_assets.tres references the file instead of embedding a copy
			results.append("saved %s (err=%d)" % [capped_path, err])
			capped_by_path[std_path] = sm
		asset.set_material_override(capped_by_path[std_path])
		results.append("id=%d -> %s" % [id, (capped_by_path[std_path] as ShaderMaterial).resource_path.get_file()])
	assets.update_mesh_list()
	results.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(results)
