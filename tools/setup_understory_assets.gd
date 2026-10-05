@tool
extends Node

## Setup for the understory layer (shrubs + ferns), kept apart from the trees:
## res://assets/models/understory/<dir>/<dir>.fbx + textures/<dir>_{diffuse,normal,translucency}.tga
## Sources: Nobiax "Bushes" pack (CC0) -> bush_01/02/04/05; Yughues "Fern v2" -> fern_02 (credit);
## Megascans "Lady Fern" (wdvlditia, 9 variants) -> lady_fern/lady_fern.glb + textures/lady_fern_*.png,
## exported by tools/blender/import_megascans_plant.py (2026-10-02); Megascans "Elderberry"
## (wfzobb2ia, variants A + B) -> elderberry/, same script (2026-10-04).
## Every setup method takes `only`: a list of dirs to limit the run to (empty = all), so adding a
## plant leaves the existing ones untouched (no re-save / reimport).
## Run via call_method(runtime:false) on tools/setup_understory_assets.tscn, node ".".

const BASE := "res://assets/models/understory/"

## "scale" -> nodes/root_scale in the .fbx.import. The FBX files are in cm and Godot's
## importer already converts to metres, so the bushes stay 1.0 (1.0-1.6 m tall).
## fern_02 is modelled huge (3.6 x 3.7 m, 1.45 m tall) -> 0.45 = ~1.6 m across, ~0.65 m tall.
## "translucency": bushes ship a translucency map (-> backlight_texture); the fern doesn't
## and gets a flat backlight colour instead.
const PLANTS := [
	{"dir": "bush_01", "kind": "fern", "scale": 1.0, "translucency": true},   # broad pinnate leaves -- the large/broad fern variant
	{"dir": "bush_02", "kind": "shrub", "scale": 1.0, "translucency": true},  # dense round, autumn-coloured
	{"dir": "bush_04", "kind": "shrub", "scale": 1.0, "translucency": true},  # grassy/spiky
	{"dir": "bush_05", "kind": "shrub", "scale": 1.0, "translucency": true},  # rounded, woody stem
	{"dir": "fern_02", "kind": "fern", "scale": 0.45, "translucency": false, "cull_back": true},  # the real fern, 5 LODs (sibling nodes FernPlantV2_LOD0..4)
	# Megascans lady fern: one glb, 9 variants x (Var<X>_Near = source LOD1, Var<X>_Far = 25 % of it).
	# Already in metres and upright. "ext" = model file type (default fbx), "tex_ext" = textures (default tga).
	{"dir": "lady_fern", "kind": "fern", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
	# Megascans elderberry (wfzobb2ia), the tall bush (2026-10-04): variants A + B only, Near = the MID
	# pack's LOD2, 4K textures from the HIGH pack (same atlas). 1.19 / 1.43 m tall as scanned; scaled
	# up to ~2-2.5 m by UnderstoryScatter.SHRUB_MIX, not here.
	{"dir": "elderberry", "kind": "shrub", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
	# Flowers (2026-10-04), placed by scripts/terrain/flower_scatter.gd. wood_sorrel + poppy: Megascans
	# (uchkajuia, 8 variants, Near = source LOD1; vmcobd0ja, the 5 red variants A/B/C/D/H, Near = source
	# LOD2), import_megascans_plant.py. clover + dandelion: taken out of the Sketchfab scene
	# grass_vegitation_mix.glb by tools/blender/import_herb_mix.py (clover = its carpet cut in 4 pieces).
	{"dir": "wood_sorrel", "kind": "flower", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
	{"dir": "poppy", "kind": "flower", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
	{"dir": "clover", "kind": "flower", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
	{"dir": "dandelion", "kind": "flower", "scale": 1.0, "translucency": false, "ext": "glb", "tex_ext": "png"},
]

func _plant(dir: String) -> Dictionary:
	for p: Dictionary in PLANTS:
		if p.dir == dir:
			return p
	return {}

func _model_path(dir: String) -> String:
	return BASE + "%s/%s.%s" % [dir, dir, _plant(dir).get("ext", "fbx")]

## res://.../<dir>/textures/<dir>_<role>.<tga|png>
func _tex_path(dir: String, role: String) -> String:
	return BASE + "%s/textures/%s_%s.%s" % [dir, dir, role, _plant(dir).get("tex_ext", "tga")]

func _wanted(only: Array, dir: String) -> bool:
	return only.is_empty() or only.has(dir)
## "cull_back": fern_02 is modelled double-layered (every frond duplicated back-to-back with
## flipped normals -- debug_print_shading: 598 up / 598 down). With CULL_DISABLED both layers
## draw and self-shadow -> near-black fronds (seen in-game 2026-09-25). The bushes are
## single-layer cards and stay double-sided.

## -- Terrain3D mesh assets for the understory (placed by scripts/terrain/understory_scatter.gd) --
## Ids continue the contiguous Terrain3D list after the trees (14-27). Keep in sync with
## UnderstoryScatter's *_ID constants.
## Each asset is BAKED: the FBX node chain (the -90 deg X Z-up fix; the fern's 0.45 import scale
## is already in its vertices) goes into the vertices, because Terrain3D only takes the mesh of
## each LOD node, not its transform -- an unbaked plant lies on its side (seen 2026-09-25).
## "lods": FBX node per Terrain3D LOD; "ranges": where each LOD ends (the last = draw distance).
## "last_shadow_lod": the last LOD that casts sun shadows. Since 2026-10-05 (performance_findings.md
## step 3; Kirill checked it in-game: fine): 0 for the ferns, bushes and elderberry -- only the nearest LOD casts (to 60 m, bushes
## 80 m; the ferns' near LOD ended at 50 m until Kirill asked for 60 the same day, measured to each 32 m cell's centre), the far mesh and the impostor cast nothing. Was
## every LOD (2 / bushes 1): shadows were 50-70 % of the understory's draws. Apply a changed value
## with apply_shadow_lods(); to go back, restore 2 / 1 and run it again. Poppies still cast on
## every LOD. (History: the first version stopped shadows at 35 m via a duplicate LOD1 -- the
## Terrain3D fade margin then visibly faded plant shadows in/out as the player walked, 2026-09-25.)
const ASSETS_PATH := "res://terrain_assets.tres"
## 0 = NO LOD cross-fade. With a margin, Terrain3D sets each LOD MultiMesh to Godot's visibility-range
## "fade self" with overlapping ranges (fern: L0 0-23 m fading 15-23, L1 7-43 fading in 7-15 ...,
## measured 2026-09-25) -- instances inside those dithered bands cast no proper shadow, so fern
## shadows faded out/in as the player walked closer (Godot issue #91671 family). Hard LOD switches
## (same silhouette, fewer tris) are far less noticeable than vanishing shadows.
## Default for assets with LOD switches (the fern): no fade.
const UNDERSTORY_FADE_MARGIN := 0.0
## Single-LOD bushes: their only fade is at the far draw edge, where losing the shadow during the
## fade doesn't show -- a hard pop there was very visible (user, 2026-09-25: "pop in for the shrubs
## and their shadows" at the old 70 m). Note Terrain3D measures ranges to each 32 m cell's CENTRE,
## so a whole cell of plants appears together, ~+/-22 m around the nominal range.
const BUSH_FADE_MARGIN := 12.0
const UNDERSTORY_ASSETS := [
	# Fern: full 440-tri mesh (source LOD2) to 50 m, then the source's cheapest (LOD4, 88 tris, same
	# bounds) out to 600 m like the trees -- ferns must never pop in, even across the map (user,
	# 2026-09-25). No fade (fading kills shadows); shadows on both LODs so none cut off at the switch.
	# History: 440/264/88 at 15/35/70-100 m popped visibly both at the switches and the far edge.
	# + far IMPOSTOR (4 tris) with range 0 = never culled (user: visible even beyond 600 m).
	{"id": 28, "name": "Fern02", "dir": "fern_02", "mat": "fern_02", "lods": ["FernPlantV2_LOD2", "FernPlantV2_LOD4", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	# Bushes: the SAME mesh twice. Terrain3D clamps fade_margin to half the LOD0->LOD1 gap, so a
	# single-LOD asset silently gets NO fade (verified at runtime 2026-09-25). LOD1 (100-124 m)
	# exists only to allow the far fade-out (~112-136 m); the 100 m hand-over is the identical mesh.
	# Bushes: full mesh to 80 m, then the far IMPOSTOR (4 tris), range 0 = never culled. Replaces the
	# 100/124 m same-mesh fade-out (bushes vanished far away; user wants them visible at any range).
	{"id": 29, "name": "Bush01", "dir": "bush_01", "mat": "bush_01", "lods": ["bush_01", "IMPOSTOR"], "ranges": [80.0, 0.0], "last_shadow_lod": 0},
	{"id": 30, "name": "Bush02Green", "dir": "bush_02", "mat": "bush_02_green", "lods": ["bush_02", "IMPOSTOR"], "ranges": [80.0, 0.0], "last_shadow_lod": 0},
	{"id": 31, "name": "Bush04", "dir": "bush_04", "mat": "bush_04", "lods": ["bush_04", "IMPOSTOR"], "ranges": [80.0, 0.0], "last_shadow_lod": 0},
	{"id": 32, "name": "Bush05", "dir": "bush_05", "mat": "bush_05", "lods": ["bush_05", "IMPOSTOR"], "ranges": [80.0, 0.0], "last_shadow_lod": 0},
	# Lady fern variants (2026-10-02), same scheme as Fern02: Near (source LOD1) to 50 m, Far to 150 m,
	# then the impostor. A/E/F/G/H = full clumps (1.3-1.9 m wide, 446-1129 tris), B/I = small plants
	# (196 / 254 tris), C/D = single-frond sprigs (124 / 74 tris). Ids 33-54 are rocks / deadfall.
	{"id": 55, "name": "LadyFernA", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarA_Near", "VarA_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 56, "name": "LadyFernB", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarB_Near", "VarB_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 57, "name": "LadyFernC", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarC_Near", "VarC_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 58, "name": "LadyFernD", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarD_Near", "VarD_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 59, "name": "LadyFernE", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarE_Near", "VarE_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 60, "name": "LadyFernF", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarF_Near", "VarF_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 61, "name": "LadyFernG", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarG_Near", "VarG_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 62, "name": "LadyFernH", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarH_Near", "VarH_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 63, "name": "LadyFernI", "dir": "lady_fern", "mat": "lady_fern", "lods": ["VarI_Near", "VarI_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	# Elderberry, the tall bush (2026-10-04): Near 3150 / 3968 tris to 50 m, Far (25 %) to 150 m, then
	# the impostor. Ids 64-68 are the saplings (tools/setup_tree_assets.gd).
	{"id": 69, "name": "ElderberryA", "dir": "elderberry", "mat": "elderberry", "lods": ["VarA_Near", "VarA_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	{"id": 70, "name": "ElderberryB", "dir": "elderberry", "mat": "elderberry", "lods": ["VarB_Near", "VarB_Far", "IMPOSTOR"], "ranges": [60.0, 150.0, 0.0], "last_shadow_lod": 0},
	# Flowers (2026-10-04) -- keep in sync with FlowerScatter's ids. "shadows": false = casts none
	# (plants a few cm tall). Unlike the ferns and bushes, the small ones are CULLED at their last range
	# (no impostor): a 10 cm plant is under a pixel long before that. Poppies keep the fern scheme
	# (impostor, never culled, shadows) -- they are 0.4-0.7 m and red.
	# Wood sorrel: Near 70-632 tris to 25 m, Far (25 %, min 48) to 60 m.
	{"id": 71, "name": "WoodSorrelA", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarA_Near", "VarA_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 72, "name": "WoodSorrelB", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarB_Near", "VarB_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 73, "name": "WoodSorrelC", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarC_Near", "VarC_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 74, "name": "WoodSorrelD", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarD_Near", "VarD_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 75, "name": "WoodSorrelE", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarE_Near", "VarE_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 76, "name": "WoodSorrelF", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarF_Near", "VarF_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 77, "name": "WoodSorrelG", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarG_Near", "VarG_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 78, "name": "WoodSorrelH", "dir": "wood_sorrel", "mat": "wood_sorrel", "lods": ["VarH_Near", "VarH_Far"], "ranges": [25.0, 60.0], "last_shadow_lod": 0, "shadows": false},
	# Poppy: Near 166-1474 tris to 40 m, Far (25 %) to 120 m, then the impostor.
	{"id": 79, "name": "PoppyA", "dir": "poppy", "mat": "poppy", "lods": ["VarA_Near", "VarA_Far", "IMPOSTOR"], "ranges": [40.0, 120.0, 0.0], "last_shadow_lod": 2},
	{"id": 80, "name": "PoppyB", "dir": "poppy", "mat": "poppy", "lods": ["VarB_Near", "VarB_Far", "IMPOSTOR"], "ranges": [40.0, 120.0, 0.0], "last_shadow_lod": 2},
	{"id": 81, "name": "PoppyC", "dir": "poppy", "mat": "poppy", "lods": ["VarC_Near", "VarC_Far", "IMPOSTOR"], "ranges": [40.0, 120.0, 0.0], "last_shadow_lod": 2},
	{"id": 82, "name": "PoppyD", "dir": "poppy", "mat": "poppy", "lods": ["VarD_Near", "VarD_Far", "IMPOSTOR"], "ranges": [40.0, 120.0, 0.0], "last_shadow_lod": 2},
	{"id": 83, "name": "PoppyH", "dir": "poppy", "mat": "poppy", "lods": ["VarH_Near", "VarH_Far", "IMPOSTOR"], "ranges": [40.0, 120.0, 0.0], "last_shadow_lod": 2},
	# Dandelion clump (369 tris) and the four clover carpet pieces (581-777 tris): one LOD, culled at 60 m.
	{"id": 84, "name": "Dandelion", "dir": "dandelion", "mat": "dandelion", "lods": ["VarA_Near"], "ranges": [60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 85, "name": "CloverA", "dir": "clover", "mat": "clover", "lods": ["VarA_Near"], "ranges": [60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 86, "name": "CloverB", "dir": "clover", "mat": "clover", "lods": ["VarB_Near"], "ranges": [60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 87, "name": "CloverC", "dir": "clover", "mat": "clover", "lods": ["VarC_Near"], "ranges": [60.0], "last_shadow_lod": 0, "shadows": false},
	{"id": 88, "name": "CloverD", "dir": "clover", "mat": "clover", "lods": ["VarD_Near"], "ranges": [60.0], "last_shadow_lod": 0, "shadows": false},
]

## Bakes each UNDERSTORY_ASSETS entry to <dir>/<name>_<node>.res meshes + a <dir>/<Name>.tscn
## with LOD0..n children, and registers/updates it as a Terrain3D mesh asset in
## terrain_assets.tres. Safe to re-run (overwrites). Run in the EDITOR process (call_method,
## runtime:false) -- same reason as setup_tree_assets.gd: the editor holds terrain_assets.tres.
func build_understory_assets(only: Array = []) -> String:
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	var out: Array[String] = []
	for e: Dictionary in UNDERSTORY_ASSETS:
		if not _wanted(only, e.dir):
			continue
		var src: Node = (ResourceLoader.load(_model_path(e.dir), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
		var baked: Dictionary = {}  # FBX node name -> baked ArrayMesh
		var root := Node3D.new()
		root.name = e.name
		var lod_info: Array[String] = []
		for i in (e.lods as Array).size():
			var node_name: String = e.lods[i]
			if not baked.has(node_name) and node_name == "IMPOSTOR":
				# Far impostor (bake_impostors()): crossed quads + their own material.
				var ibase := _impostor_base(e.name, e.dir)
				var imesh: ArrayMesh = ResourceLoader.load(ibase + ".res", "", ResourceLoader.CACHE_MODE_REPLACE)
				if imesh == null:
					out.append("%s: impostor mesh missing -- run bake_impostors()" % e.name)
					break
				imesh.surface_set_material(0, load(ibase + "_material.tres"))
				ResourceSaver.save(imesh, ibase + ".res")
				baked[node_name] = imesh
			elif not baked.has(node_name):
				var mi := src.find_child(node_name, true, false) as MeshInstance3D
				if mi == null or mi.mesh == null:
					out.append("%s: node %s not found -- skipped" % [e.name, node_name])
					break
				var am := _bake_node_mesh(mi)
				# Material on the SURFACE, not the asset's material_override: Terrain3D applies one
				# override to every LOD, which would paint the leaf material onto the impostor quads.
				am.surface_set_material(0, load(BASE + "%s/%s_material.tres" % [e.dir, e.mat]))
				var mesh_path: String = BASE + "%s/%s_%s.res" % [e.dir, (e.name as String).to_snake_case(), node_name.to_snake_case()]
				ResourceSaver.save(am, mesh_path)
				am.take_over_path(mesh_path)
				baked[node_name] = am
			var lod := MeshInstance3D.new()
			lod.name = "LOD%d" % i
			lod.mesh = baked[node_name]
			root.add_child(lod)
			lod.owner = root
			var aabb: AABB = (baked[node_name] as Mesh).get_aabb()
			lod_info.append("LOD%d=%s %d tris to %.0f m (h %.2f, y %.2f..%.2f)" % [i, node_name, _tri_count(baked[node_name]), e.ranges[i], aabb.size.y, aabb.position.y, aabb.end.y])
		src.free()
		var ps := PackedScene.new()
		ps.pack(root)
		root.free()
		var scene_path: String = BASE + "%s/%s.tscn" % [e.dir, e.name]
		ResourceSaver.save(ps, scene_path)
		var a: Terrain3DMeshAsset = assets.get_mesh_asset(e.id)
		var is_new := a == null
		if is_new:
			a = Terrain3DMeshAsset.new()
			a.set_id(e.id)
		a.set_name(e.name)
		a.set_scene_file(ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_REPLACE))
		a.set_material_override(null)  # per-LOD surface materials instead (impostor LOD needs its own)
		a.set_height_offset(0.0)
		a.set_density(0.1)
		if is_new:
			assets.set_mesh_asset(e.id, a)
		for i in (e.ranges as Array).size():
			a.set_lod_range(i, e.ranges[i])
		a.set_last_lod((e.lods as Array).size() - 1)
		a.set_last_shadow_lod(e.last_shadow_lod)
		a.set_cast_shadows(GeometryInstance3D.SHADOW_CASTING_SETTING_ON if e.get("shadows", true) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
		a.set_shadow_impostor(0)
		a.set_fade_margin(e.get("fade", UNDERSTORY_FADE_MARGIN))
		out.append("id=%d %s (%s): lod_count=%d last_lod=%d last_shadow_lod=%d | %s" % [
			e.id, e.name, "created" if is_new else "updated", a.get_lod_count(), a.get_last_lod(), a.get_last_shadow_lod(), "; ".join(lod_info)])
	assets.update_mesh_list()
	out.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(out)

## Writes only each entry's "ranges" and "last_shadow_lod" to its Terrain3D mesh asset -- no mesh
## is re-baked. Run in the EDITOR process like build_understory_assets().
func apply_shadow_lods(only: Array = []) -> String:
	var assets: Terrain3DAssets = load(ASSETS_PATH)
	var out: Array[String] = []
	for e: Dictionary in UNDERSTORY_ASSETS:
		if not _wanted(only, e.dir):
			continue
		var a: Terrain3DMeshAsset = assets.get_mesh_asset(e.id)
		if a == null:
			out.append("id=%d %s: no mesh asset -- run build_understory_assets()" % [e.id, e.name])
			continue
		var before := a.get_last_shadow_lod()
		var range_before := a.get_lod_range(0)
		for i in (e.ranges as Array).size():
			a.set_lod_range(i, e.ranges[i])
		a.set_last_shadow_lod(e.last_shadow_lod)
		out.append("id=%d %s: lod0 range %.0f -> %.0f m, last_shadow_lod %d -> %d" % [e.id, e.name, range_before, a.get_lod_range(0), before, a.get_last_shadow_lod()])
	out.append("saved %s (err=%d)" % [ASSETS_PATH, assets.save(ASSETS_PATH)])
	return "\n".join(out)

## -- Far impostors (2026-09-25) --
## User: plants must stay visible at ANY distance (> 600 m), cheapest solution possible. Each plant
## gets a baked 2-view texture (front + side, IMPOSTOR_RES px each) and a crossed-quad mesh (4 tris)
## used as its last Terrain3D LOD with range 0 = never culled.
## Pipeline: bake_impostors() -> rescan -> impostor_import() -> setup_impostor_materials() ->
## build_understory_assets().
const IMPOSTOR_RES := 256
const IMPOSTOR_CAPTURE_SHADER := "res://shaders/foliage/foliage_impostor_capture.gdshader"
const IMPOSTOR_SHADER := "res://shaders/foliage/foliage_impostor.gdshader"
## [asset name, dir, FBX node photographed, MATERIALS name for albedo texture + tint]
const IMPOSTORS := [
	["Fern02", "fern_02", "FernPlantV2_LOD2", "fern_02"],
	["Bush01", "bush_01", "bush_01", "bush_01"],
	["Bush02Green", "bush_02", "bush_02", "bush_02_green"],
	["Bush04", "bush_04", "bush_04", "bush_04"],
	["Bush05", "bush_05", "bush_05", "bush_05"],
	["LadyFernA", "lady_fern", "VarA_Near", "lady_fern"],
	["LadyFernB", "lady_fern", "VarB_Near", "lady_fern"],
	["LadyFernC", "lady_fern", "VarC_Near", "lady_fern"],
	["LadyFernD", "lady_fern", "VarD_Near", "lady_fern"],
	["LadyFernE", "lady_fern", "VarE_Near", "lady_fern"],
	["LadyFernF", "lady_fern", "VarF_Near", "lady_fern"],
	["LadyFernG", "lady_fern", "VarG_Near", "lady_fern"],
	["LadyFernH", "lady_fern", "VarH_Near", "lady_fern"],
	["LadyFernI", "lady_fern", "VarI_Near", "lady_fern"],
	["ElderberryA", "elderberry", "VarA_Near", "elderberry"],
	["ElderberryB", "elderberry", "VarB_Near", "elderberry"],
	["PoppyA", "poppy", "VarA_Near", "poppy"],
	["PoppyB", "poppy", "VarB_Near", "poppy"],
	["PoppyC", "poppy", "VarC_Near", "poppy"],
	["PoppyD", "poppy", "VarD_Near", "poppy"],
	["PoppyH", "poppy", "VarH_Near", "poppy"],
]

func _impostor_base(name: String, dir: String) -> String:
	return BASE + "%s/%s_impostor" % [dir, name.to_snake_case()]

func _material_entry(name: String) -> Dictionary:
	for m: Dictionary in MATERIALS:
		if m.name == name:
			return m
	return {}

## Renders each plant (baked upright mesh, unlit albedo x tint, hard cutout) from the front (+Z,
## looking -Z) and the side (+X, looking -X) with an orthographic camera into a transparent
## SubViewport attached to the editor, and saves <dir>/<name>_impostor.png (2*RES x RES: front
## left, side right) + <dir>/<name>_impostor.res (two crossed quads, UP normals). Each view is a
## square S = max(plant width, height), bottom-aligned, so the quads match the plant's footprint.
func bake_impostors(only: Array = []) -> String:
	var out: Array[String] = []
	var vp := SubViewport.new()
	vp.size = Vector2i(IMPOSTOR_RES, IMPOSTOR_RES)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	EditorInterface.get_base_control().add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = 100.0
	vp.add_child(cam)
	cam.current = true
	var mi := MeshInstance3D.new()
	vp.add_child(mi)
	var cap_shader: Shader = load(IMPOSTOR_CAPTURE_SHADER)
	for row: Array in IMPOSTORS:
		var name: String = row[0]
		var dir: String = row[1]
		if not _wanted(only, dir):
			continue
		var m := _material_entry(row[3])
		var src: Node = (ResourceLoader.load(_model_path(dir), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
		var node := src.find_child(row[2], true, false) as MeshInstance3D
		if node == null:
			out.append("%s: node %s not found" % [name, row[2]])
			src.free()
			continue
		var mesh := _bake_node_mesh(node)
		src.free()
		var mat := ShaderMaterial.new()
		mat.shader = cap_shader
		mat.set_shader_parameter("albedo_tex", load(_tex_path(dir, m.diffuse)))
		mat.set_shader_parameter("albedo_color", Color(m.albedo, m.albedo, m.albedo))
		mi.mesh = mesh
		mi.material_override = mat
		var aabb := mesh.get_aabb()
		var c := aabb.get_center()
		var atlas := Image.create(IMPOSTOR_RES * 2, IMPOSTOR_RES, false, Image.FORMAT_RGBA8)
		var sizes: Array[float] = []
		for view in 2:
			var axis := Vector3(0, 0, 1) if view == 0 else Vector3(1, 0, 0)
			var w := aabb.size.x if view == 0 else aabb.size.z
			var s := maxf(w, aabb.size.y) * 1.02  # tiny margin so leaf tips aren't clipped
			sizes.append(s)
			cam.size = s
			var look_at := Vector3(c.x, aabb.position.y + s * 0.5, c.z)
			cam.look_at_from_position(look_at + axis * 50.0, look_at, Vector3.UP)
			# Transform changes reach the renderer only at the next frame flush -- force_draw() alone
			# rendered from the camera's DEFAULT pose (both views identical, framed on the origin).
			cam.force_update_transform()
			vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			RenderingServer.force_draw(false)
			RenderingServer.force_draw(false)
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			atlas.blit_rect(img, Rect2i(0, 0, IMPOSTOR_RES, IMPOSTOR_RES), Vector2i(view * IMPOSTOR_RES, 0))
		var base := _impostor_base(name, dir)
		var err := atlas.save_png(ProjectSettings.globalize_path(base + ".png"))
		var quad := _impostor_mesh(aabb, sizes[0], sizes[1])
		var err2 := ResourceSaver.save(quad, base + ".res")
		# coverage check: share of opaque texels per view (0 = the capture came out empty)
		var opaque := [0, 0]
		for y in range(0, IMPOSTOR_RES, 4):
			for x in range(0, IMPOSTOR_RES * 2, 4):
				if atlas.get_pixel(x, y).a > 0.5:
					opaque[0 if x < IMPOSTOR_RES else 1] += 1
		var per_view := float((IMPOSTOR_RES / 4) * (IMPOSTOR_RES / 4))
		out.append("%s: png err=%d, mesh err=%d, view size front %.2f m / side %.2f m, opaque front %.0f%% side %.0f%%" % [
			name, err, err2, sizes[0], sizes[1], 100.0 * opaque[0] / per_view, 100.0 * opaque[1] / per_view])
	vp.queue_free()
	return "\n".join(out)

## Two crossed vertical quads matching bake_impostors()' views: front quad in the XY plane through
## the AABB centre (u 0..0.5, +X = right), side quad in the ZY plane (u 0.5..1, -Z = right, as
## seen from +X). Bottom at the AABB floor, square S x S. Normals UP (the shader forces it anyway).
func _impostor_mesh(aabb: AABB, s_front: float, s_side: float) -> ArrayMesh:
	var c := aabb.get_center()
	var y0 := aabb.position.y
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var hf := s_front * 0.5
	v.append_array([Vector3(c.x - hf, y0 + s_front, c.z), Vector3(c.x + hf, y0 + s_front, c.z), Vector3(c.x + hf, y0, c.z), Vector3(c.x - hf, y0, c.z)])
	uv.append_array([Vector2(0.0, 0.0), Vector2(0.5, 0.0), Vector2(0.5, 1.0), Vector2(0.0, 1.0)])
	var hs := s_side * 0.5
	v.append_array([Vector3(c.x, y0 + s_side, c.z + hs), Vector3(c.x, y0 + s_side, c.z - hs), Vector3(c.x, y0, c.z - hs), Vector3(c.x, y0, c.z + hs)])
	uv.append_array([Vector2(0.5, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.5, 1.0)])
	var n := PackedVector3Array()
	for i in 8:
		n.append(Vector3.UP)
	var idx := PackedInt32Array([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return am

## Impostor PNGs: VRAM-compressed with mipmaps (same as leaf diffuse). Run after bake + rescan.
func impostor_import(only: Array = []) -> String:
	var out: Array[String] = []
	for row: Array in IMPOSTORS:
		if not _wanted(only, row[1]):
			continue
		out.append(set_texture_import_mode(_impostor_base(row[0], row[1]) + ".png", "vram"))
	return "\n".join(out)

## <dir>/<name>_impostor_material.tres on foliage_impostor.gdshader (tint already baked in).
func setup_impostor_materials(only: Array = []) -> String:
	var out: Array[String] = []
	for row: Array in IMPOSTORS:
		if not _wanted(only, row[1]):
			continue
		var base := _impostor_base(row[0], row[1])
		var mat := ShaderMaterial.new()
		mat.resource_name = "%s_impostor_material" % row[0]
		mat.shader = load(IMPOSTOR_SHADER)
		var tex: Texture2D = load(base + ".png")
		if tex == null:
			out.append("%s: MISSING impostor texture" % row[0])
		mat.set_shader_parameter("albedo_tex", tex)
		mat.set_shader_parameter("saturation", _material_entry(row[3]).get("saturation", 1.0))
		mat.set_shader_parameter("backlight_color", FERN_BACKLIGHT)
		mat.set_shader_parameter("alpha_cutoff", ALPHA_SCISSOR)
		mat.set_shader_parameter("mip_alpha_scale", MIP_ALPHA_SCALE)
		mat.set_shader_parameter("shadow_alpha_cutoff", SHADOW_ALPHA_CUTOFF)
		mat.set_shader_parameter("shadow_mip_alpha_scale", SHADOW_MIP_ALPHA_SCALE)
		var err := ResourceSaver.save(mat, base + "_material.tres")
		out.append("saved %s_material.tres (err=%d)" % [base, err])
	return "\n".join(out)

## Mesh of `mi` with its node chain's rotation/scale (up to and incl. the scene root) baked into
## vertices, normals and tangents. Origin kept (the bushes' roots sit a little below y=0 --
## that's the intended ground contact). Single-surface materials are left off: the Terrain3D
## mesh asset applies <mat>_material.tres as material_override.
func _bake_node_mesh(mi: MeshInstance3D) -> ArrayMesh:
	var basis := Basis.IDENTITY
	var n: Node = mi
	while n != null:
		if n is Node3D:
			basis = (n as Node3D).basis * basis
		n = n.get_parent()
	var nbasis := basis.inverse().transposed()
	var flip := basis.determinant() < 0.0
	var am := ArrayMesh.new()
	for si in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] = basis * verts[i]
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
				tg[i] = t.x
				tg[i + 1] = t.y
				tg[i + 2] = t.z
				if flip:
					tg[i + 3] = -tg[i + 3]
			arr[Mesh.ARRAY_TANGENT] = tg
		am.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(si), arr)
	return am

## Diagnostic (2026-09-25, "fern shadows disappear as I approach"): per baked LOD mesh of each
## understory asset -- normals up/down (double-layered?), triangle winding vs normal
## (front face = counter-clockwise in Godot... reported as share of tris whose geometric normal
## agrees with the vertex normal), and the UV bounds (which part of the texture it uses).
func debug_print_lod_meshes() -> String:
	var out: Array[String] = []
	for e: Dictionary in UNDERSTORY_ASSETS:
		var scene: PackedScene = ResourceLoader.load(BASE + "%s/%s.tscn" % [e.dir, e.name], "", ResourceLoader.CACHE_MODE_IGNORE)
		var root := scene.instantiate()
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			var arr := mi.mesh.surface_get_arrays(0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var up := 0
			var down := 0
			for n in nr:
				if n.y > 0.3:
					up += 1
				elif n.y < -0.3:
					down += 1
			var agree := 0
			var tris := idx.size() / 3
			for t in tris:
				var a := idx[t * 3]
				var b := idx[t * 3 + 1]
				var c := idx[t * 3 + 2]
				# Godot front faces are clockwise when viewed from the front -> geometric normal (b-a)x(c-a) points BACK.
				var g := (v[b] - v[a]).cross(v[c] - v[a])
				if g.dot(nr[a] + nr[b] + nr[c]) < 0.0:
					agree += 1
			var uvmin := Vector2(INF, INF)
			var uvmax := Vector2(-INF, -INF)
			for u in uv:
				uvmin = uvmin.min(u)
				uvmax = uvmax.max(u)
			out.append("%s %s: tris=%d normals up=%d down=%d | winding-consistent-with-normal %d/%d | uv %s..%s" % [
				e.name, mi.name, tris, up, down, agree, tris, uvmin.snapped(Vector2.ONE * 0.01), uvmax.snapped(Vector2.ONE * 0.01)])
		root.free()
	return "\n".join(out)

func _tri_count(mesh: Mesh) -> int:
	var tris := 0
	for si in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(si)
		var idx = arr[Mesh.ARRAY_INDEX]
		tris += ((idx as PackedInt32Array).size() if idx != null else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return tris

const ALPHA_SCISSOR := 0.5
## Foliage cutout shader (docs/shadows.md). Tuning: raise MIP_ALPHA_SCALE if distant plants look
## thin, lower if they look blobby; raise SHADOW_MIP_ALPHA_SCALE / lower SHADOW_ALPHA_CUTOFF if far
## shadows are still too faint, the reverse if near shadows lose their leafy gaps.
const FOLIAGE_SHADER_DOUBLE := "res://shaders/foliage/foliage_cutout_double.gdshader"
const FOLIAGE_SHADER_BACK := "res://shaders/foliage/foliage_cutout_back.gdshader"
const MIP_ALPHA_SCALE := 0.25
const SHADOW_ALPHA_CUTOFF := 0.35
const SHADOW_MIP_ALPHA_SCALE := 0.6
const ROUGHNESS := 0.85
const FERN_BACKLIGHT := Color(0.28, 0.36, 0.12)  # flat leaf-glow for plants without a translucency map
## Colour strength of the flower materials (1 = as scanned). After changing it rerun
## setup_materials + setup_impostor_materials for the flower dirs; no rebuild needed.
const FLOWER_SATURATION := 1.6

## Import settings for every plant model (FBX / glb): root_scale from PLANTS, and DISCARD embedded /
## referenced textures (fbx/embedded_image_handling=0) -- the materials below are applied as
## overrides, and fern_02.fbx references textures on the artist's old E:\ drive. See
## docs/adding_models.md rules 3 + 4. Editing .import alone doesn't reimport -> forced here.
func configure_imports(only: Array = []) -> String:
	var out: Array[String] = []
	var paths := PackedStringArray()
	for p: Dictionary in PLANTS:
		if not _wanted(only, p.dir):
			continue
		var fbx: String = _model_path(p.dir)
		var cfg := ConfigFile.new()
		var err := cfg.load(fbx + ".import")
		if err != OK:
			out.append("%s: could not read .import (err=%d)" % [p.dir, err])
			continue
		cfg.set_value("params", "nodes/root_scale", float(p.scale))
		cfg.set_value("params", "%s/embedded_image_handling" % ("gltf" if fbx.ends_with(".glb") else "fbx"), 0)
		# NO import-generated shadow meshes: they keep vertex positions only (no UVs), so the
		# alpha-scissor leaf cutout samples a transparent texel in the shadow pass and the plant
		# casts no shadow at all (seen in-game 2026-09-25). The baked trees have none either.
		cfg.set_value("params", "meshes/create_shadow_meshes", false)
		err = cfg.save(fbx + ".import")
		out.append("%s: root_scale=%s embedded_image_handling=0 create_shadow_meshes=false (save err=%d)" % [p.dir, p.scale, err])
		paths.append(fbx)
	EditorInterface.get_resource_filesystem().reimport_files(paths)
	out.append("reimported %d files" % paths.size())
	return "\n".join(out)

## Materials, one .tres each: <dir>/<name>_material.tres (used as a material override by the
## placement layer, like the rocks). Realistic flat-lit textures (docs/vegetation.md art
## direction); leaf cards: alpha scissor, backlight.
##
## Brightness is matched to fern_02 (user, 2026-09-25: bushes "too bright, closer to the
## ferns"). Measured on the source textures (solid leaf texels, linear luminance): fern diffuse
## 0.031; bushes 0.033-0.082. Backlight: fern flat colour = 0.091; bushes were WHITE x their
## translucency map = 0.04-0.60 (bush_01 6.7x the fern). So:
##   "albedo"    = grey albedo_color (sRGB) scaling each diffuse's mean to the fern's;
##   "backlight" = grey backlight colour (sRGB) scaling translucency map mean to the fern's glow.
## "backlight_tex": false -> flat FERN_BACKLIGHT, no map (fern; bush_02_green, whose map is
## orange-red and would glow the wrong colour).
const MATERIALS := [
	{"name": "bush_01", "dir": "bush_01", "diffuse": "diffuse", "albedo": 0.82, "backlight_tex": true, "backlight": 0.42},
	{"name": "bush_02", "dir": "bush_02", "diffuse": "diffuse", "albedo": 0.97, "backlight_tex": true, "backlight": 1.0},
	{"name": "bush_02_green", "dir": "bush_02", "diffuse": "diffuse_green", "albedo": 0.70, "backlight_tex": false},
	{"name": "bush_04", "dir": "bush_04", "diffuse": "diffuse", "albedo": 0.76, "backlight_tex": true, "backlight": 0.57},
	{"name": "bush_05", "dir": "bush_05", "diffuse": "diffuse", "albedo": 0.65, "backlight_tex": true, "backlight": 0.79},
	{"name": "fern_02", "dir": "fern_02", "diffuse": "diffuse", "albedo": 1.0, "backlight_tex": false, "cull_back": true},
	# Lady fern: diffuse measured 0.145 (4.6x fern_02, import_megascans_plant.py) -> 0.50. Single-layer
	# cards -> double-sided. Flat backlight (its translucency is one channel of a packed ORT map).
	{"name": "lady_fern", "dir": "lady_fern", "diffuse": "diffuse", "albedo": 0.50, "backlight_tex": false},
	# Elderberry: diffuse measured 0.069 (2.2x fern_02) -> 0.71. Double-sided cards, flat backlight.
	{"name": "elderberry", "dir": "elderberry", "diffuse": "diffuse", "albedo": 0.71, "backlight_tex": false},
	# Flowers: grey from the import scripts' luminance print (whole plant incl. petals vs fern_02 0.031):
	# wood sorrel 0.269, poppy 0.194, clover 0.157, dandelion 0.124. Clover's normal map is flat (the
	# source scene has none).
	# "saturation" (default 1.0): shader colour strength, also used by the plant's impostor. The
	# flowers got lost among the other foliage at 1.0 (user, 2026-10-04) -> FLOWER_SATURATION.
	{"name": "wood_sorrel", "dir": "wood_sorrel", "diffuse": "diffuse", "albedo": 0.38, "backlight_tex": false, "saturation": FLOWER_SATURATION},
	{"name": "poppy", "dir": "poppy", "diffuse": "diffuse", "albedo": 0.44, "backlight_tex": false, "saturation": FLOWER_SATURATION},
	{"name": "clover", "dir": "clover", "diffuse": "diffuse", "albedo": 0.49, "backlight_tex": false, "saturation": FLOWER_SATURATION},
	{"name": "dandelion", "dir": "dandelion", "diffuse": "diffuse", "albedo": 0.54, "backlight_tex": false, "saturation": FLOWER_SATURATION},
]

func setup_materials(only: Array = []) -> String:
	var out: Array[String] = []
	# The shader body lives in an include: reload it first, or the shaders recompile against the
	# editor's stale copy and a new uniform is dropped from the saved material (seen 2026-10-04).
	ResourceLoader.load("res://shaders/foliage/foliage_cutout.gdshaderinc", "", ResourceLoader.CACHE_MODE_REPLACE)
	for m: Dictionary in MATERIALS:
		if not _wanted(only, m.dir):
			continue
		# ShaderMaterial on the foliage cutout shader (shaders/foliage/, docs/shadows.md): mip-scaled
		# alpha + separate shadow-pass cutoff so leaf shadows neither vanish up close nor fade out
		# ~20 m ahead. Replaced StandardMaterial3D 2026-09-25.
		var mat := ShaderMaterial.new()
		mat.resource_name = "%s_material" % m.name
		# CACHE_MODE_REPLACE: the editor's stale copy of an edited shader silently drops parameters
		# for uniforms added since it was loaded.
		mat.shader = ResourceLoader.load(FOLIAGE_SHADER_BACK if m.get("cull_back", false) else FOLIAGE_SHADER_DOUBLE, "", ResourceLoader.CACHE_MODE_REPLACE)
		var textures := {
			"albedo_tex": load(_tex_path(m.dir, m.diffuse)),
			"normal_tex": load(_tex_path(m.dir, "normal")),
		}
		if m.backlight_tex:
			textures["backlight_tex"] = load(_tex_path(m.dir, "translucency"))
		for param: String in textures:
			if textures[param] == null:
				push_error("setup_understory_assets: %s failed to load for %s" % [param, m.name])
				out.append("%s: MISSING %s" % [m.name, param])
			mat.set_shader_parameter(param, textures[param])
		mat.set_shader_parameter("albedo_color", Color(m.albedo, m.albedo, m.albedo))
		mat.set_shader_parameter("saturation", m.get("saturation", 1.0))
		mat.set_shader_parameter("roughness", ROUGHNESS)
		mat.set_shader_parameter("backlight_color", Color(m.backlight, m.backlight, m.backlight) if m.backlight_tex else FERN_BACKLIGHT)
		mat.set_shader_parameter("alpha_cutoff", ALPHA_SCISSOR)
		mat.set_shader_parameter("mip_alpha_scale", MIP_ALPHA_SCALE)
		mat.set_shader_parameter("shadow_alpha_cutoff", SHADOW_ALPHA_CUTOFF)
		mat.set_shader_parameter("shadow_mip_alpha_scale", SHADOW_MIP_ALPHA_SCALE)
		var mat_path: String = BASE + "%s/%s_material.tres" % [m.dir, m.name]
		var err := ResourceSaver.save(mat, mat_path)
		out.append("saved %s (err=%d)" % [mat_path, err])
	return "\n".join(out)

## Diagnostic (2026-09-25, "ferns render near-black, no ground shadows"): per plant, with the
## import rotation applied -- share of vertex normals pointing up vs down, shadow_mesh presence,
## vertex format (UV/tangent/color), and the normal map's mean green (OpenGL vs DirectX hint).
func debug_print_shading() -> String:
	var out: Array[String] = []
	for p: Dictionary in PLANTS:
		var scene: PackedScene = ResourceLoader.load(_model_path(p.dir), "", ResourceLoader.CACHE_MODE_IGNORE)
		var root: Node3D = scene.instantiate()
		var mi: MeshInstance3D = root.find_children("*", "MeshInstance3D", true, false)[0]
		var b := Basis.IDENTITY
		var n: Node = mi
		while n != null:
			if n is Node3D:
				b = (n as Node3D).basis * b
			n = n.get_parent()
		var arr := mi.mesh.surface_get_arrays(0)
		var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var up := 0
		var down := 0
		var sum := Vector3.ZERO
		for v: Vector3 in nr:
			var w := (b * v).normalized()
			sum += w
			if w.y > 0.3:
				up += 1
			elif w.y < -0.3:
				down += 1
		var am := mi.mesh as ArrayMesh
		var fmt: int = am.surface_get_format(0) if am else 0
		var img: Image = (load(_tex_path(p.dir, "normal")) as Texture2D).get_image()
		if img.is_compressed():
			img.decompress()
		var g := 0.0
		var r := 0.0
		var cnt := 0
		for y in range(0, img.get_height(), 8):
			for x in range(0, img.get_width(), 8):
				var c := img.get_pixel(x, y)
				g += c.g; r += c.r; cnt += 1
		out.append("%s: normals n=%d up=%d down=%d mean=%s | shadow_mesh=%s | uv=%s tangent=%s color=%s | normalmap meanR=%.3f meanG=%.3f" % [
			p.dir, nr.size(), up, down, (sum / maxf(1, nr.size())).snapped(Vector3.ONE * 0.01),
			am.shadow_mesh != null if am else "n/a",
			bool(fmt & Mesh.ARRAY_FORMAT_TEX_UV), bool(fmt & Mesh.ARRAY_FORMAT_TANGENT), bool(fmt & Mesh.ARRAY_FORMAT_COLOR),
			r / cnt, g / cnt])
		root.free()
	return "\n".join(out)

## Leaf diffuse import: VRAM-compressed WITH mipmaps ("vram"). History (2026-09-25): plain
## StandardMaterial alpha scissor + mips -> the shadow pass sampled tiny mips, sparse leaf alpha
## averaged below the cutoff, no shadows; mips were then turned off (-> distant shimmer, and far
## shadows still faded). Now the foliage shader (shaders/foliage/, docs/shadows.md) boosts alpha
## by the sampled mip level, so mips are back ON. Do NOT strip mips again to "fix" shadows.
func leaf_diffuse_import(only: Array = []) -> String:
	var out: Array[String] = []
	for p: Dictionary in PLANTS:
		if _wanted(only, p.dir):
			out.append(set_texture_import_mode(_tex_path(p.dir, "diffuse"), "vram"))
	if _wanted(only, "bush_02"):
		out.append(set_texture_import_mode(BASE + "bush_02/textures/bush_02_diffuse_green.tga", "vram"))
	return "\n".join(out)

## PNG normal maps of the glb plants (Megascans / herb mix): a new PNG imports as a plain colour
## texture, so flag it as a normal map (compress/normal_map=1, roughness/mode=1), then VRAM + mipmaps.
## Pass `only` -- an empty list redoes every glb plant's normal map.
func normal_map_import(only: Array = []) -> String:
	var out: Array[String] = []
	for p: Dictionary in PLANTS:
		if p.get("tex_ext", "tga") != "png" or not _wanted(only, p.dir):
			continue
		var path := _tex_path(p.dir, "normal")
		var cfg := ConfigFile.new()
		var err := cfg.load(path + ".import")
		if err != OK:
			out.append("could not read %s.import (err=%d)" % [path, err])
			continue
		cfg.set_value("params", "compress/normal_map", 1)
		cfg.set_value("params", "roughness/mode", 1)
		cfg.save(path + ".import")
		out.append(set_texture_import_mode(path, "vram"))
	return "\n".join(out)

## Shadow A/B test (2026-09-25): force a texture's import mode and reimport.
## mode "raw" = lossless, no mipmaps; "vram" = VRAM-compressed + mipmaps (what the originals
## got from Godot's detect-3D); "vram_nomip" = VRAM-compressed, no mipmaps (leaf diffuse). detect_3d/compress_to=0 so the editor doesn't flip it later.
func set_texture_import_mode(path: String, mode: String) -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load(path + ".import")
	if err != OK:
		return "could not read %s.import (err=%d)" % [path, err]
	cfg.set_value("params", "compress/mode", 0 if mode == "raw" else 2)
	cfg.set_value("params", "mipmaps/generate", mode == "vram")
	# mipmaps/limit is UNIMPLEMENTED in Godot 4 (written but ignored -- verified 2026-09-25 with
	# debug_print_alpha_mips: full chain still imported). Always reset it to the default.
	cfg.set_value("params", "mipmaps/limit", -1)
	cfg.set_value("params", "detect_3d/compress_to", 0)
	err = cfg.save(path + ".import")
	EditorInterface.get_resource_filesystem().reimport_files(PackedStringArray([path]))
	return "%s -> %s (save err=%d), reimported" % [path.get_file(), mode, err]

## Diagnostic (2026-09-25, "only the green bush_02 casts a shadow"): alpha coverage of each
## diffuse AS IMPORTED (VRAM-compressed + mipmaps, i.e. what the shadow pass samples), per mip:
## share of texels with alpha >= the scissor threshold, relative to mip 0. Also the import format.
func debug_print_alpha_mips() -> String:
	var out: Array[String] = []
	var paths: Array[String] = []
	for p: Dictionary in PLANTS:
		paths.append(_tex_path(p.dir, "diffuse"))
	paths.append(BASE + "bush_02/textures/bush_02_diffuse_green.tga")
	for path in paths:
		var tex: Texture2D = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		var img := tex.get_image()
		var fmt_before := img.get_format()
		if img.is_compressed():
			img.decompress()
		var line := "%s: fmt=%d mipmaps=%s |" % [path.get_file(), fmt_before, img.has_mipmaps()]
		var base_cov := -1.0
		var w := img.get_width()
		var level := 0
		while w >= 4 and level <= img.get_mipmap_count():
			var m := Image.create_from_data(img.get_width(), img.get_height(), img.has_mipmaps(), img.get_format(), img.get_data())
			var lvl_img: Image
			if level == 0:
				lvl_img = m
				if m.has_mipmaps():
					lvl_img = Image.create_from_data(img.get_width(), img.get_height(), false, img.get_format(), img.get_data().slice(0, img.get_mipmap_offset(1)))
			else:
				var start := img.get_mipmap_offset(level)
				var end := img.get_mipmap_offset(level + 1) if level < img.get_mipmap_count() else img.get_data().size()
				lvl_img = Image.create_from_data(w, w, false, img.get_format(), img.get_data().slice(start, end))
			var solid := 0
			var total := 0
			var step := maxi(1, w / 128)
			for y in range(0, w, step):
				for x in range(0, w, step):
					total += 1
					if lvl_img.get_pixel(x, y).a >= ALPHA_SCISSOR:
						solid += 1
			var cov := float(solid) / total
			if base_cov < 0.0:
				base_cov = maxf(cov, 0.0001)
			line += " %d:%d%%" % [w, roundi(100.0 * cov / base_cov)]
			if not img.has_mipmaps():
				break
			w /= 2
			level += 1
		out.append(line)
	return "\n".join(out)

## Diagnostic: every MeshInstance3D in each imported plant -- node name, world-space
## size (node transforms applied, i.e. what the importer's unit conversion produced),
## triangle count and surface count. Loads from disk, ignoring the cache.
func debug_print_sizes() -> String:
	var out: Array[String] = []
	for p: Dictionary in PLANTS:
		var path: String = _model_path(p.dir)
		var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if scene == null:
			out.append("%s: could not load %s" % [p.dir, path])
			continue
		var root: Node3D = scene.instantiate()
		out.append("== %s (root=%s scale=%s)" % [p.dir, root.get_class(), root.scale])
		for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
			var xf: Transform3D = Transform3D.IDENTITY
			var n: Node = mi
			while n != null and n != root:
				if n is Node3D:
					xf = (n as Node3D).transform * xf
				n = n.get_parent()
			xf = root.transform * xf
			var aabb: AABB = xf * mi.mesh.get_aabb()
			var tris := 0
			var mats: Array[String] = []
			for s in mi.mesh.get_surface_count():
				var arr := mi.mesh.surface_get_arrays(s)
				var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				tris += (idx.size() if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
				var m := mi.mesh.surface_get_material(s)
				mats.append(m.resource_name if m else "null")
			out.append("  %s: size=%s min=%s tris=%d surfaces=%d mats=%s" % [
				mi.name, aabb.size.snapped(Vector3.ONE * 0.01), aabb.position.snapped(Vector3.ONE * 0.01),
				tris, mi.mesh.get_surface_count(), mats])
			out.append("      raw mesh aabb size=%s | node-chain rotation(deg)=%s scale=%s" % [
				mi.mesh.get_aabb().size.snapped(Vector3.ONE * 0.01),
				(xf.basis.get_euler() * 180.0 / PI).snapped(Vector3.ONE * 0.1),
				xf.basis.get_scale().snapped(Vector3.ONE * 0.001)])
		root.free()
	return "\n".join(out)
