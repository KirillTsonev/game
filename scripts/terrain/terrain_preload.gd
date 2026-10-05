## Background loading of the models and textures the terrain pipeline needs later in
## WorldGenerator._ready() (2026-10-05). begin() queues them on the engine's loader threads as the
## first thing _ready() does, so they load while the heightmap is being built (~3 s of main-thread
## GDScript). The modules keep their plain load() calls: a load() of a path that is already queued
## waits for that same task instead of starting a second one, and returns at once if it has finished.
## Measured: cliff dressing load 1.31 s -> 0.00 s, outcrop placement 1.35 s -> 0.04 s. Only the
## cliff / outcrop textures are worth queuing; the rock and deadfall glbs were tried and gained
## nothing (their cost was building collision shapes -- now TerrainUtil.cached_shape).
class_name TerrainPreload
extends RefCounted

static var _requested := PackedStringArray()

## Queues every path for background loading. Call first in WorldGenerator._ready().
static func begin() -> void:
	_requested = PackedStringArray()
	var paths := PackedStringArray()
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		_append_def_paths(paths, def)
	for def in TerrainOutcrops.OUTCROP_DEFS:
		_append_def_paths(paths, def)
	for path in paths:
		if _requested.has(path):
			continue
		if ResourceLoader.load_threaded_request(path) == OK:
			_requested.append(path)

## Hands every queued load back to the engine (a queued load is kept until it is fetched). Call
## at the end of _ready(), after the modules have loaded what they need.
static func finish() -> void:
	for path in _requested:
		ResourceLoader.load_threaded_get(path)
	_requested = PackedStringArray()

## The files of one cliff / outcrop def: its glb and its diff / nor / orm-or-rough textures.
static func _append_def_paths(paths: PackedStringArray, def: Dictionary) -> void:
	for key in ["glb", "diff", "nor", "orm", "rough"]:
		if def.has(key):
			paths.append(def[key])
