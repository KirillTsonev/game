## Packs an ambientCG "PBR Maps" set (1K PNG) into the two files a Terrain3D texture needs:
##   textures/source/<name>_albedo_height_1k.png      Color RGB + Displacement in A (stretched to 0..1)
##   textures/source/<name>_normal_roughness_1k.png   NormalGL RGB + Roughness in A
## and writes their .import sidecars with the same [params] as the Ground pair, so the first
## import already matches the rest of the texture array (CLAUDE.md, "Adding a new Terrain3D texture id").
##
## Run:  "<blender>" -b --factory-startup --python tools/blender/pack_ambientcg_texture.py -- <set folder> <name>
##   e.g. ... -- "D:\...\raw-assets\textures\Grass002_1K-PNG" grass002
## Then in Godot: add the pair to TEXTURES_BY_ID in tools/assign_flat_textures.gd, rescan,
## force_reimport(), fix_textures().
import bpy, os, sys, glob
import numpy as np

src, name = sys.argv[sys.argv.index("--") + 1:][:2]
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
TEX_DIR = os.path.join(ROOT, "textures", "source")
N = 1024

def load(role):
    hits = glob.glob(os.path.join(src, "*_%s.png" % role)) + glob.glob(os.path.join(src, "*_%s.jpg" % role))
    if not hits:
        raise RuntimeError("no *_%s image in %s" % (role, src))
    im = bpy.data.images.load(hits[0])
    im.colorspace_settings.name = 'Non-Color'  # raw file values, no colour management
    if tuple(im.size) != (N, N):
        im.scale(N, N)
    a = np.empty(N * N * 4, dtype=np.float32)
    im.pixels.foreach_get(a)
    return a.reshape(N, N, 4)[:, :, :3].astype(np.float64)

def save(path, rgb, alpha):
    im = bpy.data.images.new(os.path.basename(path), N, N, alpha=True)
    im.colorspace_settings.name = 'Non-Color'
    im.alpha_mode = 'CHANNEL_PACKED'
    im.pixels.foreach_set(np.concatenate([rgb, alpha[:, :, None]], axis=2).astype(np.float32).ravel())
    im.filepath_raw = path; im.file_format = 'PNG'
    im.save()

color = load("Color")
height = load("Displacement")[:, :, 0]
lo, hi = np.percentile(height, 0.5), np.percentile(height, 99.5)
height = np.clip((height - lo) / max(hi - lo, 1e-6), 0, 1)
normal = load("NormalGL")
rough = load("Roughness")[:, :, 0]

for kind, ref, rgb, alpha in (("albedo_height", "ground_albedo_height_1k.png", color, height), ("normal_roughness", "ground_normal_roughness_1k.png", normal, rough)):
    out = os.path.join(TEX_DIR, "%s_%s_1k.png" % (name, kind))
    save(out, rgb, alpha)
    if not os.path.exists(out + ".import"):
        txt = open(os.path.join(TEX_DIR, ref + ".import"), encoding="utf-8").read()
        with open(out + ".import", "w", encoding="utf-8", newline="\n") as f:
            f.write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n' + txt[txt.index("[params]"):])
    print("PACKED " + out)

lin = np.where(color <= 0.04045, color / 12.92, ((color + 0.055) / 1.055) ** 2.4).reshape(-1, 3).mean(0)
print("MEAN %s albedo: linear (%.4f %.4f %.4f), sRGB (%.3f %.3f %.3f); roughness mean %.2f" % (
    name, lin[0], lin[1], lin[2], *np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055), rough.mean()))
