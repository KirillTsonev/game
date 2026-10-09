# Prepares the downloaded photo scan of a hilltop village (calcata.glb) as a distant set piece:
# assets/models/village/calcata/calcata_village.glb. Run with Blender:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/prepare_cliff_village.py -- "D:\Downloads\calcata.glb"
#
# Written 2026-10-09 for the village at the far end of the castle's bridge (TerrainCastle). It is
# only ever seen from the valley floor, hundreds of metres away, so the scan is cut down hard:
# 1. the scan lies on its side (its roofs face Blender's -Y): turned upright;
# 2. only the village and the rock right under it are kept -- everything within an ellipse fitted
#    to the houses (the highest part of the scan) and no lower than KEEP_HEIGHT below the roofs.
#    The forested slopes around it are scan blobs in daylight colours and are dropped;
# 3. decimated to about TARGET_TRIS triangles, the 8K texture shrunk to TEXTURE_SIZE;
# 4. scaled to metres (SCALE: the houses come out life-size), the village's middle at the
#    origin, the cut-off bottom at height 0, its long axis along Blender's Y (Godot's Z).
# The game stands it on a rock base of its own (TerrainCastle.spawn_placeholder).
import math, os, sys
import bpy, bmesh
import numpy as np
from mathutils import Matrix

SCALE = 11.5         # scan units -> metres
HOUSE_BAND = 1.2     # scan units below the highest point that count as "the houses" for the fit
# 2026-10-09, after the first try in the game (2.6 sigmas, 4.5 units): the scan's own cliff and
# its bushes were still there under the houses and the piece was wider than the rock base built
# for it. Now only the houses and the top of the rock they stand on (about 12 m under street level).
ELLIPSE_SIGMAS = 2.05 # the kept ellipse's radii, in standard deviations of the houses' positions
KEEP_HEIGHT = 2.4     # scan units below the highest point that are kept
TARGET_TRIS = 90000
TEXTURE_SIZE = 2048

src = sys.argv[sys.argv.index("--") + 1]
dst_dir = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "models", "village", "calcata"))
os.makedirs(dst_dir, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
	o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.join()
obj = bpy.context.view_layer.objects.active
world = obj.matrix_world.copy()
obj.parent = None
obj.data.transform(world)
obj.matrix_world = Matrix.Identity(4)
obj.data.transform(Matrix.Rotation(-math.pi * 0.5, 4, "X")) # the scan's up (-Y) to +Z

mesh = obj.data
co = np.empty(len(mesh.vertices) * 3, dtype=np.float64)
mesh.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
top = float(np.percentile(co[:, 2], 99.9))
houses = co[co[:, 2] > top - HOUSE_BAND][:, :2]
centre = houses.mean(axis=0)
values, vectors = np.linalg.eigh(np.cov((houses - centre).T))
major = vectors[:, 1] # eigh sorts ascending: the long axis is the last
minor = vectors[:, 0]
radius_major = ELLIPSE_SIGMAS * math.sqrt(values[1])
radius_minor = ELLIPSE_SIGMAS * math.sqrt(values[0])
rel = co[:, :2] - centre
inside = (rel @ major / radius_major) ** 2 + (rel @ minor / radius_minor) ** 2 <= 1.0
keep = inside & (co[:, 2] >= top - KEEP_HEIGHT)
print("VILLAGE: %d of %d vertices kept; ellipse %.1f x %.1f scan units (%.0f x %.0f m)" % (
	int(keep.sum()), len(co), radius_major * 2.0, radius_minor * 2.0, radius_major * 2.0 * SCALE, radius_minor * 2.0 * SCALE))

bm = bmesh.new()
bm.from_mesh(mesh)
bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not keep[v.index]], context="VERTS")
bmesh.ops.triangulate(bm, faces=bm.faces[:])
before = len(bm.faces)
bm.to_mesh(mesh)
bm.free()

bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.context.view_layer.objects.active = obj
if before > TARGET_TRIS:
	modifier = obj.modifiers.new("Decimate", "DECIMATE")
	modifier.ratio = TARGET_TRIS / before
	bpy.ops.object.modifier_apply(modifier=modifier.name)

# Into place: the village's middle at the origin, its long axis along +Y, the bottom at 0, metres.
angle = math.atan2(major[1], major[0])
mesh.transform(Matrix.Translation((-centre[0], -centre[1], -(top - KEEP_HEIGHT))))
mesh.transform(Matrix.Rotation(math.pi * 0.5 - angle, 4, "Z"))
mesh.transform(Matrix.Scale(SCALE, 4))
mesh.update()
for polygon in mesh.polygons:
	polygon.use_smooth = True

co = np.empty(len(mesh.vertices) * 3, dtype=np.float64)
mesh.vertices.foreach_get("co", co)
co = co.reshape(-1, 3)
inner = (co[:, 0] / (radius_minor * SCALE * 0.7)) ** 2 + (co[:, 1] / (radius_major * SCALE * 0.7)) ** 2 <= 1.0
print("VILLAGE: %d -> %d triangles; size %.0f x %.0f m, %.0f m tall; highest roof %.1f m, middle of the village's surface %.1f m above the cut-off bottom" % (
	before, len(mesh.polygons), co[:, 0].max() - co[:, 0].min(), co[:, 1].max() - co[:, 1].min(), co[:, 2].max() - co[:, 2].min(),
	float(np.percentile(co[:, 2], 99.9)), float(np.median(co[inner][:, 2]))))

for image in bpy.data.images:
	if image.size[0] > TEXTURE_SIZE:
		print("VILLAGE: texture %s %dx%d -> %d" % (image.name, image.size[0], image.size[1], TEXTURE_SIZE))
		image.scale(TEXTURE_SIZE, TEXTURE_SIZE)
		image.pack()

obj.name = "calcata_village"
out_path = os.path.join(dst_dir, "calcata_village.glb")
bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", use_selection=True, export_yup=True, export_apply=True,
	export_tangents=False, export_image_format="JPEG", export_jpeg_quality=85)
print("VILLAGE: wrote %s (%.1f MB)" % (out_path, os.path.getsize(out_path) / 1048576.0))
