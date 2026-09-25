## Terrain-generation constants shared by more than one module (map size, master seed,
## texture/mesh ids, ...). Constants used by only one system live in that system's module.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## TerrainConfig.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name TerrainConfig
extends RefCounted

## -- Master seed --
## Every noise layer, the erosion RNG, and the cliff-feature RNG derive
## their individual seed from this ONE value (via _derive_seeds below)
## instead of each carrying its own hardcoded seed. That's what makes both
## "one seed per runtime session" and "regenerate the exact same map later
## from a saved seed" simple: change this number and the whole pipeline
## reshuffles together as one unit.
##
## -1 (default) -- randomize: a fresh seed is rolled via randi() every time
##                 this scene runs, so every run is a different map. The
##                 seed actually used is always printed at the top of the
##                 console output, specifically so a result you like can be
##                 reproduced: copy that printed number in here to pin it.
## any other int -- always regenerate that exact map (byte-identical every
##                  run). Useful while tuning a specific result, or for
##                  pinning down a bug tied to one particular seed.
const MASTER_SEED := -1
#const MASTER_SEED := 1195801279

## World-space size of the area to (re)generate, in world units --
## independent X (width) and Z (length) so it doesn't have to be square.
## For a LIVE (not TEST) regeneration, keep each a multiple of Terrain3D's
## region size (256 by default, read at runtime via get_region_size() in
## _ready() -- see the heightmap_corner comment below) so it aligns cleanly
## on region boundaries. Erosion iterations and smoothing below both scale
## with AREA_WIDTH*AREA_LENGTH, so no other retuning is needed when you
## resize either axis. When either axis exceeds the region size, Terrain3D
## spans multiple regions -- see the heightmap_corner gotcha in _ready().
const AREA_WIDTH := 256 ## X axis -- one region's worth of real generated terrain, no flat filler
const AREA_LENGTH := 512 ## Z axis -- spans two regions (see note above)

## -- Macro valley shape --
## The playable area reads as a U-shaped glacial valley: a flat-ish floor in
## the middle of the map, steepening walls on both sides, up to a rim. This
## runs BEFORE the noise layers below and defines the macro shape noise
## perturbs -- noise no longer defines the terrain's overall silhouette by
## itself (see _valley_profile and its use in _build_heightmap). The
## valley's long axis is straight, aligned with the map's Z axis at the
## map's X-center (x = AREA_WIDTH*0.5) -- this deliberately matches the
## road's forced north/south endpoints (_generate_road), which are also
## pinned to x = width*0.5, so the road that gets routed afterward naturally
## starts and ends on the valley floor, then curves around whatever macro/
## micro terrain (wall, cliff features) its A* pathfinding finds in the way
## -- the valley SHAPE stays a straight-axis macro feature; only the road's
## routed path bends.
## Asymmetric on purpose: LEFT wall (low X) is the tall mountain boundary,
## RIGHT wall (high X) is the smaller one -- both are geometry-only for now
## (no distinct meshes/textures/snow/fog yet -- that's an explicitly later
## pass, not part of this macro-shape work).
const VALLEY_FLOOR_WIDTH_FRACTION := 0.55 ## fraction of AREA_WIDTH that's floor (flat-ish, walkable, room for nooks/crannies/snaking paths/structures/ruins/woods/glades/meadow/caves later) -- the remaining (1-this)/2 on each side is wall
const BOULDER_END_INSET_FRACTION := 0.15 ## keep boulders off the very tapering tips of the cliff line
## "real_size" is each model's own AABB width (X); "height"/"depth" are its AABB height (Y)
## and depth (Z) -- all three measured directly off the imported GLBs on 2026-09-17 (see the
## debug cube in _dress_cliff_faces, which is sized from these to show each placement's real
## footprint before any terrain-fitting work touches the heightmap again).
const CLIFF_DRESSING_DEFS := [
	{"name": "namaqualand_cliff_01", "glb": "res://assets/models/cliffs/namaqualand_cliff_01/namaqualand_cliff_01_2k.glb", "diff": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_diff_2k.jpg", "nor": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_nor_gl_2k.exr", "rough": "res://assets/models/cliffs/namaqualand_cliff_01/textures/namaqualand_cliff_01_rough_2k.exr", "real_size": 8.3, "height": 4.96, "depth": 4.39},
	# 2026-09-20: mountainside moved out of the cliff system -> OUTCROP_DEFS (laid flat,
	# scattered on the valley floor by _scatter_outcrops). Kirill: "looks very out of place".
	{"name": "namaqualand_cliff_02", "glb": "res://assets/models/cliffs/namaqualand_cliff_02/namaqualand_cliff_02_2k.glb", "diff": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_diff_2k.jpg", "nor": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_nor_gl_2k.exr", "rough": "res://assets/models/cliffs/namaqualand_cliff_02/textures/namaqualand_cliff_02_rough_2k.exr", "real_size": 20.2, "height": 7.18, "depth": 6.59},
]
const CLIFF_DRESSING_EMBED_DEPTH := 1.5 ## sink the mesh's base this far below the sampled terrain height (scaled by that instance's own scale jitter) so its bottom edge never floats visibly above the ground regardless of the source mesh's own base/pivot
## 2026-09-17 reorder: cliff dressing is now PLANNED (and its footprint flattened into the
## heightmap) BEFORE the road is routed, so the road avoidance responsibility flips direction
## from the old _cliff_placement_blocks_road (cliff placement reactively dodging an
## already-routed road) to this -- road pathfinding (_find_road_path) now treats each planned
## cliff-dressing footprint as real, solid terrain to route around, the same way it already
## treats a too-steep slope as impassable via ROAD_SLOPE_HARD_LIMIT. No parallel/perpendicular
## judgment call is needed any more: a fault running alongside where the road ends up is
## naturally just terrain beside the route, not an obstacle blocking it.
const CLIFF_DRESSING_ROAD_OBSTACLE_MARGIN := 3.0 ## extra clearance (world units) added around each footprint so the road doesn't shave right past the mesh's edge

## Independent, sparse glacial-erratic boulders scattered across the open
## valley floor -- unrelated to any cliff feature, the way a retreating
## glacier drops the odd oversized boulder far from any rock face. Kept
## separate from the cliff-foot talus loop above: different placement zone
## (floor only), different (larger, since a lone erratic reads as a single
## dramatic rock rather than a pile of debris) scale range, and a stricter
## flatness requirement since the floor is meant to be genuinely walkable.
## Calibrated at a 256x256 map (matches FEATURE_DENSITY's own baseline),
## then scaled by actual map area at scatter time -- see _scatter_boulders.
## Flat constants here would mean the SAME 15-30 erratics regardless of
## whether the map is 256x256 or 1024x1024, so density (and the visual
## "how sparse does the floor feel") would silently collapse as the area
## grows. Scaling by area keeps erratics-per-square-unit constant instead,
## the same way FEATURE_DENSITY already keeps cliff-feature density constant.
const ERRATIC_DENSITY_BASE_AREA := 256.0 * 256.0

## -- Control-map texture ids --
## These MUST match the Terrain3DTextureAsset `id` values set up by
## res://tools/assign_flat_textures.gd's TEXTURES_BY_ID (Ground/Road,
## real 1k PBR textures under res://textures/source/) -- that's what's
## actually rendered per pixel; changing one without the other just
## repaints which id points at which texture, or breaks it. Run
## assign_flat_textures.gd's fix_textures() via call_method(runtime:false)
## on the EDITOR process, never via run_scene/Play mode -- see that
## script's own header comment for why. (setup_terrain_textures.gd was an
## earlier, now-deleted flat-color placeholder version of this -- if you
## see old references to it, they're stale.)
## id 0 renamed GRASS_TEXTURE_ID -> GROUND_TEXTURE_ID (2026-09-16) -- the
## texture it points at has always been ambientCG's Ground106 (bare dirt),
## never actual grass, so the identifier now matches what's really shown.
const GROUND_TEXTURE_ID := 0

const DATA_DIRECTORY := "res://terrain_data" ## the LIVE surface main.tscn reads
const TEST_DATA_DIRECTORY := "res://terrain_data_test" ## isolated -- res://scenes/terrain_preview.tscn reads this one

## Where (if anywhere) this run's heightmap gets written:
##   NONE -- diagnostics only (console print), nothing touches disk. Fastest
##           loop for pure number-tuning.
##   TEST -- writes to TEST_DATA_DIRECTORY, a directory nothing else reads
##           except terrain_preview.tscn. Always safe regardless of
##           AREA_SIZE, since that directory never holds stale data at a
##           different size/position to clash with (each run replaces the
##           whole thing). This is the default: run this scene, then run
##           terrain_preview.tscn and fly over the result with WASD+mouse.
##   LIVE -- writes to DATA_DIRECTORY, the actual surface main.tscn loads.
##           main.tscn and terrain_preview.tscn were merged into one scene
##           (main.tscn is now the only thing reading DATA_DIRECTORY, and
##           each run replaces that directory's contents in place), so
##           there's no longer a risk of a small run leaving a partial
##           patch inside separately-sized existing data -- any AREA_WIDTH/
##           AREA_LENGTH is safe here now.
enum WriteTarget { NONE, TEST, LIVE }
const WRITE_TARGET := WriteTarget.LIVE
