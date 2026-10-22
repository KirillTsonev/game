# Step 2 of the Blender arm pipeline (docs/blender_animation.md): builds
# animation_sources/fp_arms/fp_arms.blend, the scene first-person moves are animated in, from what
# export_arm_source.gd wrote (arm_source.glb / .json):
#
#   - the world is the EYES' space: origin at the eyes, +Y ahead, +Z up (the game's -Z ahead, +Y up);
#   - "Eyes": a camera at the eyes with the game's field of view, on the Eyes bone (turning that
#     bone is the head's turn, nod and tilt during a move -- PlayerBody's view offset);
#   - "FPArms": the rogue's right arm as the game draws it apart, the other meshes cut away, with
#     controls: CTRL_shoulder (where the arm hangs from), CTRL_hand (the hand: move AND turn it),
#     CTRL_elbow (which way the elbow points), and the Weapon bone (the sword's place in the
#     fist; turn it to turn the handle in the hand). Fingers are plain bones (rotate them).
#   - the sword on the Weapon bone;
#   - actions: "hold" (the stance as the game holds it, one frame) and one per entry of SWINGS
#     below, made from the game's copied ArmClip so there is something to adjust.
#
# Run it in an open Blender (the Blender MCP, or the Text editor) or in the background:
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup --python tools/blender/fp_arms/build_scene.py
# It clears the open scene first. Re-running it REBUILDS the actions from the ArmClips: edits made
# in Blender are lost -- once a move has been adjusted by hand, take it out of SWINGS.
import bpy, bmesh, json, math, os
from mathutils import Matrix, Vector, Quaternion

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(PROJECT, "animation_sources", "fp_arms")
BLEND = os.path.join(SRC, "fp_arms.blend")
FPS = 30
# Action name -> (ArmClip in assets/animations/first_person/, from s, to s, wind-up frames,
# recovery frames): the window of the clip PlayerBody.SWINGS played, after a wind-up from the hold
# (frame 1 = the stance; the window starts on frame 1 + wind-up) and before a recovery back into it
# (the stance again, recovery frames after the window's last). Blender's interpolation in both is
# a draft to shape by hand. The game's entry must match the clip's length (clip_to) and its times.
SWINGS = {
    "swing_down": ("stances_high_attackright.json", 0.27, 0.82, 6, 14),
}
# Keys are thinned to what reproduces the clip within these (m, quaternion component), so that
# the curves can be edited; 0 keeps a key on every frame.
LOCATION_TOLERANCE = 0.004
ROTATION_TOLERANCE = 0.004

FINGER_WORDS = ("Thumb", "Index", "Middle", "Ring", "Little")
ELBOW_BEND = 0.015  # m the elbow joint sits behind the straight T-pose arm (see the edit-bone step)

# The game's axes (+X right, +Y up, -Z ahead) -> Blender's (+X right, +Z up, +Y ahead).
C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def gv(v):
    return C @ Vector(v)


def gbasis(a):  # a Godot Basis from its three columns
    return Matrix((a[0:3], a[3:6], a[6:9])).transposed()


def gtransform(a):  # (basis, origin), still in the game's axes
    return gbasis(a[0:9]), Vector(a[9:12])


def to_blender(basis):  # a turn in the game's axes, in Blender's
    return C @ basis @ C.transposed()


def world(rotation, at):
    m = rotation.to_4x4()
    m.translation = at
    return m


def fcurves_of(action):
    if hasattr(action, "fcurves"):
        try:
            return list(action.fcurves)
        except Exception:
            pass
    out = []
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                out.extend(bag.fcurves)
    return out


def clear_scene():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for data in (bpy.data.meshes, bpy.data.armatures, bpy.data.cameras, bpy.data.actions, bpy.data.materials, bpy.data.lights, bpy.data.images):
        for d in list(data):
            data.remove(d)


def main():
    src = json.load(open(os.path.join(SRC, "arm_source.json")))
    bones = src["bones"]
    clear_scene()
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.render.resolution_x, scene.render.resolution_y = 1920, 1080

    # --- the arm ---
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "arm_source.glb"), bone_heuristic='BLENDER')
    imported = [o for o in bpy.data.objects if o not in before]
    arm = [o for o in imported if o.type == 'ARMATURE'][0]
    for o in imported:
        if o.type == 'ARMATURE' or (o.type == 'MESH' and o.parent and o.parent.type != 'ARMATURE'):
            kept = o.matrix_world.copy()
            o.parent = None if o.type == 'ARMATURE' else arm
            o.matrix_world = kept
    for o in imported:
        if o.type == 'EMPTY' or (o.type == 'MESH' and o.parent != arm):
            bpy.data.objects.remove(o, do_unlink=True)
    arm.name = arm.data.name = "FPArms"
    meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.parent == arm]
    # Leaf helper bones with no weights (weapon_r, some twist helpers) do not come through the import.
    bones = {n: b for n, b in bones.items() if n in arm.data.bones}
    chain = set(bones.keys())
    # Only what the arm's bones carry: the rest of the shirt and gloves is shrunk into the shoulder
    # in the game (PlayerBody._draw_arm_apart).
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
    meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.parent == arm]

    to_arm = arm.matrix_world.inverted()
    # The import must have put the bones where the game has them at rest.
    worst = max((arm.matrix_world @ arm.data.bones[n].head_local - gv(gtransform(bones[n]["rest"])[1])).length for n in chain)
    print("FP_ARMS rest check: bones at most %.4f m from the game's rest" % worst)

    # --- bones ---
    bpy.context.view_layer.objects.active = arm
    arm.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = arm.data.edit_bones
    # The T-pose arm is perfectly straight, and Blender's IK cannot bend a straight chain (it points
    # it past the target): the elbow joint is set ELBOW_BEND back from the line, so the rest itself
    # is bent and nothing (Alt+R, an exporter resetting the pose) can take the bend away. A pose
    # rotation for this was tried first and was reset by the exporter. The game reads only the
    # joints' places and the hand's turn, and the upper arm is ELBOW_BEND^2 / 2 / 0.285 longer.
    elbow_at = eb["RightLowerArm"].head + to_arm.to_3x3() @ Vector((0, -ELBOW_BEND, 0))
    for child in eb["RightUpperArm"].children:
        if child.head == eb["RightLowerArm"].head:
            child.head = elbow_at.copy()
    eb["RightLowerArm"].head = elbow_at.copy()
    eb["RightUpperArm"].tail = elbow_at.copy()
    eb["RightLowerArm"].tail = eb["RightHand"].head.copy()
    hand_rest_b, hand_rest_at = gtransform(bones["RightHand"]["rest"])
    socket_b, socket_at = gtransform(src["socket"])
    hand_pose_b, _ = gtransform(bones["RightHand"]["pose"])
    sword_b, _ = gtransform(src["sword"])
    grip_rest = hand_rest_at + hand_rest_b @ socket_at
    # The blade (the sword scene's +Z) as it lies with the hand at rest.
    blade_rest = (hand_rest_b @ hand_pose_b.inverted() @ sword_b.col[2]).normalized()

    def new_bone(name, head, tail, parent=None, deform=False):
        b = eb.new(name)
        b.head, b.tail = head, tail
        b.parent = parent
        b.use_deform = deform
        return b

    new_bone("Eyes", to_arm @ Vector((0, 0, 0)), to_arm @ Vector((0, 0.05, 0)), deform=True)
    new_bone("Weapon", to_arm @ gv(grip_rest), to_arm @ gv(grip_rest + blade_rest * 0.25), eb["RightHand"], deform=True)
    hand = eb["RightHand"]
    ctrl_hand = new_bone("CTRL_hand", hand.head.copy(), hand.tail.copy())
    ctrl_hand.roll = hand.roll
    ctrl_hand.length = 0.12
    upper = eb["RightUpperArm"]
    ctrl_shoulder = new_bone("CTRL_shoulder", upper.head.copy(), upper.head + to_arm.to_3x3() @ Vector((0, 0, 0.1)))
    upper.parent = ctrl_shoulder  # the arm hangs from the control, as the game's drawn-apart arm hangs from its shoulder
    upper.use_connect = False
    elbow = eb["RightLowerArm"].head
    new_bone("CTRL_elbow", elbow + to_arm.to_3x3() @ Vector((0, -0.3, 0)), elbow + to_arm.to_3x3() @ Vector((0, -0.3, 0.06)))
    bpy.ops.object.mode_set(mode='POSE')

    pb = arm.pose.bones
    rest_world = {b.name: arm.matrix_world @ b.matrix_local for b in arm.data.bones}
    for name in ("CTRL_hand", "CTRL_shoulder", "CTRL_elbow", "Eyes", "Weapon"):
        pb[name].rotation_mode = 'QUATERNION'
    ik = pb["RightLowerArm"].constraints.new('IK')
    ik.target, ik.subtarget = arm, "CTRL_hand"
    ik.pole_target, ik.pole_subtarget = arm, "CTRL_elbow"
    ik.chain_count = 2
    ik.use_stretch = False
    turn = pb["RightHand"].constraints.new('COPY_ROTATION')
    turn.target, turn.subtarget = arm, "CTRL_hand"

    # Bone collections: only what is animated is shown -- the controls and the fingers. The arm's
    # own bones (driven by the IK) and the body are hidden.
    collections = {n: arm.data.collections.new(n) for n in ("Controls", "Fingers", "Arm", "Body")}
    for b in arm.data.bones:
        if b.name.startswith("CTRL_") or b.name in ("Eyes", "Weapon"):
            collections["Controls"].assign(b)
        elif b.name in chain and (any(w in b.name for w in FINGER_WORDS) or b.name.endswith("metacarpal_r")):
            collections["Fingers"].assign(b)
        elif b.name in chain:
            collections["Arm"].assign(b)
        else:
            collections["Body"].assign(b)
    collections["Arm"].is_visible = False
    collections["Body"].is_visible = False
    for name, colour in (("CTRL_hand", 'THEME01'), ("CTRL_shoulder", 'THEME03'), ("CTRL_elbow", 'THEME04'), ("Eyes", 'THEME09'), ("Weapon", 'THEME02')):
        arm.data.bones[name].color.palette = colour
    # Octahedral, sized by each bone's length. B-bones were tried: the import made their boxes
    # far thicker than an arm, and drawn in front they hid it (Kirill: "a bunch of blocks").
    arm.data.display_type = 'OCTAHEDRAL'
    arm.show_in_front = True

    palm_out, fingers_out = Vector(src["palm_out"]), Vector(src["fingers_out"])
    # The marker's axes (-X the palm, +Y the thumb's side, -Z the fingers) in the hand bone's: ArmClip's "hand".
    K = Matrix((-palm_out, fingers_out.cross(palm_out), -fingers_out)).transposed()
    socket_in_grip = Matrix(((0, 0, -1), (0, 1, 0), (1, 0, 0))).transposed()  # WeaponStance.SOCKET_IN_GRIP (columns)
    fingers = [n for n in bones if any(w in n for w in FINGER_WORDS) or n.endswith("metacarpal_r")]
    depth = lambda n: 0 if arm.data.bones[n].parent is None else 1 + depth(arm.data.bones[n].parent.name)
    fingers.sort(key=depth)
    previous = {}

    def key_quaternion(name, frame):
        q = pb[name].rotation_quaternion
        last = previous.get(name)
        if last is not None and q.dot(last) < 0.0:
            pb[name].rotation_quaternion = -q
        previous[name] = pb[name].rotation_quaternion.copy()
        pb[name].keyframe_insert("rotation_quaternion", frame=frame)

    def set_world(name, matrix):
        pb[name].matrix = to_arm @ matrix

    def pose(frame, shoulder, elbow, wrist, hand_b, socket, view):
        """One frame, all in the game's eye space: the arm's three joints, the hand bone's turn,
        the sword's socket in the hand (game hand-bone axes), the head's turn (degrees)."""
        set_world("CTRL_shoulder", world(rest_world["CTRL_shoulder"].to_3x3(), gv(shoulder)))
        set_world("CTRL_hand", world(to_blender(hand_b @ hand_rest_b.inverted()) @ rest_world["CTRL_hand"].to_3x3(), gv(wrist)))
        foot = shoulder + (wrist - shoulder) * max(0.0, min(1.0, (elbow - shoulder).dot(wrist - shoulder) / max((wrist - shoulder).length_squared, 1e-9)))
        out = elbow - foot
        out = out.normalized() if out.length > 1e-4 else Vector((0, -1, 0))
        set_world("CTRL_elbow", world(rest_world["CTRL_elbow"].to_3x3(), gv(elbow + out * 0.4)))
        v = Matrix.Rotation(-math.radians(view[0]), 3, 'Y') @ Matrix.Rotation(math.radians(view[1]), 3, 'X') @ Matrix.Rotation(math.radians(view[2]), 3, 'Z')
        set_world("Eyes", world(to_blender(v) @ rest_world["Eyes"].to_3x3(), rest_world["Eyes"].translation))
        for name in ("CTRL_shoulder", "CTRL_hand", "CTRL_elbow"):
            pb[name].keyframe_insert("location", frame=frame)
        for name in ("CTRL_hand", "Eyes"):
            key_quaternion(name, frame)
        bpy.context.view_layer.update()
        socket_b_now, socket_at_now = socket
        grip_now = hand_b @ socket_b_now
        grip_then = hand_rest_b @ socket_b
        evaluated_hand = arm.matrix_world @ pb["RightHand"].matrix
        set_world("Weapon", world(to_blender(grip_now @ grip_then.inverted()) @ rest_world["Weapon"].to_3x3(), evaluated_hand.translation + C @ (hand_b @ socket_at_now)))
        pb["Weapon"].keyframe_insert("location", frame=frame)
        key_quaternion("Weapon", frame)

    def pose_fingers(frame):
        """The stance's fingers (as posed by hand in the editor), turned with the hand."""
        for name in fingers:
            g_pose, _ = gtransform(bones[name]["pose"])
            g_rest, _ = gtransform(bones[name]["rest"])
            relative = hand_pose_b.inverted() @ g_pose  # the finger against the hand, as the stance has it
            evaluated_hand = (arm.matrix_world @ pb["RightHand"].matrix).to_3x3()
            hand_now = C.transposed() @ evaluated_hand @ (C.transposed() @ rest_world["RightHand"].to_3x3()).inverted() @ hand_rest_b
            game_now = hand_now @ relative
            set_world(name, world(to_blender(game_now @ g_rest.inverted()) @ rest_world[name].to_3x3(), arm.matrix_world @ pb[name].head))
            pb[name].location = (0, 0, 0)
            key_quaternion(name, frame)
            bpy.context.view_layer.update()

    def stance_frame():
        at = lambda n: gtransform(bones[n]["pose"])[1]
        return at("RightUpperArm"), at("RightLowerArm"), at("RightHand"), hand_pose_b, (socket_b, socket_at), (0.0, 0.0, 0.0)

    arm.animation_data_create()
    actions = []

    def begin(name):
        action = bpy.data.actions.new(name)
        action.use_fake_user = True
        arm.animation_data.action = action
        previous.clear()
        actions.append(action)
        return action

    # --- "hold": the stance; also where the elbow pole's angle is found ---
    begin("hold")
    shoulder, elbow, wrist, hand_b, socket, view = stance_frame()
    pose(1, shoulder, elbow, wrist, hand_b, socket, view)
    best = (9.0, 0.0)
    for step in (math.radians(5), math.radians(0.25)):
        centre = best[1]
        for i in range(-36 if step > 0.01 else -20, 37 if step > 0.01 else 21):
            ik.pole_angle = centre + i * step
            bpy.context.view_layer.update()
            miss = ((arm.matrix_world @ pb["RightLowerArm"].head) - gv(elbow)).length
            if miss < best[0]:
                best = (miss, ik.pole_angle)
    ik.pole_angle = best[1]
    bpy.context.view_layer.update()
    wrist_miss = ((arm.matrix_world @ pb["RightHand"].head) - gv(wrist)).length
    print("FP_ARMS pole angle %.2f deg: the stance's elbow within %.4f m, wrist within %.4f m" % (math.degrees(best[1]), best[0], wrist_miss))
    pose_fingers(1)

    # --- the sword, held as the stance holds it ---
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROJECT, src["sword_scene"].replace("res://", "")))
    sword_objects = [o for o in bpy.data.objects if o not in before]
    for o in sword_objects:
        if o.type == 'EMPTY' and not o.children:
            bpy.data.objects.remove(o, do_unlink=True)
    sword_objects = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in sword_objects if o.parent is None or o.parent not in sword_objects]
    sword = bpy.data.objects.new("Sword", None)
    scene.collection.objects.link(sword)
    for o in roots:
        o.parent = sword
    bpy.context.view_layer.update()
    sword.parent = arm
    sword.parent_type = 'BONE'
    sword.parent_bone = "Weapon"
    bpy.context.view_layer.update()
    sword_at = gtransform(src["sword"])
    sword.matrix_world = world(to_blender(sword_at[0]), gv(sword_at[1]))
    for o in sword_objects:
        o.hide_select = True  # select the Weapon bone to move it

    # --- the camera ---
    camera = bpy.data.objects.new("EyesCamera", bpy.data.cameras.new("EyesCamera"))
    scene.collection.objects.link(camera)
    camera.data.sensor_fit = 'VERTICAL'
    camera.data.angle_y = math.radians(src["fov"])
    camera.data.clip_start = 0.01
    camera.parent = arm
    camera.parent_type = 'BONE'
    camera.parent_bone = "Eyes"
    bpy.context.view_layer.update()
    camera.matrix_world = Matrix.Rotation(math.pi / 2, 4, 'X')
    camera.hide_select = True
    scene.camera = camera
    light = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
    scene.collection.objects.link(light)
    light.rotation_euler = (math.radians(50), 0, math.radians(30))

    # --- the swings ---
    for name, (clip_file, start, end, wind, recover) in SWINGS.items():
        clip = json.load(open(os.path.join(PROJECT, "assets", "animations", "first_person", clip_file)))
        frames = clip["frames"]
        clip_fps = clip.get("fps", 30.0)

        def sample(t):
            at = t * clip_fps
            i = min(int(at), len(frames) - 1)
            j = min(i + 1, len(frames) - 1)
            part = at - i
            a, b = frames[i], frames[j]
            lerp = lambda k: Vector(a[k]).lerp(Vector(b[k]), part)
            turn = lambda k: gbasis(a[k]).to_quaternion().slerp(gbasis(b[k]).to_quaternion(), part).to_matrix()
            return {"shoulder": lerp("shoulder"), "elbow": lerp("elbow"), "wrist": lerp("wrist"), "hand": turn("hand"),
                    "grip": turn("grip"), "grip_at": lerp("grip_at"), "view": lerp("view") if "view" in a else Vector()}

        begin(name)
        count = int(round((end - start) * FPS)) + 1
        targets = []
        if wind > 0:
            pose(1, *stance_frame())
            pose_fingers(1)
        for f in range(count):
            s = sample(start + f / FPS)
            shoulder, elbow, wrist = s["shoulder"], s["elbow"], s["wrist"]
            # As PlayerBody._clip_swing_pose: the wrist's reach scaled by our arm over the clip's.
            theirs = (elbow - shoulder).length + (wrist - elbow).length
            wrist = shoulder + (wrist - shoulder) * (src["arm_length"] / max(theirs, 0.01))
            marker = s["hand"].to_quaternion().to_matrix()
            hand_b = marker @ K.inverted()
            socket = (K @ s["grip"].to_quaternion().to_matrix() @ socket_in_grip, K @ s["grip_at"])
            pose(f + 1 + wind, shoulder, elbow, wrist, hand_b, socket, s["view"])
            targets.append((elbow, wrist))
            if f == 0 and wind == 0:
                pose_fingers(1)
        if recover > 0:
            pose(count + wind + recover, *stance_frame())
        thin(arm, bpy.data.actions[name])
        miss = 0.0
        for f, (elbow, wrist) in enumerate(targets):
            scene.frame_set(f + 1 + wind)
            miss = max(miss, ((arm.matrix_world @ pb["RightHand"].head) - gv(wrist)).length, ((arm.matrix_world @ pb["RightLowerArm"].head) - gv(elbow)).length)
        print("FP_ARMS %s: %d frames (%.2f s) from %s %.2f-%.2f s; after thinning the wrist and elbow within %.4f m of the clip" % (name, count, (count - 1) / FPS, clip_file, start, end, miss))

    # The game's materials (game_materials.py), for the 3D view's Material Preview.
    import importlib.util
    spec = importlib.util.spec_from_file_location("fp_arms_game_materials", os.path.join(HERE, "game_materials.py"))
    materials = importlib.util.module_from_spec(spec)
    materials.__file__ = os.path.join(HERE, "game_materials.py")
    spec.loader.exec_module(materials)
    materials.apply()

    # The first swing is the one open for editing (the Action editor switches to another).
    edit = actions[1] if len(actions) > 1 else actions[0]
    arm.animation_data.action = edit
    scene.frame_start, scene.frame_end = 1, max(2, int(round(edit.frame_range[1])))
    scene.frame_set(1)
    bpy.ops.object.mode_set(mode='OBJECT')
    try:
        for area in bpy.context.screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces[0].region_3d.view_perspective = 'CAMERA'
                area.spaces[0].clip_start = 0.01
    except Exception:
        pass
    bpy.ops.wm.save_as_mainfile(filepath=BLEND)
    print("FP_ARMS saved %s (actions: %s)" % (BLEND, ", ".join(a.name for a in actions)))


def thin(arm, action):
    """Keeps the keys a straight line between kept keys cannot replace within the tolerances, the
    same frames for every channel of one bone (so a bone's quaternion stays whole)."""
    if LOCATION_TOLERANCE <= 0.0:
        return
    by_bone = {}
    for fc in fcurves_of(action):
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
