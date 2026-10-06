## Wind sway for the understory and the flowers (2026-10-06), in step with the grass.
##
## The grass blades lean with a scrolling noise texture read at each blade's root
## (shaders/wind.gdshaderinc). The foliage cutout shader (shaders/foliage/foliage_cutout.gdshaderinc)
## reads the same texture at each plant's root and leans the plant the same way, so a gust crossing
## the grass moves the plants standing in it at the same moment. This module owns that texture and
## switches the sway on, per run, for the materials of the plants listed in SWAY. Nothing is saved:
## the material files keep sway_amount 0, so the setup tools and the impostor bakes see still plants.
##
## Trees and saplings: their leaf / branch cards sway, each about the point where it meets the bark
## (per-card data baked into the meshes by build_pack_trees() in tools/setup_tree_assets.gd); the
## trunk and bark branches stand still. Not swayed: impostors (flat far cards on another shader),
## deadfall.
##
## GrassField calls update() every frame (camera position and its live-tunable wind fade), so
## without a grass field the plants hold still.
## Compare / switch off: the user argument --no-foliage-wind starts the game without the sway.
class_name FoliageWind
extends RefCounted

## Per plant kind: `amount` = m a point `height` m above the root moves in a full gust (the wind is
## mostly calm: about 6 % of that between gusts), `core` = the share of it the plant's centre axis
## gets (see sway_core in the shader). Heights are for a plant at scale 1; a scaled-up plant moves
## more, up to 1.5x. First values, not yet judged in game.
const SWAY: Array[Dictionary] = [
	{"name": "ferns", "ids": [28, 55, 56, 57, 58, 59, 60, 61, 62, 63], "amount": 0.14, "height": 0.6, "core": 0.5},
	{"name": "broad fern", "ids": [29], "amount": 0.12, "height": 1.2, "core": 0.4},
	{"name": "bushes", "ids": [30, 31, 32], "amount": 0.1, "height": 1.0, "core": 0.35},
	{"name": "elderberry", "ids": [69, 70], "amount": 0.12, "height": 1.3, "core": 0.3},
	{"name": "wood sorrel", "ids": [71, 72, 73, 74, 75, 76, 77, 78], "amount": 0.03, "height": 0.15, "core": 1.0},
	{"name": "poppies", "ids": [79, 80, 81, 82, 83], "amount": 0.20, "height": 0.6, "core": 1.0},
	{"name": "dandelion", "ids": [84], "amount": 0.04, "height": 0.2, "core": 1.0},
	{"name": "clover", "ids": [85, 86, 87, 88], "amount": 0.024, "height": 0.14, "core": 1.0},
	# Trees ("cards": each leaf / branch card sways about the point where it meets the bark; trunk
	# and bark branches stand still). `height` = the card length in m that moves `amount` (longer
	# ones up to 1.5x); the cards are 0.8-3.6 m long (median per tree), the longest 8.5 m.
	# `speed` = the wobble, rad/s: slower than the small plants. `fade` = their own fade distances:
	# trees are seen much further than the grass sways, and must be still before the impostors take
	# over (cross-fade from 155 m).
	# The saplings (ids 64-68) share the leafy trees' meshes and materials, so they are covered.
	{"name": "leafy trees", "ids": [15, 18, 20, 21, 23, 25, 27], "cards": true, "amount": 0.40, "height": 2.0, "speed": 2.5, "fade": [110.0, 150.0]},
	# The dry ones (bare twig cards): stiffer.
	{"name": "dry trees", "ids": [14, 16, 17, 19, 22, 24, 26], "cards": true, "amount": 0.20, "height": 2.0, "speed": 2.5, "fade": [110.0, 150.0]},
]

static var _noise: ImageTexture
static var _materials: Array[ShaderMaterial] = []
static var _own_fade: Dictionary = {} # material -> Vector2(start, end), for the kinds with a "fade"

## Per-run static state reset -- called first thing in WorldGenerator._ready().
static func reset_run_state() -> void:
	_materials = []
	_own_fade = {}

## The wind noise both the grass and the foliage read. GodotGrass's mat_grass.tres noise, rebuilt in
## code: perlin 512 seamless, freq 0.0275, fractal gain 0.1, domain warp amp 20 freq 0.005.
static func noise_texture() -> ImageTexture:
	if _noise == null:
		var wind := FastNoiseLite.new()
		wind.noise_type = FastNoiseLite.TYPE_PERLIN
		wind.frequency = 0.0275
		wind.fractal_gain = 0.1
		wind.domain_warp_enabled = true
		wind.domain_warp_amplitude = 20.0
		wind.domain_warp_frequency = 0.005
		_noise = ImageTexture.create_from_image(wind.get_seamless_image(512, 512))
	return _noise

## Switches the sway on for every foliage-cutout material of the SWAY plants (all their LOD meshes;
## the impostor LODs are on another shader and are skipped).
static func setup(assets: Terrain3DAssets) -> void:
	_materials = []
	_own_fade = {}
	if assets == null or "--no-foliage-wind" in OS.get_cmdline_user_args():
		return
	for kind: Dictionary in SWAY:
		for id: int in kind.ids:
			var asset := assets.get_mesh_asset(id)
			if asset == null:
				continue
			for lod in asset.get_lod_count():
				var mesh := asset.get_mesh(lod) as Mesh
				for si in (mesh.get_surface_count() if mesh else 0):
					var mat := mesh.surface_get_material(si) as ShaderMaterial
					if mat == null or mat.shader == null or _materials.has(mat):
						continue
					if not mat.shader.resource_path.get_file().begins_with("foliage_cutout"):
						continue
					mat.set_shader_parameter("wind_noise", noise_texture())
					mat.set_shader_parameter("sway_amount", float(kind.amount))
					mat.set_shader_parameter("sway_height", float(kind.height))
					mat.set_shader_parameter("sway_core", float(kind.get("core", 1.0)))
					mat.set_shader_parameter("sway_cards", bool(kind.get("cards", false)))
					if kind.has("speed"):
						mat.set_shader_parameter("sway_speed", float(kind.speed))
					if kind.has("fade"):
						_own_fade[mat] = Vector2(kind.fade[0], kind.fade[1])
					_materials.append(mat)
	print("FOLIAGE_WIND: sway on for %d materials" % _materials.size())

## Every frame (GrassField): where the view camera is, and the grass's wind fade distances.
static func update(camera_position: Vector3, fade_start: float, fade_end: float) -> void:
	for mat in _materials:
		mat.set_shader_parameter("sway_camera_position", camera_position)
		var fade: Vector2 = _own_fade.get(mat, Vector2(fade_start, fade_end))
		mat.set_shader_parameter("wind_fade_start", fade.x)
		mat.set_shader_parameter("wind_fade_end", fade.y)
