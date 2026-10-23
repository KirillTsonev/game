# The chest control in animation_sources/fp_arms/fp_arms.blend (docs/blender_animation.md, "The
# chest"), ADDED to the open scene: CTRL_chest on the body's spine line, parent of both shoulder
# controls, so turning it carries both shoulders round the spine as a real torso does. The hand
# controls are not under it (the sword's and the shield's paths stay where they are keyed); the
# arms reach for them by IK.
#
# The game reads CTRL_chest's turn from its rest (PlayerBody._rig_sample) and turns the body's
# spine by it during the swing. It deforms nothing but is marked deforming, so the exporter
# (export_def_bones) keeps it.
#
# Adding it moves nothing: it starts unkeyed, at rest. Run it in the open Blender (the Blender
# MCP, or the Text editor); it does nothing if CTRL_chest is there. Save the file afterwards.
import bpy
from mathutils import Vector

CHEST = "CTRL_chest"
SHOULDERS = ("CTRL_shoulder", "CTRL_shoulder_l")
# The spine line it turns about, in the eyes' space (+X right, +Y ahead, +Z up): the body's
# UpperChest as the rig has it (3 cm left, 17 cm behind the eyes), at that bone's height.
SPINE_BONE = "UpperChest"
LENGTH = 0.15


def add_chest(arm):
    if CHEST in arm.data.bones:
        print("FP_ARMS %s is there already" % CHEST)
        return
    view_layer = bpy.context.view_layer
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    view_layer.objects.active = arm
    arm.select_set(True)
    to_arm = arm.matrix_world.inverted()
    at = arm.matrix_world @ arm.data.bones[SPINE_BONE].head_local
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    chest = eb.new(CHEST)
    chest.head = to_arm @ at
    chest.tail = to_arm @ (at + Vector((0.0, 0.0, LENGTH))) # upright: its own +Y is the eyes' up
    chest.roll = 0.0
    chest.use_deform = True
    for name in SHOULDERS:
        eb[name].parent = chest
        eb[name].use_connect = False
    bpy.ops.object.mode_set(mode='POSE')
    pb = arm.pose.bones[CHEST]
    pb.rotation_mode = 'QUATERNION'
    by_name = {c.name: c for c in arm.data.collections}
    bone = arm.data.bones[CHEST]
    for c in list(bone.collections):
        c.unassign(bone)
    by_name["Controls"].assign(bone)
    bone.color.palette = 'THEME06'
    bpy.ops.object.mode_set(mode='OBJECT')
    view_layer.update()
    print("FP_ARMS %s added at %s (eyes' space), parent of %s" % (CHEST, tuple(round(x, 3) for x in at), ", ".join(SHOULDERS)))


add_chest(bpy.data.objects["FPArms"])
