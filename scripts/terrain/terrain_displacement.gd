class_name TerrainDisplacement
extends RefCounted

## Where the DRAWN ground is. Terrain3D's displacement moves the terrain's vertices by the
## textures' height, on the graphics card only: collision, and everything this project places
## on the ground, use the heightmap underneath, so on a texture with a large relief (the
## walkable rock face: about half a metre each way) the player's feet and small rocks are
## swallowed. This is a copy in script of what Terrain3D's displacement buffer shader works out
## for one point, to build collision and to place things on the surface that is seen.
##
## STAGE 1 (2026-10-12): the function and a debug view (PerfDebug F1) to compare it with the
## drawn ground. Kirill's screenshot of the markers on the rock face showed them on its surface.
## Used by the scree stones (RockScatter.scatter_scree, MountainWalls.scatter_foot_debris).
##
## The shader's source is not in the addon's files: it was read out of the library
## (libterrain.windows.release.x86_64.dll holds it as text; commit 854a457). What it does, per
## point: takes the four heightmap vertices round it, each with its control value (two texture
## ids and a blend) and its own lookup of each texture's height (the albedo's alpha), mixes
## them by the bilinear weights sharpened by the heights, and moves the point along the
## terrain's interpolated normal by (height - 0.5) x 2 x the terrain's displacement scale,
## where a texture's height is first scaled by 0.04 x its displacement scale / (the control
## scale x its uv scale) about 0.5 and shifted by its displacement offset.
##
## Where this copy is NOT the shader:
## - Detiling. The shader gives each tile-sized cell a random turn and shift from
##   fract(sin(...) * 43758.5453) in 32-bit floats; that cannot be repeated exactly here. So
##   WorldGenerator's shader patch replaces that function by one made of whole-number steps
##   (CELL_RANDOM_SHADER, the same steps as _cell_random here) and sets `exact_detiling`.
##   Without the patch a texture with detiling comes out wrong. A cell's number can still
##   differ where a vertex lies exactly on the border between two cells (32-bit rounding).
## - The second texture of a vertex is weighted with the first's normal map in the shader;
##   here that factor is 1. It matters only in the blend between two textures.
## - The per-pixel projection patch (steep ground textured from the side) is left out: this
##   is for ground that can be walked on, where it is the plain projection from above.

const DEBUG_MARKERS_NAME := "TerrainDisplacementMarkers"
const DEBUG_HALF := 3.0 ## the debug view covers this far each way from the player (m)
const DEBUG_STEP := 0.2 ## and has a marker every this far

static var _terrain: Terrain3D
static var _data: Terrain3DData
static var _spacing: float = 1.0
static var _global_scale: float = 0.0
static var _sharpness: float = 4.0
## Per texture id: [uv scale, detiling turn, detiling shift, displacement offset, displacement
## scale, the height image's bytes (one per pixel), its width, its height].
static var _textures: Array = []
## True once the terrain's shaders use CELL_RANDOM_SHADER (WorldGenerator._apply_projection_override).
static var exact_detiling: bool = false

## The shaders' random(): what Terrain3D generates, and what the patch puts in its place.
const CELL_RANDOM_ORIGINAL := "return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);"
const CELL_RANDOM_SHADER := """ivec2 cr_cell = ivec2(floor(xy + 0.5));
	uint cr_n = (uint(cr_cell.x) * 73856093u) ^ (uint(cr_cell.y) * 19349663u);
	cr_n = (cr_n ^ (cr_n >> 15u)) * 739157483u;
	cr_n = cr_n ^ (cr_n >> 13u);
	return float(cr_n >> 8u) * (1.0 / 16777216.0);"""

## CELL_RANDOM_SHADER in script: 0-1 for a cell of whole-number coordinates.
static func _cell_random(cell: Vector2) -> float:
	var n := (((int(roundf(cell.x)) & 0xFFFFFFFF) * 73856093) & 0xFFFFFFFF) ^ (((int(roundf(cell.y)) & 0xFFFFFFFF) * 19349663) & 0xFFFFFFFF)
	n = ((n ^ (n >> 15)) * 739157483) & 0xFFFFFFFF
	n = n ^ (n >> 13)
	return float(n >> 8) / 16777216.0

## How far above (below: negative) a point found on the collision the ground is drawn there:
## for the player's feet, every frame. 0 where the point is not on the terrain itself (a rock,
## a cliff mesh, a floor: further than `tolerance` from the heightmap), before setup() and
## without displacement. The sideways part of the displacement is left out: one lookup.
static func lift_at(point: Vector3, tolerance: float = 0.15) -> float:
	if _data == null or _global_scale <= 0.0:
		return 0.0
	var found := displacement_at(point.x, point.z)
	if is_nan(found[0]) or absf(float(found[0]) - point.y) > tolerance:
		return 0.0
	return (found[1] as Vector3).y

static func is_ready() -> bool:
	return _data != null

## A point of the plain ground, moved to where it is drawn (unchanged before setup(), outside
## the terrain and without displacement).
static func drawn(point: Vector3) -> Vector3:
	if _data == null or _global_scale <= 0.0:
		return point
	var found := displacement_at(point.x, point.z)
	return point if is_nan(found[0]) else point + (found[1] as Vector3)

static func reset_run_state() -> void:
	_terrain = null
	_data = null
	_textures = []
	exact_detiling = false

## Reads the terrain's and the textures' settings as they are now. Call it after the
## displacement and detiling settings have been applied; the debug view calls it each time.
static func setup(terrain: Terrain3D) -> bool:
	if terrain == null or terrain.get_data() == null or terrain.get_assets() == null:
		return false
	_terrain = terrain
	_data = terrain.get_data()
	_spacing = terrain.get_vertex_spacing()
	_global_scale = terrain.displacement_scale if terrain.tessellation_level > 0 else 0.0
	var blend_sharpness: Variant = terrain.material.get_shader_param(&"blend_sharpness")
	_sharpness = 60.0 * (float(blend_sharpness) if blend_sharpness != null else 0.5) * terrain.displacement_sharpness + 4.0
	var assets: Terrain3DAssets = terrain.get_assets()
	_textures = []
	for id in assets.get_texture_count():
		var asset: Terrain3DTextureAsset = assets.get_texture_asset(id)
		if asset == null or asset.albedo_texture == null:
			_textures.append(null)
			continue
		var image: Image = asset.albedo_texture.get_image()
		if image == null:
			_textures.append(null)
			continue
		if image.is_compressed():
			image.decompress()
		image.clear_mipmaps()
		image.convert(Image.FORMAT_RGBA8)
		var rgba := image.get_data()
		var heights := PackedByteArray()
		heights.resize(image.get_width() * image.get_height())
		for i in heights.size():
			heights[i] = rgba[i * 4 + 3]
		_textures.append([asset.uv_scale, asset.detiling_rotation, asset.detiling_shift, asset.displacement_offset, asset.displacement_scale, heights, image.get_width(), image.get_height()])
	return true

## One texture's height (0-1) at a place in its own tiles, as the card reads it: between the
## four nearest pixels, the picture repeating.
static func _texture_height(texture: Array, uv: Vector2) -> float:
	var width: int = texture[6]
	var height: int = texture[7]
	var heights: PackedByteArray = texture[5]
	var px := uv.x * width - 0.5
	var py := uv.y * height - 0.5
	var x0 := floori(px)
	var y0 := floori(py)
	var fx := px - x0
	var fy := py - y0
	var xa := posmod(x0, width)
	var xb := posmod(x0 + 1, width)
	var ya := posmod(y0, height) * width
	var yb := posmod(y0 + 1, height) * width
	return (lerpf(lerpf(heights[ya + xa], heights[ya + xb], fx), lerpf(heights[yb + xa], heights[yb + xb], fx), fy)) / 255.0

## The shader's rotate_vec2().
static func _turned(v: Vector2, cs: Vector2) -> Vector2:
	return Vector2(cs.x * v.x + cs.y * v.y, cs.x * v.y - cs.y * v.x)

## What the displacement adds to the point of the undisplaced ground at (x, z): [the ground's
## own height there, the vector added]. The drawn surface has a point at
## (x, height, z) + vector -- not straight above (x, z) where the ground slopes.
static func displacement_at(x: float, z: float) -> Array:
	var ux := x / _spacing
	var uz := z / _spacing
	var ix := floorf(ux)
	var iz := floorf(uz)
	var wx := ux - ix
	var wz := uz - iz
	# The four vertices in the shader's order: (0,1), (1,1), (1,0), (0,0).
	var corners: Array[Vector2] = [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var weights: Array[float] = [(1.0 - wx) * wz, wx * wz, wx * (1.0 - wz), (1.0 - wx) * (1.0 - wz)]
	var h := func(dx: float, dz: float) -> float:
		return _data.get_height(Vector3((ix + dx) * _spacing, 0.0, (iz + dz) * _spacing))
	var h0: float = h.call(0, 1)
	var h1: float = h.call(1, 1)
	var h2: float = h.call(1, 0)
	var h3: float = h.call(0, 0)
	if is_nan(h0) or is_nan(h1) or is_nan(h2) or is_nan(h3):
		return [NAN, Vector3.ZERO]
	var h4: float = h.call(1, 2)
	var h5: float = h.call(2, 1)
	var h6: float = h.call(2, 0)
	var h7: float = h.call(0, 2)
	if is_nan(h4): h4 = h1
	if is_nan(h5): h5 = h1
	if is_nan(h6): h6 = h2
	if is_nan(h7): h7 = h0
	var normal := Vector3(h0 - h1, _spacing, h0 - h7).normalized() * weights[0] \
		+ Vector3(h1 - h5, _spacing, h1 - h4).normalized() * weights[1] \
		+ Vector3(h2 - h6, _spacing, h2 - h1).normalized() * weights[2] \
		+ Vector3(h3 - h2, _spacing, h3 - h0).normalized() * weights[3]
	var ground := h0 * weights[0] + h1 * weights[1] + h2 * weights[2] + h3 * weights[3]
	if _global_scale <= 0.0:
		return [ground, Vector3.ZERO]

	# Each vertex's control value: two texture ids, their blend, a turn and a scale.
	var base: Array[int] = [0, 0, 0, 0]
	var over: Array[int] = [0, 0, 0, 0]
	var blend: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var control: Array[int] = [0, 0, 0, 0]
	for k in 4:
		var c: int = _data.get_control(Vector3((ix + corners[k].x) * _spacing, 0.0, (iz + corners[k].y) * _spacing))
		control[k] = c
		base[k] = (c >> 27) & 0x1F
		over[k] = (c >> 22) & 0x1F
		blend[k] = float((c >> 14) & 0xFF) / 255.0
	var total_height := 0.0
	var total_weight := 0.0
	for k in 4:
		# How much of this vertex's two textures there is at the point, over all four vertices.
		var base_weight := 0.0
		var over_weight := 0.0
		for i in 4:
			var w0 := (1.0 - blend[i]) * weights[i]
			var w1 := blend[i] * weights[i]
			base_weight += w0 * float(base[k] == base[i]) + w1 * float(base[k] == over[i])
			over_weight += w0 * float(over[k] == base[i]) + w1 * float(over[k] == over[i])
		var c := control[k]
		var control_scale := 0.9 - float((((c >> 7) & 0x7) + 3) % 8 + 1) * 0.1
		var angle := float((c >> 10) & 0xF) * (-TAU / 16.0)
		var cs := Vector2(cos(angle), sin(angle))
		var uv := _turned(Vector2(x, z) * control_scale, cs)
		var vertex := _turned(Vector2((ix + corners[k].x) * _spacing, (iz + corners[k].y) * _spacing) * control_scale, cs)
		for which in 2:
			if which == 0 and blend[k] >= 1.0:
				continue
			if which == 1 and (blend[k] <= 0.0 or over[k] == base[k]):
				continue
			var id := base[k] if which == 0 else over[k]
			if id >= _textures.size() or _textures[id] == null:
				continue
			var texture: Array = _textures[id]
			var id_scale: float = texture[0]
			var centre := (vertex * id_scale + Vector2(0.5, 0.5)).floor()
			var turn := 0.0
			var shift := 0.0
			if texture[1] != 0.0 or texture[2] != 0.0:
				# Without the patch this is NOT the card's number: see the header.
				var random := (_cell_random(centre) if exact_detiling else fposmod(sin(centre.dot(Vector2(12.9898, 78.233))) * 43758.5453, 1.0)) * 2.0 - 1.0
				turn = random * float(texture[1]) * TAU
				shift = random * float(texture[2]) * TAU
			var id_uv := _turned(uv * id_scale - centre, Vector2(cos(turn), sin(turn))) + centre + Vector2(shift - 0.5, shift - 0.5)
			var height := _texture_height(texture, id_uv)
			var id_weight := pow(weights[k] + (base_weight if which == 0 else over_weight) + height, _sharpness) * weights[k]
			var height_scale := float(texture[4]) * 0.04 / (control_scale * id_scale)
			height = clampf(height * height_scale + 0.5 + float(texture[3]) * height_scale - 0.5 * height_scale, 0.0, 1.0)
			total_height += height * id_weight
			total_weight += id_weight
	var relief := total_height / maxf(total_weight, 1e-8)
	return [ground, normal * (relief - 0.5) * 2.0 * _global_scale]

## The height of the drawn ground straight above or below (x, z). On a slope the displacement
## also moves points sideways, so the point of the plain ground that lands there is searched
## for (three rounds). NAN outside the terrain.
static func surface_height(x: float, z: float) -> float:
	var from := Vector2(x, z)
	var found: Array = [NAN, Vector3.ZERO]
	for _i in 3:
		found = displacement_at(from.x, from.y)
		if is_nan(found[0]):
			return NAN
		var moved: Vector3 = found[1]
		from = Vector2(x - moved.x, z - moved.z)
	found = displacement_at(from.x, from.y)
	return NAN if is_nan(found[0]) else float(found[0]) + (found[1] as Vector3).y

## DEBUG (PerfDebug F1): markers on the computed surface round `around`, to compare with the
## drawn ground; again = remove them. Green = on the plain ground or above it, red = below.
static func toggle_debug_markers(scene: Node, terrain: Terrain3D, around: Vector3) -> String:
	var old := scene.get_node_or_null(DEBUG_MARKERS_NAME)
	if old:
		old.queue_free()
		return "[TerrainDisplacement] markers removed"
	if not setup(terrain):
		return "[TerrainDisplacement] no Terrain3D"
	var started := Time.get_ticks_usec()
	var points: Array[Transform3D] = []
	var colours: Array[Color] = []
	var lowest := 0.0
	var highest := 0.0
	var steps := int(DEBUG_HALF / DEBUG_STEP)
	for gz in range(-steps, steps + 1):
		for gx in range(-steps, steps + 1):
			var x := around.x + gx * DEBUG_STEP
			var z := around.z + gz * DEBUG_STEP
			var found := displacement_at(x, z)
			if is_nan(found[0]):
				continue
			var moved: Vector3 = found[1]
			lowest = minf(lowest, moved.y)
			highest = maxf(highest, moved.y)
			points.append(Transform3D(Basis(), Vector3(x, float(found[0]), z) + moved))
			colours.append(Color(0.2, 1.0, 0.3) if moved.y >= 0.0 else Color(1.0, 0.25, 0.2))
	var mesh := SphereMesh.new()
	mesh.radius = 0.025
	mesh.height = 0.05
	mesh.radial_segments = 6
	mesh.rings = 3
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	mesh.material = material
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = points.size()
	for i in points.size():
		multimesh.set_instance_transform(i, points[i])
		multimesh.set_instance_color(i, colours[i])
	var node := MultiMeshInstance3D.new()
	node.name = DEBUG_MARKERS_NAME
	node.multimesh = multimesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(node)
	var here := displacement_at(around.x, around.z)
	var control: int = _data.get_control(Vector3(roundf(around.x), 0.0, roundf(around.z)))
	var names := PackedStringArray()
	for id in [(control >> 27) & 0x1F, (control >> 22) & 0x1F]:
		var asset: Terrain3DTextureAsset = terrain.get_assets().get_texture_asset(id)
		names.append("%d %s (uv %.2f, displacement %.2f, offset %.2f, detiling %.2f / %.2f)" % [id, asset.name if asset else "?", asset.uv_scale if asset else 0.0, asset.displacement_scale if asset else 0.0, asset.displacement_offset if asset else 0.0, asset.detiling_rotation if asset else 0.0, asset.detiling_shift if asset else 0.0])
	return "[TerrainDisplacement] %d markers on the computed surface, %.1f m each way (%d ms); it lies %.2f m below to %.2f m above the plain ground here; under the player: %.2f m, textures %s, blend %.2f; green = on or above the plain ground, red = below. F1 again removes them." % [
		points.size(), DEBUG_HALF, (Time.get_ticks_usec() - started) / 1000, -lowest, highest, (here[1] as Vector3).y, " + ".join(names), float((control >> 14) & 0xFF) / 255.0]
