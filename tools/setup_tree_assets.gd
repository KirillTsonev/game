@tool
extends Node

## One-shot setup for the canopy (tree) layer.
## The forest uses 14 trees from the Fab "vegetation" pack (Vegetation.fbx), baked by
## build_pack_trees() into standalone meshes + small scenes and registered as
## Terrain3DMeshAsset ids 14-27 (see PACK_TREES; terrain_gen.gd's TREE_IDS_FAB_PACK
## must match). The pack's 256 px bark is swapped for 2K PBR bark (pine: Poly Haven
## pine bark, deciduous: Poly Haven jolcham oak bark), world-triplanar mapped.
## (2026-09-24: the old Poly Haven fir/pine tree assets, ids 14-19, were removed.)
##
## Trees keep per-surface materials (opaque bark + alpha-scissor leaf cards) -- no
## material override, unlike the single-surface rock/scree setups.
##
## Run via call_method(runtime:false) on the EDITOR process (scene
## setup_tree_assets.tscn, node "."): Play mode's separate process would never touch
## the editor's live Terrain3DAssets instance.

const ASSETS_PATH := "res://terrain_assets.tres"

## -- Fab "vegetation" pack trees --
## Terrain3D mesh assets 14-27 (2026-09-24: renumbered from 20-33 when the old Poly
## Haven fir/pine assets 14-19 were removed; terrain_gen.gd's TREE_MESH_IDS must match).
## build_pack_trees() bakes each FBX node's rotation/scale into a
## standalone mesh (base at y=0), fixes the foliage materials and saves a
## small scene per tree, then registers it.
const PACK_FBX := "res://assets/models/candidates/vegetation/Models/Vegetation.fbx"
const PACK_OUT_DIR := "res://assets/models/candidates/vegetation/trees/"
const PACK_TREES := [
	# Kirill's cleaned selection (Untitled.blend, 2026-09-23): 4 pines + 3
	# deciduous, each with its second colour variant.
	{"id": 14, "node": "Tree_09",      "name": "PackPineA"},
	{"id": 15, "node": "Cylinder",     "name": "PackPineB"},
	{"id": 16, "node": "Tree_07",      "name": "PackPineC"},
	{"id": 17, "node": "Tree_08",      "name": "PackPineD"},
	{"id": 18, "node": "Tree_09_001",  "name": "PackPineA2"},
	{"id": 19, "node": "Cylinder_006", "name": "PackPineB2"},
	{"id": 20, "node": "Tree_07_V",    "name": "PackPineC2"},
	{"id": 21, "node": "Tree_08_V",    "name": "PackPineD2"},
	{"id": 22, "node": "Tree",         "name": "PackDecidA"},
	{"id": 23, "node": "Tree_V",       "name": "PackDecidA2"},
	{"id": 24, "node": "Tree_01",      "name": "PackDecidB"},
	{"id": 25, "node": "Tree_01_V",    "name": "PackDecidB2"},
	{"id": 26, "node": "Tree_02",      "name": "PackDecidC"},
	{"id": 27, "node": "Tree_02_V",    "name": "PackDecidC2"},
]
const PACK_LOD0_RANGE := 600.0  ## single-LOD meshes (1.9-11.3k tris) -- visible out to 600 m

## -- High-res bark for the pack trunks (2026-09-24) --
## The pack's own bark is 256 px. Trunk UVs tile (V runs ~-10..10), so each bark
## surface gets a real 2K PBR bark. The pack's trunk UVs are MIRRORED on
## alternating faces (tangents flip 180 deg between neighbours), which made the
## normal-mapped bark look faceted -- so the bark ignores the UVs and uses
## WORLD TRIPLANAR mapping instead (size set directly in metres).
## PACK_BARK_TILE_M = metres covered by one texture WIDTH -- the one knob to
## tune by eye. Non-square textures (oak is 1:2) keep their aspect.
const PACK_BARK_TILE_M := 1.4
const PACK_BARK_TRIPLANAR_SHARPNESS := 6.0  ## higher = crisper blend between side projections
const PACK_BARK := {
	"BarkPine": [  # Poly Haven pine_tree_01 bark (CC0), 2048x2048
		"res://assets/models/candidates/vegetation/bark/pine_bark_diff_2k.png",
		"res://assets/models/candidates/vegetation/bark/pine_bark_nor_gl_2k.png",
		"res://assets/models/candidates/vegetation/bark/pine_bark_rough_2k.png"],
	"BarkDecidious": [  # Poly Haven jolcham_oak_bark_01 (CC0), 2048x4096
		"res://assets/models/candidates/vegetation/bark/oak_bark_diff_2k.jpg",
		"res://assets/models/candidates/vegetation/bark/oak_bark_nor_gl_2k.png",
		"res://assets/models/candidates/vegetation/bark/oak_bark_rough_2k.png"],
}

func _pack_bark_key(tex_file: String) -> String:
	for k: String in PACK_BARK:
		if tex_file.begins_with(k):
			return k
	return ""

## Swaps the 256 px pack bark for the 2K PBR set, world-triplanar mapped.
func _apply_pack_bark(bm: BaseMaterial3D, key: String) -> String:
	var maps: Array = PACK_BARK[key]
	var alb := load(maps[0]) as Texture2D
	# triplanar: uv1_scale = texture repeats per metre along world X / Y / Z
	var sx := 1.0 / PACK_BARK_TILE_M
	var sy := sx * float(alb.get_width()) / float(alb.get_height())
	var old_tint := bm.albedo_color
	bm.albedo_texture = alb
	bm.albedo_color = Color.WHITE
	bm.normal_enabled = true
	bm.normal_texture = load(maps[1])
	bm.roughness = 1.0
	bm.roughness_texture = load(maps[2])
	bm.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
	bm.metallic = 0.0
	bm.uv1_triplanar = true
	bm.uv1_world_triplanar = true
	bm.uv1_triplanar_sharpness = PACK_BARK_TRIPLANAR_SHARPNESS
	bm.uv1_scale = Vector3(sx, sy, sx)
	bm.uv1_offset = Vector3.ZERO
	bm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return "bark %s: world triplanar, uv1=(%.2f, %.2f, %.2f) sharpness=%.1f old_tint=%s" % [key, sx, sy, sx, PACK_BARK_TRIPLANAR_SHARPNESS, old_tint.to_html(false)]

## Foliage cutout shader for the pack's leaf/branch cards (2026-09-25, docs/shadows.md): mip-scaled
## alpha + separate shadow-pass cutoff so canopy shadows don't fade out ~20 m ahead. Built from the
## card's StandardMaterial3D: same texture, tint, vertex-colour tinting (the pack tints cards via
## vertex colours), roughness and normal map. No backlight (the trees never had any). Cutoff/boost
## values come from the understory tool so both layers stay in sync.
const UNDERSTORY_TOOL := preload("res://tools/setup_understory_assets.gd")

func _foliage_leaf_material(bm: BaseMaterial3D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.resource_name = "%s_foliage" % (bm.albedo_texture.resource_path.get_file().get_basename() if bm.albedo_texture else "leaf")
	mat.shader = load(UNDERSTORY_TOOL.FOLIAGE_SHADER_DOUBLE)
	mat.set_shader_parameter("albedo_tex", bm.albedo_texture)
	mat.set_shader_parameter("albedo_color", bm.albedo_color)
	mat.set_shader_parameter("use_vertex_color", bm.vertex_color_use_as_albedo)
	mat.set_shader_parameter("roughness", bm.roughness)
	if bm.normal_enabled and bm.normal_texture:
		mat.set_shader_parameter("normal_tex", bm.normal_texture)
		mat.set_shader_parameter("normal_scale", bm.normal_scale)
	mat.set_shader_parameter("alpha_cutoff", UNDERSTORY_TOOL.ALPHA_SCISSOR)
	mat.set_shader_parameter("mip_alpha_scale", UNDERSTORY_TOOL.MIP_ALPHA_SCALE)
	mat.set_shader_parameter("shadow_alpha_cutoff", UNDERSTORY_TOOL.SHADOW_ALPHA_CUTOFF)
	mat.set_shader_parameter("shadow_mip_alpha_scale", UNDERSTORY_TOOL.SHADOW_MIP_ALPHA_SCALE)
	return mat

## Diagnostic (2026-09-25, before moving leaf cards to the foliage shader): every distinct
## alpha-scissor (leaf/branch card) material across the baked pack trees and what it sets.
func debug_print_leaf_materials() -> String:
	var seen := {}
	var out: Array[String] = []
	for entry: Dictionary in PACK_TREES:
		var mesh: Mesh = ResourceLoader.load(PACK_OUT_DIR + "%s.res" % entry.name, "", ResourceLoader.CACHE_MODE_IGNORE)
		if mesh == null:
			out.append("%s: no baked mesh" % entry.name)
			continue
		for si in mesh.get_surface_count():
			var m := mesh.surface_get_material(si)
			var desc := "null"
			if m is BaseMaterial3D:
				var bm := m as BaseMaterial3D
				if bm.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
					continue
				desc = "alb=%s color=%s normal=%s(%s) rough=%.2f/%s metal=%.2f spec=%.2f vcol_albedo=%s backlight=%s rim=%s cull=%d filter=%d scissor=%.2f shading=%d" % [
					bm.albedo_texture.resource_path.get_file() if bm.albedo_texture else "-", bm.albedo_color.to_html(), bm.normal_texture.resource_path.get_file() if bm.normal_texture else "-", bm.normal_enabled,
					bm.roughness, bm.roughness_texture.resource_path.get_file() if bm.roughness_texture else "-", bm.metallic, bm.metallic_specular, bm.vertex_color_use_as_albedo,
					bm.backlight_enabled, bm.rim_enabled, bm.cull_mode, bm.texture_filter, bm.alpha_scissor_threshold, bm.shading_mode]
			else:
				desc = m.get_class() if m else "null"
			var key := desc
			if not seen.has(key):
				seen[key] = []
			seen[key].append("%s s%d (%d tris)" % [entry.name, si, (mesh.surface_get_arrays(si)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3])
	for k in seen:
		out.append("%s\n    used by: %s" % [k, ", ".join(seen[k])])
	return "\n".join(out)

func build_pack_trees() -> String:
	var src: Node = (load(PACK_FBX) as PackedScene).instantiate()
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PACK_OUT_DIR))
	var out: Array[String] = []
	for entry: Dictionary in PACK_TREES:
		var mi := src.find_child(entry.node, true, false) as MeshInstance3D
		if mi == null or mi.mesh == null:
			out.append("%s: node %s not found -- skipped" % [entry.name, entry.node])
			continue
		var xf := Transform3D()
		var n: Node = mi
		while n != src and n is Node3D:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var basis := xf.basis  # rotation + scale only; the showroom position is dropped
		var nbasis := basis.inverse().transposed()
		var flip := basis.determinant() < 0.0
		# pass 1: lowest point after rotation/scale, so the base sits at y = 0
		var min_y := INF
		for si in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				min_y = minf(min_y, (basis * v).y)
		var lift := Vector3(0.0, -min_y, 0.0)
		var am := ArrayMesh.new()
		var tris := 0
		for si in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for i in verts.size():
				verts[i] = basis * verts[i] + lift
			arr[Mesh.ARRAY_VERTEX] = verts
			if arr[Mesh.ARRAY_NORMAL] != null:
				var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
				for i in nr.size():
					nr[i] = (nbasis * nr[i]).normalized()
				arr[Mesh.ARRAY_NORMAL] = nr
			if arr[Mesh.ARRAY_TANGENT] != null:
				var tg: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
				for i in range(0, tg.size(), 4):
					var t := (basis * Vector3(tg[i], tg[i + 1], tg[i + 2])).normalized()
					tg[i] = t.x; tg[i + 1] = t.y; tg[i + 2] = t.z
					if flip:
						tg[i + 3] = -tg[i + 3]
				arr[Mesh.ARRAY_TANGENT] = tg
			tris += ((arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arr[Mesh.ARRAY_INDEX] != null else verts.size()) / 3
			var src_mat := mi.get_active_material(si)
			var bark_key := ""
			if src_mat is BaseMaterial3D and (src_mat as BaseMaterial3D).albedo_texture:
				bark_key = _pack_bark_key((src_mat as BaseMaterial3D).albedo_texture.resource_path.get_file())
			am.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(si), arr)
			var mat := src_mat
			if mat is BaseMaterial3D:
				var bm := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
				var tex := bm.albedo_texture.resource_path.get_file() if bm.albedo_texture else ""
				var leaf_mat: Material = null
				if tex.contains("Branch") or tex.contains("Tree_B") or tex.contains("Grass"):
					bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
					bm.alpha_scissor_threshold = 0.5
					bm.cull_mode = BaseMaterial3D.CULL_DISABLED
					# 2026-09-25: leaf cards go on the foliage cutout shader (docs/shadows.md) --
					# their canopy shadows faded out ~20 m ahead like the understory's did.
					leaf_mat = _foliage_leaf_material(bm)
				else:
					bm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
					bm.cull_mode = BaseMaterial3D.CULL_BACK
					if bark_key != "":
						out.append("  %s s%d: %s" % [entry.name, si, _apply_pack_bark(bm, bark_key)])
				am.surface_set_material(am.get_surface_count() - 1, leaf_mat if leaf_mat else bm)
		var mesh_path := PACK_OUT_DIR + "%s.res" % entry.name
		ResourceSaver.save(am, mesh_path)
		var root := Node3D.new()
		root.name = entry.name
		var lod0 := MeshInstance3D.new()
		lod0.name = "LOD0"
		lod0.mesh = load(mesh_path)
		root.add_child(lod0)
		lod0.owner = root
		var ps := PackedScene.new()
		ps.pack(root)
		var scene_path := PACK_OUT_DIR + "%s.tscn" % entry.name
		ResourceSaver.save(ps, scene_path)
		root.free()
		var scene: PackedScene = load(scene_path)
		var a: Terrain3DMeshAsset = assets.get_mesh_asset(entry.id)
		var is_new := a == null
		if is_new:
			a = Terrain3DMeshAsset.new()
			a.set_id(entry.id)
		a.set_name(entry.name)
		a.set_scene_file(scene)
		a.set_height_offset(0.0)
		a.set_density(0.05)
		if is_new:
			assets.set_mesh_asset(entry.id, a)
		a.set_lod0_range(PACK_LOD0_RANGE)
		a.set_fade_margin(TREE_FADE_MARGIN)
		a.set_shadow_impostor(0)
		out.append("id=%d %s <- %s: %d tris, %.1f m tall, last_lod=%d" % [
			entry.id, entry.name, entry.node, tris, am.get_aabb().size.y, a.get_last_lod()])
	src.free()
	assets.update_mesh_list()
	out.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(out)

## Dithered cross-fade (metres) at the pack trees' cull distance -- used by build_pack_trees().
const TREE_FADE_MARGIN := 24.0
