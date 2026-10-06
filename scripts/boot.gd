extends Node

## The project's start scene (scenes/boot.tscn): puts the loading screen up, draws it, then loads
## the main scene and switches to it. WorldGenerator (terrain_gen.gd) carries the same loading
## screen on through world generation. Running main.tscn directly (F6) still works -- it just
## starts its loading screen later.
##
## The load blocks on the main thread (the screen is frozen meanwhile). Two threaded ways were
## used before and dropped:
## - polling a threaded load from _process() took 4.7 s: loader threads wait for the main thread
##   at many points, and a main thread that only comes round once per frame makes each of those
##   waits a frame long;
## - requesting it with sub-threads and fetching it at once took ~2 s, but hung for good whenever
##   shaders had to be compiled during the load (no cached copy): every launch of an exported
##   game (2026-10-06), and once in the editor right after a shader file was edited.

const MAIN_SCENE := "res://scenes/main.tscn"
## Share of the whole bar given to loading the main scene (~2 s of ~8 s on the dev machine).
const LOAD_SHARE := 0.25

func _ready() -> void:
	LoadingScreen.begin()
	LoadingScreen.set_progress(0.0, "Loading")
	# Two drawn frames, so the screen is really on the display before the blocking load.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var scene := load(MAIN_SCENE) as PackedScene
	if scene == null:
		push_error("BOOT: could not load %s" % MAIN_SCENE)
		LoadingScreen.end()
		return
	LoadingScreen.set_progress(LOAD_SHARE, "Loading")
	get_tree().change_scene_to_packed(scene)
