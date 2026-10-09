# Cuts valley-wall segments out of a downloaded mountain model (one terrain-like mesh with baked
# base colour / ORM / normal textures) into assets/models/mountains/<name>/. Run with Blender:
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\blender.exe" -b --factory-startup
#       --python tools/blender/cut_mountain_wall.py -- <src_glb or .obj> <name>
#
# Written 2026-10-08 for the valley's mountain walls (MountainWalls, scripts/terrain/mountain_walls.gd).
# A segment is a rectangle on the source seen from above: its front edge is the wall's foot (toward
# the valley), its depth runs up the face to a little behind the crest. Only that part is kept --
# the back of the mountain is never seen from the valley.
#
# Per segment in SEGMENTS[<name>]:
# 1. cuts the rectangle out of the mesh (4 bisects), scales it by "scale" and moves it into the
#    wall frame: Godot +X = depth (away from the valley, front edge at x = 0), Godot Z = along the
#    wall (centred), Y = up with the front edge at y = 0. Over the first FOOT_BLEND m of the depth
#    the heights fade in from 0, level at the front edge: the game adds its own ramp under the
#    first row (MountainWalls._ramp_height), fitted to the terrain it starts from.
#    Both ends are shaped to ONE cross-section shared by every segment (_end_profile), blended in
#    over END_BLEND m, so any two segments meet without a gap. Over the last END_OVERLAP m the
#    surface also dips by END_SINK: neighbours are placed overlapping by END_OVERLAP
#    (MountainWalls.END_OVERLAP must match), and the two dipping ends cross inside the overlap
#    instead of lying on top of each other.
# 2. crops the three textures to the part the segment uses and remaps its UVs to the crop
#    (textures/<name>_<seg>_diff.png, _orm.png (R = AO, G = roughness, B = metallic), _nor_gl.png).
#    Only for the sources in WITH_MAPS.
# 3. exports <name>_<seg>.glb with NO images; MountainWalls builds the material in code.
#
# A source of several meshes is joined into one first; a slice denser than MAX_TRIS is decimated.
#
# Picking rectangles: the picks below came from a search over the model's heights for rectangles
# whose face rises steadily from a level front edge to a crest at 70-85 % of the depth.
import math, os, sys
import bpy, bmesh
import numpy as np
from mathutils import Matrix, Vector

# "front": middle of the front edge on the source (its X / Y, Blender Z-up), "angle": direction of
# the depth axis in degrees from +X, "length" / "depth": the rectangle in source units, "scale":
# source units -> metres.
SEGMENTS = {
	"rugged_mountain": [
		{"seg": "a", "front": (5700.0, 3600.0), "angle": 150.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "b", "front": (2700.0, 3300.0), "angle": 30.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "c", "front": (3150.0, 7050.0), "angle": 300.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
	],
	# 2026-10-08, for the rows further back (their crests are 350-440 m above the foot as cut):
	"landscape_sketching": [ # a sharp horn above terraced ridges; 2 x 2 units
		{"seg": "a", "front": (0.672, -0.384), "angle": 300.0, "length": 0.24, "depth": 0.336, "scale": 1250.0},
		{"seg": "b", "front": (0.24, -0.624), "angle": 270.0, "length": 0.24, "depth": 0.336, "scale": 1250.0},
		{"seg": "c", "front": (0.432, -0.48), "angle": 270.0, "length": 0.24, "depth": 0.336, "scale": 1250.0},
	],
	"mountain_alpine_style": [ # one pyramid peak with gullies; 5 x 5 units
		{"seg": "a", "front": (1.2, 0.36), "angle": 195.0, "length": 0.6, "depth": 0.84, "scale": 500.0},
		{"seg": "b", "front": (0.36, 1.44), "angle": 255.0, "length": 0.6, "depth": 0.84, "scale": 500.0},
		{"seg": "c", "front": (-0.36, 0.6), "angle": 0.0, "length": 0.6, "depth": 0.84, "scale": 500.0},
	],
	# 2026-10-09, for variety (Kirill): five more of the downloaded models, their rectangles from
	# the same kind of search (crest at about 79 % of the depth, 260-370 m above the foot).
	"mountain_lakes_211109": [ # a range of ridges and valleys, as steep as rugged_mountain; x / y -4000..12000; mesh Object_4
		{"seg": "a", "front": (500.0, 8250.0), "angle": 300.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "b", "front": (2500.0, 10750.0), "angle": 315.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "c", "front": (4500.0, -2250.0), "angle": 195.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
	],
	"mountain_lake_211106": [ # the same kind of range, broader and gentler; mesh Object_4
		{"seg": "a", "front": (9500.0, 3250.0), "angle": 345.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "b", "front": (8750.0, 2250.0), "angle": 330.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
		{"seg": "c", "front": (2250.0, 9000.0), "angle": 105.0, "length": 1000.0, "depth": 1400.0, "scale": 0.3},
	],
	"mountain_1": [ # a jagged multi-peak massif; 1000 x 1000 units, four meshes
		{"seg": "a", "front": (-343.75, 109.375), "angle": 285.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
		{"seg": "b", "front": (-62.5, 328.125), "angle": 300.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
		{"seg": "c", "front": (250.0, -46.875), "angle": 165.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
	],
	"mountain_2": [ # one broad peak with a steep face; same layout as mountain_1
		{"seg": "a", "front": (-140.625, 171.875), "angle": 345.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
		{"seg": "b", "front": (-78.125, -109.375), "angle": 150.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
		{"seg": "c", "front": (-234.375, -140.625), "angle": 75.0, "length": 62.5, "depth": 87.5, "scale": 4.8},
	],
	"terrain005": [ # Terrain005_1K.obj: a huge massif with radial ridges, the steepest of all; 5000 x 5000 units, 2 M triangles
		{"seg": "a", "front": (3750.0, 2500.0), "angle": 165.0, "length": 500.0, "depth": 700.0, "scale": 0.6},
		{"seg": "b", "front": (2125.0, 3625.0), "angle": 195.0, "length": 500.0, "depth": 700.0, "scale": 0.6},
		{"seg": "c", "front": (2500.0, 2000.0), "angle": 60.0, "length": 500.0, "depth": 700.0, "scale": 0.6},
	],
}
# Sources whose baked textures are cropped and written out per segment. The others are several
# meshes with UVs all over their textures (a crop would be nearly the whole 4K map): they are
# exported as shape only, and the game draws them with its rock shader alone.
WITH_MAPS = {"rugged_mountain", "mountain_lakes_211109", "mountain_lake_211106"}
# Sources that hold more than the terrain (water surfaces as separate meshes): the one mesh to cut.
ONLY_MESH = {"mountain_lakes_211109": "Object_4", "mountain_lake_211106": "Object_4"}
MAX_TRIS = 6000    # a cut slice with more triangles than this is decimated down to it
FOOT_BLEND = 110.0 # m of depth over which the slice's own heights fade in from 0
FRONT_BAND = 0.06  # share of the depth whose mean height counts as the front edge's level
END_BLEND = 70.0   # m at each end over which the heights blend into the shared end profile
END_OVERLAP = 10.0 # m at each end that is fully the end profile (and overlaps the neighbour)
END_SINK = 3.0     # m the very end dips below the profile
END_CREST = 280.0  # m, the end profile's crest height above the foot
END_CREST_AT = 0.78  # share of the depth where the end profile's crest is
END_BACK_DROP = 0.3  # share of the crest height the end profile loses from the crest to the back edge
TEX_PAD = 8        # px kept around the used part of each texture
ROLES = {"Base Color": "diff", "Normal Map": "nor_gl", "Separate Color": "orm"}

def _smoothstep(lo, hi, x):
	t = min(max((x - lo) / (hi - lo), 0.0), 1.0)
	return t * t * (3.0 - 2.0 * t)

# Height above the foot (m) of the cross-section every segment ends in, `d` m from the front edge
# of a segment `depth` m deep: a smooth rise to the crest, then a gentle drop to the back edge.
def _end_profile(d, depth):
	crest_d = depth * END_CREST_AT
	d = min(max(d, 0.0), depth)  # a cut vertex can land a hair outside the rectangle
	if d <= crest_d:
		return END_CREST * math.sin(0.5 * math.pi * d / crest_d) ** 1.3
	back = (d - crest_d) / (depth - crest_d)
	return END_CREST * (1.0 - END_BACK_DROP * back * back)

args = sys.argv[sys.argv.index("--") + 1:]
src, name = args[0], args[1]
dst = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "models", "mountains", name))
os.makedirs(os.path.join(dst, "textures") if name in WITH_MAPS else dst, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
if src.lower().endswith(".obj"):
	bpy.ops.wm.obj_import(filepath=src)
else:
	bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH" and (name not in ONLY_MESH or o.name == ONLY_MESH[name])]
if not meshes:
	raise SystemExit("no mesh in %s" % src)
if len(meshes) > 1:
	bpy.ops.object.select_all(action="DESELECT")
	for o in meshes:
		o.select_set(True)
	bpy.context.view_layer.objects.active = meshes[0]
	bpy.ops.object.join()
source = bpy.context.view_layer.objects.active if len(meshes) > 1 else meshes[0]
# Parent empties carry part of the transform: bake the whole of it into the vertices.
world = source.matrix_world.copy()
source.parent = None
source.data.transform(world)
source.matrix_world = Matrix.Identity(4)
with_maps = name in WITH_MAPS

# The source textures by role, as float arrays (rows bottom to top, like UV v).
textures = {}
for mat in (source.data.materials if with_maps else []): # the terrain's own, not e.g. a water surface's
	if mat is None or not mat.use_nodes:
		continue
	for node in mat.node_tree.nodes:
		if node.type != "TEX_IMAGE" or node.image is None:
			continue
		for output in node.outputs:
			for link in output.links:
				for key, role in ROLES.items():
					if link.to_node.name.startswith(key) or link.to_socket.name == key:
						img = node.image
						buf = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
						img.pixels.foreach_get(buf)
						textures[role] = (buf.reshape(img.size[1], img.size[0], 4), img.colorspace_settings.name)
print("CUT_WALL: textures found: %s" % ", ".join("%s %dx%d" % (r, t[0].shape[1], t[0].shape[0]) for r, t in textures.items()))

for spec in SEGMENTS[name]:
	seg_name = "%s_%s" % (name, spec["seg"])
	theta = math.radians(spec["angle"])
	depth_axis = Vector((math.cos(theta), math.sin(theta), 0.0))
	length_axis = Vector((-math.sin(theta), math.cos(theta), 0.0))
	front = Vector((spec["front"][0], spec["front"][1], 0.0))
	length, depth, scale = spec["length"], spec["depth"], spec["scale"]

	mesh = source.data.copy()
	bm = bmesh.new()
	bm.from_mesh(mesh)
	# Keep the inside of the rectangle: each plane's normal points out of it.
	for point, normal in [
		(front, -depth_axis), (front + depth_axis * depth, depth_axis),
		(front - length_axis * (length * 0.5), -length_axis), (front + length_axis * (length * 0.5), length_axis),
	]:
		geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
		bmesh.ops.bisect_plane(bm, geom=geom, plane_co=point, plane_no=normal, clear_outer=True, clear_inner=False)
	bmesh.ops.triangulate(bm, faces=bm.faces[:])
	if len(bm.faces) > MAX_TRIS:
		# Too dense for a distant ridge: through a temporary object, for the Decimate modifier.
		before = len(bm.faces)
		bm.to_mesh(mesh)
		bm.free()
		temp = bpy.data.objects.new("decimate_tmp", mesh)
		bpy.context.scene.collection.objects.link(temp)
		bpy.ops.object.select_all(action="DESELECT")
		temp.select_set(True)
		bpy.context.view_layer.objects.active = temp
		modifier = temp.modifiers.new("Decimate", "DECIMATE")
		modifier.ratio = MAX_TRIS / before
		bpy.ops.object.modifier_apply(modifier=modifier.name)
		mesh = temp.data
		bpy.data.objects.remove(temp)
		bm = bmesh.new()
		bm.from_mesh(mesh)
		bmesh.ops.triangulate(bm, faces=bm.faces[:])
		print("CUT_WALL: %s decimated %d -> %d tris" % (seg_name, before, len(bm.faces)))

	# Into the wall frame (Blender: X = depth, Y = along the wall, Z = up; exported Y-up). A turn,
	# never a mirror: mirroring flips every face, and the wall is then only visible from underneath.
	front_heights = []
	for v in bm.verts:
		rel = v.co - front
		d = rel.dot(depth_axis)
		along = rel.dot(length_axis)
		v.co = Vector((d, along, v.co.z))
		if d < depth * FRONT_BAND:
			front_heights.append(v.co.z)
	front_level = sum(front_heights) / len(front_heights)
	top = 0.0
	half = length * scale * 0.5
	for v in bm.verts:
		d_m = v.co.x * scale
		along_m = abs(v.co.y) * scale
		height = (v.co.z - front_level) * scale
		to_profile = _smoothstep(half - END_BLEND, half - END_OVERLAP, along_m)
		height += (_end_profile(d_m, depth * scale) - height) * to_profile
		height *= _smoothstep(0.0, FOOT_BLEND, d_m)
		height -= END_SINK * _smoothstep(half - END_OVERLAP, half, along_m)
		v.co = Vector((d_m, v.co.y * scale, height))
		top = max(top, height)

	for face in bm.faces:
		face.smooth = True
	x0 = x1 = y0 = y1 = 0
	if with_maps:
		# Textures: crop to the UVs in use, remap the UVs to the crop.
		uv_layer = bm.loops.layers.uv.active
		us = [loop[uv_layer].uv.x for face in bm.faces for loop in face.loops]
		vs = [loop[uv_layer].uv.y for face in bm.faces for loop in face.loops]
		any_tex = next(iter(textures.values()))[0]
		tex_h, tex_w = any_tex.shape[0], any_tex.shape[1]
		x0 = max(int(math.floor(min(us) * tex_w)) - TEX_PAD, 0)
		x1 = min(int(math.ceil(max(us) * tex_w)) + TEX_PAD, tex_w)
		y0 = max(int(math.floor(min(vs) * tex_h)) - TEX_PAD, 0)
		y1 = min(int(math.ceil(max(vs) * tex_h)) + TEX_PAD, tex_h)
		for face in bm.faces:
			for loop in face.loops:
				uv = loop[uv_layer].uv
				loop[uv_layer].uv = ((uv.x * tex_w - x0) / (x1 - x0), (uv.y * tex_h - y0) / (y1 - y0))
		for role, (pixels, colorspace) in textures.items():
			crop = np.ascontiguousarray(pixels[y0:y1, x0:x1, :])
			out_img = bpy.data.images.new("%s_%s" % (seg_name, role), x1 - x0, y1 - y0, alpha=False)
			out_img.colorspace_settings.name = colorspace
			out_img.pixels.foreach_set(crop.ravel())
			out_img.filepath_raw = os.path.join(dst, "textures", "%s_%s.png" % (seg_name, role))
			out_img.file_format = "PNG"
			out_img.save()
			bpy.data.images.remove(out_img)

	bm.normal_update()
	tris = len(bm.faces)
	bm.to_mesh(mesh)
	bm.free()
	# Only the UV map the textures use is kept.
	keep_uv = mesh.uv_layers.active.name if mesh.uv_layers.active else ""
	for layer in [l.name for l in mesh.uv_layers if l.name != keep_uv]:
		mesh.uv_layers.remove(mesh.uv_layers[layer])
	mesh.materials.clear()

	obj = bpy.data.objects.new(seg_name, mesh)
	bpy.context.scene.collection.objects.link(obj)
	bpy.ops.object.select_all(action="DESELECT")
	obj.select_set(True)
	bpy.context.view_layer.objects.active = obj
	bpy.ops.export_scene.gltf(filepath=os.path.join(dst, seg_name + ".glb"), export_format="GLB", use_selection=True,
		export_materials="NONE", export_yup=True, export_apply=True, export_tangents=True)
	print("CUT_WALL: %s -- %d tris, %.0f m long, %.0f m deep, crest %.0f m above the foot, texture crop %dx%d px" % (
		seg_name, tris, length * scale, depth * scale, top, x1 - x0, y1 - y0))
	bpy.data.objects.remove(obj)
