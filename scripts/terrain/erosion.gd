## Simplified hydraulic (droplet) erosion over a heightmap.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainErosion.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainErosion
extends RefCounted

const MAX_DROPLET_LIFETIME := 32
const INERTIA := 0.1 ## 0 = always follows steepest descent, 1 = never turns -- raised slightly so droplets wander instead of cutting razor-straight channels
const SEDIMENT_CAPACITY_FACTOR := 3.0 ## lower than before -- less aggressive carving
const MIN_SEDIMENT_CAPACITY := 0.01
const ERODE_SPEED := 0.15 ## halved -- was carving canyon-sharp walls
const DEPOSIT_SPEED := 0.45 ## raised -- fills back in faster, rounds off peaks
const EVAPORATE_SPEED := 0.02
const GRAVITY := 4.0
const INITIAL_WATER_VOLUME := 1.0
const INITIAL_SPEED := 1.0

## Simplified hydraulic erosion: simulates EROSION_ITERATIONS water droplets,
## each starting at a random point and flowing downhill for up to
## MAX_DROPLET_LIFETIME steps. A droplet erodes material when it's moving
## fast down a steep slope (more than it can carry, i.e. over its sediment
## capacity) and deposits when it slows down or the ground flattens out --
## which is what turns raw noise into believable valleys, ridgelines, and
## alluvial fans instead of just "noise with jitter". Operates directly on
## the flat heights array (no erosion-radius brush, just bilinear point
## sampling/deposit) to stay fast enough to run synchronously at this
## resolution.
static func erode(heights: PackedFloat32Array, width: int, length: int, rng: RandomNumberGenerator, iterations: int) -> void:
	for iter in iterations:
		var pos_x := rng.randf_range(0.0, width - 1.001)
		var pos_z := rng.randf_range(0.0, length - 1.001)
		var dir_x := 0.0
		var dir_z := 0.0
		var speed := INITIAL_SPEED
		var water := INITIAL_WATER_VOLUME
		var sediment := 0.0

		for step in MAX_DROPLET_LIFETIME:
			var node_x := int(pos_x)
			var node_z := int(pos_z)
			var cell_x := pos_x - node_x
			var cell_z := pos_z - node_z
			var node_x1 := mini(node_x + 1, width - 1)
			var node_z1 := mini(node_z + 1, length - 1)

			var h_nw := heights[node_z * width + node_x]
			var h_ne := heights[node_z * width + node_x1]
			var h_sw := heights[node_z1 * width + node_x]
			var h_se := heights[node_z1 * width + node_x1]

			var gradient_x := (h_ne - h_nw) * (1.0 - cell_z) + (h_se - h_sw) * cell_z
			var gradient_z := (h_sw - h_nw) * (1.0 - cell_x) + (h_se - h_ne) * cell_x
			var old_height := h_nw * (1 - cell_x) * (1 - cell_z) \
				+ h_ne * cell_x * (1 - cell_z) \
				+ h_sw * (1 - cell_x) * cell_z \
				+ h_se * cell_x * cell_z

			dir_x = dir_x * INERTIA - gradient_x * (1.0 - INERTIA)
			dir_z = dir_z * INERTIA - gradient_z * (1.0 - INERTIA)
			var dir_len := sqrt(dir_x * dir_x + dir_z * dir_z)
			if dir_len < 0.0001:
				# Flat spot / directionless: pick a random escape direction
				# instead of stalling the droplet in place forever.
				var ang := rng.randf_range(0.0, TAU)
				dir_x = cos(ang)
				dir_z = sin(ang)
				dir_len = 1.0
			dir_x /= dir_len
			dir_z /= dir_len

			var new_x := pos_x + dir_x
			var new_z := pos_z + dir_z
			if new_x < 0.0 or new_x >= width - 1 or new_z < 0.0 or new_z >= length - 1:
				break

			var new_node_x := int(new_x)
			var new_node_z := int(new_z)
			var new_cell_x := new_x - new_node_x
			var new_cell_z := new_z - new_node_z
			var new_node_x1 := mini(new_node_x + 1, width - 1)
			var new_node_z1 := mini(new_node_z + 1, length - 1)
			var n_h_nw := heights[new_node_z * width + new_node_x]
			var n_h_ne := heights[new_node_z * width + new_node_x1]
			var n_h_sw := heights[new_node_z1 * width + new_node_x]
			var n_h_se := heights[new_node_z1 * width + new_node_x1]
			var new_height := n_h_nw * (1 - new_cell_x) * (1 - new_cell_z) \
				+ n_h_ne * new_cell_x * (1 - new_cell_z) \
				+ n_h_sw * (1 - new_cell_x) * new_cell_z \
				+ n_h_se * new_cell_x * new_cell_z

			var height_diff := new_height - old_height
			var capacity := maxf(-height_diff, MIN_SEDIMENT_CAPACITY) * speed * water * SEDIMENT_CAPACITY_FACTOR

			if sediment > capacity or height_diff > 0.0:
				# Moving uphill, or carrying more than it can hold: drop sediment.
				var deposit_amount := minf(height_diff, sediment) if height_diff > 0.0 else (sediment - capacity) * DEPOSIT_SPEED
				sediment -= deposit_amount
				heights[node_z * width + node_x] += deposit_amount * (1 - cell_x) * (1 - cell_z)
				heights[node_z * width + node_x1] += deposit_amount * cell_x * (1 - cell_z)
				heights[node_z1 * width + node_x] += deposit_amount * (1 - cell_x) * cell_z
				heights[node_z1 * width + node_x1] += deposit_amount * cell_x * cell_z
			else:
				# Steep and fast: pick up sediment, capped by what's actually there.
				var erode_amount := minf((capacity - sediment) * ERODE_SPEED, -height_diff)
				sediment += erode_amount
				heights[node_z * width + node_x] -= erode_amount * (1 - cell_x) * (1 - cell_z)
				heights[node_z * width + node_x1] -= erode_amount * cell_x * (1 - cell_z)
				heights[node_z1 * width + node_x] -= erode_amount * (1 - cell_x) * cell_z
				heights[node_z1 * width + node_x1] -= erode_amount * cell_x * cell_z

			speed = sqrt(maxf(0.0, speed * speed + height_diff * -GRAVITY))
			water *= (1.0 - EVAPORATE_SPEED)
			pos_x = new_x
			pos_z = new_z
			if water < 0.001:
				break
