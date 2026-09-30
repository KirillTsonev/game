# Brings one Poly Haven rock (.blend download) into assets/models/rocks/<name>/ -- steps 1-2 of
# "A. New scatter rock" in docs/adding_models.md. Run with Blender's own Python (it bundles
# OpenImageIO; no pip install needed):
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_polyhaven_rock.py -- <src_blend_dir> <name>
#
# <src_blend_dir> is the Poly Haven "<name>_2k.blend" FOLDER (holds <name>_2k.blend + textures/).
# Written for namaqualand_boulder_02..06 (2026-09-30).
#
# 1. re-encodes <name>_{nor_gl,rough}_2k.exr to ZIP -- Poly Haven ships DWAA, which Godot's EXR
#    importer can't decode and fails on silently (see CLAUDE.md, "DWAA compression")
# 2. copies <name>_diff_2k.jpg
# 3. exports every *_LODn mesh (sibling nodes -- Terrain3D uses them as LODs) to <name>_2k.glb
#    with NO images: the rock renders through <name>_material.tres, so nothing to embed/extract
# Afterwards: set root_scale + gltf/embedded_image_handling=0 in the new .glb.import (step 3).
import os, shutil, sys
import bpy
import OpenImageIO as oiio

src, name = sys.argv[sys.argv.index("--") + 1:][:2]
dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "models", "rocks", name)
dst = os.path.normpath(dst)
os.makedirs(os.path.join(dst, "textures"), exist_ok=True)

for kind in ("nor_gl", "rough"):
    s = os.path.join(src, "textures", f"{name}_{kind}_2k.exr")
    d = os.path.join(dst, "textures", f"{name}_{kind}_2k.exr")
    buf = oiio.ImageBuf(s)
    spec = buf.spec()
    buf.specmod().attribute("compression", "zip")
    if not buf.write(d, spec.format):
        raise RuntimeError(f"write failed {d}: {buf.geterror()}")
    chk = oiio.ImageInput.open(d)
    print("WROTE", d, "compression=", chk.spec().get_string_attribute("compression"),
          "channels=", list(chk.spec().channelnames), "format=", chk.spec().format)
    chk.close()

shutil.copy2(os.path.join(src, "textures", f"{name}_diff_2k.jpg"),
             os.path.join(dst, "textures", f"{name}_diff_2k.jpg"))
print("COPIED diff")

bpy.ops.wm.open_mainfile(filepath=os.path.join(src, f"{name}_2k.blend"))
for ob in bpy.data.objects:
    if ob.type == 'MESH':
        print("MESH", ob.name, "dims=", tuple(round(v, 3) for v in ob.dimensions))
glb = os.path.join(dst, f"{name}_2k.glb")
bpy.ops.export_scene.gltf(
    filepath=glb,
    export_format='GLB',
    export_apply=True,
    export_yup=True,
    use_visible=False,      # the LODs sit in separate collections -- export all of them
    use_renderable=False,
    export_image_format='NONE',
)
print("EXPORTED", glb, os.path.getsize(glb))
