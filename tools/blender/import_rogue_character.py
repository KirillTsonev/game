# Brings the "rogue" character download (rigged FBX on an Unreal 5 mannequin skeleton, no
# animations, 4K textures not linked to the FBX) and its animation clips into
# assets/models/characters/rogue/. Run with Blender's own Python (it bundles OpenImageIO, numpy):
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_rogue_character.py
#
# Written 2026-10-12. Sources, all under raw-assets/: models/rogue (rogue_all.fbx +
# textures_and_weapons/) and, in animations/, Quaternius' Universal Animation Library 1 and 2
# (CC0) and eight jog clips from Mixamo (free with an Adobe account, any engine).
#
# The character and the two sources have three different skeletons. Each is imported with a bone
# map (bone_maps/*.tres) onto Godot's humanoid profile, which renames the mapped bones (Hips,
# LeftUpperArm ...), turns their axes the profile's way and, with "fix silhouette", makes every
# rest pose the profile's T-pose -- the rogue's is an A-pose. After that a clip from either
# pack plays on the rogue. Bones the profile does not know keep their names and get no tracks:
# on the rogue these are the twist and corrective bones, which stay as in the rest pose.
#
# 1. rogue.fbx: a plain copy of the source; Godot imports it. Its size is set in
#    rogue.fbx.import: nodes/root_scale makes the top of the HEAD (not the hood) PLAYER_HEIGHT.
# 2. animations/: the files of ANIMATION_FILES, copied under plain names. scripts/player_body.gd
#    lists which clip of which file it plays.
# 3. knife.glb, shield.glb: the two props, scaled like the character.
# 4. textures/: the source PNGs reduced to TEXTURE_SIZES (skipped where already up to date); the
#    cloth's opacity map goes into its albedo's alpha (a Godot material has no opacity texture).
# 5. Written only where missing, so hand edits survive a re-run: every .import file, the bone
#    maps and one material per source material. The .import files must exist BEFORE the editor
#    first scans the folder. To change an import setting later, delete the .import and re-run.
#
# Tried before, 2026-10-12: Kevin Iglesias' Human Basic Motions FREE for the run in eight
# directions. Its sideways clips are forward runs with the hips turned 90 degrees and the
# shoulders 42, not sidesteps (Kirill: the body faces fully sideways); Mixamo's keep the body
# within 25 degrees of straight ahead. Also Epic's Paragon clips (5,385 of them, on the rogue's own skeleton,
# so no bone map was needed and the twist bones were animated). Dropped: licensed for Unreal
# Engine projects only. Also tried: converting the rogue to glb in Blender -- its FBX import
# misplaces six bones of this rig (right forearm, left shin and their helpers); Godot's does not.
import os, shutil, sys
import bpy
import numpy as np
import OpenImageIO as oiio
from mathutils import Vector

RAW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "raw-assets"))
SRC = os.path.join(RAW, "models", "rogue")
SRC_PROPS = os.path.join(SRC, "textures_and_weapons", "Textures_And_Weapons")
ANIM_ROOT = os.path.join(RAW, "animations")
RES_DIR = "res://assets/models/characters/rogue"
DST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "assets", "models", "characters", "rogue"))

PLAYER_HEIGHT = 1.85  # metres, ground to the top of the head, standing straight
# Degrees a bone's rest direction may differ from the profile's before "fix silhouette" turns it.
SILHOUETTE_THRESHOLD = 1


def pack_dir(start, *more):
    """A pack's folder by the start of its name (two of them have brackets in their names)."""
    found = sorted(d for d in os.listdir(ANIM_ROOT) if d.startswith(start))
    if not found:
        raise RuntimeError("no folder in %s starts with %r" % (ANIM_ROOT, start))
    path = os.path.join(ANIM_ROOT, found[0])
    if os.listdir(path) == [found[0]]:  # unzipped into a folder of its own name
        path = os.path.join(path, found[0])
    return os.path.join(path, *more)


# File in animations/ -> (source file, bone map, path of its Skeleton3D in the imported scene).
# The two libraries hold 43 clips each (the versions without root motion); a Mixamo file holds
# one. The Mixamo jogs lie loose in raw-assets/animations as downloaded ("Without Skin", 30
# frames a second, "In Place" ticked, all from one of Mixamo's own characters). Which file is
# which way was read from the feet: "Forward Diagonal(1)" goes forward-LEFT and the plain one
# forward-right; "Backward Diagonal(1)" goes back-right. The plain "Backward Diagonal" is the
# back-left one and was downloaded WITHOUT "In Place" (twice): the script takes its travel out.
ANIMATION_FILES = {
    "ual1.glb": (pack_dir("Universal Animation Library[", "Unreal-Godot", "UAL1_Standard.glb"), "ual", "Armature/Skeleton3D"),
    "ual2.glb": (pack_dir("Universal Animation Library 2", "Unreal-Godot", "UAL2_Standard.glb"), "ual", "Armature/Skeleton3D"),
}
for clip, source in (("jog_fwd", "Jog Forward"), ("jog_bwd", "Jog Backward"),
                     ("jog_left", "Jog Strafe Left"), ("jog_right", "Jog Strafe Right"),
                     ("jog_fwd_left", "Jog Forward Diagonal(1)"), ("jog_fwd_right", "Jog Forward Diagonal"),
                     ("jog_bwd_left", "Jog Backward Diagonal"), ("jog_bwd_right", "Jog Backward Diagonal(1)")):
    ANIMATION_FILES[clip + ".fbx"] = (os.path.join(ANIM_ROOT, source + ".fbx"), "mixamo", "Skeleton3D")
# Mixamo's "Standing Dodge" hops, for the dash (raw-assets/animations/dodge; "Without Skin", 30
# frames a second, NOT in place: each travels about 2 m, which the script takes out).
for clip, source in (("dodge_fwd", "Forward"), ("dodge_bwd", "Backward"), ("dodge_left", "Left"), ("dodge_right", "Right")):
    ANIMATION_FILES[clip + ".fbx"] = (os.path.join(ANIM_ROOT, "dodge", "Standing Dodge %s.fbx" % source), "mixamo", "Skeleton3D")


def humanoid_map(fixed, side_bones, fingers, side_name, finger_name):
    """Godot humanoid profile bone -> a skeleton's bone, from that skeleton's naming scheme."""
    bones = dict(fixed)
    for side in ("Left", "Right"):
        for profile, name in side_bones.items():
            bones[side + profile] = side_name(name, side)
        for profile_finger, finger in fingers.items():
            joints = ("Metacarpal", "Proximal", "Distal") if profile_finger == "Thumb" else ("Proximal", "Intermediate", "Distal")
            for number, joint in enumerate(joints, 1):
                bones[side + profile_finger + joint] = side_name(finger_name(finger, number), side)
    return bones


UNREAL_SIDE = {"Shoulder": "clavicle", "UpperArm": "upperarm", "LowerArm": "lowerarm", "Hand": "hand",
               "UpperLeg": "thigh", "LowerLeg": "calf", "Foot": "foot", "Toes": "ball"}
UNREAL_FINGERS = {"Thumb": "thumb", "Index": "index", "Middle": "middle", "Ring": "ring", "Little": "pinky"}
BONE_MAPS = {
    # The rogue has five spine bones and two neck bones for the profile's three and one:
    # spine_02, spine_04 and neck_02 stay unmapped.
    "rogue": humanoid_map(
        {"Root": "root", "Hips": "pelvis", "Spine": "spine_01", "Chest": "spine_03", "UpperChest": "spine_05",
         "Neck": "neck_01", "Head": "head"},
        UNREAL_SIDE, UNREAL_FINGERS,
        lambda name, side: "%s_%s" % (name, side[0].lower()), lambda finger, n: "%s_0%d" % (finger, n)),
    "ual": humanoid_map(
        {"Root": "root", "Hips": "pelvis", "Spine": "spine_01", "Chest": "spine_02", "UpperChest": "spine_03",
         "Neck": "neck_01", "Head": "Head"},
        UNREAL_SIDE, UNREAL_FINGERS,
        lambda name, side: "%s_%s" % (name, side[0].lower()), lambda finger, n: "%s_0%d" % (finger, n)),
    # Mixamo's rig: "mixamorig:Hips" in the file, which Godot reads as "mixamorig_Hips". It has
    # no root bone above the hips.
    "mixamo": humanoid_map(
        {"Hips": "mixamorig_Hips", "Spine": "mixamorig_Spine", "Chest": "mixamorig_Spine1",
         "UpperChest": "mixamorig_Spine2", "Neck": "mixamorig_Neck", "Head": "mixamorig_Head"},
        {"Shoulder": "Shoulder", "UpperArm": "Arm", "LowerArm": "ForeArm", "Hand": "Hand",
         "UpperLeg": "UpLeg", "LowerLeg": "Leg", "Foot": "Foot", "Toes": "ToeBase"},
        {"Thumb": "HandThumb", "Index": "HandIndex", "Middle": "HandMiddle", "Ring": "HandRing", "Little": "HandPinky"},
        lambda name, side: "mixamorig_%s%s" % (side, name), lambda finger, n: "%s%d" % (finger, n)),
}
# Source material -> size of its reduced textures.
TEXTURE_SIZES = {"Cloth": 2048, "LeatherA": 2048, "LeatherB": 2048, "Head": 1024, "Metal": 1024,
                 "knife": 2048, "shield": 2048}


def write_if_missing(path, text):
    if os.path.exists(path):
        print("KEPT", path)
        return
    with open(path, "w", newline="\n") as f:
        f.write(text)
    print("WROTE", path)


# ---------------------------------------------------------------- textures

def reduced(path, size):
    buf = oiio.ImageBuf(path)
    spec = buf.spec()
    if spec.width <= size:
        return buf
    return oiio.ImageBufAlgo.resize(buf, roi=oiio.ROI(0, size, 0, size, 0, 1, 0, spec.nchannels))


def normal_map_is_directx(buf):
    """A normal map is the slope of a height field, so its red and green channels have no curl
    in the convention it was baked for. Rows run top to bottom here: an OpenGL map (green = up)
    has dR/dy + dG/dx = 0, a DirectX map (green = down) has dR/dy - dG/dx = 0."""
    px = buf.get_pixels(oiio.FLOAT)
    r = px[:, :, 0] * 2.0 - 1.0
    g = px[:, :, 1] * 2.0 - 1.0
    dr_dy = r[2:, 1:-1] - r[:-2, 1:-1]
    dg_dx = g[1:-1, 2:] - g[1:-1, :-2]
    as_opengl = float(np.abs(dr_dy + dg_dx).mean())
    as_directx = float(np.abs(dr_dy - dg_dx).mean())
    print("   curl as OpenGL %.5f, as DirectX %.5f" % (as_opengl, as_directx))
    return as_directx < as_opengl


def texture_import(res_path, normal=False, invert_y=False):
    return """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="%s"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=%d
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=%s
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
""" % (res_path, 1 if normal else 0, "true" if invert_y else "false")


def bring_textures(material, src_dir, src_prefix, dst_prefix):
    """Writes <dst_prefix>_{albedo,normal,orm[,emission]}.png + .import; returns the kinds present."""
    size = TEXTURE_SIZES[material]
    tex_dir = os.path.join(DST, "textures")
    kinds = []
    for kind, src_kind in (("albedo", "BaseColor"), ("normal", "Normal"), ("orm", "ORM"), ("emission", "Emiss")):
        src = os.path.join(src_dir, "%s_%s.1001.png" % (src_prefix, src_kind))
        if not os.path.exists(src):
            continue
        kinds.append(kind)
        opacity = os.path.join(src_dir, "%s_Opacity.1001.png" % src_prefix)
        with_alpha = kind == "albedo" and os.path.exists(opacity)
        if with_alpha:
            kinds.append("alpha")
        name = "%s_%s.png" % (dst_prefix, kind)
        dst = os.path.join(tex_dir, name)
        if os.path.exists(dst) and os.path.exists(dst + ".import") and os.path.getmtime(dst) >= os.path.getmtime(src):
            continue
        buf = reduced(src, size)
        if with_alpha:
            alpha = oiio.ImageBufAlgo.channels(reduced(opacity, size), (0,))
            rgb = oiio.ImageBufAlgo.channels(buf, (0, 1, 2))
            buf = oiio.ImageBufAlgo.channels(oiio.ImageBufAlgo.channel_append(rgb, alpha),
                                             (0, 1, 2, 3), ("R", "G", "B", "A"))
        if not buf.write(dst, oiio.UINT8):
            raise RuntimeError("write failed %s: %s" % (dst, buf.geterror()))
        print("TEXTURE", name, buf.spec().width, "px,", buf.spec().nchannels, "channels,", os.path.getsize(dst) // 1024, "KB")
        invert_y = kind == "normal" and normal_map_is_directx(buf)
        if kind == "normal":
            print("   ->", "DirectX: green is inverted at import" if invert_y else "OpenGL: used as it is")
        write_if_missing(dst + ".import", texture_import("%s/textures/%s" % (RES_DIR, name), kind == "normal", invert_y))
    return kinds


def material_tres(dst_prefix, kinds):
    ext, body = [], []
    for kind, lines in (("albedo", ["albedo_texture = %s"]), ("orm", ["orm_texture = %s"]),
                        ("normal", ["normal_enabled = true", "normal_texture = %s"]),
                        ("emission", ["emission_enabled = true", "emission_texture = %s"])):
        if kind not in kinds:
            continue
        ext.append('[ext_resource type="Texture2D" path="%s/textures/%s_%s.png" id="%s"]' % (RES_DIR, dst_prefix, kind, kind))
        body += [line % ('ExtResource("%s")' % kind) if "%s" in line else line for line in lines]
    if "alpha" in kinds:
        # Cut-out cloth, seen from both sides.
        body = ["transparency = 2", "alpha_scissor_threshold = 0.5", "cull_mode = 2"] + body
    return '[gd_resource type="ORMMaterial3D" load_steps=%d format=3]\n\n%s\n\n[resource]\n%s\n' % (
        len(ext) + 1, "\n".join(ext), "\n".join(body))


# ---------------------------------------------------------------- models

def bone_map_tres(bones):
    lines = ['bone_map/%s = &"%s"' % kv for kv in bones.items()]
    return ('[gd_resource type="BoneMap" load_steps=2 format=3]\n\n'
            '[sub_resource type="SkeletonProfileHumanoid" id="profile"]\n\n'
            '[resource]\nprofile = SubResource("profile")\n' + "\n".join(lines) + "\n")


def scene_import(res_path, materials=None, root_scale=1.0, skeleton=None, bone_map=None, clip=False):
    """Only the settings that differ from Godot's defaults; the editor fills in the rest.
    skeleton: the Skeleton3D's path in the imported scene, bone_map: a key of BONE_MAPS."""
    parts = []
    if materials:
        parts.append('"materials": {\n%s\n}' % ",\n".join(
            '"%s": {\n"use_external/enabled": true,\n"use_external/path": "%s/materials/%s.tres"\n}' % (m, RES_DIR, f)
            for m, f in materials.items()))
    if bone_map:
        settings = ['"retarget/bone_map": Resource("%s/bone_maps/%s.tres")' % (RES_DIR, bone_map),
                    # Every skeleton's rest pose becomes the profile's T-pose, whatever it was.
                    '"retarget/rest_fixer/fix_silhouette/enable": true',
                    '"retarget/rest_fixer/fix_silhouette/threshold": %s' % SILHOUETTE_THRESHOLD]
        if clip:
            # No tracks for bones the rogue does not have under the same name.
            settings.append('"retarget/remove_tracks/unmapped_bones": true')
        parts.append('"nodes": {\n"PATH:%s": {\n%s\n}\n}' % (skeleton, ",\n".join(settings)))
    subresources = "\n%s\n" % ",\n".join(parts) if parts else ""
    return """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="%s"

[params]

nodes/apply_root_scale=true
nodes/root_scale=%s
meshes/light_baking=0
animation/import=true
animation/remove_immutable_tracks=%s
_subresources={%s}
gltf/embedded_image_handling=0
fbx/importer=0
fbx/embedded_image_handling=0
""" % (res_path, root_scale, "false" if clip else "true", subresources)


def world_top(ob):
    return max((ob.matrix_world @ Vector(c)).z for c in ob.bound_box)


def build_prop(name, factor):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=os.path.join(SRC_PROPS, "FBX", name + ".fbx"))
    ob = next(o for o in bpy.data.objects if o.type == 'MESH')
    ob.scale = ob.scale * factor
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # Not the file's name: Godot renames one of two nodes that share a name.
    ob.name = name + "_mesh"
    ob.data.name = name + "_mesh"
    path = os.path.join(DST, name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True,
                              export_materials='EXPORT', export_image_format='NONE', export_tangents=True)
    print("PROP", name, "dims", tuple(round(d, 3) for d in ob.dimensions), os.path.getsize(path) // 1024, "KB")


for sub in ("textures", "materials", "animations", "bone_maps"):
    os.makedirs(os.path.join(DST, sub), exist_ok=True)
for name, bones in BONE_MAPS.items():
    write_if_missing(os.path.join(DST, "bone_maps", name + ".tres"), bone_map_tres(bones))

character_materials = {}
for material in ("Cloth", "Head", "LeatherA", "LeatherB", "Metal"):
    prefix = "rogue_" + material.lower()
    kinds = bring_textures(material, os.path.join(SRC_PROPS, "Rogue_Textures"), "rogueCH_" + material, prefix)
    write_if_missing(os.path.join(DST, "materials", prefix + ".tres"), material_tres(prefix, kinds))
    character_materials[material] = prefix
for prop in ("knife", "shield"):
    kinds = bring_textures(prop, os.path.join(SRC_PROPS, "Weapon_Textures"), prop, prop)
    write_if_missing(os.path.join(DST, "materials", prop + ".tres"), material_tres(prop, kinds))

# The scale that makes the head's top PLAYER_HEIGHT, measured on the source.
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=os.path.join(SRC, "rogue_all.fbx"))
bpy.context.view_layer.update()
factor = round(PLAYER_HEIGHT / world_top(bpy.data.objects["head_geo"]), 4)
print("SCALE", factor, "-> hood top %.3f m" % (world_top(bpy.data.objects["hood_geo"]) * factor))

shutil.copy2(os.path.join(SRC, "rogue_all.fbx"), os.path.join(DST, "rogue.fbx"))
write_if_missing(os.path.join(DST, "rogue.fbx.import"),
                 scene_import(RES_DIR + "/rogue.fbx", character_materials, factor, "Skeleton3D", "rogue"))
for name, (source, bone_map, skeleton) in ANIMATION_FILES.items():
    shutil.copy2(source, os.path.join(DST, "animations", name))
    write_if_missing(os.path.join(DST, "animations", name + ".import"),
                     scene_import("%s/animations/%s" % (RES_DIR, name), None, 1.0, skeleton, bone_map, clip=True))
print("COPIED rogue.fbx and", len(ANIMATION_FILES), "animation files")

for prop in ("knife", "shield"):
    build_prop(prop, factor)
    write_if_missing(os.path.join(DST, prop + ".glb.import"),
                     scene_import("%s/%s.glb" % (RES_DIR, prop), {prop: prop}))
