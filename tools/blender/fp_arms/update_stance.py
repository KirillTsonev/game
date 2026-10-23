# After the stance changed in Godot (the WeaponStance markers: hand, elbow, the sword's turn in the
# fist), brings animation_sources/fp_arms/fp_arms.blend up to it WITHOUT losing hand edits -- what
# build_scene.py cannot do (it rebuilds the moves). First re-run step 1
# (tools/blender/fp_arms/export_arm_source.gd), which rewrites arm_source.json; then this, in the
# open Blender (the Blender MCP, or the Scripting tab's Run Script); then export_clips.py.
#
# What it changes:
#   - every key that holds the OLD stance -- the "hold" action, and in every move the keys equal to
#     it (the first and last frame of a move that starts and ends in the hold, the fingers' key) --
#     is set to the new stance. A key is "the stance" when all its channels equal the old hold's
#     (quaternions either sign); keys posed by hand never are, and are left alone.
#   - the Weapon bone's rest moves to the new grip's place (its keyed moves and turns ride on it),
#     and the Sword object is laid on the new grip.
# export_clips.py then writes the new socket into fp_arms_rig.json, and the game draws the sword
# from it: a turn of the sword in the stance turns it through every move, the keyed turns on top.
#
# The maths is build_scene.py's (the eyes' space as Blender's world, everything a turn from the
# rest): keep the two the same.
import bpy, json, math, os
from mathutils import Matrix, Vector

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(PROJECT, "animation_sources", "fp_arms")
CONTROLS = ("CTRL_shoulder", "CTRL_hand", "CTRL_elbow", "Eyes", "Weapon")
FINGER_WORDS = ("Thumb", "Index", "Middle", "Ring", "Little")
SAME = 1e-4  # a key within this of the old hold's value is the stance

C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def gv(v):
    return C @ Vector(v)


def gbasis(a):
    return Matrix((a[0:3], a[3:6], a[6:9])).transposed()


def gtransform(a):
    return gbasis(a[0:9]), Vector(a[9:12])


def to_blender(basis):
    return C @ basis @ C.transposed()


def world(rotation, at):
    m = rotation.to_4x4()
    m.translation = at
    return m


def fcurves_of(action):
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                out.extend(bag.fcurves)
    return out


def main():
    scene = bpy.context.scene
    if bpy.context.object and bpy.context.object.mode == 'EDIT':
        bpy.ops.object.mode_set(mode='OBJECT')
    src = json.load(open(os.path.join(SRC, "arm_source.json")))
    arm = bpy.data.objects["FPArms"]
    bones = {n: b for n, b in src["bones"].items() if n in arm.data.bones}
    pb = arm.pose.bones
    hold = bpy.data.actions["hold"]
    editing, frame_was = arm.animation_data.action, scene.frame_current
    old = {(f.data_path, f.array_index): f.evaluate(1) for f in fcurves_of(hold)}

    # The Weapon bone's rest onto the new grip (turned as before: only its place moves).
    hand_rest_b, hand_rest_at = gtransform(bones["RightHand"]["rest"])
    socket_b, socket_at = gtransform(src["socket"])
    grip_rest = hand_rest_at + hand_rest_b @ socket_at
    to_arm = arm.matrix_world.inverted()
    active = bpy.context.view_layer.objects.active
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    weapon = arm.data.edit_bones["Weapon"]
    shift = to_arm @ gv(grip_rest) - weapon.head
    weapon.head += shift
    weapon.tail += shift
    bpy.ops.object.mode_set(mode='POSE')
    rest_world = {b.name: arm.matrix_world @ b.matrix_local for b in arm.data.bones}

    def set_world(name, matrix):
        pb[name].matrix = to_arm @ matrix

    # The new stance, posed on the rig (as build_scene.py's pose() for the hold).
    arm.animation_data.action = hold
    scene.frame_set(1)
    at = lambda n: gtransform(bones[n]["pose"])[1]
    shoulder, elbow, wrist = at("RightUpperArm"), at("RightLowerArm"), at("RightHand")
    hand_b = gtransform(bones["RightHand"]["pose"])[0]
    set_world("CTRL_shoulder", world(rest_world["CTRL_shoulder"].to_3x3(), gv(shoulder)))
    set_world("CTRL_hand", world(to_blender(hand_b @ hand_rest_b.inverted()) @ rest_world["CTRL_hand"].to_3x3(), gv(wrist)))
    foot = shoulder + (wrist - shoulder) * max(0.0, min(1.0, (elbow - shoulder).dot(wrist - shoulder) / max((wrist - shoulder).length_squared, 1e-9)))
    out = elbow - foot
    out = out.normalized() if out.length > 1e-4 else Vector((0, -1, 0))
    set_world("CTRL_elbow", world(rest_world["CTRL_elbow"].to_3x3(), gv(elbow + out * 0.4)))
    set_world("Eyes", world(rest_world["Eyes"].to_3x3(), rest_world["Eyes"].translation))
    bpy.context.view_layer.update()
    evaluated_hand = arm.matrix_world @ pb["RightHand"].matrix
    set_world("Weapon", world(to_blender(hand_b @ socket_b @ (hand_rest_b @ socket_b).inverted()) @ rest_world["Weapon"].to_3x3(), evaluated_hand.translation + C @ (hand_b @ socket_at)))
    bpy.context.view_layer.update()
    fingers = [n for n in bones if any(w in n for w in FINGER_WORDS) or n.endswith("metacarpal_r")]
    depth = lambda n: 0 if arm.data.bones[n].parent is None else 1 + depth(arm.data.bones[n].parent.name)
    fingers.sort(key=depth)
    for name in fingers:
        g_pose, _ = gtransform(bones[name]["pose"])
        g_rest, _ = gtransform(bones[name]["rest"])
        hand_eval = (arm.matrix_world @ pb["RightHand"].matrix).to_3x3()
        hand_now = C.transposed() @ hand_eval @ (C.transposed() @ rest_world["RightHand"].to_3x3()).inverted() @ hand_rest_b
        set_world(name, world(to_blender(hand_now @ hand_b.inverted() @ g_pose @ g_rest.inverted()) @ rest_world[name].to_3x3(), arm.matrix_world @ pb[name].head))
        pb[name].location = (0, 0, 0)
        bpy.context.view_layer.update()
    new = {}
    for name in list(CONTROLS) + fingers:
        for i in range(3):
            new[('pose.bones["%s"].location' % name, i)] = pb[name].location[i]
        for i in range(4):
            new[('pose.bones["%s"].rotation_quaternion' % name, i)] = pb[name].rotation_quaternion[i]

    # Every key that is the old stance -> the new one.
    replaced = {}
    for action in bpy.data.actions:
        groups = {}
        for fc in fcurves_of(action):
            groups.setdefault(fc.data_path, {})[fc.array_index] = fc
        count = 0
        for path, channels in groups.items():
            if not all((path, i) in old and (path, i) in new for i in channels):
                continue
            quaternion = path.endswith("rotation_quaternion")
            frames = sorted({k.co[0] for fc in channels.values() for k in fc.keyframe_points})
            for f in frames:
                now = {i: fc.evaluate(f) for i, fc in channels.items()}
                sign = 0
                if all(abs(now[i] - old[(path, i)]) < SAME for i in channels):
                    sign = 1
                elif quaternion and all(abs(now[i] + old[(path, i)]) < SAME for i in channels):
                    sign = -1
                if sign == 0:
                    continue
                value = {i: new[(path, i)] for i in channels}
                if quaternion and sum(value[i] * old[(path, i)] for i in channels) < 0.0:
                    value = {i: -v for i, v in value.items()}
                for i, fc in channels.items():
                    for k in fc.keyframe_points:
                        if abs(k.co[0] - f) < 0.01:
                            d = sign * value[i] - k.co[1]
                            k.co[1] += d
                            k.handle_left[1] += d
                            k.handle_right[1] += d
                    fc.update()
                count += 1
        replaced[action.name] = count

    # The sword on the new grip, the rig in the (new) hold.
    scene.frame_set(1)
    bpy.context.view_layer.update()
    sword = bpy.data.objects.get("Sword")
    if sword:
        sword_b, sword_at = gtransform(src["sword"])
        sword.matrix_world = world(to_blender(sword_b), gv(sword_at))
    arm.animation_data.action = editing
    scene.frame_set(frame_was)
    bpy.ops.object.mode_set(mode='OBJECT')
    bpy.context.view_layer.objects.active = active
    bpy.ops.wm.save_mainfile()
    moved = shift.length
    print("FP_ARMS stance updated: the grip moved %.4f m; stance keys replaced per action: %s" % (moved, ", ".join("%s %d" % kv for kv in replaced.items())))


# The "Look down" preview (view_preview.py) off while this reads the scene, back after.
_looking = getattr(bpy.context.scene, "fp_look_down", False)
if _looking:
    bpy.context.scene.fp_look_down = False
try:
    main()
finally:
    if _looking:
        bpy.context.scene.fp_look_down = _looking
