# "Look down" preview for animation_sources/fp_arms/fp_arms.blend (docs/blender_animation.md, "Looking
# down in Blender"): the scene as the game shows it while the Player looks down, so the arm can be
# judged against the body reference. The 3D view's sidebar (N) -> "FP Arms" tab -> "Look down".
#
# What the game does looking down (PlayerBody._clip_swing_pose, _hold_shield): the camera turns by
# the whole pitch; the arms are placed from the eyes turned by weapon_follows_view (0.8) of it -- the
# shoulders, the elbows' way and the shield arm wholly, the sword's wrist and hand held to at most
# swing_view_down_limit (10 deg) below level during the stroke (faded in until the swing's
# "view_cap".x s and out from "view_cap".y to its "time": _swing_view). The body does not turn.
# Here: helper bones at the eyes, VIEW_arms (parent of CTRL_chest, CTRL_elbow and the shield arm's
# controls), VIEW_hand (parent of CTRL_hand) and VIEW_camera (parent of Eyes, and so of the camera),
# turned about the eyes' right axis on every frame. They are not keyed and deform nothing; at 0 they
# change nothing. One toggle: looking down as far as the game lets the Player (MOST_DOWN, 80.2 deg;
# the default) or straight ahead. export_clips.py, wrap_fingers.py, add_shield_arm.py and
# update_stance.py switch it off while they run and back after, so it never reaches a clip;
# another script that reads places from the scene must do the same.
#
# It also keeps the body reference's head where the game keeps it (_hold_head; see there).
#
# add_view_bones() puts the bones in once (with the file open: run this file with ADD = True, or the
# Blender MCP). The .blend carries the rest as a text block registered on load, as the ghosts.
import bpy, math
from mathutils import Matrix, Vector

FOLLOWS_VIEW = 0.8       # PlayerBody.weapon_follows_view
MOST_DOWN = math.degrees(1.4)  # the furthest the Player can look down (player.gd clamps its pitch to 1.4 rad): the default
DOWN_LIMIT = 10.0        # PlayerBody.swing_view_down_limit (degrees)
# Per action: the swing's "view_cap" and "time" (s) in PlayerBody.SWINGS; an action not listed is a hold.
VIEW_CAPS = {"swing_down": (0.367, 0.733, 1.317), "swing_down_right": (0.367, 0.733, 1.317)}
FPS = 30.0
ARMS = ("CTRL_chest", "CTRL_elbow", "CTRL_hand_l", "CTRL_elbow_l")
HAND = ("CTRL_hand",)
CAMERA = ("Eyes",)
ADD = False


def _ease(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0) if b != a else (1.0 if x >= b else 0.0)
    return t * t * t * (20.0 + t * (-45.0 + t * (36.0 - 10.0 * t)))


def add_view_bones(arm):
    """Puts in VIEW_arms, VIEW_hand and VIEW_camera at the eyes, parents of their controls. Nothing moves."""
    if "VIEW_arms" in arm.data.bones:
        return
    view_layer = bpy.context.view_layer
    if getattr(bpy.context, "object", None) and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    view_layer.objects.active = arm
    arm.select_set(True)
    to_arm = arm.matrix_world.inverted()
    eyes = arm.matrix_world @ arm.data.bones["Eyes"].head_local
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    for name, children in (("VIEW_arms", ARMS), ("VIEW_hand", HAND), ("VIEW_camera", CAMERA)):
        bone = eb.new(name)
        bone.head = to_arm @ eyes
        bone.tail = to_arm @ (eyes + Vector((0.0, 0.0, 0.1)))  # upright
        bone.use_deform = False
        for child in children:
            if child in eb:
                eb[child].parent = bone
                eb[child].use_connect = False
    bpy.ops.object.mode_set(mode='POSE')
    by_name = {c.name: c for c in arm.data.collections}
    for name in ("VIEW_arms", "VIEW_hand", "VIEW_camera"):
        b = arm.data.bones[name]
        for c in list(b.collections):
            c.unassign(b)
        if "Body" in by_name:
            by_name["Body"].assign(b)  # hidden: they are turned by the setting, not by hand
        arm.pose.bones[name].rotation_mode = 'QUATERNION'
    bpy.ops.object.mode_set(mode='OBJECT')
    print("FP_ARMS view preview bones added")


def apply(scene):
    """Turns the VIEW_ bones for the scene's Look down and frame."""
    arm = bpy.data.objects.get("FPArms")
    if arm is None or "VIEW_arms" not in arm.pose.bones:
        return
    look = math.radians(MOST_DOWN) if getattr(scene, "fp_look_down", False) and not _straight[0] else 0.0
    full = -look * FOLLOWS_VIEW
    hand = full
    action = arm.animation_data.action if arm.animation_data else None
    cap = VIEW_CAPS.get(action.name if action else "")
    if cap:
        t = scene.frame_current / FPS
        weight = _ease(0.0, cap[0], t) * (1.0 - _ease(cap[1], cap[2], t))
        hand = full + (max(full, -math.radians(DOWN_LIMIT)) - full) * weight
    for name, angle in (("VIEW_arms", full), ("VIEW_hand", hand), ("VIEW_camera", -look)):
        bone = arm.pose.bones[name]
        # About the eyes' right axis (the world's +X; the bone sits at the eyes): - = down.
        world_turn = Matrix.Rotation(angle, 3, 'X')
        rest = arm.matrix_world.to_3x3() @ bone.bone.matrix_local.to_3x3()
        bone.rotation_quaternion = (rest.inverted() @ world_turn @ rest).to_quaternion()
        bone.location = (0.0, 0.0, 0.0)
        bone.scale = (1.0, 1.0, 1.0)


def _on_frame(scene, depsgraph=None):
    apply(scene)


_holding = [False]


def _hold_head(scene, depsgraph=None):
    """The body reference (add_body_reference.py) moved so that its head is where the recording has
    it on this frame: the game keeps the camera at the eyes and moves the body under it, so as
    CTRL_chest turns the spine the head stays put and the rest shifts. After every update, so it
    follows the chest while it is dragged too."""
    if _holding[0]:
        return
    body = bpy.data.objects.get("BodyRef")
    if body is None or "head_path" not in body or "Head" not in body.pose.bones:
        return
    path = body["head_path"]
    count = len(path) // 3
    frame = min(max(scene.frame_current - int(body.get("head_path_start", 0)), 0), count - 1)
    want = Vector(path[frame * 3:frame * 3 + 3])
    now = body.matrix_world @ body.pose.bones["Head"].head
    shift = want - now
    if shift.length > 0.0002:
        _holding[0] = True
        try:
            body.location += shift
        finally:
            _holding[0] = False


# The swing line: the path of the sword's tip through the downward cut of the move FPArms plays
# (_cut_frames), frame by frame, as the view is set (straight or down) -- a thin bright line drawn in front of everything, in the collection
# "Debug" (not under FPArms: the export never takes it; not selectable). Debug only: nothing reads it.
LINE = "SwingLine"
LINE_COLOUR = (1.0, 0.85, 0.1, 1.0)


_straight = [False]  # True while the cut's frames are found: apply() then looks straight whatever the toggle


def _cut_frames(scene, sword, tip_local, first, last):
    """The downward cut (Kirill: "not the return stroke, only the downward cut"): the run of frames in
    which the tip keeps going down that drops it furthest -- found looking straight, so the frames are
    the same in both views. (From its highest point instead took in the wind-up where that was higher.)"""
    _straight[0] = True
    heights = []
    for frame in range(first, last + 1):
        scene.frame_set(frame)
        heights.append((sword.matrix_world @ tip_local).z)
    _straight[0] = False
    best, start = (0, 0, 0.0), 0
    for i in range(1, len(heights) + 1):
        if i == len(heights) or heights[i] >= heights[i - 1]:
            drop = heights[start] - heights[i - 1]
            if drop > best[2]:
                best = (start, i - 1, drop)
            start = i
    return first + best[0], first + best[1]


def build_swing_line(scene):
    arm = bpy.data.objects.get("FPArms")
    sword = bpy.data.objects.get("sword")
    if arm is None or sword is None or not arm.animation_data or not arm.animation_data.action:
        return
    tip_local = max((v.co for v in sword.data.vertices), key=lambda co: co.z).copy()  # the blade runs along +Z
    first, last = (int(round(x)) for x in arm.animation_data.action.frame_range)
    was = scene.frame_current
    start, end = _cut_frames(scene, sword, tip_local, first, last)
    points = []
    for frame in range(start, end + 1):
        scene.frame_set(frame)  # the frame handler turns the view first
        points.append(sword.matrix_world @ tip_local)
    scene.frame_set(was)
    collection = bpy.data.collections.get("Debug")
    if collection is None:
        collection = bpy.data.collections.new("Debug")
        scene.collection.children.link(collection)
    curve = bpy.data.curves.get(LINE) or bpy.data.curves.new(LINE, 'CURVE')
    curve.dimensions = '3D'
    curve.bevel_depth = 0.002
    curve.splines.clear()
    spline = curve.splines.new('POLY')
    spline.points.add(len(points) - 1)
    for point, at in zip(spline.points, points):
        point.co = (at.x, at.y, at.z, 1.0)
    material = bpy.data.materials.get(LINE) or bpy.data.materials.new(LINE)
    material.diffuse_color = LINE_COLOUR  # the colour solid and material preview both show
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    glow = nodes.new('ShaderNodeEmission')
    glow.inputs["Color"].default_value = LINE_COLOUR
    glow.inputs["Strength"].default_value = 3.0
    out = nodes.new('ShaderNodeOutputMaterial')
    material.node_tree.links.new(glow.outputs["Emission"], out.inputs["Surface"])
    if not curve.materials:
        curve.materials.append(material)
    line = bpy.data.objects.get(LINE) or bpy.data.objects.new(LINE, curve)
    if line.name not in collection.objects:
        for c in list(line.users_collection):
            c.objects.unlink(line)
        collection.objects.link(line)
    line.show_in_front = True
    line.hide_select = True
    line.color = LINE_COLOUR


def _on_change(self, context):
    apply(context.scene)
    build_swing_line(context.scene)


class FPARMS_OT_swing_line(bpy.types.Operator):
    bl_idname = "fp_arms.swing_line"
    bl_label = "Update the swing line"
    bl_description = "Draws again the path of the sword's tip through the move FPArms plays, as the view is set"

    def execute(self, context):
        build_swing_line(context.scene)
        return {'FINISHED'}


class FPARMS_PT_view(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "FP Arms"
    bl_label = "Look down"

    def draw(self, context):
        col = self.layout.column(align=True)
        down = context.scene.fp_look_down
        col.prop(context.scene, "fp_look_down", toggle=True, icon='TRIA_DOWN' if down else 'TRIA_RIGHT',
                 text="Looking down (%.0f deg)" % MOST_DOWN if down else "Looking straight")
        col.label(text="Preview only: the export looks straight")
        self.layout.operator("fp_arms.swing_line", icon='CURVE_PATH')


def register():
    for cls in (FPARMS_OT_swing_line, FPARMS_PT_view):
        if hasattr(bpy.types, cls.__name__):
            try:
                bpy.utils.unregister_class(getattr(bpy.types, cls.__name__))
            except RuntimeError:
                pass
        bpy.utils.register_class(cls)
    bpy.types.Scene.fp_look_down = bpy.props.BoolProperty(name="Look down", default=True, update=_on_change,
            description="The scene as the game shows it looking as far down as it can (on) or straight ahead (off)")
    for handlers, handler in ((bpy.app.handlers.frame_change_pre, _on_frame), (bpy.app.handlers.frame_change_post, _hold_head),
            (bpy.app.handlers.depsgraph_update_post, _hold_head)):
        for h in [h for h in handlers if getattr(h, "__name__", "") == handler.__name__]:
            handlers.remove(h)
        handlers.append(handler)


if ADD:
    add_view_bones(bpy.data.objects["FPArms"])
register()
