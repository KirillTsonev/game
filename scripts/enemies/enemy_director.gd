## Runs every enemy (2026-10-21, rudimentary): each one thinks once per TICK -- state, target,
## path (Enemy.think) -- with the enemies' turns spread over the tick so they do not all think on
## the same frame, and every frame slides toward the cell it is stepping to (Enemy.move).
## Enemies have no physics body: they keep apart by reserving cells (`occupied`), one enemy per
## cell, which is what stops them jostling in narrow places. The player walks through them.
##
## Made by ensure() the first time an enemy is spawned (PerfDebug U), together with the grid.
class_name EnemyDirector
extends Node

const NODE_NAME := "EnemyDirector"
const TICK := 0.333 ## s between two thoughts of one enemy
const CROWD_WEIGHT := 12.0 ## path cost of a cell another enemy stands on, while a stuck enemy looks for a way round
const CROWD_REACH := 6 ## cells round a stuck enemy whose occupants are weighed that way

var grid: EnemyGrid
var enemies: Array[Enemy] = []
var occupied: Dictionary = {} ## Vector2i -> the Enemy on (or stepping onto) that cell
var player: Node3D
var _container: Node3D

## The scene's director, made (with its grid) when there is none yet; null before the world exists.
static func ensure(tree: SceneTree) -> EnemyDirector:
	var scene := tree.current_scene
	if scene == null:
		return null
	var existing := scene.get_node_or_null(NODE_NAME) as EnemyDirector
	if existing:
		return existing
	var world := scene.get_node_or_null("WorldGenerator")
	if world == null or not (world.get("startup_timings") as Dictionary).has("settled_at_ms"):
		return null
	var g := EnemyGrid.build(world)
	if g == null:
		return null
	var director := EnemyDirector.new()
	director.name = NODE_NAME
	director.grid = g
	director.player = scene.get_node_or_null("Player") as Node3D
	scene.add_child(director)
	director._container = Node3D.new()
	director._container.name = "Enemies"
	scene.add_child(director._container)
	return director

func _process(delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for e in enemies:
		if now >= e.next_think:
			e.next_think = maxf(e.next_think + TICK, now) # keeps its place in the tick
			e.think(self, now)
		e.move(self, delta)

## `count` enemies on free walkable cells within `spread` m of `at`, in the area the player can
## walk to from there. Returns how many were placed.
func spawn_group(at: Vector3, count: int, spread: float = 4.0) -> int:
	var centre := grid.nearest_walkable(grid.cell_of(at), 8)
	if centre.x < 0:
		print("ENEMIES: no walkable ground near %s (off the grid, or all blocked)" % at)
		return 0
	var area := grid.area_of(centre)
	var placed := 0
	var now := Time.get_ticks_msec() / 1000.0
	for i in count:
		var cell := Vector2i(-1, -1)
		for attempt in 24:
			var offset := Vector2.from_angle(randf() * TAU) * sqrt(randf()) * spread if i > 0 or attempt > 0 else Vector2.ZERO
			var c := grid.nearest_walkable(centre + Vector2i(roundi(offset.x), roundi(offset.y)), 2, area)
			if c.x >= 0 and not occupied.has(c):
				cell = c
				break
		if cell.x < 0:
			continue
		var e := Enemy.new()
		e.name = "Enemy%d" % enemies.size()
		_container.add_child(e)
		e.place(self, cell, now + randf() * TICK)
		enemies.append(e)
		placed += 1
	print("ENEMIES: spawned %d of %d at %s (%d in the world)" % [placed, count, grid.world_of(centre), enemies.size()])
	return placed

func clear() -> void:
	for e in enemies:
		e.queue_free()
	enemies.clear()
	occupied.clear()
	print("ENEMIES: all removed")

## True if `cell` is now `e`'s (free, or already its own).
func reserve(cell: Vector2i, e: Enemy) -> bool:
	var holder = occupied.get(cell)
	if holder != null and holder != e:
		return false
	occupied[cell] = e
	return true

func release(cell: Vector2i, e: Enemy) -> void:
	if occupied.get(cell) == e:
		occupied.erase(cell)

## A path for `e` that goes round the other enemies near it when it can (they cost CROWD_WEIGHT
## a cell instead of blocking: a crowd never cuts the way off completely).
func crowd_path(e: Enemy, from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var weighed: Array[Vector2i] = []
	for cell: Vector2i in occupied:
		if occupied[cell] != e and absi(cell.x - from.x) <= CROWD_REACH and absi(cell.y - from.y) <= CROWD_REACH:
			grid.astar.set_point_weight_scale(cell, CROWD_WEIGHT)
			weighed.append(cell)
	var path := grid.find_path(from, to)
	for cell in weighed:
		grid.astar.set_point_weight_scale(cell, 1.0)
	return path
