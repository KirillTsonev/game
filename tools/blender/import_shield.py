# Brings the shield (a glTF: one mesh, one material, three 2K textures beside it) into
# assets/models/weapons/shield/. Run with Blender's own Python:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_shield.py
#
# Written 2026-10-13 for the shield on the player's left forearm (scripts/player_body.gd).
# Source: raw-assets/models/shields/medieval_shield_gltf (a Fab export of a Sketchfab model;
# the files carry no licence note: unchecked).
#
# What the source is (surveyed before this was written): a flat board 0.44 m wide, 0.97 m
# tall and 8 mm thick, standing 1 m off its own origin, the painted face on one side and on
# the other a padded arm rest with two straps, lying ACROSS the shield a third of the way
# down. A notch for a lance is cut in the top corner on the side the hand is on.
#
# 1. shield.glb: the mesh at life size with every transform of the source baked into the
#    vertices (the mesh node in the glb has NO turn of its own: the sword's had one, and a day
#    of grips was fitted to the wrong axis). IN GODOT: +Y is the shield's top, +Z the way the
#    painted face looks, and the forearm lies along X with THE HAND AT -X. THE ORIGIN IS ON
#    THE FOREARM'S MIDDLE LINE, AT THE STRAP ON THE HAND'S SIDE: STANDOFF behind the board.
#    No images in the glb.
# 2. textures/: the three maps as they are. The glTF's metal / roughness map has roughness in
#    green and metal in blue, which is what Godot's material reads.
# 3. Written only where missing: the .import files and the material.
#
# Not written here: shield.tres, the WeaponData (on_forearm) that says where the fist is.
import os
import shutil
import bpy
import bmesh
import numpy as np
from math import radians
from mathutils import Matrix

RAW = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "raw-assets"))
SRC_DIR = os.path.join(RAW, "models", "shields", "medieval_shield_gltf")
RES_DIR = "res://assets/models/weapons/shield"
DST = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", "..", "assets", "models", "weapons", "shield"))
TEXTURES = {"material_baseColor.png": "albedo", "material_normal.png": "normal", "material_metallicRoughness.png": "metal_rough"}
# The forearm's middle line is this far behind the arm rest's face (m): a forearm is about
# 4 cm from its middle to its skin, and it lies on the rest. (This was 0.073 at first, from a
# survey that took the straps' vertices for the rest's and made the rest 3.3 cm thick: it is
# 7 mm, and the arm floated 3 cm off it.)
STANDOFF = 0.045
# The source's three straps stand 4.5-6 cm off the board and their loops are 8-11 cm tall:
# too small for an arm to be in them (Kirill, 2026-10-13: "the shield inner handles are too
# small for our hands", and after a first stretch away from the board only: "still clip
# through the palm and forearm"). Each is reshaped to go round what it holds, as measured on
# the rogue's own left arm lying on the rest with the hand open (its mesh's vertices at each
# strap, plus about 2.5 cm: a strap is an arch and the bracer is square, so with
# less its corners came through the arch's shoulders): how far it stands off the arm rest's face ("reach", m), and
# where its loop begins and ends up the shield, from the forearm's middle line ("low",
# "high", m; the open hand with its thumb is 13.6 cm across, the forearm in its bracer 10.6).
# The two straps on the hand's side lie across the palm, the third goes round the forearm.
# The hand's two go round the PALM ONLY (10.1 cm across without the thumb), the thumb outside
# them: sized round the thumb as well they made a hoop 19 cm tall (Kirill: "too big now").
STRAPS = {
    "hand": {"reach": 0.075, "low": -0.073, "high": 0.056},
    "forearm": {"reach": 0.132, "low": -0.102, "high": 0.07},
}


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

[ext_resource type="Texture2D" path="{dir}/textures/shield_albedo.png" id="albedo"]
[ext_resource type="Texture2D" path="{dir}/textures/shield_normal.png" id="normal"]
[ext_resource type="Texture2D" path="{dir}/textures/shield_metal_rough.png" id="metal_rough"]

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

source_file="{dir}/shield.glb"

[params]

meshes/light_baking=0
_subresources={{
"materials": {{
"shield": {{
"use_external/enabled": true,
"use_external/path": "{dir}/materials/shield.tres"
}}
}}
}}
gltf/embedded_image_handling=0
"""

for sub in ("textures", "materials"):
    os.makedirs(os.path.join(DST, sub), exist_ok=True)

for source, ours in TEXTURES.items():
    name = "shield_%s.png" % ours
    dst = os.path.join(DST, "textures", name)
    shutil.copyfile(os.path.join(SRC_DIR, "textures", source), dst)
    print("TEXTURE", name, os.path.getsize(dst) // 1024, "KB")
    write_if_missing(dst + ".import", texture_import("%s/textures/%s" % (RES_DIR, name), ours == "normal"))
write_if_missing(os.path.join(DST, "materials", "shield.tres"), MATERIAL.format(dir=RES_DIR))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC_DIR, "scene.gltf"))
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
if len(meshes) != 1:
    raise RuntimeError("expected one mesh, found %d" % len(meshes))
ob = meshes[0]
# Out of its parents, every transform into the vertices.
world = ob.matrix_world.copy()
ob.parent = None
ob.matrix_world = Matrix.Identity(4)
ob.data.transform(world)
for other in [o for o in bpy.data.objects if o != ob]:
    bpy.data.objects.remove(other)

co = np.empty(len(ob.data.vertices) * 3, dtype=np.float32)
ob.data.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
size = co.max(0) - co.min(0)
if not (size[0] < size[1] < size[2]):
    raise RuntimeError("not as surveyed (thin along X, wide along Y, tall along Z): size %s" % size.round(3))
# The board is where most vertices are along the thin axis; what stands off it is the arm
# rest, and the side it stands off to is the back.
counts, edges = np.histogram(co[:, 0], bins=40)
board = float((edges[np.argmax(counts)] + edges[np.argmax(counts) + 1]) * 0.5)
back_sign = -1.0 if board - co[:, 0].min() > co[:, 0].max() - board else 1.0
off = (co[:, 0] - board) * back_sign > 0.02 # further than 2 cm behind the board: the straps
if off.sum() < 20:
    raise RuntimeError("no arm rest found behind the board")
board_back = float(np.percentile((co[~off, 0] - board) * back_sign, 99)) * back_sign + board
strap_height = float((co[off, 2].min() + co[off, 2].max()) * 0.5)
# The two straps: the two groups of those vertices across the width.
ys = np.sort(co[off, 1])
gap = int(np.argmax(np.diff(ys)))
straps = [float(ys[:gap + 1].mean()), float(ys[gap + 1:].mean())]
# The lance notch: near the top the board is cut short on one side. The hand is on that side.
top = co[:, 2] > co[:, 2].max() - size[2] * 0.12
hand_sign = -1.0 if (co[:, 1].max() - co[top, 1].max()) < (co[top, 1].min() - co[:, 1].min()) else 1.0
hand_strap = min(straps) if hand_sign < 0.0 else max(straps)
arm_strap = max(straps) if hand_sign < 0.0 else min(straps)
print("SHIELD board at x %.3f (back face %.3f), back toward %+.0f x; straps at y %.3f and %.3f, z %.3f; notch and hand toward %+.0f y; hand's strap y %.3f, forearm's %.3f (%.3f m apart)"
      % (board, board_back, back_sign, straps[0], straps[1], strap_height, hand_sign, hand_strap, arm_strap, abs(hand_strap - arm_strap)))
# The straps, as pieces of the mesh: found on a welded copy (the export splits vertices at
# texture seams), as the pieces that stand more than 4 cm off the board; then every vertex of
# the real mesh that sits on one of a strap's is moved, by its distance from the rest's face.
weld = bmesh.new()
weld.from_mesh(ob.data)
bmesh.ops.remove_doubles(weld, verts=weld.verts, dist=0.00001)
done = set()
moved = 0
for start in weld.verts:
    if start.index in done:
        continue
    piece = [start]
    done.add(start.index)
    todo = [start]
    while todo:
        a = todo.pop()
        for e in a.link_edges:
            b = e.other_vert(a)
            if b.index not in done:
                done.add(b.index)
                piece.append(b)
                todo.append(b)
    stand = max((v.co.x - board_back) * back_sign for v in piece)
    if stand < 0.04 or len(piece) > 1000:
        continue
    across = sum(v.co.y for v in piece) / len(piece)
    kind = "hand" if abs(across - hand_strap) < abs(across - arm_strap) else "forearm"
    want = STRAPS[kind]
    factor = want["reach"] / stand
    # The loop is the part that stands off the board (its ends lie flat on it, further out).
    standing = [v.co.z for v in piece if (v.co.x - board_back) * back_sign > 0.015]
    bottom = min(standing)
    top = max(standing)
    taller = (want["high"] - want["low"]) / (top - bottom)
    places = {(round(v.co.x, 4), round(v.co.y, 4), round(v.co.z, 4)) for v in piece}
    count = 0
    for v in ob.data.vertices:
        if (round(v.co.x, 4), round(v.co.y, 4), round(v.co.z, 4)) in places:
            off_face = (v.co.x - board_back) * back_sign
            if off_face > 0.0:
                v.co.x = board_back + back_sign * off_face * factor
            v.co.z = strap_height + want["low"] + (v.co.z - bottom) * taller
            count += 1
    moved += count
    print("STRAP at y %.3f (%s): stood %.3f m off the rest's face, now %.3f; its loop was %.3f m tall, now %.3f (%d vertices)" % (across, kind, stand, want["reach"], top - bottom, want["high"] - want["low"], count))
weld.free()
ob.data.update()
if moved == 0:
    raise RuntimeError("no straps found to stretch")
fist = (board_back + back_sign * STANDOFF, hand_strap, strap_height)
# The fist to the origin; then turned about the upright so that the face looks along -Y and
# the hand is at -X (Blender), which the exporter makes +Z and -X in Godot, top +Y.
face = (-back_sign, 0.0, 0.0)
turn = Matrix.Rotation(radians(-90.0 if face[0] > 0.0 else 90.0), 4, 'Z')
ob.data.transform(turn @ Matrix.Translation((-fist[0], -fist[1], -fist[2])))
ob.data.update()
co = np.empty(len(ob.data.vertices) * 3, dtype=np.float32)
ob.data.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
hand_x = float((turn @ Matrix.Translation((0.0, hand_sign, 0.0))).translation.x)
if hand_x > 0.0: # the hand came out at +X: the shield is the other way up than surveyed
    raise RuntimeError("the hand's side came out at +X")
ob.name = "shield"
ob.data.name = "shield"
ob.data.materials[0].name = "shield"
print("SHIELD in Blender now: x %.3f..%.3f (hand at -x), y %.3f..%.3f (face at -y), z %.3f..%.3f (top at +z); tris %d"
      % (co[:, 0].min(), co[:, 0].max(), co[:, 1].min(), co[:, 1].max(), co[:, 2].min(), co[:, 2].max(),
         sum(len(p.vertices) - 2 for p in ob.data.polygons)))
bpy.ops.object.select_all(action='DESELECT')
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
path = os.path.join(DST, "shield.glb")
bpy.ops.export_scene.gltf(filepath=path, export_format='GLB', export_yup=True, use_selection=True,
                          export_materials='EXPORT', export_image_format='NONE', export_tangents=True)
print("EXPORTED", path, os.path.getsize(path) // 1024, "KB")
write_if_missing(path + ".import", GLB_IMPORT.format(dir=RES_DIR))
