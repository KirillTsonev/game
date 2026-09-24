extends Node

## One-shot, step 1 of 2: Terrain3D's texture-array builder specifically
## requires each albedo/normal texture to be "connected to a file" (a real
## imported resource with a resource_path) -- an in-memory ImageTexture
## made via ImageTexture.create_from_image() does NOT count and still
## triggers the "not connected to a file" warning + checkerboard
## placeholder, even though it renders fine in isolation. So: save real
## PNG files to disk here, let Godot's editor import them (async), then a
## second script (assign_flat_textures.gd) loads the imported files and
## wires them into terrain_assets.tres. Run once (run_scene); frees itself.
##
## Paths/names here MUST match assign_flat_textures.gd's TEXTURES_BY_ID
## exactly -- this used to write res://textures/grass_albedo.png etc. with
## one shared flat_normal.png, but assign_flat_textures.gd was later
## updated (res://textures/source/ subfolder, "_1k" suffix, a separate
## normal file per texture, and a third Rock entry) without this generator
## being updated to match, which is why the real PNGs it expected never
## actually existed on disk.

const TEXTURES_DIR := "res://textures/source"

func _save_flat(path: String, color: Color) -> void:
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	img.fill(color)
	var err := img.save_png(path)
	print("GENERATE_FLAT_TEXTURES: saved %s (err=%d)" % [path, err])

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(TEXTURES_DIR)
	var flat_normal := Color(0.5, 0.5, 1.0) ## straight-up tangent-space normal -- "no bump" -- same for every flat placeholder texture
	# id 0 renamed grass_* -> ground_* (2026-09-16) to match
	# assign_flat_textures.gd's TEXTURES_BY_ID -- the real texture was always
	# a bare-ground scan, never actual grass.
	_save_flat(TEXTURES_DIR + "/ground_albedo_1k.png", Color(0.25, 0.62, 0.22))
	_save_flat(TEXTURES_DIR + "/ground_normal_1k.png", flat_normal)
	_save_flat(TEXTURES_DIR + "/road_albedo_1k.png", Color(0.85, 0.72, 0.15))
	_save_flat(TEXTURES_DIR + "/road_normal_1k.png", flat_normal)
	# Rock texture removed -- terrain_gen.gd no longer paints any slope-based
	# rock texture (see assign_flat_textures.gd's TEXTURES_BY_ID comment),
	# so this generator no longer produces rock_albedo_1k.png/rock_normal_1k.png.
	print("GENERATE_FLAT_TEXTURES: done -- rescan the filesystem, wait for import, then run assign_flat_textures.gd's fix_textures() via call_method(runtime:false) on the EDITOR process (not run_scene/Play mode -- see assign_flat_textures.gd's own comment for why)")
	queue_free()
