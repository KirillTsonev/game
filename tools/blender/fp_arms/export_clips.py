# Step 3 of the Blender arm pipeline (docs/blender_animation.md): writes every action of
# animation_sources/fp_arms/fp_arms.blend into
# assets/animations/first_person/fp_arms.glb -- the arm's deforming bones plus Eyes and Weapon, the
# controls baked in (sampled every frame) -- and fp_arms_rig.json beside it: what PlayerBody needs
# to read the rig back (the hand's rest and the sword's socket the scene was built with).
#
# Run it in the open Blender after editing (the Blender MCP, or the Text editor), or:
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b animation_sources/fp_arms/fp_arms.blend --python tools/blender/fp_arms/export_clips.py
# Then rescan in Godot (the editor's FileSystem, or the Godot MCP's rescan_filesystem).
import bpy, json, os

try:
    HERE = os.path.dirname(os.path.abspath(__file__))
except NameError:
    HERE = r"D:\Downloads\Godot_v4.7.2-stable_win64.exe\herald-of-oblivion\tools\blender\fp_arms"
PROJECT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SRC = os.path.join(PROJECT, "animation_sources", "fp_arms")
OUT_DIR = os.path.join(PROJECT, "assets", "animations", "first_person")
OUT = os.path.join(OUT_DIR, "fp_arms.glb")
# The clips' frame rate: the export takes the timing from the scene's, so it is set to this for
# the export and put back after -- the scene's own may be lowered to watch a move slowly (it was
# 12 once, and a 1.2 s swing came out 3.0 s long).
FPS = 30


def main():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    arm = bpy.data.objects["FPArms"]
    editing = arm.animation_data.action
    # The exporter (ACTIONS mode) writes every action that has been assigned to the armature once,
    # "hold" included (harmless: one frame). A new move = a new action made with the armature
    # selected (the Action editor's New); delete an action to leave it out.
    bpy.ops.object.select_all(action='DESELECT')
    arm.select_set(True)
    for child in arm.children:
        if child.type == 'MESH':
            child.select_set(True)
    bpy.context.view_layer.objects.active = arm
    os.makedirs(OUT_DIR, exist_ok=True)
    render = bpy.context.scene.render
    preview = (render.fps, render.fps_base, render.frame_map_old, render.frame_map_new)
    render.fps, render.fps_base, render.frame_map_old, render.frame_map_new = FPS, 1.0, 100, 100
    bpy.ops.export_scene.gltf(filepath=OUT, export_format='GLB', use_selection=True, export_animations=True,
                              export_animation_mode='ACTIONS', export_def_bones=True, export_force_sampling=True,
                              export_frame_step=1, export_materials='NONE', export_cameras=False, export_lights=False,
                              export_apply=False, export_yup=True, export_optimize_animation_size=False,
                              # Blender's first frame is 1: without this every clip starts 1/30 s late.
                              export_anim_slide_to_zero=True,
                              # Not reset: the forearm's small unkeyed bend is what lets the IK solve (build_scene.py).
                              export_reset_pose_bones=False)
    render.fps, render.fps_base, render.frame_map_old, render.frame_map_new = preview
    arm.animation_data.action = editing
    src = json.load(open(os.path.join(SRC, "arm_source.json")))
    with open(os.path.join(OUT_DIR, "fp_arms_rig.json"), "w", newline="\n") as fh:
        json.dump({"hand_rest": src["bones"]["RightHand"]["rest"], "socket": src["socket"], "fps": FPS}, fh, indent=1)
    print("FP_ARMS exported %s: %s" % (OUT, ", ".join(sorted(a.name for a in bpy.data.actions))))


main()
