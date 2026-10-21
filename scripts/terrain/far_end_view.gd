## What the player sees of the valley beyond the section being played (PROTOTYPE 2026-10-21,
## the biome valley; only with TerrainCastle.FAR_END).
##
## The valley is to be five sections of about 1 km, of which only the one being played is built;
## the walk through fog between two sections is to be the loading screen (Kirill). So nothing
## past the section's end may be seen: a bank of dense fog fills the valley's end
## (shaders/fog_bank.gdshader), from BANK_START_PZ m inside the map's north edge to well past
## the end of the terrain, its top a U across the valley (BANK_FLOOR_TOP m above the floor, up to
## about BANK_TOP over the side ridges). It is dense from any distance
## (a first version thickened the scene's distance fog as the player came near the end; Kirill:
## "that weird thing where the fog appears as we get closer to the edge"). It hides the ground
## past the section and the side ridges; the castle and the mountain rows behind it
## (MountainWalls.END_ROWS, with their cloud sheets) are drawn after it and seen through it,
## their feet in mist of BANK_COLOR so they rise out of it (TerrainCastle.FAR_DRAW_ORDER).
##
## It also lets the camera see that far: the castle stands about 5 km out, the rows behind it
## up to about 8 km, and a camera's default far plane is 4 km.
class_name FarEndView
extends Node

const NODE_NAME := "FarEndView"
const BANK_SHADER_PATH := "res://shaders/fog_bank.gdshader"
## The bank's south face, in heightmap pz (positive = inside the map, south of its north edge),
## and the m over which the fog thickens north of it. TUNING.
const BANK_START_PZ := 150.0
const BANK_FRONT_FADE := 150.0
## How far it reaches north of the north apron's end, and past both sides of the import, m
## (past the sides: at least BANK_SIDE_RISE minus the ~200 m from a floor edge to the import's).
const BANK_OVERRUN := 900.0
## Its top: m above the valley floor where the fog has thinned to nothing, the m below that over
## which it thins, and how far that line wanders. TUNING. (160 / 90 / 35 at first: from the
## overlook anything more than about 4 deg up passed over the bank or through its thin top, and
## the castle and the horizon showed through -- Kirill. Now it fills the gap far above the ridges.)
const BANK_TOP := 700.0
## (150 / 80 while it was a flat fog; a cloud sea has a firmer top, with billows on it.)
const BANK_TOP_FADE := 60.0
const BANK_TOP_WANDER := 60.0
## The top is a U across the valley (Kirill, 2026-10-21: "make the fog u-shaped, along the valley
## shape"): BANK_TOP over the side ridges, only BANK_FLOOR_TOP m above the floor between its two
## edges (as the map's north row has them, which the north apron carries on), rising over
## BANK_SIDE_RISE m outward from each edge (an S: easing in and out). Dense up to
## BANK_FLOOR_TOP - BANK_TOP_FADE over the floor. TUNING. (200 at first: the sides stood as walls
## of cloud; Kirill asked for the slope of the mountains it hides. At 700 the steepest part is
## about 49 deg, and the apron's peaks, up to 220 m about 200 m out, stay about 50 m under its top there, 267 m.)
const BANK_FLOOR_TOP := 160.0
const BANK_SIDE_RISE := 700.0
## The curve along the valley (Kirill, 2026-10-21: the next sections are hidden anyway, so curve
## the fog instead, "so it looks like it floats along curved terrain"): the whole top rises by
## BANK_CURVE_RISE m from the bank's south face to the castle (TerrainCastle's far site), level
## near and steepening toward it (BANK_CURVE_POWER; 1 = a straight incline). The castle's foot is
## lifted by FAR_RISE, so with the two equal it stands BANK_FLOOR_TOP deep in the fog, as it did
## on a level valley. The bank now reaches BANK_BEYOND_CASTLE m past the castle. TUNING.
const BANK_CURVE_RISE := TerrainCastle.FAR_RISE
const BANK_CURVE_POWER := 2.0
const BANK_BEYOND_CASTLE := 600.0
## The castle, its lights and the far rows are drawn after the bank (seen through it), so below
## its top they would be painted over the fog (Kirill, 2026-10-21: their misty feet showed as a
## dark band between the section's end and the castle). They fade out from BANK_REVEAL_ABOVE m
## over the top to nothing BANK_REVEAL_BELOW m under it (soft, as the top wanders BANK_TOP_WANDER).
## The castle's lights are left out under the top. TUNING.
const BANK_REVEAL_BELOW := 100.0
const BANK_REVEAL_ABOVE := 40.0
## Fog per m of view ray inside it (0.03: 95 % hidden after 100 m). TUNING.
const BANK_DENSITY := 0.03
## A sea of low cloud since 2026-10-21 (Kirill: "it could be haze, low clouds, anything that
## completely blocks the view"), lit by the moon (the DirectionalLight3D, read at start): its
## colour deep in, just under its top where a billow faces the moon / is turned from it, and
## how far under the top the light reaches, m. Billows on the top: height (m, up and down) and
## size. TUNING.
const BANK_COLOR := MountainWalls.HAZE_COLOR
const BANK_TOP_COLOR := Color(0.42, 0.47, 0.58)
const BANK_SHADE_COLOR := MountainWalls.MIST_COLOR
const BANK_LIGHT_DEPTH := 60.0
const BANK_BILLOW_HEIGHT := 35.0
const BANK_BILLOW_SCALE := 180.0
const CAMERA_FAR := 10000.0

var _player: Node3D

## Adds a fresh one, with its fog bank, under `parent_node` (deferred, like the other generated
## nodes). No-op without TerrainCastle.FAR_END.
static func spawn(parent_node: Node, heightmap_corner: Vector3) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	if not TerrainCastle.FAR_END:
		return
	var view := FarEndView.new()
	view.name = NODE_NAME
	view.add_child(_build_bank(heightmap_corner))
	parent_node.add_child.call_deferred(view)

## Sets the bank's top (the uniforms of shaders/fog_bank_top.gdshaderinc) on `material`: the
## bank's own, and those of everything drawn after it and seen through it (the castle, the far
## mountain rows), which are not drawn below that top.
static func set_bank_shape(material: ShaderMaterial, heightmap_corner: Vector3) -> void:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	material.set_shader_parameter("bank_top_y", floor_y + BANK_TOP)
	material.set_shader_parameter("bank_floor_top_y", floor_y + BANK_FLOOR_TOP)
	material.set_shader_parameter("bank_floor_x_low", heightmap_corner.x + TerrainHeightmap.floor_lo(0.0))
	material.set_shader_parameter("bank_floor_x_high", heightmap_corner.x + TerrainHeightmap.floor_hi(0.0))
	material.set_shader_parameter("bank_side_rise", BANK_SIDE_RISE)
	material.set_shader_parameter("bank_curve_start_z", heightmap_corner.z + BANK_START_PZ)
	material.set_shader_parameter("bank_curve_end_z", _castle_z(heightmap_corner))
	material.set_shader_parameter("bank_curve_rise", maxf(BANK_CURVE_RISE, 0.0))
	material.set_shader_parameter("bank_curve_power", BANK_CURVE_POWER)
	material.set_shader_parameter("bank_reveal_below", BANK_REVEAL_BELOW)
	material.set_shader_parameter("bank_reveal_above", BANK_REVEAL_ABOVE)

## The bank's top at world (x, z), m: bank_top_at() of the include, without the wander.
static func bank_top_at(x: float, z: float, heightmap_corner: Vector3) -> float:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	var outside := maxf(maxf(heightmap_corner.x + TerrainHeightmap.floor_lo(0.0) - x, x - heightmap_corner.x - TerrainHeightmap.floor_hi(0.0)), 0.0)
	return lerpf(floor_y + BANK_FLOOR_TOP, floor_y + BANK_TOP, smoothstep(0.0, BANK_SIDE_RISE, outside)) + curve_rise_at(z, heightmap_corner)

## How far the curve along the valley has raised the bank's top at world z, m (0 at its south
## face, BANK_CURVE_RISE from the castle on). What stands far out along it rises with it.
static func curve_rise_at(z: float, heightmap_corner: Vector3) -> float:
	var start_z := heightmap_corner.z + BANK_START_PZ
	var along := clampf((start_z - z) / (start_z - _castle_z(heightmap_corner)), 0.0, 1.0)
	return maxf(BANK_CURVE_RISE, 0.0) * pow(along, BANK_CURVE_POWER)

static func _castle_z(heightmap_corner: Vector3) -> float:
	return heightmap_corner.z + TerrainCastle.SITE_PX.y - TerrainCastle.FAR_SHIFT

static func _build_bank(heightmap_corner: Vector3) -> MeshInstance3D:
	var floor_y: float = TerrainHeightmap.BASE_LEVEL
	var import_low_x := heightmap_corner.x - float(MountainWalls.APRON_WIDTH)
	var import_high_x := heightmap_corner.x + float(TerrainConfig.AREA_WIDTH + MountainWalls.APRON_WIDTH)
	var castle_z := _castle_z(heightmap_corner)
	var curve_rise := maxf(BANK_CURVE_RISE, 0.0)
	var box_min := Vector3(import_low_x - BANK_OVERRUN, floor_y - 100.0, minf(heightmap_corner.z - float(TerrainCastle.LENGTH) - BANK_OVERRUN, castle_z - BANK_BEYOND_CASTLE))
	var box_max := Vector3(import_high_x + BANK_OVERRUN, floor_y + BANK_TOP + BANK_TOP_WANDER + curve_rise, heightmap_corner.z + BANK_START_PZ)
	var material := ShaderMaterial.new()
	material.shader = load(BANK_SHADER_PATH) as Shader
	material.set_shader_parameter("noise", MountainWalls._cloud_noise_texture())
	material.set_shader_parameter("box_min", box_min)
	material.set_shader_parameter("box_max", box_max)
	material.set_shader_parameter("fog_color", BANK_COLOR)
	material.set_shader_parameter("top_color", BANK_TOP_COLOR)
	material.set_shader_parameter("shade_color", BANK_SHADE_COLOR)
	material.set_shader_parameter("light_depth", BANK_LIGHT_DEPTH)
	material.set_shader_parameter("billow_height", BANK_BILLOW_HEIGHT)
	material.set_shader_parameter("billow_scale", BANK_BILLOW_SCALE)
	material.set_shader_parameter("density", BANK_DENSITY)
	material.set_shader_parameter("front_z", box_max.z)
	material.set_shader_parameter("front_fade", BANK_FRONT_FADE)
	material.set_shader_parameter("top_fade", BANK_TOP_FADE)
	material.set_shader_parameter("top_wander", BANK_TOP_WANDER)
	set_bank_shape(material, heightmap_corner)
	var box := BoxMesh.new()
	box.size = box_max - box_min
	box.material = material
	var bank := MeshInstance3D.new()
	bank.name = "FogBank"
	bank.mesh = box
	bank.position = (box_min + box_max) * 0.5
	bank.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	print("TERRAIN_GEN: far end -- fog bank from %.0f m inside the map's north edge to %.0f m past the castle, top %.0f m above the floor between px %.0f..%.0f, %.0f m over the sides, rising %.0f m toward the castle (power %.1f)" % [BANK_START_PZ, BANK_BEYOND_CASTLE, BANK_FLOOR_TOP, TerrainHeightmap.floor_lo(0.0), TerrainHeightmap.floor_hi(0.0), BANK_TOP, curve_rise, BANK_CURVE_POWER])
	return bank

func _ready() -> void:
	# The cloud's top is lit from the moon: a DirectionalLight3D shines along its -Z, so the moon is at +Z.
	var moon := get_parent().get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	var bank := get_node_or_null("FogBank") as MeshInstance3D
	if moon and bank:
		var material := (bank.mesh as PrimitiveMesh).material as ShaderMaterial
		if material:
			material.set_shader_parameter("moon_toward", moon.global_transform.basis.z.normalized())
	_player = get_parent().get_node_or_null("Player") as Node3D
	if _player:
		var camera := _player.get_node_or_null("Camera3D") as Camera3D
		if camera:
			camera.far = maxf(camera.far, CAMERA_FAR)
