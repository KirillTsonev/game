# Brings one Megascans asset (Fab "converted" glb, e.g. <asset>_mid.glb) into
# assets/models/ground_debris/<name>/. Run with Blender's own Python:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_megascans_glb.py -- <src_glb|src_fbx> <name> [--recenter]
#       [--ratios 1,0.35,0.1] [--mesh <name part>] [--scale <s>] [--textures <dir> <prefix>]
#       [--dir <folder>]   (several assets in one folder sharing its textures -- the debris-pack sticks)
#       [--rotate x,y,z] [--floor]   (degrees; stand a sideways scan up -- then --recenter --floor)
#       [--loose-roles] [--tex-size <px>]   (non-Megascans sources -- the pine cones, 2026-10-02)
#       [--out <category>]   (assets/models/<category>/<name>/ instead of ground_debris -- cliffs, 2026-10-02:
#        nordic_coastal_cliff_huge = --out cliffs --scale 0.7 --recenter --tex-size 2048 (_large: --scale 2)
#        --ratios 1,0.5,0.25,0.12; a cliff needs its width on X and the rock face toward Godot +Z -- --rotate if not)
#
# Written for the deadfall stumps/logs (2026-09-30). Fab's converted glbs are one mesh under a chain
# of Sketchfab empties, with base colour / ORM / normal embedded as Image_0/1/2.
#
# 1. flattens the empties into one mesh (transforms applied, metres, Z-up -> exported Y-up).
#    --mesh: the source holds several meshes (tree_debris_pack) -- keep only the one whose name
#    contains this. --scale: uniform scale baked into the vertices (the small sticks are scaled up
#    to deadfall size; the 2K texture has texel density to spare).
# 2. --recenter: moves the mesh so its bbox is centred on the origin in X/Y (the log glbs had the
#    pivot at one end); the ground level (Z) is never touched. Stumps keep the scan's own pivot.
# 3. writes the embedded textures out byte-for-byte (no re-encode) as
#    textures/<name>_diff_2k.jpg, <name>_orm_2k.png (R = AO, G = roughness, B = metallic),
#    <name>_nor_gl_2k.jpg (glTF normal = OpenGL convention, same as Godot).
#    --textures <dir> <prefix>: loose Unreal-named textures instead (the FBX download): copies
#    <prefix>_BC.png / _ORM.png / _N.png to _diff / _orm / _nor_gl (.png). Check the normal map's
#    convention first -- tree_branch_arbem's _N was tested OpenGL (vs its height map, 2026-09-30).
#    --loose-roles: the source has no ORM (or no normal map either) -- write whichever of the three
#    it has; only the base colour is required. --tex-size <px>: embedded textures larger than this
#    are scaled down and re-encoded, and the files are named for it (1024 -> _1k).
# 4. builds LODs with Decimate (collapse): <name>_LOD0, _LOD1, _LOD2 -- sibling nodes, which
#    Terrain3D uses as LODs (same layout as the rock glbs). --ratios sets each LOD's share of the
#    source tris (default 1,0.35,0.1: LOD0 = the source). A first ratio < 1 decimates LOD0 too --
#    used for stump_broken, whose source is 20.5k tris for a 0.4 m stump (0.35,0.1,0.03).
# 5. exports <name>.glb with NO images: it renders through <name>_material.tres
#    (tools/setup_ground_debris_assets.gd)
import os, shutil, sys
import bpy
from mathutils import Matrix, Vector

LOD_RATIOS = [1.0, 0.35, 0.1]  # of the source triangle count
LOD_MIN_TRIS = 150             # never decimate below this

args = sys.argv[sys.argv.index("--") + 1:]
src, name = args[0], args[1]
recenter = "--recenter" in args
if "--ratios" in args:
    LOD_RATIOS = [float(x) for x in args[args.index("--ratios") + 1].split(",")]
mesh_key = args[args.index("--mesh") + 1] if "--mesh" in args else ""
bake_scale = float(args[args.index("--scale") + 1]) if "--scale" in args else 1.0
loose_tex = args[args.index("--textures") + 1:args.index("--textures") + 3] if "--textures" in args else []
folder = args[args.index("--dir") + 1] if "--dir" in args else name  # also the texture name prefix
loose_roles = "--loose-roles" in args
tex_size = int(args[args.index("--tex-size") + 1]) if "--tex-size" in args else 0
res_tag = f"{tex_size // 1024}k" if tex_size else "2k"
category = args[args.index("--out") + 1] if "--out" in args else "ground_debris"  # assets/models/<category>/
dst = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "models", category, folder))
os.makedirs(os.path.join(dst, "textures"), exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
if src.lower().endswith(".fbx"):
    bpy.ops.import_scene.fbx(filepath=src)
else:
    bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.data.objects if o.type == 'MESH' and mesh_key in o.name]
if len(meshes) != 1:
    raise RuntimeError(f"expected one mesh matching '{mesh_key}' in {src}, got {[o.name for o in meshes]}")
ob = meshes[0]
for o in [o for o in bpy.data.objects if o.type == 'MESH' and o != ob]:
    bpy.data.objects.remove(o, do_unlink=True)

# 1. flatten
mw = ob.matrix_world.copy()
ob.parent = None
ob.matrix_world = mw
bpy.ops.object.select_all(action='DESELECT')
ob.select_set(True)
bpy.context.view_layer.objects.active = ob
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in [o for o in bpy.data.objects if o.type == 'EMPTY']:
    bpy.data.objects.remove(o, do_unlink=True)
if bake_scale != 1.0:
    ob.data.transform(Matrix.Scale(bake_scale, 4))
    ob.data.update()
# --rotate x,y,z (degrees, Blender Z-up axes): stand a scan the right way up. stump_broken is
# authored lying on its side (trunk along -X, roots at +X) and read in-game as a stump planted
# sideways -> 0,90,0 stands it on its roots.
if "--rotate" in args:
    from mathutils import Euler
    from math import radians
    rx, ry, rz = (radians(float(a)) for a in args[args.index("--rotate") + 1].split(","))
    ob.data.transform(Euler((rx, ry, rz)).to_matrix().to_4x4())
    ob.data.update()

# 2. recenter (X/Y only), measured from the vertices -- bound_box can be stale here
if recenter:
    xs = [v.co.x for v in ob.data.vertices]
    ys = [v.co.y for v in ob.data.vertices]
    ob.data.transform(Matrix.Translation((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, 0)))
    ob.data.update()
# --floor: lowest vertex to z = 0 (the debris-pack sticks are centred on their own middle, so half
# of each would sit below the ground).
if "--floor" in args:
    ob.data.transform(Matrix.Translation((0, 0, -min(v.co.z for v in ob.data.vertices))))
    ob.data.update()

# 3. textures: loose files (--textures), or the embedded ones found by what each image node feeds
if loose_tex:
    tdir, prefix = loose_tex
    for role, suffix in (("diff", "BC"), ("orm", "ORM"), ("nor_gl", "N")):
        s = os.path.join(tdir, f"{prefix}_{suffix}.png")
        d = os.path.join(dst, "textures", f"{folder}_{role}_2k.png")
        shutil.copy2(s, d)
        print(f"TEXTURE {role} {s} -> {d}")
else:
    mat = ob.material_slots[0].material
    roles = {}
    for nd in mat.node_tree.nodes:
        if nd.type != 'TEX_IMAGE' or not nd.image:
            continue
        for out in nd.outputs:
            for l in out.links:
                if l.to_node.type == 'BSDF_PRINCIPLED' and l.to_socket.name == "Base Color":
                    roles["diff"] = nd.image
                elif l.to_node.type == 'NORMAL_MAP':
                    roles["nor_gl"] = nd.image
                elif l.to_node.type == 'SEPARATE_COLOR':
                    roles["orm"] = nd.image
    if set(roles) != {"diff", "orm", "nor_gl"} and not (loose_roles and "diff" in roles):
        raise RuntimeError(f"unexpected image roles {list(roles)}")
    for role, img in roles.items():
        ext = ".png" if img.file_format == 'PNG' else ".jpg"
        path = os.path.join(dst, "textures", f"{folder}_{role}_{res_tag}{ext}")
        src_size = tuple(img.size)
        if tex_size and max(src_size) > tex_size:
            img.scale(tex_size, tex_size)
            img.save(filepath=path, quality=92, save_copy=True)
        else:
            with open(path, "wb") as f:
                f.write(img.packed_file.data)
        print(f"TEXTURE {role} {src_size[0]}x{src_size[1]} -> {path} ({os.path.getsize(path) / 1e3:.0f} kB)")
    mat.name = folder + "_material"

# 4. LODs
def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)

def decimate(o, ratio):
    mod = o.modifiers.new("Decimate", 'DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = ratio
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.modifier_apply(modifier=mod.name)

src_tris = tri_count(ob)
src = ob.copy()  # untouched source; every LOD is decimated from it
src.data = ob.data.copy()
lods = []
for i, ratio in enumerate(LOD_RATIOS):
    target = max(LOD_MIN_TRIS, int(src_tris * ratio))
    if lods and target >= tri_count(lods[-1]):
        break
    lod = ob if i == 0 else src.copy()
    if i > 0:
        lod.data = src.data.copy()
        bpy.context.collection.objects.link(lod)
    lod.name = lod.data.name = f"{name}_LOD{i}"
    if target < src_tris:
        decimate(lod, target / src_tris)
    lods.append(lod)
bpy.data.objects.remove(src, do_unlink=True)

vs = [v.co for v in ob.data.vertices]
lo = Vector([min(v[k] for v in vs) for k in range(3)])
hi = Vector([max(v[k] for v in vs) for k in range(3)])
print(f"SIZE {name}: {hi.x - lo.x:.2f} x {hi.y - lo.y:.2f} x {hi.z - lo.z:.2f} m (Blender X/Y/Z), "
      f"centre xy ({(lo.x + hi.x) / 2:.3f}, {(lo.y + hi.y) / 2:.3f}), min z {lo.z:.3f}")
print("LODS " + ", ".join(f"{o.name} {tri_count(o)}" for o in lods))

# 5. export
bpy.ops.object.select_all(action='DESELECT')
for o in lods:
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
