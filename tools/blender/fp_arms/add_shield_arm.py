# The shield arm in animation_sources/fp_arms/fp_arms.blend (docs/blender_animation.md, "The
# shield arm"), ADDED to the open scene -- nothing of the sword arm, its keys or the camera is
# rebuilt. From what export_shield_source.gd wrote (shield_source.glb / .json):
#
#   - the left arm's meshes (the rest of the shirt cut away, as for the right arm) on FPArms'
#     own left arm bones;
#   - controls: CTRL_shoulder_l (where the arm hangs from), CTRL_hand_l (the wrist: MOVE it to
#     move the shield arm, TURN it about the forearm to roll the forearm and the shield with it),
#     CTRL_elbow_l (which way the elbow points);
#   - the shield on the left forearm, where the game carries it (it is fixed to the forearm);
#   - keys: "hold" (the stance) and each recorded swing (the arm as the game moved it through
#     that swing before the clip had a shield arm: the stance with the counterweight), thinned.
#     The hand and fingers are keyed once (the game keeps the stance's grip on the handle).
#
# The game reads the left arm's joints and the forearm's turn (PlayerBody._rig_sample) and plays
# them as changes from "hold" (PlayerBody._hold_shield).
#
# Run it in the open Blender (the Blender MCP, or the Text editor). It stops if the scene already
# has CTRL_hand_l. Save the file afterwards, then export_clips.py.
import bpy, bmesh, json, math, os
from mathutils import Matrix, Vector, Quaternion

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(PROJECT, "animation_sources", "fp_arms")
ELBOW_BEND = 0.015  # as build_scene.py: Blender's IK cannot bend a straight chain
FACE_MARKER = 0.1   # m: the helper the forearm's roll follows, off the wrist along the forearm's X
LOCATION_TOLERANCE = 0.002
ROTATION_TOLERANCE = 0.002
FINGER_WORDS = ("Thumb", "Index", "Middle", "Ring", "Little")
LEFT_CONTROLS = ("CTRL_shoulder_l", "CTRL_hand_l", "CTRL_elbow_l")

# The game's axes (+X right, +Y up, -Z ahead) -> Blender's (+X right, +Z up, +Y ahead). As build_scene.py.
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
    src = json.load(open(os.path.join(SRC, "shield_source.json")))
    scene = bpy.context.scene
    arm = bpy.data.objects["FPArms"]
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    editing = arm.animation_data.action
    frame_was = scene.frame_current
    if "CTRL_hand_l" in arm.data.bones:
        # Already there: only the swings' shield arm is keyed again from the recording (hand edits
        # of the shield arm in those actions are replaced; the sword arm's keys are not touched).
        key_swings(arm, src)
        arm.animation_data.action = editing
        scene.frame_set(frame_was)
        print("FP_ARMS the shield arm was there: its keys in the recorded swings replaced (not saved)")
        return
    bones = src["bones"]

    # --- the left arm's meshes, moved onto FPArms' left arm ---
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "shield_source.glb"), bone_heuristic='BLENDER')
    imported = [o for o in bpy.data.objects if o not in before]
    source = [o for o in imported if o.type == 'ARMATURE'][0]
    bones = {n: b for n, b in bones.items() if n in source.data.bones and n in arm.data.bones}
    chain = set(bones.keys())
    # Each bone's rest in the eyes' space as the game's left copy has it (Blender's axes and bone
    # axes): the game's turns from rest are applied to these.
    source_rest = {n: source.matrix_world @ source.data.bones[n].matrix_local for n in chain}
    to_fp = (arm.matrix_world @ arm.data.bones["LeftUpperArm"].matrix_local) @ source_rest["LeftUpperArm"].inverted()
    print("FP_ARMS the left copy sits %.3f m and %.2f deg from FPArms' left arm at rest" % (to_fp.translation.length, math.degrees(to_fp.to_quaternion().angle)))
    meshes = []
    for o in imported:
        if o.type == 'MESH':
            kept = o.matrix_world.copy()
            o.parent = arm
            o.matrix_world = to_fp @ kept
            for m in o.modifiers:
                if m.type == 'ARMATURE':
                    m.object = arm
            o.name = o.name.split(".")[0] + "_left"
            meshes.append(o)
    for o in imported:
        if o not in meshes:
            bpy.data.objects.remove(o, do_unlink=True)
    for mesh in meshes:
        groups = {g.index: g.name for g in mesh.vertex_groups}
        bm = bmesh.new()
        bm.from_mesh(mesh.data)
        deform = bm.verts.layers.deform.active
        if deform is not None:
            gone = [v for v in bm.verts if sum(w for i, w in v[deform].items() if groups.get(i) in chain) < 0.5]
            bmesh.ops.delete(bm, geom=gone, context='VERTS')
        bm.to_mesh(mesh.data)
        bm.free()
        if len(mesh.data.vertices) == 0:
            bpy.data.objects.remove(mesh, do_unlink=True)

    # --- bones ---
    to_arm = arm.matrix_world.inverted()
    bpy.context.view_layer.objects.active = arm
    for o in bpy.context.selected_objects:
        o.select_set(False)
    arm.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    elbow_at = eb["LeftLowerArm"].head + to_arm.to_3x3() @ Vector((0, -ELBOW_BEND, 0))
    for child in eb["LeftUpperArm"].children:
        if child.head == eb["LeftLowerArm"].head:
            child.head = elbow_at.copy()
    eb["LeftLowerArm"].head = elbow_at.copy()
    eb["LeftUpperArm"].tail = elbow_at.copy()
    eb["LeftLowerArm"].tail = eb["LeftHand"].head.copy()

    def new_bone(name, head, tail, parent=None):
        b = eb.new(name)
        b.head, b.tail = head, tail
        b.parent = parent
        b.use_deform = False
        return b

    lower = eb["LeftLowerArm"]
    upper = eb["LeftUpperArm"]
    ctrl_hand = new_bone("CTRL_hand_l", lower.tail.copy(), lower.tail + (lower.tail - lower.head).normalized() * 0.12)
    ctrl_hand.roll = lower.roll
    marker_offset = source_rest["LeftLowerArm"].to_3x3().col[0].normalized() * FACE_MARKER
    new_bone("CTRL_shield_face_l", lower.tail + to_arm.to_3x3() @ marker_offset, lower.tail + to_arm.to_3x3() @ (marker_offset * 1.3), ctrl_hand)
    ctrl_shoulder = new_bone("CTRL_shoulder_l", upper.head.copy(), upper.head + to_arm.to_3x3() @ Vector((0, 0, 0.1)))
    upper.parent = ctrl_shoulder
    upper.use_connect = False
    new_bone("CTRL_elbow_l", elbow_at + to_arm.to_3x3() @ Vector((0, -0.3, 0)), elbow_at + to_arm.to_3x3() @ Vector((0, -0.3, 0.06)))
    # The IK solves a hidden copy of the arm (MCH_*): Blender's IK solver runs after the chain
    # bones' own constraints and overrides them, so a roll put on the IK's own forearm is lost
    # (found: the shield 6.4 deg off the game's through the whole swing).
    mch_upper = new_bone("MCH_upper_l", upper.head.copy(), upper.tail.copy(), ctrl_shoulder)
    mch_upper.roll = upper.roll
    mch_lower = new_bone("MCH_lower_l", lower.head.copy(), lower.tail.copy(), mch_upper)
    mch_lower.roll = lower.roll
    mch_lower.use_connect = True
    bpy.ops.object.mode_set(mode='POSE')

    pb = arm.pose.bones
    rest_world = {b.name: arm.matrix_world @ b.matrix_local for b in arm.data.bones}
    for name in LEFT_CONTROLS:
        pb[name].rotation_mode = 'QUATERNION'
    ik = pb["MCH_lower_l"].constraints.new('IK')
    ik.target, ik.subtarget = arm, "CTRL_hand_l"
    ik.pole_target, ik.pole_subtarget = arm, "CTRL_elbow_l"
    ik.chain_count = 2
    ik.use_stretch = False
    for name, mch in (("LeftUpperArm", "MCH_upper_l"), ("LeftLowerArm", "MCH_lower_l")):
        copy = pb[name].constraints.new('COPY_TRANSFORMS')
        copy.target, copy.subtarget = arm, mch
    # The forearm's roll: its X axis turned toward the marker on the hand control, about its own
    # length (which the IK set). So turning CTRL_hand_l about the forearm rolls the forearm and the
    # shield on it, as the game's forearm takes the roll of the hand's turn (WeaponHold.solve_arm).
    roll = pb["LeftLowerArm"].constraints.new('LOCKED_TRACK')
    roll.target, roll.subtarget = arm, "CTRL_shield_face_l"
    roll.track_axis, roll.lock_axis = 'TRACK_X', 'LOCK_Y'

    by_name = {c.name: c for c in arm.data.collections}
    for b in arm.data.bones:
        if b.name in LEFT_CONTROLS:
            for c in list(b.collections):
                c.unassign(b)
            by_name["Controls"].assign(b)
        elif b.name in ("CTRL_shield_face_l", "MCH_upper_l", "MCH_lower_l") or b.name in chain:
            for c in list(b.collections):
                c.unassign(b)
            fingerish = any(w in b.name for w in FINGER_WORDS) or b.name.endswith("metacarpal_l")
            by_name["Fingers" if fingerish and b.name in chain else "Arm"].assign(b)
    for name, colour in (("CTRL_hand_l", 'THEME01'), ("CTRL_shoulder_l", 'THEME03'), ("CTRL_elbow_l", 'THEME04')):
        arm.data.bones[name].color.palette = colour

    tools = make_tools(arm, src)
    pose, miss, set_world = tools["pose"], tools["miss"], tools["set_world"]

    # --- "hold": the stance; the pole's angle; the hand and fingers ---
    hold = bpy.data.actions["hold"]
    arm.animation_data.action = hold
    hold_frame = int(round(hold.frame_range[0]))
    scene.frame_set(hold_frame)
    stance = {n: bones[n]["pose"] for n in ("LeftUpperArm", "LeftLowerArm", "LeftHand")}
    pose(hold_frame, stance)
    best = (9.0, 0.0)
    for step in (math.radians(5), math.radians(0.25)):
        centre = best[1]
        for i in range(-36 if step > 0.01 else -20, 37 if step > 0.01 else 21):
            ik.pole_angle = centre + i * step
            bpy.context.view_layer.update()
            m = miss(stance)[0]
            if m < best[0]:
                best = (m, ik.pole_angle)
    ik.pole_angle = best[1]
    bpy.context.view_layer.update()
    print("FP_ARMS left pole angle %.2f deg: the stance's elbow / wrist within %.4f / %.4f m, the forearm's turn within %.2f deg" % ((math.degrees(best[1]),) + miss(stance)))
    # The hand and the fingers as the stance has them (their turns on their parents), kept for every action.
    grip = [n for n in chain if n == "LeftHand" or any(w in n for w in FINGER_WORDS) or n.endswith("metacarpal_l")]
    depth = lambda n: 0 if arm.data.bones[n].parent is None else 1 + depth(arm.data.bones[n].parent.name)
    grip.sort(key=depth)
    held = {}
    for name in grip:
        pb[name].rotation_mode = 'QUATERNION'
        g_pose, _ = gtransform(bones[name]["pose"])
        g_rest, _ = gtransform(bones[name]["rest"])
        wanted = to_blender(g_pose.normalized() @ g_rest.normalized().inverted()) @ source_rest[name].to_3x3().normalized()
        set_world(name, world(wanted, arm.matrix_world @ pb[name].head))
        pb[name].location = (0, 0, 0)
        bpy.context.view_layer.update()
        held[name] = pb[name].rotation_quaternion.copy()
        pb[name].keyframe_insert("rotation_quaternion", frame=hold_frame)

    # --- the shield, on the forearm as the stance carries it ---
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROJECT, src["shield_scene"].replace("res://", "")))
    shield_objects = [o for o in bpy.data.objects if o not in before]
    for o in shield_objects:
        if o.type == 'EMPTY' and not o.children:
            bpy.data.objects.remove(o, do_unlink=True)
    shield_objects = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in shield_objects if o.parent is None or o.parent not in shield_objects]
    shield = bpy.data.objects.new("Shield", None)
    scene.collection.objects.link(shield)
    for o in roots:
        o.parent = shield
    shield.parent = arm
    shield.parent_type = 'BONE'
    shield.parent_bone = "LeftLowerArm"
    bpy.context.view_layer.update()
    shield_b, shield_at = gtransform(src["shield"])
    shield.matrix_world = world(to_blender(shield_b), gv(shield_at))
    for o in shield_objects:
        o.hide_select = True

    # --- the swings, as the game moved the arm through them ---
    key_swings(arm, src)

    # The game's materials on the new meshes (game_materials.py names them).
    import importlib.util
    spec = importlib.util.spec_from_file_location("fp_arms_game_materials", os.path.join(HERE, "game_materials.py"))
    materials = importlib.util.module_from_spec(spec)
    materials.__file__ = os.path.join(HERE, "game_materials.py")
    spec.loader.exec_module(materials)
    materials.apply()

    arm.animation_data.action = editing
    scene.frame_set(frame_was)
    bpy.ops.object.mode_set(mode='OBJECT')
    left_meshes = [o.name for o in arm.children if o.type == 'MESH' and o.name.endswith("_left")]
    print("FP_ARMS shield arm added (not saved): meshes %s, controls %s" % (", ".join(left_meshes), ", ".join(LEFT_CONTROLS)))


def make_tools(arm, src):
    """What keys the shield arm: pose(frame, at) keys the controls for the game's left arm `at`
    (bone name -> Godot transform array, eyes' space); miss(at) is how far the posed elbow and
    wrist are from it (m) and how far the forearm's change from the hold is from the game's (deg;
    0 until hold_forearm is set)."""
    pb = arm.pose.bones
    to_arm = arm.matrix_world.inverted()
    rest_world = {b.name: arm.matrix_world @ b.matrix_local for b in arm.data.bones}
    lower_rest_game = gtransform(src["bones"]["LeftLowerArm"]["rest"])[0].normalized()
    stance_lower = gtransform(src["bones"]["LeftLowerArm"]["pose"])[0].normalized()
    tools = {"previous": {}, "hold_forearm": None}

    def key_quaternion(name, frame):
        q = pb[name].rotation_quaternion
        last = tools["previous"].get(name)
        if last is not None and q.dot(last) < 0.0:
            pb[name].rotation_quaternion = -q
        tools["previous"][name] = pb[name].rotation_quaternion.copy()
        pb[name].keyframe_insert("rotation_quaternion", frame=frame)

    def set_world(name, matrix):
        pb[name].matrix = to_arm @ matrix

    def pose(frame, at):
        shoulder = gtransform(at["LeftUpperArm"])[1]
        elbow = gtransform(at["LeftLowerArm"])[1]
        lower_b = gtransform(at["LeftLowerArm"])[0]
        wrist = gtransform(at["LeftHand"])[1]
        turn = to_blender(lower_b.normalized() @ lower_rest_game.inverted())
        set_world("CTRL_shoulder_l", world(rest_world["CTRL_shoulder_l"].to_3x3(), gv(shoulder)))
        set_world("CTRL_hand_l", world(turn @ rest_world["CTRL_hand_l"].to_3x3(), gv(wrist)))
        foot = shoulder + (wrist - shoulder) * max(0.0, min(1.0, (elbow - shoulder).dot(wrist - shoulder) / max((wrist - shoulder).length_squared, 1e-9)))
        out = elbow - foot
        out = out.normalized() if out.length > 1e-4 else Vector((0, -1, 0))
        set_world("CTRL_elbow_l", world(rest_world["CTRL_elbow_l"].to_3x3(), gv(elbow + out * 0.4)))
        for name in LEFT_CONTROLS:
            pb[name].keyframe_insert("location", frame=frame)
        key_quaternion("CTRL_hand_l", frame)
        bpy.context.view_layer.update()

    def miss(at):
        elbow = gv(gtransform(at["LeftLowerArm"])[1])
        wrist = gv(gtransform(at["LeftHand"])[1])
        turned = 0.0
        if tools["hold_forearm"] is not None:
            lower_b = gtransform(at["LeftLowerArm"])[0].normalized()
            wanted = to_blender(lower_b @ stance_lower.inverted()) @ tools["hold_forearm"]
            now = (arm.matrix_world @ pb["LeftLowerArm"].matrix).to_3x3().normalized()
            turned = math.degrees((now @ wanted.inverted()).to_quaternion().angle)
        return ((arm.matrix_world @ pb["LeftLowerArm"].head) - elbow).length, ((arm.matrix_world @ pb["LeftLowerArm"].tail) - wrist).length, turned

    tools.update({"pose": pose, "miss": miss, "set_world": set_world, "key_quaternion": key_quaternion})
    return tools


def key_swings(arm, src):
    """Keys the shield arm in every recorded swing (src["swings"]): its controls on every frame,
    then thinned; the hand and fingers once, as "hold" has them. Keys of the shield arm already in
    those actions are removed first."""
    scene = bpy.context.scene
    pb = arm.pose.bones
    tools = make_tools(arm, src)
    hold = bpy.data.actions["hold"]
    arm.animation_data.action = hold
    scene.frame_set(int(round(hold.frame_range[0])))
    tools["hold_forearm"] = (arm.matrix_world @ pb["LeftLowerArm"].matrix).to_3x3().normalized()
    grip = [n for n in src["bones"] if n in pb and (n == "LeftHand" or any(w in n for w in FINGER_WORDS) or n.endswith("metacarpal_l"))]
    held = {n: pb[n].rotation_quaternion.copy() for n in grip}
    paths = ["pose.bones[\"%s\"]" % n for n in list(LEFT_CONTROLS) + grip]
    for action_name, frames in src["swings"].items():
        action = bpy.data.actions.get(action_name)
        if action is None:
            print("FP_ARMS no action %s in the scene: its recording is left out" % action_name)
            continue
        for layer in action.layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    for fc in list(bag.fcurves):
                        if any(fc.data_path.startswith(p + ".") for p in paths):
                            bag.fcurves.remove(fc)
        arm.animation_data.action = action
        tools["previous"].clear()
        # Frame 0 is the swing's start, as recorded (the exporter slides the clip's first key to 0).
        # Not the action's first key: a key before 0 (one was keyed at -3) put the arm 3 frames early.
        first = 0
        for i, at in enumerate(frames):
            scene.frame_set(first + i)
            tools["pose"](first + i, at)
        for name in grip:
            pb[name].rotation_quaternion = held[name]
            pb[name].keyframe_insert("rotation_quaternion", frame=first)
        thin(action, ["pose.bones[\"%s\"]" % n for n in LEFT_CONTROLS])
        worst = [0.0, 0.0, 0.0]
        for i, at in enumerate(frames):
            scene.frame_set(first + i)
            worst = [max(a, b) for a, b in zip(worst, tools["miss"](at))]
        print("FP_ARMS %s: %d frames keyed from the game; after thinning the elbow / wrist within %.4f / %.4f m, the forearm's change within %.2f deg" % ((action_name, len(frames)) + tuple(worst)))


def thin(action, prefixes):
    """build_scene.py's thinning, for the curves under `prefixes` only (the hand-edited sword
    arm's curves are left alone)."""
    by_bone = {}
    for fc in fcurves_of(action):
        if any(fc.data_path.startswith(p) for p in prefixes):
            by_bone.setdefault(fc.data_path, []).append(fc)
    for path, curves in by_bone.items():
        frames = sorted({k.co[0] for fc in curves for k in fc.keyframe_points})
        if len(frames) < 3:
            continue
        values = [[fc.evaluate(f) for f in frames] for fc in curves]
        tolerance = [LOCATION_TOLERANCE if fc.data_path.endswith("location") else ROTATION_TOLERANCE for fc in curves]
        keep = {0, len(frames) - 1}

        def split(a, b):
            worst, at = 0.0, None
            for i in range(a + 1, b):
                share = (frames[i] - frames[a]) / (frames[b] - frames[a])
                miss = max(abs(v[i] - (v[a] + (v[b] - v[a]) * share)) / t for v, t in zip(values, tolerance))
                if miss > worst:
                    worst, at = miss, i
            if at is not None and worst > 1.0:
                keep.add(at)
                split(a, at)
                split(at, b)

        split(0, len(frames) - 1)
        kept_frames = {frames[i] for i in keep}
        for fc in curves:
            for k in reversed(list(fc.keyframe_points)):
                if k.co[0] not in kept_frames:
                    fc.keyframe_points.remove(k)
            for k in fc.keyframe_points:
                k.handle_left_type = k.handle_right_type = 'AUTO_CLAMPED'
            fc.update()


main()
