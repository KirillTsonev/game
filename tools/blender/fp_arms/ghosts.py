# Ghosts (onion skin) for animation_sources/fp_arms/fp_arms.blend: see-through copies of the arm and
# the sword as they are a few frames before and after the current one -- blue before, orange after,
# fainter the further away. The 3D view's sidebar (N) -> "FP Arms" tab -> Ghosts: "Show" draws them
# around the current frame, "Clear" removes them. They are frozen: press Show again after moving to
# another frame or changing a pose. They live in the "Ghosts" collection, are not selectable, and
# the export (export_clips.py, the armature and its meshes selected) never takes them.
#
# The .blend carries this as a text block registered on load ("Register" ticked), so the panel is
# there whenever the file is opened -- if Blender asks to allow the file's scripts, allow it, or
# run this file once from the Scripting tab.
import bpy

GHOSTS = "Ghosts"
BEFORE_COLOUR = (0.25, 0.55, 1.0)
AFTER_COLOUR = (1.0, 0.55, 0.15)


def _ghost_material(offset, count):
    name = "Ghost_%+d" % offset
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    colour = BEFORE_COLOUR if offset < 0 else AFTER_COLOUR
    alpha = 0.45 * (1.0 - (abs(offset) - 1) / max(count, 1)) + 0.05
    material.diffuse_color = (*colour, alpha)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    out = nodes.new('ShaderNodeOutputMaterial')
    shader = nodes.new('ShaderNodeBsdfPrincipled')
    shader.inputs["Base Color"].default_value = (*colour, 1.0)
    shader.inputs["Alpha"].default_value = alpha
    shader.inputs["Emission Color"].default_value = (*colour, 1.0)
    shader.inputs["Emission Strength"].default_value = 0.3
    material.node_tree.links.new(shader.outputs["BSDF"], out.inputs["Surface"])
    if hasattr(material, "surface_render_method"):
        material.surface_render_method = 'BLENDED'
    if hasattr(material, "blend_method"):
        material.blend_method = 'BLEND'
    if hasattr(material, "use_backface_culling"):
        material.use_backface_culling = True
    return material


def _sources(scene):
    """The arm's and the sword's meshes: every visible mesh under the FPArms armature."""
    arm = bpy.data.objects.get("FPArms")
    found = []
    for o in scene.objects:
        if o.type != 'MESH' or not o.visible_get() or o.name.startswith("ghost "):
            continue
        parent = o.parent
        while parent is not None and parent != arm:
            parent = parent.parent
        if parent == arm:
            found.append(o)
    return found


def clear(scene):
    collection = bpy.data.collections.get(GHOSTS)
    if collection is None:
        return
    for o in list(collection.objects):
        mesh = o.data
        bpy.data.objects.remove(o, do_unlink=True)
        if mesh is not None and mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def show(context):
    scene = context.scene
    clear(scene)
    collection = bpy.data.collections.get(GHOSTS)
    if collection is None:
        collection = bpy.data.collections.new(GHOSTS)
    if collection.name not in scene.collection.children:
        scene.collection.children.link(collection)
    sources = _sources(scene)
    current = scene.frame_current
    before, after, step = scene.fp_ghosts_before, scene.fp_ghosts_after, max(scene.fp_ghosts_step, 1)
    offsets = [-i * step for i in range(before, 0, -1)] + [i * step for i in range(1, after + 1)]
    made = 0
    for offset in offsets:
        scene.frame_set(current + offset)
        depsgraph = context.evaluated_depsgraph_get()
        material = _ghost_material(offset // step, max(before, after))
        for source in sources:
            evaluated = source.evaluated_get(depsgraph)
            mesh = bpy.data.meshes.new_from_object(evaluated, depsgraph=depsgraph)
            mesh.materials.clear()
            mesh.materials.append(material)
            ghost = bpy.data.objects.new("ghost %+d %s" % (offset, source.name), mesh)
            ghost.matrix_world = evaluated.matrix_world.copy()
            ghost.hide_select = True
            collection.objects.link(ghost)
            made += 1
    scene.frame_set(current)
    return made


class FPARMS_OT_show_ghosts(bpy.types.Operator):
    bl_idname = "fp_arms.show_ghosts"
    bl_label = "Show"
    bl_description = "See-through copies of the arm and the sword a few frames before (blue) and after (orange) this one"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        made = show(context)
        self.report({'INFO'}, "%d ghost copies around frame %d" % (made, context.scene.frame_current))
        return {'FINISHED'}


class FPARMS_OT_clear_ghosts(bpy.types.Operator):
    bl_idname = "fp_arms.clear_ghosts"
    bl_label = "Clear"
    bl_description = "Remove the ghost copies"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        clear(context.scene)
        return {'FINISHED'}


class FPARMS_PT_ghosts(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "FP Arms"
    bl_label = "Ghosts"

    def draw(self, context):
        scene = context.scene
        col = self.layout.column(align=True)
        col.prop(scene, "fp_ghosts_before")
        col.prop(scene, "fp_ghosts_after")
        col.prop(scene, "fp_ghosts_step")
        row = self.layout.row(align=True)
        row.operator("fp_arms.show_ghosts", icon='GHOST_ENABLED')
        row.operator("fp_arms.clear_ghosts", icon='X')


CLASSES = (FPARMS_OT_show_ghosts, FPARMS_OT_clear_ghosts, FPARMS_PT_ghosts)


def register():
    for cls in CLASSES:
        if hasattr(bpy.types, cls.__name__):
            try:
                bpy.utils.unregister_class(getattr(bpy.types, cls.__name__))
            except RuntimeError:
                pass
        bpy.utils.register_class(cls)
    bpy.types.Scene.fp_ghosts_before = bpy.props.IntProperty(name="Frames before", default=3, min=0, max=20)
    bpy.types.Scene.fp_ghosts_after = bpy.props.IntProperty(name="Frames after", default=3, min=0, max=20)
    bpy.types.Scene.fp_ghosts_step = bpy.props.IntProperty(name="Every n frames", default=1, min=1, max=10)


register()
