# Brings the hurricane lantern (a Fab download converted to glTF: scene.gltf + scene.bin +
# four 4K textures) into assets/models/props/lantern/. Run with Blender's own Python:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_lantern.py
#
# Written 2026-10-12 for the lantern on the player's belt (scripts/player_body.gd).
# Source: raw-assets/models/lanterns/lantern_gltf. Its licence is unchecked.
#
# 1. lantern.glb: the two meshes ("lantern_frame", "lantern_glass") at life size (0.30 m tall),
#    transforms applied, the ORIGIN AT THE TOP OF THE HANDLE so it hangs from the point it is
#    placed at. No images in the glb.
# 2. textures/: the frame's four maps reduced to TEXTURE_SIZE.
# 3. Written only where missing: the .import files and the two materials. The frame's flame is
#    in its emission map; the glass is a plain see-through material (the source used
#    transmission, which Godot's glTF import does not carry over).
import os, sys
import bpy
import OpenImageIO as oiio
from mathutils import Vector

RAW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "raw-assets"))
SRC = os.path.join(RAW, "models", "lanterns", "lantern_gltf")
RES_DIR = "res://assets/models/props/lantern"
DST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "assets", "models", "props", "lantern"))
TEXTURE_SIZE = 1024
# Source mesh -> (mesh name, material name) in the glb.
MESHES = {"Lantern_3_Material.006_0": ("lantern_frame", "lantern_frame"),
          "Glass_Material.007_0": ("lantern_glass", "lantern_glass")}
# Source texture -> ours.
TEXTURES = {"baseColor": "albedo", "normal": "normal", "metallicRoughness": "metal_rough", "emissive": "emission"}


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


FRAME_MATERIAL = """[gd_resource type="StandardMaterial3D" load_steps=5 format=3]

[ext_resource type="Texture2D" path="{dir}/textures/lantern_albedo.png" id="albedo"]
[ext_resource type="Texture2D" path="{dir}/textures/lantern_normal.png" id="normal"]
[ext_resource type="Texture2D" path="{dir}/textures/lantern_metal_rough.png" id="metal_rough"]
[ext_resource type="Texture2D" path="{dir}/textures/lantern_emission.png" id="emission"]

[resource]
cull_mode = 2
albedo_texture = ExtResource("albedo")
metallic = 1.0
metallic_texture = ExtResource("metal_rough")
metallic_texture_channel = 2
roughness_texture = ExtResource("metal_rough")
roughness_texture_channel = 1
emission_enabled = true
emission_energy_multiplier = 4.0
emission_texture = ExtResource("emission")
normal_enabled = true
normal_texture = ExtResource("normal")
"""

GLASS_MATERIAL = """[gd_resource type="StandardMaterial3D" format=3]

[resource]
transparency = 1
cull_mode = 2
albedo_color = Color(0.65, 0.65, 0.65, 0.2)
metallic = 0.5
roughness = 0.06
"""

GLB_IMPORT = """[remap]

importer="scene"
importer_version=1
type="PackedScene"

[deps]

source_file="{dir}/lantern.glb"

[params]

meshes/light_baking=0
_subresources={{
"materials": {{
"lantern_frame": {{
"use_external/enabled": true,
"use_external/path": "{dir}/materials/lantern_frame.tres"
}},
"lantern_glass": {{
"use_external/enabled": true,
"use_external/path": "{dir}/materials/lantern_glass.tres"
}}
}}
}}
gltf/embedded_image_handling=0
"""

for sub in ("textures", "materials"):
    os.makedirs(os.path.join(DST, sub), exist_ok=True)

for source, ours in TEXTURES.items():
    src = os.path.join(SRC, "textures", "Material.006_%s.png" % source)
    name = "lantern_%s.png" % ours
    dst = os.path.join(DST, "textures", name)
    buf = oiio.ImageBuf(src)
    spec = buf.spec()
    if spec.width > TEXTURE_SIZE:
        buf = oiio.ImageBufAlgo.resize(buf, roi=oiio.ROI(0, TEXTURE_SIZE, 0, TEXTURE_SIZE, 0, 1, 0, spec.nchannels))
    if not buf.write(dst, oiio.UINT8):
        raise RuntimeError("write failed %s: %s" % (dst, buf.geterror()))
    print("TEXTURE", name, buf.spec().width, "px,", buf.spec().nchannels, "channels,", os.path.getsize(dst) // 1024, "KB")
    write_if_missing(dst + ".import", texture_import("%s/textures/%s" % (RES_DIR, name), ours == "normal"))
write_if_missing(os.path.join(DST, "materials", "lantern_frame.tres"), FRAME_MATERIAL.format(dir=RES_DIR))
write_if_missing(os.path.join(DST, "materials", "lantern_glass.tres"), GLASS_MATERIAL)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "scene.gltf"))
bpy.context.view_layer.update()
meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.name in MESHES]
if len(meshes) != len(MESHES):
    raise RuntimeError("expected the meshes %s, found %s" % (list(MESHES), [o.name for o in bpy.data.objects]))
for ob in meshes:  # out of the Sketchfab node chain, keeping their place
    world = ob.matrix_world.copy()
    ob.parent = None
    ob.matrix_world = world
for ob in [o for o in bpy.data.objects if o not in meshes]:
    bpy.data.objects.remove(ob)
bpy.context.view_layer.update()
top = max((ob.matrix_world @ Vector(c)).z for ob in meshes for c in ob.bound_box)
bpy.ops.object.select_all(action='DESELECT')
for ob in meshes:
    ob.location.z -= top
    ob.select_set(True)
    mesh_name, material_name = MESHES[ob.name]
    ob.name = mesh_name
    ob.data.name = mesh_name
    ob.data.materials[0].name = material_name
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for ob in meshes:
    print("MESH", ob.name, "tris", sum(len(p.vertices) - 2 for p in ob.data.polygons),
          "z %.3f..%.3f" % (min(v.co.z for v in ob.data.vertices), max(v.co.z for v in ob.data.vertices)))
path = os.path.join(DST, "lantern.glb")
bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True,
                          export_materials='EXPORT', export_image_format='NONE', export_tangents=True)
print("EXPORTED", path, os.path.getsize(path) // 1024, "KB")
write_if_missing(path + ".import", GLB_IMPORT.format(dir=RES_DIR))
