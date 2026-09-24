@tool
extends Node

## One-shot setup for the scree layer's rock props: two Poly Haven multi-rock
## sets (namaqualand_rocks_01 = 4 fist-sized rocks a-d, namaqualand_stones_01
## = 5 smaller stones a-e), exported one glb per rock (each carrying its own
## LOD0-3 chain) into res://assets/models/scree/ and registered here as
## Terrain3DMeshAsset ids 5-13. Mirrors setup_rock_assets.gd exactly (shared
## StandardMaterial3D built from the bundled 2K textures, same MeshAsset
## registration) but each source SET shares ONE material across its rocks, so
## there are only two materials for all nine meshes. Boulder01 + stone_01/
## rock_07/rock_09 own ids 1-4; these take 5-13.
##
## Run via call_method(runtime:false) on the EDITOR process (scene
## setup_scree_assets.tscn, node "."), same reasoning as setup_rock_assets.gd:
## Play mode's separate process would never touch the editor's live
## Terrain3DAssets instance. Order: debug_print_mesh_sizes() to sanity-check
## the imported scale, then setup_materials(), then setup_mesh_assets().

const ASSETS_PATH := "res://terrain_assets.tres"
const SCREE_DIR := "res://assets/models/scree/"

## Two texture sets -> two shared materials. Textures are the byte-for-byte
## Poly Haven 2K maps (diff jpg, nor_gl + rough exr) copied into
## SCREE_DIR/textures/. nor_gl is already OpenGL-convention (Y+), same as the
## existing rock props -- no green-channel flip.
const TEX_SETS := [
	{"set": "namaqualand_rocks_01"},
	{"set": "namaqualand_stones_01"},
]

## id -> glb stem (under SCREE_DIR) + which set's material it uses + a name.
## 5-8: rocks_01 a-d (fist tier). 9-13: stones_01 a-e (gravel tier).
const SCREE := [
	{"id": 5,  "glb": "namaqualand_rocks_01_a",  "set": "namaqualand_rocks_01",  "name": "ScreeRockA"},
	{"id": 6,  "glb": "namaqualand_rocks_01_b",  "set": "namaqualand_rocks_01",  "name": "ScreeRockB"},
	{"id": 7,  "glb": "namaqualand_rocks_01_c",  "set": "namaqualand_rocks_01",  "name": "ScreeRockC"},
	{"id": 8,  "glb": "namaqualand_rocks_01_d",  "set": "namaqualand_rocks_01",  "name": "ScreeRockD"},
	{"id": 9,  "glb": "namaqualand_stones_01_a", "set": "namaqualand_stones_01", "name": "ScreeStoneA"},
	{"id": 10, "glb": "namaqualand_stones_01_b", "set": "namaqualand_stones_01", "name": "ScreeStoneB"},
	{"id": 11, "glb": "namaqualand_stones_01_c", "set": "namaqualand_stones_01", "name": "ScreeStoneC"},
	{"id": 12, "glb": "namaqualand_stones_01_d", "set": "namaqualand_stones_01", "name": "ScreeStoneD"},
	{"id": 13, "glb": "namaqualand_stones_01_e", "set": "namaqualand_stones_01", "name": "ScreeStoneE"},
]

func _mat_path(set_name: String) -> String:
	return SCREE_DIR + "%s_material.tres" % set_name

## Diagnostic -- prints each scree glb's LOD0 mesh AABB, so we can confirm the
## exported meshes came in at their real fist/gravel scale (~0.04-0.23 m on the
## longest axis) and were NOT accidentally up-scaled the way stone_01/rock_07/
## rock_09 had to be. Also reports how many LOD nodes each glb carries.
func debug_print_mesh_sizes() -> String:
	var results: Array[String] = []
	for entry: Dictionary in SCREE:
		var path := SCREE_DIR + "%s.glb" % entry.glb
		var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			results.append("id=%d %s: COULD NOT LOAD %s" % [entry.id, entry.name, path])
			continue
		var sample := scene.instantiate()
		var lod_nodes := 0
		for child in sample.find_children("*LOD*", "MeshInstance3D", true, false):
			lod_nodes += 1
		var lod0: MeshInstance3D = sample.find_child("*LOD0*", true, false)
		if lod0 and lod0.mesh:
			var s := lod0.mesh.get_aabb().size
			results.append("id=%d %s: LOD0 AABB=%.3f x %.3f x %.3f m (longest %.3f), %d LOD node(s)" % [
				entry.id, entry.name, s.x, s.y, s.z, maxf(s.x, maxf(s.y, s.z)), lod_nodes])
		else:
			results.append("id=%d %s: no LOD0 mesh found (%d LOD node(s))" % [entry.id, entry.name, lod_nodes])
		sample.free()
	return "\n".join(results)

func setup_materials() -> String:
	var results: Array[String] = []
	for ts: Dictionary in TEX_SETS:
		var set_name: String = ts.set
		var base := SCREE_DIR + "textures/"
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = load(base + "%s_diff_2k.jpg" % set_name)
		mat.normal_enabled = true
		mat.normal_texture = load(base + "%s_nor_gl_2k.exr" % set_name)
		mat.roughness_texture = load(base + "%s_rough_2k.exr" % set_name)
		# Rock isn't metallic; a lower non-metal specular avoids a bright
		# specular hotspot under the moon light on a low-roughness patch --
		# same reasoning as the road/boulder materials.
		mat.metallic = 0.0
		mat.metallic_specular = 0.3
		for tex_label: String in ["albedo_texture", "normal_texture", "roughness_texture"]:
			if mat.get(tex_label) == null:
				push_error("setup_scree_assets: %s failed to load for %s" % [tex_label, set_name])
		var mat_path := _mat_path(set_name)
		var err := ResourceSaver.save(mat, mat_path)
		results.append("saved %s (err=%d)" % [mat_path, err])
	return "\n".join(results)

func setup_mesh_assets() -> String:
	# Plain load() of the shared Terrain3DAssets instance -- same reasoning as
	# setup_rock_assets.gd: the editor holds ONE canonical instance and only
	# mutating that same one sticks.
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	if assets == null:
		return "ERROR: could not load %s" % ASSETS_PATH
	var results: Array[String] = []
	for entry: Dictionary in SCREE:
		var scene_path := SCREE_DIR + "%s.glb" % entry.glb
		var mat_path := _mat_path(entry.set)
		var mesh_asset: Terrain3DMeshAsset = assets.get_mesh_asset(entry.id)
		var is_new := mesh_asset == null
		if is_new:
			mesh_asset = Terrain3DMeshAsset.new()
			mesh_asset.set_id(entry.id)
		mesh_asset.set_name(entry.name)
		mesh_asset.set_scene_file(load(scene_path))
		mesh_asset.set_material_override(load(mat_path))
		mesh_asset.set_height_offset(0.0)
		mesh_asset.set_density(0.05)
		if is_new:
			assets.set_mesh_asset(entry.id, mesh_asset)
		results.append("mesh asset id=%d %s (%s)" % [entry.id, "created" if is_new else "updated", entry.name])
	assets.update_mesh_list()
	var err := assets.save(ASSETS_PATH)
	results.append("saved %s (err=%d)" % [ASSETS_PATH, err])
	return "\n".join(results)
