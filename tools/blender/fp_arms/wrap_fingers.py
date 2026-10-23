# The sword hand's fingers in animation_sources/fp_arms/fp_arms.blend closed round the handle on
# every frame (docs/blender_animation.md, "The fist closes on the handle where it is"): each
# finger, from the fist keyed in the action, wraps the handle in three stages, each until the finger's part beyond the bending joint
# lies GRIP_RADIUS + FINGER_THICKNESS from the handle's middle line: all three joints alike (or
# opened, if the fist is in the handle; the thumb's first joint swings in across the palm, its
# other two closing half as much), then the outer two, then the last. With the first stage alone
# the middle joint touched first and the tips stayed 4.2 cm out: a ring, not a grip. The handle's line
# is the Weapon bone's: through its head, along its own Y (the blade's way within 1.4 deg).
#
# The game plays these keys during a Blender swing (PlayerBody._play_clip_fingers, the Body's
# swing_fingers_from_rig); outside one the stance's posed fist is kept. Run it again after changing
# a move's hand or Weapon keys, then export. It REPLACES the right hand's finger keys in every
# action with one key a frame (hand edits of the fingers are lost: edit them after running it).
#
# Run it in the open Blender (the Blender MCP, or the Text editor), then save.
import bpy, math
from mathutils import Matrix, Vector, Quaternion

GRIP_RADIUS = 0.022     # the sword's handle (assets/models/weapons/sword/sword.tres, grip_radius)
FINGER_THICKNESS = 0.007  # PlayerBody.grip_finger_thickness
STEP = 0.05             # radians a joint: PlayerBody.GRIP_CURL_STEP
MOST = 0.6              # radians a joint: PlayerBody.GRIP_CURL_MAX
FINGERS = ("Thumb", "Index", "Middle", "Ring", "Little")
DOWN = Vector((0.0, 0.0, -1.0))  # the palm's side in the rest pose, in the armature's space


def joints_of(arm):
    """Per finger its three bones and the axis each closes about in its own rest axes, and the
    thumb's swing-in axis (WeaponHold.finger_joints)."""
    bones = arm.data.bones
    out = {}
    for finger in FINGERS:
        names = ["Right%s%s" % (finger, j) for j in (("Metacarpal", "Proximal", "Distal") if finger == "Thumb" else ("Proximal", "Intermediate", "Distal"))]
        out[finger] = []
        for i, name in enumerate(names):
            head = bones[name].head_local
            along = (bones[names[i + 1]].head_local - head) if i < 2 else (head - bones[names[i - 1]].head_local)
            out[finger].append((name, (bones[name].matrix_local.to_3x3().inverted() @ along.cross(DOWN)).normalized()))
    thumb = bones["RightThumbMetacarpal"]
    thumb_along = bones["RightThumbProximal"].head_local - thumb.head_local
    knuckle = bones["RightMiddleProximal"].head_local - bones["RightHand"].head_local
    out["thumb_in"] = (thumb.matrix_local.to_3x3().inverted() @ thumb_along.cross(knuckle)).normalized()
    return out


def wrap_frame(arm, joints):
    """Sets the fingers' rotation_quaternion for the frame the scene is on (the hand and the
    Weapon bone evaluated). Returns the nearest any finger part comes to the handle's line (m)."""
    pb = arm.pose.bones
    bones = arm.data.bones
    weapon = pb["Weapon"]
    line_from = weapon.head.copy()
    line_way = weapon.y_axis.normalized()
    target = GRIP_RADIUS + FINGER_THICKNESS
    nearest = math.inf

    def from_line(point):
        off = point - line_from
        return (off - line_way * off.dot(line_way)).length

    for finger in FINGERS:
        chain = joints[finger]
        names = [n for n, _ in chain]
        posed = [pb[n].rotation_quaternion.copy() for n in names]
        parent = bones[names[0]].parent
        parent_matrix = pb[parent.name].matrix.copy()

        def placed(turns):
            # The three joints' heads (armature space) for these rotations.
            matrix = parent_matrix
            parent_rest = parent.matrix_local
            heads = []
            for j, name in enumerate(names):
                rest = bones[name].matrix_local
                matrix = matrix @ (parent_rest.inverted() @ rest) @ turns[j].to_matrix().to_4x4()
                heads.append(matrix.translation.copy())
                parent_rest = rest
            return heads

        def turned(stage, extra):
            # Stage 0 closes all three joints alike (the thumb's first swings in across the palm,
            # its others close half as much); stage 1 the outer two; stage 2 the last.
            turns = list(posed)
            for j in range(stage, 3):
                axis = chain[j][1]
                if finger == "Thumb" and stage == 0:
                    turns[j] = posed[j] @ Quaternion(joints["thumb_in"] if j == 0 else axis, extra if j == 0 else extra * 0.5)
                else:
                    turns[j] = posed[j] @ Quaternion(axis, extra)
            return turns

        def gap(stage, extra):
            # The nearest part beyond the joint that bends first in this stage.
            heads = placed(turned(stage, extra))
            parts = [heads[1], heads[2], heads[2] + (heads[2] - heads[1]) * 0.8][stage:]
            return min(from_line(p) for p in parts) - target

        for stage in range(3):
            start = gap(stage, 0.0)
            way = 1.0 if start > 0.0 else -1.0
            if stage > 0 and way < 0.0:
                continue # already touching: the later stages only close
            best, best_gap, crossed = 0.0, abs(start), None
            for i in range(1, int(round(MOST / STEP)) + 1):
                tried = way * STEP * i
                has = gap(stage, tried)
                if (has > 0.0) != (start > 0.0):
                    crossed = [tried - way * STEP, tried]
                    break
                if abs(has) >= best_gap:
                    break
                best, best_gap = tried, abs(has)
            if crossed:
                for _ in range(8):
                    middle = (crossed[0] + crossed[1]) * 0.5
                    if (gap(stage, middle) > 0.0) == (start > 0.0):
                        crossed[0] = middle
                    else:
                        crossed[1] = middle
                best = (crossed[0] + crossed[1]) * 0.5
            posed = turned(stage, best)
        for name, turn in zip(names, posed):
            pb[name].rotation_quaternion = turn
        nearest = min(nearest, gap(0, 0.0) + target)
    return nearest


def fcurves_of(action):
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                out.extend((bag, fc) for fc in bag.fcurves)
    return out


def main():
    arm = bpy.data.objects["FPArms"]
    scene = bpy.context.scene
    if getattr(bpy.context, "object", None) and bpy.context.object.mode not in ('OBJECT', 'POSE'):
        bpy.ops.object.mode_set(mode='OBJECT')
    editing = arm.animation_data.action
    frame_was = scene.frame_current
    joints = joints_of(arm)
    names = [n for f in FINGERS for n, _ in joints[f]]
    for action in bpy.data.actions:
        if not any(fc.data_path.startswith('pose.bones["Weapon"]') for _, fc in fcurves_of(action)) and action.name != "hold":
            continue
        arm.animation_data.action = action
        first, last = (int(round(x)) for x in action.frame_range)
        # The fist keyed in the action, before any wrap: each frame starts from it.
        scene.frame_set(first)
        fist = {n: arm.pose.bones[n].rotation_quaternion.copy() for n in names}
        for bag, fc in fcurves_of(action):
            if any(fc.data_path.startswith('pose.bones["%s"]' % n) for n in names):
                bag.fcurves.remove(fc)
        nearest = math.inf
        for frame in range(first, last + 1):
            scene.frame_set(frame)
            for n in names:
                arm.pose.bones[n].rotation_quaternion = fist[n]
            bpy.context.view_layer.update()
            nearest = min(nearest, wrap_frame(arm, joints))
            for n in names:
                arm.pose.bones[n].keyframe_insert("rotation_quaternion", frame=frame)
        print("FP_ARMS %s: fingers wrapped on frames %d-%d, the nearest finger part %.1f cm from the handle's middle" % (action.name, first, last, nearest * 100.0))
    arm.animation_data.action = editing
    scene.frame_set(frame_was)


main()
