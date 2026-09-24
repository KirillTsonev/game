extends Node3D

## Non-destructive per-material color/value tint for the Church model.
## Never touches the source .glb or its baked textures: at runtime, for each
## matching MeshInstance3D child, duplicates the material it's already using
## (so the baked albedo/roughness/normal maps are preserved) and multiplies
## albedo_color to push value/hue apart per the color-lighting guide notes
## in godot_notes/color_lighting_for_painterly_postprocess.md.
##
## To retune: edit the multipliers below and re-run the scene. To remove
## entirely: delete this script (or detach it from Church) -- the model
## reverts to its original baked materials with zero cleanup.

# name substring (matched against the child MeshInstance3D's name) -> tint
# multiplier applied component-wise to the existing albedo_color.
const TINTS := {
	"walls": Color(1.0, 1.0, 0.95),
	"bricks_old": Color(0.55, 0.6, 0.58),
	"bricks": Color(0.85, 0.72, 0.6),
	"roof_parts": Color(0.55, 0.5, 0.46),
	"roof": Color(0.45, 0.42, 0.4),
	"statue": Color(1.3, 1.3, 1.25),
	"bell": Color(1.4, 1.15, 0.75),
	"plaster": Color(1.25, 1.22, 1.1),
	"doors": Color(1.1, 0.85, 0.55),
	"symbol": Color(1.2, 1.05, 0.7),
}

func _ready() -> void:
	_apply_tints(self)

func _apply_tints(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_tint_mesh_instance(child)
		_apply_tints(child)

func _tint_mesh_instance(mesh_instance: MeshInstance3D) -> void:
	var tint = _find_tint(mesh_instance.name)
	if tint == null:
		return

	var surface_count := mesh_instance.mesh.get_surface_count() if mesh_instance.mesh else 0
	for i in range(surface_count):
		var base_material := mesh_instance.get_active_material(i)
		if base_material == null:
			continue
		var tinted: Material = base_material.duplicate()
		if tinted is BaseMaterial3D:
			var c: Color = tinted.albedo_color
			tinted.albedo_color = Color(
				c.r * tint.r,
				c.g * tint.g,
				c.b * tint.b,
				c.a
			)
		mesh_instance.set_surface_override_material(i, tinted)

func _find_tint(mesh_name: String):
	var lower := mesh_name.to_lower()
	for key in TINTS.keys():
		if lower.contains(key):
			return TINTS[key]
	return null
