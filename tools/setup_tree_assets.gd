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
		# Far impostor as LOD1, if bake_tree_impostors() has made one (2026-09-25).
		var imp_base := PACK_OUT_DIR + "%s_impostor" % entry.name
		var has_impostor := ResourceLoader.exists(imp_base + ".res") and ResourceLoader.exists(imp_base + "_material.tres")
		if has_impostor:
			var imesh: ArrayMesh = ResourceLoader.load(imp_base + ".res", "", ResourceLoader.CACHE_MODE_REPLACE)
			imesh.surface_set_material(0, load(imp_base + "_material.tres"))
			ResourceSaver.save(imesh, imp_base + ".res")
			var lod1 := MeshInstance3D.new()
			lod1.name = "LOD1"
			lod1.mesh = imesh
			root.add_child(lod1)
			lod1.owner = root
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
		if has_impostor:
			# Full tree to TREE_IMPOSTOR_RANGE, then the 8-tri impostor out to 100 km (= never culled).
			# Not range 0 ('unlimited'): Terrain3D clamps fade_margin to half the gap to the next range,
			# and with 0 there is no gap -> fade forced to 0 -> hard swap at 150 m.
			# Impostor casts no shadow (sun shadows end at 150 m anyway -- docs/shadows.md).
			a.set_lod_range(0, TREE_IMPOSTOR_RANGE)
			a.set_lod_range(1, TREE_IMPOSTOR_FAR)
			a.set_last_lod(1)
			a.set_last_shadow_lod(0)
			a.set_fade_margin(TREE_IMPOSTOR_FADE)
		else:
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
## (Without an impostor the asset is single-LOD, and Terrain3D clamps the fade to 0 anyway.)
const TREE_FADE_MARGIN := 24.0

## -- Far tree impostors (2026-09-25) --
## Measured in one view (same run): trees beyond 150 m cost ~10 M tris, ~3.3k draw calls, ~3.9 ms
## GPU + ~3 ms CPU of a 10.9 ms GPU frame. Each tree gets a 4-view impostor: 4 vertical planes at
## 0/45/90/135 deg crossing at the trunk (8 tris), texture = unlit captures of the baked tree.
## Pipeline: bake_tree_impostors() -> rescan -> tree_impostor_import() -> build_pack_trees().
const TREE_IMPOSTOR_RANGE := 150.0  ## full tree up to here (= sun shadow max distance)
const TREE_IMPOSTOR_FAR := 100000.0  ## impostor end range -- effectively never culled
const TREE_IMPOSTOR_FADE := 10.0  ## cross-fade full tree <-> impostor (shadows are gone out there anyway)
const TREE_IMPOSTOR_VIEWS := 4
const TREE_IMPOSTOR_RES_H := 256  ## px per view, height; width follows the crown/height ratio
const TREE_IMPOSTOR_SS := 4  ## capture supersampling (power of 2) -- coverage becomes alpha
## Up-normal impostors glowed when looking toward the sun/moon while the real crowns around them
## were dark silhouettes (magenta-tint test, 2026-09-25). Tilting the normal toward the camera
## darkens them into the light and brightens them with the light behind -- like a crown.
## Superseded the same day by baked normals (<name>_impostor_normal.png, use_normal_tex): the tilt
## only helped looking into the light; user still saw a very noticeable switch. Kept as the
## fallback when no normal atlas exists (0 = off).
const TREE_IMPOSTOR_VIEW_NORMAL := 0.0
const TREE_IMPOSTOR_TINT := Color(0.8, 0.8, 0.8)  ## impostor albedo multiplier, for matching the full trees
## Saturation of the impostor colour (1 = as baked). 0.9: at the switch the impostors measured
## 0.66 vs the real crowns' 0.58 (user before/after screenshots, 2026-09-25).
const TREE_IMPOSTOR_SATURATION := 1.0
## Leaf-coverage boost, applied in the SHADER (alpha_gain) so it can be tuned live with the
## PerfDebug keys; the bake stores true coverage (TREE_IMPOSTOR_BAKE_GAIN = 1). Was 2.0 baked:
## impostors came out fuller/smoother than the real trees at the switch. 1.4 = >= ~36 % leaf
## cover survives the 0.5 cutout at full res.
## User-tuned in-game with the PerfDebug keys, 2026-09-25: saturation 1.00, near 0.30,
## far 2.20, brightness 0.80.
const TREE_IMPOSTOR_ALPHA_GAIN := 0.3  ## fullness at TREE_IMPOSTOR_GAIN_NEAR_DIST
## Fullness at TREE_IMPOSTOR_GAIN_FAR_DIST and beyond (shader blends between): coarser mips thin
## the impostor with distance -- 1.4 looked right at 130 m but nearly invisible at 170 m (user).
const TREE_IMPOSTOR_ALPHA_GAIN_FAR := 2.2
## Dry trees: sparse brown twig cards, no leaves (user: ids 14, 16, 17, 19, 22, 24, 26). The green
## gains turned their thin twigs into full brown canopies, so they get their own near/far pair
## (tagged meta impostor_group = "dry" for the PerfDebug keys). User-tuned in-game 2026-09-25.
const TREE_IMPOSTOR_DRY_NAMES: Array[String] = ["PackPineA", "PackPineC", "PackPineD", "PackPineB2", "PackDecidA", "PackDecidB", "PackDecidC"]
const TREE_IMPOSTOR_DRY_ALPHA_GAIN := 0.15
const TREE_IMPOSTOR_DRY_ALPHA_GAIN_FAR := 1.05
## The cross-fade band as Godot actually draws it: impostor fades in 130-150, real tree out
## 150-170 (symmetric margins around begin 140 / end 160 -- see docs/vegetation.md).
const TREE_IMPOSTOR_GAIN_NEAR_DIST := 130.0
const TREE_IMPOSTOR_GAIN_FAR_DIST := 170.0
const TREE_IMPOSTOR_BAKE_GAIN := 1.0  ## alpha = coverage x gain, so >= 25 % leaf cover survives the 0.5 cutout
const TREE_IMPOSTOR_CAPTURE_SHADER := "res://shaders/foliage/foliage_impostor_capture.gdshader"
const TREE_IMPOSTOR_SHADER := "res://shaders/foliage/foliage_impostor.gdshader"

## Renders every baked pack tree (PACK_OUT_DIR/<name>.res) unlit -- bark via an UNSHADED copy of its
## material (keeps the world-triplanar bark), leaf cards via the capture shader (albedo x vertex
## colour, hard cutout) -- from TREE_IMPOSTOR_VIEWS angles with an orthographic camera in an editor
## SubViewport. Saves <name>_impostor.png (views side by side) + <name>_impostor.res (the planes).
## Frame = crown radius R (max horizontal vertex distance from the trunk axis) x tree height.
func bake_tree_impostors() -> String:
	var out: Array[String] = []
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	EditorInterface.get_base_control().add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.1
	cam.far = 400.0
	vp.add_child(cam)
	cam.current = true
	var mi := MeshInstance3D.new()
	vp.add_child(mi)
	var cap_shader: Shader = ResourceLoader.load(TREE_IMPOSTOR_CAPTURE_SHADER, "", ResourceLoader.CACHE_MODE_REPLACE)
	for entry: Dictionary in PACK_TREES:
		var mesh: Mesh = ResourceLoader.load(PACK_OUT_DIR + "%s.res" % entry.name, "", ResourceLoader.CACHE_MODE_IGNORE)
		if mesh == null:
			out.append("%s: no baked mesh -- run build_pack_trees() first" % entry.name)
			continue
		mi.mesh = mesh
		var r := 0.0
		var alb_mats: Array[Material] = []
		var nrm_mats: Array[Material] = []
		for si in mesh.get_surface_count():
			var m := mesh.surface_get_material(si)
			var cm: Material
			var nm: Material
			if m is ShaderMaterial:
				var sm := ShaderMaterial.new()
				sm.shader = cap_shader
				sm.set_shader_parameter("albedo_tex", (m as ShaderMaterial).get_shader_parameter("albedo_tex"))
				var col = (m as ShaderMaterial).get_shader_parameter("albedo_color")
				sm.set_shader_parameter("albedo_color", col if col != null else Color.WHITE)
				sm.set_shader_parameter("use_vertex_color", (m as ShaderMaterial).get_shader_parameter("use_vertex_color") == true)
				cm = sm
				var sn := sm.duplicate() as ShaderMaterial
				sn.set_shader_parameter("normal_pass", true)
				nm = sn
			elif m is BaseMaterial3D:
				var bm := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				cm = bm
				var bn := ShaderMaterial.new()  # bark: opaque, normals only
				bn.shader = cap_shader
				bn.set_shader_parameter("opaque", true)
				bn.set_shader_parameter("normal_pass", true)
				nm = bn
			alb_mats.append(cm)
			nrm_mats.append(nm)
			for v: Vector3 in mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				r = maxf(r, Vector2(v.x, v.z).length())
		var aabb := mesh.get_aabb()
		var y0 := aabb.position.y
		var h := aabb.size.y * 1.01
		r *= 1.02
		var res_h := TREE_IMPOSTOR_RES_H
		var res_w := maxi(16, int(ceil(float(res_h) * (2.0 * r) / h / 4.0)) * 4)
		vp.size = Vector2i(res_w, res_h) * TREE_IMPOSTOR_SS
		cam.size = h
		var atlas := Image.create(res_w * TREE_IMPOSTOR_VIEWS, res_h, false, Image.FORMAT_RGBA8)
		var natlas := Image.create(res_w * TREE_IMPOSTOR_VIEWS, res_h, false, Image.FORMAT_RGB8)
		var opaque := 0
		var nlen := 0.0  # mean raw |n| at full res -- ~1.0 if the colour-space handling is right
		var nface := 0.0  # mean n . toward-camera -- clearly > 0 if back faces got flipped
		for k in TREE_IMPOSTOR_VIEWS:
			var ang := PI * float(k) / float(TREE_IMPOSTOR_VIEWS)
			var axis := Vector3(sin(ang), 0.0, cos(ang))
			var target := Vector3(0.0, y0 + h * 0.5, 0.0)
			cam.look_at_from_position(target + axis * 150.0, target, Vector3.UP)
			cam.force_update_transform()  # else force_draw renders from the previous pose
			_tree_capture_set(mi, alb_mats)
			var img := _tree_capture_draw(vp)
			atlas.blit_rect(_tree_impostor_downsample(img, res_w, res_h), Rect2i(0, 0, res_w, res_h), Vector2i(k * res_w, 0))
			_tree_capture_set(mi, nrm_mats)
			var nimg := _tree_capture_draw(vp)
			var nres := _tree_impostor_downsample_normal(nimg, res_w, res_h, axis)
			natlas.blit_rect(nres[0], Rect2i(0, 0, res_w, res_h), Vector2i(k * res_w, 0))
			nlen += nres[1] / TREE_IMPOSTOR_VIEWS
			nface += nres[2] / TREE_IMPOSTOR_VIEWS
		for y in range(0, res_h, 4):
			for x in range(0, res_w * TREE_IMPOSTOR_VIEWS, 4):
				if atlas.get_pixel(x, y).a > 0.5:
					opaque += 1
		var base := PACK_OUT_DIR + "%s_impostor" % entry.name
		var err := atlas.save_png(ProjectSettings.globalize_path(base + ".png"))
		err = maxi(err, natlas.save_png(ProjectSettings.globalize_path(base + "_normal.png")))
		var err2 := ResourceSaver.save(_tree_impostor_mesh(r, y0, h), base + ".res")
		out.append("%s: %dx%d px/view, opaque %.0f%%, normals |n| %.3f facing %.2f, png err=%d, mesh err=%d" % [
			entry.name, res_w, res_h, 100.0 * opaque / float((res_h / 4) * (res_w * TREE_IMPOSTOR_VIEWS / 4)), nlen, nface, err, err2])
	vp.queue_free()
	return "\n".join(out)

func _tree_capture_set(mi: MeshInstance3D, mats: Array[Material]) -> void:
	for si in mats.size():
		mi.set_surface_override_material(si, mats[si])

## One capture: UPDATE_ONCE + force_draw (twice, as the original single-pass bake did).
func _tree_capture_draw(vp: SubViewport) -> Image:
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	RenderingServer.force_draw(false)
	RenderingServer.force_draw(false)
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img

## Normal-pass capture -> [RGB8 image w x h, mean raw |n| (full res), mean n . axis].
## Box-average like the albedo (premultiplied by coverage), un-premultiply, decode, renormalise,
## re-encode. Empty pixels get the view's mean normal (keeps mips at the silhouette sane).
## axis = direction from the tree toward the capture camera.
func _tree_impostor_downsample_normal(src: Image, w: int, h: int, axis: Vector3) -> Array:
	var lsum := 0.0
	var fsum := 0.0
	var lcnt := 0
	for y in range(0, src.get_height(), 3):
		for x in range(0, src.get_width(), 3):
			var s := src.get_pixel(x, y)
			if s.a > 0.99:
				var sn := Vector3(s.r, s.g, s.b) * 2.0 - Vector3.ONE
				lsum += sn.length()
				fsum += sn.normalized().dot(axis)
				lcnt += 1
	var img := src
	var cw := src.get_width()
	var ch := src.get_height()
	while cw > w:
		cw /= 2
		ch /= 2
		img = img.duplicate() as Image
		img.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
	var out := Image.create(w, h, false, Image.FORMAT_RGB8)
	var mean := Vector3.ZERO
	var empty: Array[Vector2i] = []
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.004:
				var n := Vector3(c.r / c.a, c.g / c.a, c.b / c.a) * 2.0 - Vector3.ONE
				n = n.normalized() if n.length() > 1e-4 else axis
				mean += n
				out.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
			else:
				empty.append(Vector2i(x, y))
	mean = mean.normalized() if mean.length() > 1e-4 else axis
	var fill := Color(mean.x * 0.5 + 0.5, mean.y * 0.5 + 0.5, mean.z * 0.5 + 0.5)
	for p in empty:
		out.set_pixel(p.x, p.y, fill)
	return [out, lsum / maxi(lcnt, 1), fsum / maxi(lcnt, 1)]

## Supersampled capture -> box average. The capture background is (0,0,0,0) and every drawn pixel is
## opaque, so the average is premultiplied colour + coverage. Un-premultiply, then alpha = coverage *
## TREE_IMPOSTOR_ALPHA_GAIN (thin needles cover ~20-40% of a final pixel; without the gain they vanish
## under the 0.5 cutout). Empty pixels get the view's mean leaf colour so mip filtering doesn't
## pull dark fringes into the silhouette.
func _tree_impostor_downsample(src: Image, w: int, h: int) -> Image:
	var img := src
	var cw := src.get_width()
	var ch := src.get_height()
	while cw > w:  # exact halvings -> 2x2 box average each step
		cw /= 2
		ch /= 2
		img = img.duplicate() as Image
		img.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
	var sum := Color(0, 0, 0, 0)
	var cnt := 0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a > 0.004:
				var u := Color(c.r / c.a, c.g / c.a, c.b / c.a, minf(1.0, c.a * TREE_IMPOSTOR_BAKE_GAIN))
				img.set_pixel(x, y, u)
				sum += Color(u.r, u.g, u.b, 0.0)
				cnt += 1
	var fill := Color(sum.r / maxi(cnt, 1), sum.g / maxi(cnt, 1), sum.b / maxi(cnt, 1), 0.0)
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a <= 0.004:
				img.set_pixel(x, y, fill)
	return img

## TREE_IMPOSTOR_VIEWS vertical planes through the trunk axis matching bake_tree_impostors(): plane
## k faces the view direction (sin a, 0, cos a), a = PI*k/VIEWS; it spans -R..R along
## right = UP x axis (image left = -right), y0..y0+H; UV u = k/V .. (k+1)/V. Normals UP.
func _tree_impostor_mesh(r: float, y0: float, h: float) -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var n := PackedVector3Array()
	var idx := PackedInt32Array()
	for k in TREE_IMPOSTOR_VIEWS:
		var ang := PI * float(k) / float(TREE_IMPOSTOR_VIEWS)
		var axis := Vector3(sin(ang), 0.0, cos(ang))
		var right := Vector3.UP.cross(axis) * r
		var u0 := float(k) / float(TREE_IMPOSTOR_VIEWS)
		var u1 := float(k + 1) / float(TREE_IMPOSTOR_VIEWS)
		var b := v.size()
		v.append_array([-right + Vector3(0, y0 + h, 0), right + Vector3(0, y0 + h, 0), right + Vector3(0, y0, 0), -right + Vector3(0, y0, 0)])
		uv.append_array([Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, 1.0), Vector2(u0, 1.0)])
		for i in 4:
			n.append(Vector3.UP)
		idx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

## Impostor PNGs -> VRAM-compressed with mipmaps (forced reimport), then one impostor material per
## tree (<name>_impostor_material.tres, foliage_impostor.gdshader, no backlight). Run after
## bake_tree_impostors() + a filesystem rescan.
func tree_impostor_import() -> String:
	var out: Array[String] = []
	var paths := PackedStringArray()
	for entry: Dictionary in PACK_TREES:
		var png := PACK_OUT_DIR + "%s_impostor.png" % entry.name
		var cfg := ConfigFile.new()
		if cfg.load(png + ".import") != OK:
			out.append("%s: no .import yet -- rescan first" % entry.name)
			continue
		cfg.set_value("params", "compress/mode", 2)
		cfg.set_value("params", "mipmaps/generate", true)
		cfg.set_value("params", "detect_3d/compress_to", 0)
		cfg.save(png + ".import")
		paths.append(png)
		# Normal atlas: lossless + mips (VRAM compression visibly bends normals).
		var npng := PACK_OUT_DIR + "%s_impostor_normal.png" % entry.name
		var ncfg := ConfigFile.new()
		if ncfg.load(npng + ".import") != OK:
			out.append("%s: no normal .import yet -- rescan first" % entry.name)
			continue
		ncfg.set_value("params", "compress/mode", 0)
		ncfg.set_value("params", "mipmaps/generate", true)
		ncfg.set_value("params", "detect_3d/compress_to", 0)
		ncfg.save(npng + ".import")
		paths.append(npng)
	EditorInterface.get_resource_filesystem().reimport_files(paths)
	for entry: Dictionary in PACK_TREES:
		var base := PACK_OUT_DIR + "%s_impostor" % entry.name
		var tex: Texture2D = load(base + ".png")
		if tex == null:
			out.append("%s: impostor texture failed to load" % entry.name)
			continue
		var mat := ShaderMaterial.new()
		mat.resource_name = "%s_impostor_material" % entry.name
		# CACHE_MODE_REPLACE: the editor otherwise keeps a stale shader after an external edit and
		# silently drops parameters for new uniforms (view_normal_mix vanished that way).
		mat.shader = ResourceLoader.load(TREE_IMPOSTOR_SHADER, "", ResourceLoader.CACHE_MODE_REPLACE)
		mat.set_shader_parameter("albedo_tex", tex)
		mat.set_shader_parameter("backlight_color", Color.BLACK)
		mat.set_shader_parameter("albedo_color", TREE_IMPOSTOR_TINT)
		mat.set_shader_parameter("saturation", TREE_IMPOSTOR_SATURATION)
		var dry: bool = entry.name in TREE_IMPOSTOR_DRY_NAMES
		mat.set_shader_parameter("alpha_gain", TREE_IMPOSTOR_DRY_ALPHA_GAIN if dry else TREE_IMPOSTOR_ALPHA_GAIN)
		mat.set_shader_parameter("alpha_gain_far", TREE_IMPOSTOR_DRY_ALPHA_GAIN_FAR if dry else TREE_IMPOSTOR_ALPHA_GAIN_FAR)
		mat.set_shader_parameter("gain_near_dist", TREE_IMPOSTOR_GAIN_NEAR_DIST)
		mat.set_shader_parameter("gain_far_dist", TREE_IMPOSTOR_GAIN_FAR_DIST)
		mat.set_meta("impostor_group", "dry" if dry else "green")
		mat.set_shader_parameter("view_normal_mix", TREE_IMPOSTOR_VIEW_NORMAL)
		var ntex: Texture2D = load(base + "_normal.png")
		mat.set_shader_parameter("normal_tex", ntex)
		mat.set_shader_parameter("use_normal_tex", ntex != null)
		mat.set_shader_parameter("alpha_cutoff", UNDERSTORY_TOOL.ALPHA_SCISSOR)
		mat.set_shader_parameter("mip_alpha_scale", UNDERSTORY_TOOL.MIP_ALPHA_SCALE)
		mat.set_shader_parameter("shadow_alpha_cutoff", UNDERSTORY_TOOL.SHADOW_ALPHA_CUTOFF)
		mat.set_shader_parameter("shadow_mip_alpha_scale", UNDERSTORY_TOOL.SHADOW_MIP_ALPHA_SCALE)
		out.append("%s: material err=%d" % [entry.name, ResourceSaver.save(mat, base + "_material.tres")])
	return "reimported %d png(s)\n%s" % [paths.size(), "\n".join(out)]
