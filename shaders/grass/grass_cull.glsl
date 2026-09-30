#[compute]
#version 450

// Grass groundcover -- GPU placement + culling (2026-09-25). Dispatched every frame by
// GrassField (scripts/terrain/grass_field.gd), one dispatch per blade layer (distance band).
//
// mode 0: one thread per world grid cell (`spacing` m) in an n x n square centred on the player.
//   Everything about a blade -- jitter, whether it exists -- is hashed from the cell's WORLD
//   coords, so nothing swims as the grid follows the player. A blade is written to the MultiMesh
//   instance buffer ONLY if it exists, lies inside its layer's distance band and its bounding
//   sphere is inside the camera frustum; survivors are compacted with an atomic counter. Nothing
//   culled ever reaches the vertex stage.
// mode 1: a single thread copies min(count, capacity) into the MultiMesh's indirect draw command
//   (indexed layout: [indexCount, instanceCount, firstIndex, vertexOffset, firstInstance]).
//
// BLADES (Ghost of Tsushima style, grass_blade.gdshader). Transform = position only (the blade
// shader does its own yaw, bend, width and height like GodotGrass).
// PLACEMENT = PATCHES, not thinning (2026-09-25 "middle ground": evenly thinned grass read as
// sporadic lone tufts). The map's R is COVERAGE -- the fraction of ground inside patches. The patch
// noise is thresholded against it: inside a patch every blade is kept, outside none, with a soft
// PATCH_EDGE rim. Isolated tussocks (TUSSOCK_*) grow in the gaps, gated by the map's A. Each layer
// covers a distance band [inner, radius] at its own spacing; neighbouring bands cross-fade
// STOCHASTICALLY (keep chance ramps down across the outer band while the next layer's ramps up
// over the same metres).
// 2026-09-27: the patch noise is BAKED on the CPU by GrassScatter (patch_map, binding 6, PATCH_RES
// px/m) so TerrainGroundPaint can paint the grass TEXTURE under exactly these patches. Keep
// PATCH_N_LO/HI/EDGE in sync with GrassScatter's constants of the same name (its patch_keep() is
// the CPU twin). Also 2026-09-27: the old "tufts" style (variants 0-2) was removed.
// 2026-09-28: sun-shadow culling (binding 7, skip blades in terrain/rock/tree shadow) was built,
// measured (~0.07 ms GPU saved for ~17% fewer blades) and removed. Also 2026-09-28: a tile
// pre-cull (8 m tiles frustum-tested before the per-cell pass, indirect dispatch) cut the cell
// threads to ~37% with identical output but no measurable GPU change, and made the grass flicker
// -- reverted.
// 2026-09-29 OVERHANG CAP (Kirill: far grass on slopes seems to float past the slope edges; "it's
// only when looking at grass on slopes from a big distance", fix it WITHOUT changing the grass layer
// values). The blade shader widens far blades (x (1 + min((widen_scale * d)^widen_power,
// widen_max)) -- ~0.9 m wide at 50 m, ~5 m at 80 m, ~7 m past 100 m), so a far blade on a slope or
// a brow sticks metres out horizontally over ground that has dropped away beneath it.
// Earlier the same day this was a CREST DROP (skip blades on convex brows only); it deliberately
// kept every blade on an EVEN slope, which is exactly where the floating stayed visible. Now, for
// every widened blade (half-width > OVERHANG_MIN_HALF_WIDTH), the ground is sampled at its
// half-width in 8 directions; if the biggest drop exceeds a distance-scaled tolerance (what can't be
// seen from that far: max(OVERHANG_TOL_MIN, OVERHANG_TOL_PER_M * d)), the blade's WIDTH is scaled
// down so its overhang stays within the tolerance (factor -> INSTANCE_CUSTOM.x, applied in the
// blade shader); blades that would need less than OVERHANG_MIN_SCALE are skipped. Flat / gentle
// ground and all near blades (narrow, never tested) are unchanged. The widening curve is only READ
// here (params 9.zw / 10.w) -- no grass layer value changed.
// Reads GrassScatter's bake: density_map (R coverage / G dry / B tall / A tussock, 1 px = 1 m),
// height_map (R32F, texel (px,pz) = height at map_corner + (px, 0, pz); sampled with manual
// bilinear because linear filtering of R32F isn't guaranteed on every GPU) and patch_map.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer Instances { vec4 data[]; } inst; // 4 x vec4 per instance: 3 transform rows + custom
layout(set = 0, binding = 1, std430) restrict buffer Command { uint cmd[]; } command;
layout(set = 0, binding = 2, std430) restrict buffer Stats { uint raw_count; } stats;
layout(set = 0, binding = 3, std430) restrict readonly buffer Params { vec4 v[]; } params;
layout(set = 0, binding = 4) uniform sampler2D density_map;
layout(set = 0, binding = 5) uniform sampler2D height_map;
layout(set = 0, binding = 6) uniform sampler2D patch_map;

layout(push_constant, std430) uniform Push {
	uint mode;
	uint capacity;
	uint grid_n;
	uint reserved; // was the tuft/blade variant; unused since 2026-09-27
} pc;

// params.v layout (see GrassField._add_layer / _update; PARAMS_VEC4 = 11):
//   0-5  frustum planes (xyz = outward normal, w = d; outside when dot(n, p) - d > r)
//   6    center.xyz (player), w = spacing
//   7    map_corner.x, map_corner.z, map_size.x, map_size.y
//   8    radius (band outer edge), fade_band (just inside radius), inner (band inner edge, 0 = none), inner_band (just inside inner)
//   9    seed, coverage_scale, widen_scale, widen_power (2026-09-29, read-only copy for the overhang cap)
//   10   embed, cull_radius, cull_lift, widen_max (2026-09-29, same)

// -- Blade patches (baked noise, see header; keep in sync with GrassScatter) --
const float PATCH_RES = 2.0;        // patch_map texels per metre
const float PATCH_N_LO = 0.2;
const float PATCH_N_HI = 0.8;
const float PATCH_EDGE = 0.06;      // noise units -- soft rim (a few tens of cm) where blades thin out
// -- Tussocks: small dense clumps in the gaps between patches (and on rocky/steep ground) --
const float TUSSOCK_CELL = 1.6;     // m -- at most one tussock per cell
const float TUSSOCK_RATE = 0.22;    // chance a cell has one, x the map's tussock allowance (A)
const float TUSSOCK_R_MIN = 0.10;   // m -- tussock radius range (-> ~10-30 blades near the player)
const float TUSSOCK_R_MAX = 0.28;
// -- Overhang cap (2026-09-29, see header) --
const float BLADE_HALF_WIDTH = 0.05;        // m -- the blade mesh's base half-width (grass_field.gd _build_blade_mesh)
const float OVERHANG_MIN_HALF_WIDTH = 0.25; // m -- narrower blades (roughly the nearest ~40 m) aren't tested
const float OVERHANG_TOL_MIN = 0.25;        // m -- ground may fall this much under a blade's edge without it showing ...
const float OVERHANG_TOL_PER_M = 0.005;     // ... or this much per metre of camera distance, whichever is larger
const float OVERHANG_MIN_SCALE = 0.15;      // a blade that would need to be narrower than this fraction is skipped

// Dave Hoskins' hash-without-sine
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

// Keep chance for a blade at world pos w (map pixel px), from coverage c (map R) and tussock
// allowance t (map A).
float blade_patch_keep(vec2 w, vec2 px, vec2 size, float c, float t) {
	// Patches: baked noise, same texel the CPU reads for the pixel this blade stands in.
	vec2 puv = (px * PATCH_RES + 0.5) / (size * PATCH_RES);
	float n = smoothstep(PATCH_N_LO, PATCH_N_HI, textureLod(patch_map, puv, 0.0).r);
	// Coverage is the UPPER edge of the ramp, so c = 0 -> 0 keep, always. (2026-09-25: was
	// smoothstep(-PATCH_EDGE, PATCH_EDGE, c - n), which returned 0.5 wherever c = 0 AND the noise
	// bottomed out at n = 0 -> half-density patches on the road and other zero-coverage ground.)
	float patch_keep = smoothstep(n, n + 2.0 * PATCH_EDGE, c);
	// Tussocks: one candidate per TUSSOCK_CELL cell, a small disc of blades around it.
	vec2 tc = floor(w / TUSSOCK_CELL);
	float tussock_keep = 0.0;
	if (hash12(tc + vec2(91.7, 3.3)) < TUSSOCK_RATE * t * mix(0.35, 1.0, c)) {
		vec2 centre = (tc + 0.2 + 0.6 * hash22(tc + vec2(5.3, 61.1))) * TUSSOCK_CELL;
		float r = mix(TUSSOCK_R_MIN, TUSSOCK_R_MAX, hash12(tc + vec2(2.1, 17.9)));
		tussock_keep = 1.0 - smoothstep(r * 0.7, r, distance(w, centre));
	}
	return max(patch_keep, tussock_keep);
}

float height_at(vec2 px, vec2 size) {
	vec2 p = clamp(px, vec2(0.0), size - 1.0);
	ivec2 i0 = ivec2(floor(p));
	ivec2 i1 = min(i0 + 1, ivec2(size) - 1);
	vec2 f = p - vec2(i0);
	float h00 = texelFetch(height_map, i0, 0).r;
	float h10 = texelFetch(height_map, ivec2(i1.x, i0.y), 0).r;
	float h01 = texelFetch(height_map, ivec2(i0.x, i1.y), 0).r;
	float h11 = texelFetch(height_map, i1, 0).r;
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

void main() {
	if (pc.mode == 1u) {
		command.cmd[1] = min(stats.raw_count, pc.capacity);
		return;
	}
	uint n = pc.grid_n;
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= n * n) {
		return;
	}
	vec4 c6 = params.v[6];
	vec4 mp = params.v[7];
	vec4 rg = params.v[8];
	vec4 ms = params.v[9];
	vec4 m2 = params.v[10];
	float spacing = c6.w;
	vec2 center = c6.xz;
	vec2 corner = mp.xy;
	vec2 size = mp.zw;

	int ix = int(idx % n);
	int iz = int(idx / n);
	vec2 cell = floor(center / spacing) + vec2(float(ix - int(n) / 2), float(iz - int(n) / 2));
	vec2 key = cell + vec2(ms.x * 17.13, ms.x * 29.71);
	vec2 wpos = (cell + hash22(key)) * spacing;

	float d = distance(wpos, center);
	if (d > rg.x || (rg.z > 0.0 && d < rg.z - rg.w)) {
		return;
	}
	vec2 px = wpos - corner;
	if (px.x < 0.0 || px.y < 0.0 || px.x > size.x - 1.0 || px.y > size.y - 1.0) {
		return;
	}
	vec4 m = textureLod(density_map, (px + 0.5) / size, 0.0);

	float fade_out = 1.0 - smoothstep(rg.x - rg.y, rg.x, d);
	float fade_in = rg.z > 0.0 ? smoothstep(rg.z - rg.w, rg.z, d) : 1.0;
	float p = blade_patch_keep(wpos, px, size, clamp(m.r * ms.y, 0.0, 1.0), m.a) * fade_out * fade_in;
	if (hash12(key + 7.31) >= p) {
		return;
	}

	float h0 = height_at(px, size);
	float y = h0 - m2.x;

	// Overhang cap (2026-09-29, see header): a widened blade on a slope / brow overhangs the drop.
	float width_scale = 1.0;
	float half_w = BLADE_HALF_WIDTH * (1.0 + min(pow(ms.z * d, ms.w), m2.w));
	if (half_w > OVERHANG_MIN_HALF_WIDTH) {
		float max_drop = 0.0;
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.78539816; // 45 degree steps
			max_drop = max(max_drop, h0 - height_at(px + vec2(cos(a), sin(a)) * half_w, size));
		}
		float tol = max(OVERHANG_TOL_MIN, OVERHANG_TOL_PER_M * d);
		if (max_drop > tol) {
			// Drop grows ~linearly with reach, so this width keeps the overhang at ~tol.
			width_scale = tol / max_drop;
			if (width_scale < OVERHANG_MIN_SCALE) {
				return;
			}
		}
	}

	// Frustum: bounding sphere lifted cull_lift above the root (covers height, lean, wind + trample bend).
	vec3 sc = vec3(wpos.x, y + m2.z, wpos.y);
	float r = m2.y;
	for (int i = 0; i < 6; i++) {
		vec4 pl = params.v[i];
		if (dot(pl.xyz, sc) - pl.w > r) {
			return;
		}
	}

	uint slot = atomicAdd(stats.raw_count, 1u);
	if (slot >= pc.capacity) {
		return;
	}
	uint o = slot * 4u;
	// Position only -- grass_blade.gdshader does yaw/bend/width/height itself (GodotGrass style).
	inst.data[o] = vec4(1.0, 0.0, 0.0, wpos.x);
	inst.data[o + 1u] = vec4(0.0, 1.0, 0.0, y);
	inst.data[o + 2u] = vec4(0.0, 0.0, 1.0, wpos.y);
	// -> INSTANCE_CUSTOM (width_scale, dry, tall, coverage). x used to be an unused random value;
	// since 2026-09-29 it's the overhang cap's width factor (1 = full width), read by the blade shader.
	inst.data[o + 3u] = vec4(width_scale, m.g, m.b, m.r);
}
