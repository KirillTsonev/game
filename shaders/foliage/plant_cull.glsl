#[compute]
#version 450

// Plant renderer -- GPU LOD selection + culling (2026-10-06). Dispatched every frame by PlantField
// (scripts/terrain/plant_field.gd), one dispatch per plant mesh (a Terrain3D mesh asset id).
//
// One thread per placed plant. The plant's transform is read from the source list, its LOD is
// picked from ITS OWN distance to the camera, its bounding sphere is tested against the camera
// frustum, and survivors are appended to that LOD's MultiMesh instance buffer. The append slot
// comes from an atomic add on the draw command's instance count itself (PlantField zeroes it
// before the dispatch), so no second pass is needed. Every LOD buffer holds the full plant count,
// so it cannot overflow.
// Single-surface meshes only: a multi-surface mesh has one draw command per surface, and only the
// first one's instance count is written here.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// 3 x vec4 per plant, the MultiMesh TRANSFORM_3D layout: basis rows with the origin in w.
layout(set = 0, binding = 0, std430) restrict readonly buffer Source { vec4 rows[]; } src;
// 0-5 frustum planes (xyz = outward normal, w = d; outside when dot(n, p) - d > r), 6 camera position.
layout(set = 0, binding = 1, std430) restrict readonly buffer Frame { vec4 v[]; } frame;
layout(set = 0, binding = 2, std430) restrict writeonly buffer Inst0 { vec4 data[]; } inst0;
layout(set = 0, binding = 3, std430) restrict buffer Cmd0 { uint cmd[]; } cmd0; // [1] = instance count
layout(set = 0, binding = 4, std430) restrict writeonly buffer Inst1 { vec4 data[]; } inst1;
layout(set = 0, binding = 5, std430) restrict buffer Cmd1 { uint cmd[]; } cmd1;
layout(set = 0, binding = 6, std430) restrict writeonly buffer Inst2 { vec4 data[]; } inst2;
layout(set = 0, binding = 7, std430) restrict buffer Cmd2 { uint cmd[]; } cmd2;

layout(push_constant, std430) uniform Push {
	uint count;     // plants in the source list
	uint lod_count; // 1-3; the bindings of unused LODs hold dummy buffers and are never written
	float radius;   // bounding sphere of the mesh at scale 1, around the plant's origin
	float pad;
	vec4 ranges;    // outer distance of LOD 0 / 1 / 2 (m); past the last one the plant is not drawn
} pc;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.count) {
		return;
	}
	vec4 r0 = src.rows[i * 3u];
	vec4 r1 = src.rows[i * 3u + 1u];
	vec4 r2 = src.rows[i * 3u + 2u];
	vec3 pos = vec3(r0.w, r1.w, r2.w);

	float d = distance(pos, frame.v[6].xyz);
	int lod = -1;
	for (int k = 0; k < int(pc.lod_count); k++) {
		if (d < pc.ranges[k]) {
			lod = k;
			break;
		}
	}
	if (lod < 0) {
		return;
	}

	float r = pc.radius * length(vec3(r0.x, r1.x, r2.x)); // x the plant's scale (first basis column)
	for (int k = 0; k < 6; k++) {
		vec4 pl = frame.v[k];
		if (dot(pl.xyz, pos) - pl.w > r) {
			return;
		}
	}

	if (lod == 0) {
		uint o = atomicAdd(cmd0.cmd[1], 1u) * 3u;
		inst0.data[o] = r0;
		inst0.data[o + 1u] = r1;
		inst0.data[o + 2u] = r2;
	} else if (lod == 1) {
		uint o = atomicAdd(cmd1.cmd[1], 1u) * 3u;
		inst1.data[o] = r0;
		inst1.data[o + 1u] = r1;
		inst1.data[o + 2u] = r2;
	} else {
		uint o = atomicAdd(cmd2.cmd[1], 1u) * 3u;
		inst2.data[o] = r0;
		inst2.data[o + 1u] = r1;
		inst2.data[o + 2u] = r2;
	}
}
