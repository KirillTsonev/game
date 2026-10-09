# Writes the terrain's Snow texture pair (texture id 9, tools/assign_flat_textures.gd) into
# textures/source/: snow_albedo_height_1k.png (RGB = colour, A = height) and
# snow_normal_roughness_1k.png (RGB = OpenGL normal, A = roughness), 1024 x 1024 RGBA, tiling --
# the packed layout every Terrain3D layer of this project uses. There is no scan behind it: soft
# wind-packed snow is close to featureless, so it is built from noise. Needs numpy (Blender's own
# Python has it):
#
#   "D:\Downloads\Godot_v4.7.2-stable_win64.exe\Blender 5.2\5.2\python\bin\python.exe" tools/make_snow_texture.py
#
# Written 2026-10-08 for the snow on the tips of the mountain apron (MountainWalls.apron_maps).
import os, struct, zlib
import numpy as np

SIZE = 1024
SEED = 9
out_dir = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "textures", "source"))

def write_png(path, rgba):
	h, w, _ = rgba.shape
	raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))
	def chunk(tag, data):
		return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
	with open(path, "wb") as f:
		f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

# Tiling noise: white noise with its high frequencies removed in the Fourier domain (which is
# periodic by construction). `falloff` = how fast the detail dies away; higher = smoother.
def tiling_noise(rng, falloff):
	spectrum = np.fft.fft2(rng.standard_normal((SIZE, SIZE)))
	fy = np.fft.fftfreq(SIZE)[:, None]
	fx = np.fft.fftfreq(SIZE)[None, :]
	radius = np.sqrt(fx * fx + fy * fy)
	radius[0, 0] = 1.0
	field = np.real(np.fft.ifft2(spectrum / radius ** falloff))
	field -= field.min()
	return field / field.max()

rng = np.random.default_rng(SEED)
drifts = tiling_noise(rng, 2.2)   # broad wind-shaped swells
grain = tiling_noise(rng, 1.1)    # fine crust
height = 0.8 * drifts + 0.2 * grain
height = (height - height.min()) / (height.max() - height.min())

# Colour: near white, a touch blue, slightly darker in the hollows.
shade = 0.9 + 0.1 * height
albedo = np.dstack([shade * 0.93, shade * 0.96, shade * 1.0, height])
write_png(os.path.join(out_dir, "snow_albedo_height_1k.png"), (np.clip(albedo, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8))

# Normal (OpenGL: +Y up the image) from the height, wrapping at the edges. Gentle: snow is smooth.
STRENGTH = 3.0
dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * STRENGTH
dy = (np.roll(height, 1, axis=0) - np.roll(height, -1, axis=0)) * STRENGTH
normal = np.dstack([-dx, -dy, np.ones_like(height)])
normal /= np.linalg.norm(normal, axis=2, keepdims=True)
roughness = 0.62 + 0.12 * grain
packed = np.dstack([normal * 0.5 + 0.5, roughness])
write_png(os.path.join(out_dir, "snow_normal_roughness_1k.png"), (np.clip(packed, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8))
print("wrote snow_albedo_height_1k.png and snow_normal_roughness_1k.png to %s" % out_dir)
