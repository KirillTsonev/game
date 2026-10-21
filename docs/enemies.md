# Enemies (since 2026-10-21)

A first, rudimentary enemy system: capsules that wander, notice the player, chase and "attack"
(a lunge, no damage). Code in `scripts/enemies/`; each script's header says how it works.

## Where the idea came from

A Reddit post by the maker of ALLFATHER (a procedurally generated 3D game with hordes of enemies)
explained why they dropped the engine's navigation system:

- Baking reliable nav meshes in a generated world was "a nightmare", and enemies jostling for
  position in doorways and corridors could not be fixed by any setting or extra rule.
- Instead: a 2D grid with A* under 3D characters. Enemies decide only every 0.333 s, which is
  what lets huge hordes run cheaply; between decisions each one lerps from cell to cell and plays
  the clip for its state. "Cheap, easy and fast."

Kirill chose this route for the project (2026-10-21).

## Decisions taken for the first version (Kirill, 2026-10-21)

| Question | Choice | Not chosen |
|---|---|---|
| What an enemy looks like | Placeholder capsule (colour = state) | Rogue model + UAL clips |
| Behaviour | Wander, notice, chase, stop at melee range and lunge; no damage | Damage + player health; movement only |
| Cell size | 1 m (one cell per heightmap pixel) | 2 m |
| Spawning | Debug key near the player | Fixed spawns at world generation; both |

## The pieces

- **`EnemyGrid`** (`enemy_grid.gd`, RefCounted): the grid and the path search.
  - 384 x 1536 cells: the generated map (1024 rows), then the hub (`TerrainHub.STRIP_LENGTH`
    rows). Cell (x, z) = heightmap pixel (x, z); hub row j = cell row `AREA_LENGTH + j`. World
    position = `world_corner + (x, height, z)`.
  - It reads `WorldGenerator.world_maps` (the run's maps, with `hub_heights`) and
    `WorldGenerator.world_corner` (the generated map's pixel (0, 0) in world space). Both were
    added to `terrain_gen.gd` for this.
  - A cell is **blocked** when:
    - the ground is steeper than `MAX_GRADE` (tan 40 deg; the player's limit is 45),
    - it is within `EDGE_MARGIN` (2) cells of the grid's edge,
    - it is on the mountain's rock (`MountainWalls.mountain_depth > 0`) or under the castle
      (`TerrainCastle.covers`),
    - it is within `BODY_RADIUS` (0.4 m) of an obstacle with collision. The obstacles come from
      the scatter modules' keep-out lists, which stay filled until the next run's
      `reset_run_state()`: trunks (`TreeScatter.tree_points`, `TREE_TRUNK_RADIUS` x scale),
      boulders and erratics (`RockScatter.rock_keep_circles`), stumps and logs
      (`DeadfallScatter.deadfall_keep_circles`), outcrops (`maps.outcrop_plan`), and cliff meshes
      (their turned footprints from `maps.cliff_dressing_plan`, built the way
      `TreeScatter.scatter_trees` builds its `keep_rects`).
  - **Areas:** the walkable cells are flood-filled into connected areas (`component`, joined
    side to side). A path is only searched between two cells of one area. Without this, a goal
    nobody can reach (the player on top of a knot) makes AStarGrid2D search the whole map, and
    a chasing enemy would do that every tick.
  - AStarGrid2D: diagonals only where both side cells are free (no cutting past a trunk's
    corner), octile heuristic, blocked cells set one row run at a time (`fill_solid_region`).
  - `nearest_walkable(cell, reach, area)`: used when the player stands on a blocked cell (next to a
    trunk) and for spawning.
- **`EnemyDirector`** (`enemy_director.gd`, a node named `EnemyDirector` in the main scene; the
  enemies sit under a node named `Enemies`):
  - `ensure()` makes it and builds the grid on the first spawn, once the world has settled
    (`startup_timings.settled_at_ms`).
  - Every frame each enemy whose turn has come thinks (`Enemy.think`, once per `TICK` = 0.333 s,
    with the turns spread over the tick from a random start), then every enemy moves
    (`Enemy.move`).
  - **Reservations** (`occupied`, cell -> enemy): an enemy holds the cell it stands on and the
    one it is stepping onto, and never enters a held cell. This replaces physics between enemies
    and is what stops the jostling.
  - `crowd_path()`: for an enemy that has waited `STUCK_TICKS` (2) ticks for a held cell, the
    cells other enemies hold within `CROWD_REACH` (6) cells cost `CROWD_WEIGHT` (12) instead of 1
    for one search. Weights, not walls: a crowd can never cut a way off completely. This is how
    a group spreads round the player instead of queueing.
  - `spawn_group(at, count, spread)`, `clear()`.
- **`Enemy`** (`enemy.gd`, Node3D): a capsule (1.8 m, radius 0.35) with a dark visor showing
  which way it faces (-Z).
  - States and colours: IDLE (dark green) stands for 1.5-5 s; WANDER (green) walks to a random
    cell within `WANDER_RADIUS` (10 m) of home; CHASE (orange) runs to the player's cell, path
    renewed whenever that cell changes; ATTACK (red) within `ATTACK_RANGE` (1.8 m), faces the
    player and lunges every `ATTACK_INTERVAL` (1.2 s); RETURN (blue) goes home, then IDLE.
  - **Seeing:** within `NOTICE_RADIUS` (18 m), a ray from its eyes (1.55 m) to the player's chest
    (1 m above the player's origin) that hits nothing else, or hits the player. One ray per enemy
    per tick, only when the player is in range.
  - **Losing the player:** farther than `LOSE_RADIUS` (32 m), or not seen for `LOSE_TIME` (4 s).
  - Speeds: `WALK_SPEED` 1.4 m/s, `CHASE_SPEED` 3.8 m/s (the player jogs at 3 and sprints at 4.8:
    sprinting gets away).
  - Movement: `move_toward` the next cell's middle at its speed, straight on to the next cell on
    arrival (no stop between cells). Height = the heightmap between samples
    (`EnemyGrid.ground_height`), the collision's ground. It turns eased (`TURN_RATE`).
  - The lunge moves and leans the body forward 0.45 m over 0.35 s. The feet stay on the cell.

All tunables are constants at the top of each script.

## Debug keys (PerfDebug)

- U = one enemy 8 m in front of the player; Shift+U = ten (within 4 m of that point);
  Ctrl+U = remove them all. The first U builds the grid (see the cost below).
- Spawning picks the walkable cell nearest the point, and only cells in its area.

## Measured (2026-10-21, F5 from the editor, debug build)

- Grid build on the first U: 1.14 s in all. Ground pass (slope, mountain, castle) 532 ms, obstacles
  11 ms, areas 498 ms, A* setup 103 ms. 467,889 of 589,824 cells walkable (79 %), 205 areas.
- Check run: Shift+U on the hub plateau, all 10 spawned. Within 3 s the two enemies queried were
  on the cells next to the player's, in ATTACK. No errors. Not judged in game by Kirill yet.
- Per-frame and per-tick cost not measured (one ray and at most one short A* search per enemy per
  tick; nothing per frame but a `move_toward` and a height lookup).

## Rules

- **A new scatter layer with collision must be stamped in `EnemyGrid._block_obstacles`**, or enemies
  walk through it. Likewise a new kind of ground they must not walk on (water, ...) goes in
  `_block_ground`.
- Any new data the grid needs from generation goes through `WorldGenerator` (as `world_maps` /
  `world_corner` do) or a module's static keep-out list, not through `_debug_maps`.
- Keep pathing inside one area (`area_of`). A search across areas floods the map.
- Debug keys: never F8 or F5 (see CLAUDE.md). U is taken now.

## Known limits / next steps

- The first-spawn freeze (about 1.1 s): build the grid in the loading screen, on worker threads,
  or as a native kernel (`docs/native_kernels.md`). The ground and area loops are most of it.
- No physics body: the player walks through enemies. An enemy is not stopped by the player
  either.
- No damage or health on either side; the attack is only a lunge.
- Placeholder looks: the rogue model with the UAL clips (idle / walk / jog / attack) is the
  planned swap, since any humanoid plays those clips (see "The player's body" in CLAUDE.md).
- Height comes from the undisplaced heightmap: on displaced rock an enemy may sink or float a
  little (`TerrainDisplacement.drawn()` would fix it).
- The grid covers only the generated map and the hub, not the north apron, the side aprons
  beyond the map's edges, or the castle interior to come. The castle interior will need its own
  grid (same classes, a different source of blocked cells).
- Movement is cell to cell on a 1 m grid, so paths zigzag a little. Smoothing (skip a waypoint
  while the straight line to the one after it is clear) has not been tried.
- No spawns at world generation, no groups or roles, no fleeing, no hearing.
