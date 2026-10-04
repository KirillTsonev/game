# Brings one Megascans 3D PLANT (Fab glTF download, e.g. lady_fern_wdvlditia_ue_mid) into
# assets/models/understory/<name>/. Run with Blender's own Python:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_megascans_plant.py -- <src_dir> <name> [--far-ratio 0.25]
#       [--lod 1] [--variants A,B] [--textures <other_pack_dir>]
#
# --lod: which source LOD becomes Var<X>_Near (default 1). --variants: keep only these (default
# all). --textures: take Textures/ from another tier of the same asset (same atlas layout, other
# resolution). Elderberry (2026-10-04): mid pack, --lod 2 --variants A,B, 4K textures from the high
# pack -- its LOD1 is 11k-24k tris, and the plant is scaled up in-game.
#
# Written for the lady fern (2026-10-02). <src_dir> holds standard/<id>_tier_2_nonUE.gltf (the
# plain-glTF version: alpha MASK, base colour + opacity in one texture, no vertex colours) and
# Textures/. The glTF holds every variant of the plant as sibling nodes SM_<id>_Var<X> (LOD0),
# _Var<X>_LOD1 and _Var<X>_LOD2 (a camera-facing billboard card with its own texture -- not used:
# the understory has its own baked impostors).
#
# 1. per variant keeps the source LOD1 as Var<X>_Near (transforms applied: metres, upright, pivot
#    = the plant's root as scanned) and a Decimate (collapse) copy as Var<X>_Far (--far-ratio of
#    Near's tris, never below FAR_MIN_TRIS).
# 2. the source has NO vertex normals -> smooth-shaded ones are computed here.
# 3. copies Textures/T_<id>_2K_B-O.png -> textures/<name>_diffuse.png (alpha = opacity) and
#    T_<id>_2K_N.png -> textures/<name>_normal.png. The ORT map (occlusion / roughness /
#    translucency) is not copied: the foliage shader uses flat roughness + flat backlight.
# 4. prints the diffuse's mean linear luminance over its opaque texels next to fern_02's, and the
#    grey albedo (sRGB) that scales it to fern_02 -- the "albedo" value for MATERIALS in
#    tools/setup_understory_assets.gd.
# 5. exports <name>.glb with NO images: it renders through <name>_material.tres.
import glob, os, shutil, sys
import bpy
import numpy as np

FAR_MIN_TRIS = 48

args = sys.argv[sys.argv.index("--") + 1:]
src_dir, name = args[0], args[1]
far_ratio = float(args[args.index("--far-ratio") + 1]) if "--far-ratio" in args else 0.25
near_lod = "_LOD" + (args[args.index("--lod") + 1] if "--lod" in args else "1")
variants = ["Var" + v for v in args[args.index("--variants") + 1].split(",")] if "--variants" in args else []
tex_dir = args[args.index("--textures") + 1] if "--textures" in args else src_dir
root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
dst = os.path.join(root, "assets", "models", "understory", name)
os.makedirs(os.path.join(dst, "textures"), exist_ok=True)

gltfs = glob.glob(os.path.join(src_dir, "standard", "*_nonUE.gltf"))
if len(gltfs) != 1:
    raise RuntimeError(f"expected one standard/*_nonUE.gltf in {src_dir}, got {gltfs}")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=gltfs[0])

def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)

def activate(o):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o

keep = []
report = []
for ob in sorted([o for o in bpy.data.objects if o.type == 'MESH' and o.name.endswith(near_lod)], key=lambda o: o.name):
    var = ob.name.split("_")[-2]  # SM_<id>_VarA_LOD1 -> VarA
    if variants and var not in variants:
        continue
    activate(ob)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    me = ob.data
    while me.color_attributes:
        me.color_attributes.remove(me.color_attributes[0])
    for p in me.polygons:
        p.use_smooth = True
    ob.name = me.name = f"{var}_Near"
    far = ob.copy()
    far.data = me.copy()
    bpy.context.collection.objects.link(far)
    far.name = far.data.name = f"{var}_Far"
    near_tris = tri_count(ob)
    target = max(FAR_MIN_TRIS, int(near_tris * far_ratio))
    if target < near_tris:
        mod = far.modifiers.new("Decimate", 'DECIMATE')
        mod.decimate_type = 'COLLAPSE'
        mod.ratio = target / near_tris
        activate(far)
        bpy.ops.object.modifier_apply(modifier=mod.name)
    keep += [ob, far]
    vs = np.array([v.co for v in me.vertices])
    lo, hi = vs.min(axis=0), vs.max(axis=0)
    report.append(f"{var}: near {near_tris} tris, far {tri_count(far)} tris, "
                  f"{hi[0] - lo[0]:.2f} x {hi[1] - lo[1]:.2f} m wide, {hi[2]:.2f} m tall, {-lo[2]:.2f} m below ground")
for o in [o for o in bpy.data.objects if o not in keep]:
    bpy.data.objects.remove(o, do_unlink=True)
for m in bpy.data.materials:
    m.name = name + "_material"
print("VARIANTS\n  " + "\n  ".join(report))

# 3. textures
tex = glob.glob(os.path.join(tex_dir, "Textures", "T_*_?K_B-O.png")) + glob.glob(os.path.join(tex_dir, "Textures", "T_*_?K_N.png"))
tex = [t for t in tex if "Billboard" not in t]
if len(tex) != 2:
    raise RuntimeError(f"expected one B-O and one N texture, got {tex}")
diffuse = os.path.join(dst, "textures", f"{name}_diffuse.png")
shutil.copy2(tex[0], diffuse)
shutil.copy2(tex[1], os.path.join(dst, "textures", f"{name}_normal.png"))
print(f"TEXTURES {tex[0]} -> {diffuse}; {tex[1]} -> {name}_normal.png")

# 4. brightness vs fern_02 (raw texel values -> linear by hand, opaque texels only)
def leaf_luminance(path):
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = 'Non-Color'
    px = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(-1, 4)
    solid = px[px[:, 3] >= 0.5][:, :3]
    lin = np.where(solid <= 0.04045, solid / 12.92, ((solid + 0.055) / 1.055) ** 2.4)
    return float((lin @ np.array([0.2126, 0.7152, 0.0722])).mean()), len(solid) / len(px), tuple(img.size)

lum, cover, size = leaf_luminance(diffuse)
ref_path = os.path.join(root, "assets", "models", "understory", "fern_02", "textures", "fern_02_diffuse.tga")
ref, _, _ = leaf_luminance(ref_path)
k = min(1.0, ref / lum)
grey = k * 12.92 if k <= 0.0031308 else 1.055 * k ** (1 / 2.4) - 0.055
print(f"BRIGHTNESS {name} diffuse {size[0]}x{size[1]}, {100 * cover:.0f}% opaque, leaf luminance {lum:.4f}; "
      f"fern_02 {ref:.4f} -> albedo grey (sRGB) {grey:.2f}")

# 5. export
bpy.ops.object.select_all(action='DESELECT')
for o in keep:
    o.select_set(True)
glb = os.path.join(dst, f"{name}.glb")
bpy.ops.export_scene.gltf(
    filepath=glb,
    export_format='GLB',
    use_selection=True,
    export_apply=True,
    export_yup=True,
    export_materials='EXPORT',
    export_image_format='NONE',
    export_texcoords=True,
    export_normals=True,
    export_tangents=False,
    export_animations=False,
)
print(f"EXPORTED {glb} ({os.path.getsize(glb) / 1e6:.2f} MB)")
