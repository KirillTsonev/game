# Brings the sword (one .blend: a mesh, a material, three 1K textures packed inside) into
# assets/models/weapons/sword/. Run with Blender's own Python:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_sword.py
#
# Written 2026-10-12 for the sword in the player's right hand (scripts/player_body.gd).
# Source: raw-assets/models/wapons/human_sword_lv1.blend. Its licence is unchecked.
#
# 1. sword.glb: the mesh at life size (1.19 m), the ORIGIN IN THE MIDDLE OF THE GRIP, the
#    crossguard along X. IN GODOT THE BLADE RUNS ALONG THE SCENE'S +Z, flats facing +-Y: the
#    source object is turned 90 degrees about X, this script moves only its mesh data, and the
#    exporter writes the object's turn as the mesh node's transform. (This header said "+Y"
#    until 2026-10-13, and a day of grips was fitted to an axis the blade was not on.)
#    sword.tres' grip is written for the axes as they are. No images in the glb.
# 2. textures/: albedo and normal as they are in the file. The source's third map has roughness
#    in green and "not metal" in blue (its material inverts blue); Godot cannot invert a
#    channel, so sword_metal_rough.png is written with blue inverted.
# 3. Written only where missing: the .import files and the material.
#
# Not written here: sword.tres, the WeaponData that says where the hand closes on it
# (docs/weapons.md).
#
# The normal map is used as it is: the source material feeds it straight into Blender's normal
# map node, and Blender and Godot read the green channel the same way round.
import os
import bpy
import numpy as np
from math import radians
from mathutils import Matrix

RAW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "raw-assets"))
SRC = os.path.join(RAW, "models", "wapons", "human_sword_lv1.blend")
RES_DIR = "res://assets/models/weapons/sword"
DST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "assets", "models", "weapons", "sword"))
MESH = "Human Sword_LV1"
# Source image -> ours (written as it is packed in the file).
TEXTURES = {"Human Sword_LV1_Diffuse.png": "albedo", "Human Sword_LV1_Normal.png": "normal"}
METAL_ROUGH = "Human Sword_LV1_Roughness.png"
# The grip is found as the longest stretch of the sword, on the pommel's side of the
# crossguard, that is no wider than this from the middle line (m).
GRIP_MAX_RADIUS = 0.027
GRIP_STEP = 0.005


def write_if_missing(path, text):
    if os.path.exists(path):
        print("KEPT", path)
        return
    with open(path, "w", newline="\n") as f:
        f.write(text)
    print("WROTE", path)


def texture_import(res_path, normal):
    return """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="%s"

[params]

compress/mode=2
compress/normal_map=%d
mipmaps/generate=true
detect_3d/compress_to=1
""" % (res_path, 1 if normal else 0)


MATERIAL = """[gd_resource type="StandardMaterial3D" load_steps=4 format=3]

[ext_resource type="Texture2D" path="{dir}/textures/sword_albedo.png" id="albedo"]
[ext_resource type="Texture2D" path="{dir}/textures/sword_normal.png" id="normal"]
[ext_resource type="Texture2D" path="{dir}/textures/sword_metal_rough.png" id="metal_rough"]

[resource]
albedo_texture = ExtResource("albedo")
metallic = 1.0
metallic_texture = ExtResource("metal_rough")
metallic_texture_channel = 2
roughness_texture = ExtResource("metal_rough")
roughness_texture_channel = 1
normal_enabled = true
normal_texture = ExtResource("normal")
"""

GLB_IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="{dir}/sword.glb"

[params]

meshes/light_baking=0
_subresources={{
"materials": {{
"sword": {{
"use_external/enabled": true,
"use_external/path": "{dir}/materials/sword.tres"
}}
}}
}}
gltf/embedded_image_handling=0
"""

for sub in ("textures", "materials"):
    os.makedirs(os.path.join(DST, sub), exist_ok=True)

bpy.ops.wm.open_mainfile(filepath=SRC)
ob = bpy.data.objects[MESH]
material = ob.data.materials[0]
for node in material.node_tree.nodes:
    if node.type == 'MAPPING':
        moved = [tuple(round(v, 4) for v in node.inputs[name].default_value) for name in ("Location", "Rotation", "Scale")]
        if moved != [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)]:
            raise RuntimeError("the material moves its texture coordinates: %s" % moved)

for source, ours in TEXTURES.items():
    image = bpy.data.images[source]
    name = "sword_%s.png" % ours
    dst = os.path.join(DST, "textures", name)
    with open(dst, "wb") as f:
        f.write(image.packed_file.data)
    print("TEXTURE", name, tuple(image.size), "px,", os.path.getsize(dst) // 1024, "KB")
    write_if_missing(dst + ".import", texture_import("%s/textures/%s" % (RES_DIR, name), ours == "normal"))

image = bpy.data.images[METAL_ROUGH]
width, height = image.size
pixels = np.empty(width * height * 4, dtype=np.float32)
image.pixels.foreach_get(pixels)
pixels = pixels.reshape(-1, 4)
print("SOURCE MAP mean roughness (green) %.3f, mean metal (1 - blue) %.3f, share of pixels over half metal %.2f"
      % (pixels[:, 1].mean(), 1.0 - pixels[:, 2].mean(), (pixels[:, 2] < 0.5).mean()))
pixels[:, 0] = 0.0
pixels[:, 2] = 1.0 - pixels[:, 2]
pixels[:, 3] = 1.0
out = bpy.data.images.new("sword_metal_rough", width, height, alpha=False, is_data=True)
out.pixels.foreach_set(pixels.ravel())
name = "sword_metal_rough.png"
dst = os.path.join(DST, "textures", name)
out.filepath_raw = dst
out.file_format = 'PNG'
out.save()
print("TEXTURE", name, (width, height), "px,", os.path.getsize(dst) // 1024, "KB")
write_if_missing(dst + ".import", texture_import("%s/textures/%s" % (RES_DIR, name), False))
write_if_missing(os.path.join(DST, "materials", "sword.tres"), MATERIAL.format(dir=RES_DIR))

# In the source the sword lies along Y, pommel at +Y, crossguard along X. The crossguard is
# where it is widest; the grip is the longest narrow stretch beyond it.
co = np.empty(len(ob.data.vertices) * 3, dtype=np.float32)
ob.data.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
radius = np.hypot(co[:, 0], co[:, 2])
guard = float(co[np.argmax(np.abs(co[:, 0])), 1])
steps = np.arange(guard, float(co[:, 1].max()), GRIP_STEP)
best = (0.0, 0.0)
start = None
for y in list(steps) + [None]:
    narrow = False
    if y is not None:
        inside = (co[:, 1] >= y) & (co[:, 1] < y + GRIP_STEP)
        narrow = bool(inside.any()) and float(radius[inside].max()) <= GRIP_MAX_RADIUS
    if narrow and start is None:
        start = y
    elif not narrow and start is not None:
        end = y if y is not None else float(steps[-1]) + GRIP_STEP
        if end - start > best[1] - best[0]:
            best = (start, end)
        start = None
if best[1] - best[0] < 0.08:
    raise RuntimeError("no grip found (crossguard at y %.3f)" % guard)
grip = (best[0] + best[1]) * 0.5
print("GRIP y %.3f..%.3f (%.3f m long), crossguard at y %.3f, tip at y %.3f, pommel's end at y %.3f"
      % (best[0], best[1], best[1] - best[0], guard, float(co[:, 1].min()), float(co[:, 1].max())))

# The grip's middle to the origin, then the blade (toward -Y) up: Blender's +Z is Godot's +Y.
ob.data.transform(Matrix.Rotation(radians(-90.0), 4, 'X') @ Matrix.Translation((0.0, -grip, 0.0)))
ob.data.update()
ob.name = "sword"
ob.data.name = "sword"
material.name = "sword"
for other in [o for o in bpy.data.objects if o != ob]:
    bpy.data.objects.remove(other)
zs = [v.co.z for v in ob.data.vertices]
print("MESH sword tris", sum(len(p.vertices) - 2 for p in ob.data.polygons),
      "blade's tip %.3f m above the origin, pommel's end %.3f m below" % (max(zs), -min(zs)))
bpy.ops.object.select_all(action='DESELECT')
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
path = os.path.join(DST, "sword.glb")
bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True, use_selection=True,
                          export_materials='EXPORT', export_image_format='NONE', export_tangents=True)
print("EXPORTED", path, os.path.getsize(path) // 1024, "KB")
write_if_missing(path + ".import", GLB_IMPORT.format(dir=RES_DIR))
