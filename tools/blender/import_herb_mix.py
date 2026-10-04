# Takes the clover carpet and one dandelion clump out of the Sketchfab scene
# raw-assets/models/flowers/grass_vegitation_mix.glb and writes them into
# assets/models/understory/clover/ and assets/models/understory/dandelion/ in the layout
# tools/setup_understory_assets.gd expects (same as import_megascans_plant.py). Run with Blender:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/import_herb_mix.py -- <grass_vegitation_mix.glb>
#
# Written 2026-10-04. The scene is one ~3 m meadow patch: a clover carpet (one mesh, 2741 tris,
# 2.6 x 2.8 m), 14 copies of one dandelion clump (369 tris), 5 grass tufts and 45 copies of a
# 4130-tri grass blade patch. The grass is NOT taken: the GPU grass field already covers the ground.
#
# 1. clover: the carpet is cut into 2 x 2 pieces (whole leaves, by leaf centre) -> VarA..D_Near,
#    each ~1.3 m, so a piece follows uneven ground better than the 2.7 m carpet and the patches
#    repeat less. Each piece is centred on its own footprint; heights stay as in the scene.
# 2. dandelion: the most upright of the 14 copies -> VarA_Near, centred on its footprint.
# 3. textures: the embedded 1K base colour (alpha = cutout) -> textures/<name>_diffuse.png; the
#    dandelion's normal map -> dandelion_normal.png; the clover has none -> a flat one is written.
# 4. prints each diffuse's mean leaf luminance next to fern_02's and the grey albedo that matches
#    it (the "albedo" value for MATERIALS in tools/setup_understory_assets.gd).
# 5. exports <name>.glb with NO images.
import os, sys
import bpy, bmesh
import numpy as np

CLOVER_MAT = "3457643232"
DANDELION_MAT = "383085165"

src = sys.argv[sys.argv.index("--") + 1]
root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
base = os.path.join(root, "assets", "models", "understory")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

def activate(o):
    bpy.ops.object.select_all(action='DESELECT')
    o.select_set(True)
    bpy.context.view_layer.objects.active = o

def with_material(prefix):
    return [o for o in bpy.data.objects if o.type == 'MESH' and o.data.materials and o.data.materials[0].name.startswith(prefix)]

def world_bounds(o):
    vs = np.array([o.matrix_world @ v.co for v in o.data.vertices])
    return vs.min(axis=0), vs.max(axis=0)

## Own mesh copy, world transform baked in, no parent, smooth, no vertex colours.
def detach(o, name):
    o.data = o.data.copy()
    activate(o)
    bpy.ops.object.parent_clear(type='CLEAR_KEEP_TRANSFORM')
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    me = o.data
    while me.color_attributes:
        me.color_attributes.remove(me.color_attributes[0])
    for p in me.polygons:
        p.use_smooth = True
    o.name = me.name = name
    return o

def centre_xy(o):
    vs = np.array([v.co for v in o.data.vertices])
    c = (vs.min(axis=0) + vs.max(axis=0)) * 0.5
    for v in o.data.vertices:
        v.co.x -= c[0]
        v.co.y -= c[1]
    vs = np.array([v.co for v in o.data.vertices])
    lo, hi = vs.min(axis=0), vs.max(axis=0)
    tris = sum(len(p.vertices) - 2 for p in o.data.polygons)
    return f"{o.name}: {tris} tris, {hi[0] - lo[0]:.2f} x {hi[1] - lo[1]:.2f} m wide, z {lo[2]:.3f}..{hi[2]:.3f} m"

def material_images(o):
    col = nor = None
    for n in o.data.materials[0].node_tree.nodes:
        if n.type == 'TEX_IMAGE' and n.image:
            if n.image.colorspace_settings.name == 'Non-Color':
                nor = n.image
            else:
                col = n.image
    return col, nor

def save_image(img, path):
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()

def leaf_luminance(path):
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = 'Non-Color'
    px = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(-1, 4)
    solid = px[px[:, 3] >= 0.5][:, :3]
    lin = np.where(solid <= 0.04045, solid / 12.92, ((solid + 0.055) / 1.055) ** 2.4)
    return float((lin @ np.array([0.2126, 0.7152, 0.0722])).mean()), len(solid) / len(px)

ref, _ = leaf_luminance(os.path.join(base, "fern_02", "textures", "fern_02_diffuse.tga"))

def finish(name, objects, report):
    dst = os.path.join(base, name)
    os.makedirs(os.path.join(dst, "textures"), exist_ok=True)
    col, nor = material_images(objects[0])
    diffuse = os.path.join(dst, "textures", f"{name}_diffuse.png")
    save_image(col, diffuse)
    normal = os.path.join(dst, "textures", f"{name}_normal.png")
    if nor:
        save_image(nor, normal)
    else:
        flat = bpy.data.images.new(f"{name}_flat_normal", 16, 16, alpha=False)
        flat.pixels = [0.5, 0.5, 1.0, 1.0] * (16 * 16)
        save_image(flat, normal)
    lum, cover = leaf_luminance(diffuse)
    k = min(1.0, ref / lum)
    grey = k * 12.92 if k <= 0.0031308 else 1.055 * k ** (1 / 2.4) - 0.055
    objects[0].data.materials[0].name = name + "_material"
    bpy.ops.object.select_all(action='DESELECT')
    for o in objects:
        o.select_set(True)
    glb = os.path.join(dst, f"{name}.glb")
    bpy.ops.export_scene.gltf(filepath=glb, export_format='GLB', use_selection=True, export_apply=True,
        export_yup=True, export_materials='EXPORT', export_image_format='NONE', export_texcoords=True,
        export_normals=True, export_tangents=False, export_animations=False)
    print(f"HERB {name}: normal map {'from the scene' if nor else 'FLAT (none in the scene)'}, {100 * cover:.0f}% opaque, "
          f"leaf luminance {lum:.4f}; fern_02 {ref:.4f} -> albedo grey (sRGB) {grey:.2f}; {os.path.getsize(glb) / 1e3:.0f} kB\n  "
          + "\n  ".join(report))
    # Out of the scene, so the next plant's VarA_Near doesn't become VarA_Near.001.
    for o in objects:
        me = o.data
        bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.meshes.remove(me)

# -- dandelion: the most upright copy (smallest height) --
copies = with_material(DANDELION_MAT)
def height(o):
    lo, hi = world_bounds(o)
    return hi[2] - lo[2]
copy_heights = f"{len(copies)} copies in the scene, heights {min(map(height, copies)):.2f}-{max(map(height, copies)):.2f} m"
dandelion = detach(min(copies, key=height), "VarA_Near")
finish("dandelion", [dandelion], [copy_heights, centre_xy(dandelion)])

# -- clover: 2 x 2 pieces, whole leaves (connected islands) by island centre --
carpet = detach(with_material(CLOVER_MAT)[0], "Carpet")
lo, hi = world_bounds(carpet)
mid = (lo + hi) * 0.5
bm = bmesh.new()
bm.from_mesh(carpet.data)
bm.faces.ensure_lookup_table()
piece_of_face = [-1] * len(bm.faces)
islands = 0
for f in bm.faces:
    if piece_of_face[f.index] >= 0:
        continue
    stack, island = [f], []
    piece_of_face[f.index] = 9
    while stack:
        g = stack.pop()
        island.append(g)
        for v in g.verts:
            for h in v.link_faces:
                if piece_of_face[h.index] < 0:
                    piece_of_face[h.index] = 9
                    stack.append(h)
    c = sum((g.calc_center_median() for g in island), start=island[0].calc_center_median() * 0.0) / len(island)
    q = (1 if c.x > mid[0] else 0) + (2 if c.y > mid[1] else 0)
    for g in island:
        piece_of_face[g.index] = q
    islands += 1
bm.free()
pieces, report = [], [f"carpet {hi[0] - lo[0]:.2f} x {hi[1] - lo[1]:.2f} m, z {lo[2]:.3f}..{hi[2]:.3f}, {islands} leaf islands"]
for q in range(4):
    ob = carpet.copy()
    ob.data = carpet.data.copy()
    bpy.context.collection.objects.link(ob)
    ob.name = ob.data.name = f"Var{'ABCD'[q]}_Near"
    pb = bmesh.new()
    pb.from_mesh(ob.data)
    bmesh.ops.delete(pb, geom=[f for f in pb.faces if piece_of_face[f.index] != q], context='FACES')
    pb.to_mesh(ob.data)
    pb.free()
    report.append(centre_xy(ob))
    pieces.append(ob)
finish("clover", pieces, report)
