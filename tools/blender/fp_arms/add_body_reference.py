# The body as a reference in animation_sources/fp_arms/fp_arms.blend (docs/blender_animation.md, "The
# body as a reference"): imports what export_body_source.gd wrote (body_source.glb / .json) as its
# own armature BodyRef in the collection "Body reference" -- not under FPArms, so export_clips.py
# leaves it out -- and keys it on every frame as the game moves the body through the swing: each
# bone by its turn (and move, and scale: the body's own arms are shrunk into the shoulders) from its
# rest, so the two programs' bone axes are never compared. Nothing of it can be selected.
#
# Run it in the open Blender (the Blender MCP, or the Text editor) after export_body_source.gd; it
# replaces a reference already there. Save the file afterwards. The recording leaves the swing's
# chest turn out; the reference's spine follows CTRL_chest live (constraints, a third of its turn on
# each spine bone, as the game), so editing the chest needs no new recording.
import bpy, json, os
from mathutils import Matrix, Vector

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(PROJECT, "animation_sources", "fp_arms")
COLLECTION = "Body reference"
ARMATURE = "BodyRef"
SPINE = ("Spine", "Chest", "UpperChest")  # PlayerBody.POSTURE_SPINE: the bones the swing's chest turn is shared by

# The game's axes (+X right, +Y up, -Z ahead) -> Blender's (+X right, +Z up, +Y ahead). As build_scene.py.
C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def gmatrix(a):
    """A transform written by export_body_source.gd (basis columns, then origin) in Blender's axes."""
    basis = Matrix((a[0:3], a[3:6], a[6:9])).transposed()
    m = (C @ basis @ C.transposed()).to_4x4()
    m.translation = C @ Vector(a[9:12])
    return m


def remove_old():
    old = bpy.data.collections.get(COLLECTION)
    if old:
        for o in list(old.all_objects):
            data = o.data
            bpy.data.objects.remove(o, do_unlink=True)
            if data is not None and data.users == 0:
                if isinstance(data, bpy.types.Mesh):
                    bpy.data.meshes.remove(data)
                elif isinstance(data, bpy.types.Armature):
                    bpy.data.armatures.remove(data)
        bpy.data.collections.remove(old)
    action = bpy.data.actions.get("body_reference")
    if action:
        bpy.data.actions.remove(action)


def main():
    if getattr(bpy.context, "object", None) and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    remove_old()
    data = json.load(open(os.path.join(SRC, "body_source.json")))
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "body_source.glb"), bone_heuristic='BLENDER')
    imported = [o for o in bpy.data.objects if o not in before]
    collection = bpy.data.collections.new(COLLECTION)
    bpy.context.scene.collection.children.link(collection)
    arm = [o for o in imported if o.type == 'ARMATURE'][0]
    # The importer's sphere it draws bones with is no part of the body.
    for o in [o for o in imported if o.name.startswith("Icosphere")]:
        imported.remove(o)
        bpy.data.objects.remove(o, do_unlink=True)
    meshes = [o for o in imported if o.type == 'MESH']
    # Out of the importer's empties, keeping where everything is.
    for o in [arm] + meshes:
        kept = o.matrix_world.copy()
        if o is arm or o.parent is not arm:
            o.parent = None if o is arm else arm
        o.matrix_world = kept
    for o in imported:
        for c in list(o.users_collection):
            c.objects.unlink(o)
        if o.type == 'EMPTY':
            bpy.data.objects.remove(o, do_unlink=True)
        else:
            collection.objects.link(o)
    arm.name = ARMATURE
    arm.data.name = ARMATURE
    arm.show_in_front = False
    arm.hide_viewport = False
    arm.data.display_type = 'STICK'
    arm.hide_set(False)
    for m in meshes:
        m.name = m.name.split(".")[0] + "_body"
    for o in [arm] + meshes:
        o.hide_select = True
    arm.hide_set(True)  # its bones drawn over everything; the meshes still follow it
    # The game's materials (game_materials.py builds them by name; the import's copies end in .00n).
    for m in meshes:
        for slot in m.material_slots:
            if slot.material:
                shared = bpy.data.materials.get(slot.material.name.split(".")[0])
                if shared is None:
                    slot.material.name = slot.material.name.split(".")[0]
                    shared = slot.material
                slot.material = shared
    import importlib.util
    spec = importlib.util.spec_from_file_location("fp_arms_game_materials", os.path.join(HERE, "game_materials.py"))
    materials = importlib.util.module_from_spec(spec)
    materials.__file__ = os.path.join(HERE, "game_materials.py")
    spec.loader.exec_module(materials)
    materials.apply()

    # The keys: each bone's armature-space matrix from the game's, by its change from the rest.
    bones = arm.data.bones
    to_arm = arm.matrix_world.inverted()
    rest_game = {n: gmatrix(a) for n, a in data["rest"].items()}
    order = sorted([b for b in bones if b.name in rest_game], key=lambda b: len(b.parent_recursive))
    action = bpy.data.actions.new("body_reference")
    action.use_fake_user = True
    arm.animation_data_create()
    arm.animation_data.action = action
    pb = arm.pose.bones
    for name in rest_game:
        if name in pb:
            pb[name].rotation_mode = 'QUATERNION'
    for f, frame in enumerate(data["frames"]):
        wanted = {}
        for b in order:
            # The world as the game has it now = its change from the game's rest applied to Blender's rest.
            world = gmatrix(frame[b.name]) @ rest_game[b.name].inverted() @ (arm.matrix_world @ b.matrix_local)
            wanted[b.name] = to_arm @ world
            if b.parent is not None and b.parent.name in wanted:
                parent = wanted[b.parent.name] @ (b.parent.matrix_local.inverted() @ b.matrix_local)
            else:
                parent = b.matrix_local
            basis = parent.inverted() @ wanted[b.name]
            loc, rot, scale = basis.decompose()
            p = pb[b.name]
            p.location, p.rotation_quaternion, p.scale = loc, rot, scale
            p.keyframe_insert("location", frame=f)
            p.keyframe_insert("rotation_quaternion", frame=f)
            p.keyframe_insert("scale", frame=f)
    # The chest as CTRL_chest turns it, live (the recording leaves the swing's chest turn out): a third
    # of its turn on each spine bone, as PlayerBody._turn_chest_with_swing shares it. Its own turn only
    # (local): the view's turn of its parent VIEW_arms (the look-down preview) is not the body's.
    # Where the head is on each frame, as recorded: the game keeps the camera at the eyes and moves
    # the body under it (PlayerBody: "the model moves instead"), so as the chest turns the head stays
    # put against the eyes and the rest of the body shifts. view_preview.py moves BodyRef so (its
    # _hold_head); without it the body stood up to 4 cm off the game's.
    arm["head_path"] = [c for frame in data["frames"] for c in gmatrix(frame["Head"]).translation]
    arm["head_path_start"] = 0
    fp_arms = bpy.data.objects.get("FPArms")
    if fp_arms and "CTRL_chest" in fp_arms.pose.bones:
        for name in SPINE:
            if name in pb:
                follow = pb[name].constraints.new('COPY_ROTATION')
                follow.name = "Chest turn"
                follow.target, follow.subtarget = fp_arms, "CTRL_chest"
                follow.owner_space, follow.target_space = 'LOCAL', 'LOCAL_OWNER_ORIENT'
                follow.mix_mode = 'BEFORE'
                follow.influence = 1.0 / len(SPINE)
    print("FP_ARMS body reference: %s with %s, %d frames of %s" % (ARMATURE, ", ".join(m.name for m in meshes), len(data["frames"]), data["swing"]))


main()
