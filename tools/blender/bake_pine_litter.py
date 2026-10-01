## Pine forest floor scan -> tileable Terrain3D texture pair + low-poly litter mound meshes.
##
## Source: raw-assets/models/forest_ground_soil_pine_free.glb (photogrammetry, ~500k tris, one 8K
## albedo atlas, no normal/height). As shipped it is UPSIDE DOWN (the scanned surface faces -Z after
## import) and closed by ~200 huge cap triangles on its back; both are fixed here in memory.
## One scan unit is ~0.06 m (judged from the cones / oak leaf), so the patch is ~2.2 x 2.5 m.
##
## Writes (paths relative to the project root):
##   textures/source/pine_litter_albedo_height_1k.png     albedo RGB + height A
##   textures/source/pine_litter_normal_roughness_1k.png  OpenGL normal RGB + roughness A
##   assets/models/ground_debris/litter_mound/litter_mound_{a,b,c}.glb
## The textures: orthographic top-down albedo render + one height ray per pixel, high-passed,
## wrapped (overlap strip blended onto the opposite edge), normal derived from the height.
## The mounds: shallow domes (rim below ground) with a ragged outline, bumps sampled from the same
## height map, UVs in tile units -- they render with the terrain texture pair, so they match it.
##
## Run:  "<blender>" --background --python tools/blender/bake_pine_litter.py
## Then in Godot: tools/assign_flat_textures.gd (force_reimport, fix_textures) and
## tools/setup_ground_debris_assets.gd -- see docs/forest_floor_plan.md.
import bpy, bmesh, os, math, time
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SRC = os.path.normpath(os.path.join(ROOT, "..", "raw-assets", "models", "forest_ground_soil_pine_free.glb"))
TEX_DIR = os.path.join(ROOT, "textures", "source")
MOUND_DIR = os.path.join(ROOT, "assets", "models", "ground_debris", "litter_mound")

UNIT_M = 0.06        # metres per scan unit (estimate)
N = 1024             # tile px
M = 128              # overlap px blended across the wrap
S = N + M
TILE_UNITS = 26.0    # scan units per tile -> 1.56 m; Terrain3D uv_scale = 1 / 1.56
PX = TILE_UNITS / N
SPAN = S * PX
CX, CY = 2.3, 0.5    # crop centre: clear of the scan's raised left rim and the corner plants
HIGH_PASS_PX = 80.0  # height: drop the scan's tilt and swells wider than ~12 cm

# ---------------------------------------------------------------- load + clean the scan
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
bpy.ops.object.select_all(action='DESELECT')
for o in meshes:
    mw = o.matrix_world.copy()
    o.parent = None
    o.matrix_world = Matrix.Identity(4)
    o.data.transform(mw)
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.join()
scan = bpy.context.view_layer.objects.active
scan.data.transform(Matrix.Rotation(math.pi, 4, 'X'))  # right side up
bm = bmesh.new(); bm.from_mesh(scan.data)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.calc_area() > 0.5], context='FACES')  # the cap
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
bm.to_mesh(scan.data); bm.free()
X0 = CX - SPAN / 2; Y0 = CY - SPAN / 2

# ---------------------------------------------------------------- albedo (flat textured render, 2x)
sc = bpy.context.scene
cam_data = bpy.data.cameras.new("cam"); cam_data.type = 'ORTHO'; cam_data.clip_end = 1000
cam_data.ortho_scale = SPAN
cam = bpy.data.objects.new("cam", cam_data)
sc.collection.objects.link(cam); sc.camera = cam
cam.location = (CX, CY, 50)
sc.render.engine = 'BLENDER_WORKBENCH'
sc.display.shading.light = 'FLAT'
sc.display.shading.color_type = 'TEXTURE'
sc.display.render_aa = '8'
sc.view_settings.view_transform = 'Standard'
sc.render.resolution_x = S * 2; sc.render.resolution_y = S * 2
sc.render.resolution_percentage = 100
sc.render.image_settings.file_format = 'PNG'
sc.render.image_settings.color_mode = 'RGB'
tmp_png = os.path.join(bpy.app.tempdir, "pine_litter_albedo_raw.png")
sc.render.filepath = tmp_png
bpy.ops.render.render(write_still=True)
img = bpy.data.images.load(tmp_png)
buf = np.empty(S * 2 * S * 2 * 4, dtype=np.float32)
img.pixels.foreach_get(buf)
alb = buf.reshape(S * 2, S * 2, 4)[:, :, :3].astype(np.float64)
alb = alb.reshape(S, 2, S, 2, 3).mean(axis=(1, 3))  # arrays are bottom-up, like bpy pixels

# ---------------------------------------------------------------- height (one ray per pixel centre)
t0 = time.time()
bvh = BVHTree.FromObject(scan, bpy.context.evaluated_depsgraph_get())
h = np.full((S, S), np.nan)
down = Vector((0, 0, -1))
for j in range(S):
    y = Y0 + (j + 0.5) * PX
    row = h[j]
    for i in range(S):
        loc = bvh.ray_cast(Vector((X0 + (i + 0.5) * PX, y, 50.0)), down)[0]
        if loc is not None:
            row[i] = loc.z
print("REPORT rays %.1fs, misses %d of %d" % (time.time() - t0, int(np.isnan(h).sum()), S * S))
h[np.isnan(h)] = np.nanmin(h)

def _gauss(shape, sigma):
    fx = np.fft.fftfreq(shape[1]); fy = np.fft.fftfreq(shape[0])
    return np.exp(-2 * (np.pi * sigma) ** 2 * (fx[None, :] ** 2 + fy[:, None] ** 2))

def blur(a, sigma):  # reflect-padded
    pad = int(3 * sigma) + 1
    ap = np.pad(a, pad, mode='reflect')
    return np.real(np.fft.ifft2(np.fft.fft2(ap) * _gauss(ap.shape, sigma)))[pad:-pad, pad:-pad]

def pblur(a, sigma):  # periodic (for the wrapped tile)
    return np.real(np.fft.ifft2(np.fft.fft2(a) * _gauss(a.shape, sigma)))

h = h - blur(h, HIGH_PASS_PX)
lum = alb.mean(axis=2)
alb = np.clip(alb * ((lum.mean() / blur(lum, 100.0)) ** 0.8)[:, :, None], 0, 1)  # even out brightness

# ---------------------------------------------------------------- make tileable
## The M-px strip past the tile's far edge is blended onto its near edge; the mask leans toward
## whichever side is higher (keeps needles whole) -- only slightly, a strong lean raises the strip.
def wrap(a, hh, axis):
    a = np.moveaxis(a, axis, 0); hh = np.moveaxis(hh, axis, 0)
    t = ((np.arange(M) + 0.5) / M).reshape((M,) + (1,) * (hh.ndim - 1))
    w = np.clip(0.5 + (t - 0.5) * 3.0 + (hh[:M] - hh[N:N + M]) / (7.0 * hh.std()) * 4 * t * (1 - t), 0, 1)
    ho = hh[:N].copy(); ho[:M] = hh[:M] * w + hh[N:N + M] * (1 - w)
    ao = a[:N].copy()
    wa = w if a.ndim == hh.ndim else w[..., None]
    ao[:M] = a[:M] * wa + a[N:N + M] * (1 - wa)
    return np.moveaxis(ao, 0, axis), np.moveaxis(ho, 0, axis)

alb, h1 = wrap(alb, h, 1)
alb, h = wrap(alb, h1, 0)
h = h - pblur(h, HIGH_PASS_PX)

# ---------------------------------------------------------------- normal / roughness / save
lum = alb.mean(axis=2)
hn = pblur(h, 1.2) + 0.15 * (lum - pblur(lum, 3.0))  # scan relief + a little albedo micro-detail
gx = (np.roll(hn, -1, 1) - np.roll(hn, 1, 1)) / (2 * PX)
gy = (np.roll(hn, -1, 0) - np.roll(hn, 1, 0)) / (2 * PX)
nrm = np.stack([-gx, -gy, np.ones_like(gx)], axis=2)  # OpenGL: +Y = up in the image
nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
lo, hi = np.percentile(h, 0.5), np.percentile(h, 99.5)
h01 = np.clip((h - lo) / (hi - lo), 0, 1)
rough = np.clip(0.88 - 0.6 * (lum - lum.mean()), 0.7, 1.0)

def save(path, rgb, a):
    im = bpy.data.images.new(os.path.basename(path), N, N, alpha=True)
    im.colorspace_settings.name = 'Non-Color'
    im.alpha_mode = 'CHANNEL_PACKED'
    im.pixels.foreach_set(np.concatenate([rgb, a[:, :, None]], axis=2).astype(np.float32).ravel())
    im.filepath_raw = path; im.file_format = 'PNG'
    im.save()

save(os.path.join(TEX_DIR, "pine_litter_albedo_height_1k.png"), alb, h01)
save(os.path.join(TEX_DIR, "pine_litter_normal_roughness_1k.png"), nrm * 0.5 + 0.5, rough)
m = alb.reshape(-1, 3).mean(axis=0)
print("REPORT textures saved; height band %.1f mm; mean albedo sRGB (%.3f %.3f %.3f)" % ((hi - lo) * UNIT_M * 1000, m[0], m[1], m[2]))

# ---------------------------------------------------------------- litter mounds
TILE_M = TILE_UNITS * UNIT_M
RINGS = 9
SEGS = 28
bump_map = pblur(h, 25.0) * UNIT_M  # metres; only what a ~8 cm vertex spacing can carry
MOUNDS = [  # name, radius m, dome height m, seed
    ("litter_mound_a", 1.10, 0.14, 11),
    ("litter_mound_b", 0.95, 0.11, 23),
    ("litter_mound_c", 1.25, 0.16, 37),
]
RIM_SINK = 0.08      # m the rim sits below the ground
BUMP_GAIN = 2.5
os.makedirs(MOUND_DIR, exist_ok=True)
bpy.data.objects.remove(scan, do_unlink=True)

for name, radius, height, seed in MOUNDS:
    rng = np.random.default_rng(seed)
    ph = rng.uniform(0, 2 * math.pi, 6)
    uo = rng.uniform(0, 1, 2)
    def outline(a):  # ragged, not a circle
        return radius * (1.0 + 0.14 * math.sin(2 * a + ph[0]) + 0.09 * math.sin(3 * a + ph[1]) + 0.05 * math.sin(5 * a + ph[2]))
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    def vert(rho, a):
        r = rho * outline(a)
        x = r * math.cos(a); y = r * math.sin(a)
        u = x / TILE_M + uo[0]; v = y / TILE_M + uo[1]
        lump = 0.03 * (math.sin(1.7 * x / radius + ph[3]) * math.cos(2.1 * y / radius + ph[4]))
        bump = bump_map[int((v % 1.0) * N) % N, int((u % 1.0) * N) % N] * BUMP_GAIN
        z = height * (1 - rho * rho) ** 2 - RIM_SINK * rho * rho + (lump + bump) * (1 - rho * rho)
        return bm.verts.new((x, y, z)), (u, v)
    rings = [[vert(0.0, 0.0)]]
    for ri in range(1, RINGS + 1):
        rho = (ri / RINGS) ** 0.85
        rings.append([vert(rho, 2 * math.pi * si / SEGS) for si in range(SEGS)])
    def face(corners):
        f = bm.faces.new([c[0] for c in corners])
        for loop, c in zip(f.loops, corners):
            loop[uv_layer].uv = c[1]
        f.smooth = True
    for si in range(SEGS):
        face([rings[0][0], rings[1][si], rings[1][(si + 1) % SEGS]])
    for ri in range(1, RINGS):
        for si in range(SEGS):
            a0 = rings[ri][si]; a1 = rings[ri][(si + 1) % SEGS]
            b0 = rings[ri + 1][si]; b1 = rings[ri + 1][(si + 1) % SEGS]
            face([a0, b0, b1]); face([a0, b1, a1])
    me = bpy.data.meshes.new(name + "_LOD0")
    bm.normal_update(); bm.to_mesh(me); tris = len(bm.faces); bm.free()
    ob = bpy.data.objects.new(name + "_LOD0", me)
    sc.collection.objects.link(ob)
    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True); bpy.context.view_layer.objects.active = ob
    bpy.ops.export_scene.gltf(filepath=os.path.join(MOUND_DIR, name + ".glb"), use_selection=True,
        export_format='GLB', export_materials='NONE', export_yup=True, export_tangents=True)
    print("REPORT %s: %d tris, radius %.2f m, dome %.2f m" % (name, tris, radius, height))
    bpy.data.objects.remove(ob, do_unlink=True)
print("REPORT done")
