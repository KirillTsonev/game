## Invisible walls around the generated map (2026-10-06), so the player cannot walk off its edges.
##
## Four endless vertical planes (WorldBoundaryShape3D) on one StaticBody3D, EDGE_INSET m inside the
## map's outermost height samples -- no height to jump or climb over, nothing drawn. The road's
## spawn and exit points sit on the very edge (road.gd), so WorldGenerator moves the player's start
## position inside the walls with clamp_inside().
class_name WorldBounds
extends RefCounted

const NODE_NAME := "WorldBounds"
## Distance from the map's outermost height samples to the walls, m.
const EDGE_INSET := 1.0
## How far inside the walls the player's start position is kept, m (the capsule's radius is 0.4).
const SPAWN_CLEARANCE := 0.75

## The walled area in world x / z: position = low corner, size = extent.
static func inner_rect(heightmap_corner: Vector3) -> Rect2:
	var low := Vector2(heightmap_corner.x + EDGE_INSET, heightmap_corner.z + EDGE_INSET)
	var size := Vector2(TerrainConfig.AREA_WIDTH - 1.0 - 2.0 * EDGE_INSET, TerrainConfig.AREA_LENGTH - 1.0 - 2.0 * EDGE_INSET)
	return Rect2(low, size)

## Adds the walls to `parent_node` (deferred, like the other generated bodies).
static func build(parent_node: Node, heightmap_corner: Vector3) -> void:
	var old := parent_node.get_node_or_null(NODE_NAME)
	if old:
		old.name = NODE_NAME + "_old"
		old.queue_free()
	var rect := inner_rect(heightmap_corner)
	var body := StaticBody3D.new()
	body.name = NODE_NAME
	# Each plane is solid on the side its normal points away from: the normals face into the map.
	var planes := {
		"LowX": Plane(Vector3.RIGHT, rect.position.x),
		"HighX": Plane(Vector3.LEFT, -rect.end.x),
		"LowZ": Plane(Vector3.BACK, rect.position.y),
		"HighZ": Plane(Vector3.FORWARD, -rect.end.y),
	}
	for side: String in planes:
		var shape := WorldBoundaryShape3D.new()
		shape.plane = planes[side]
		var wall := CollisionShape3D.new()
		wall.name = side
		wall.shape = shape
		body.add_child(wall)
	parent_node.add_child.call_deferred(body)
	print("TERRAIN_GEN: world bounds -- walls at x %.0f..%.0f, z %.0f..%.0f" % [rect.position.x, rect.end.x, rect.position.y, rect.end.y])

## `position` moved to at least SPAWN_CLEARANCE m inside the walls (x and z; y is kept).
static func clamp_inside(position: Vector3, heightmap_corner: Vector3) -> Vector3:
	var rect := inner_rect(heightmap_corner).grow(-SPAWN_CLEARANCE)
	return Vector3(clampf(position.x, rect.position.x, rect.end.x), position.y, clampf(position.z, rect.position.y, rect.end.y))
