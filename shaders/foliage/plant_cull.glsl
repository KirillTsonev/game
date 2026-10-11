#[compute]
#version 450

// Plant renderer -- GPU LOD selection + culling (2026-10-06). Dispatched every frame by PlantField
// (scripts/terrain/plant_field.gd), one dispatch per plant mesh (a Terrain3D mesh asset id).
//
// One thread per placed plant. The plant's transform is read from the source list, its LOD is
// picked from ITS OWN distance to the camera (two LODs inside a cross-fade band, see Push.fade),
// its bounding sphere is tested against the camera
// frustum, and survivors are appended to that LOD's MultiMesh instance buffer. The append slot
// comes from an atomic add on the draw command's instance count itself (PlantField zeroes it
// before the dispatch), so no second pass is needed. Every LOD buffer holds the full plant count,
// so it cannot overflow.
// A multi-surface mesh (trees: bark + leaves) has one draw command per surface, 5 uints each. The
// slot comes from the first surface's count; the others' counts are raised by one per survivor
// too, so all end equal (2026-10-11).

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
layout(set = 0, binding = 8, std430) restrict writeonly buffer Inst3 { vec4 data[]; } inst3;
layout(set = 0, binding = 9, std430) restrict buffer Cmd3 { uint cmd[]; } cmd3;

layout(push_constant, std430) uniform Push {
	uint count;     // plants in the source list
	uint lod_count; // 1-4; the bindings of unused LODs hold dummy buffers and are never written
	float radius;   // bounding sphere of the mesh at scale 1, around the plant's origin
	uint surfaces;  // surface count of LOD 0 / 1 / 2 / 3's mesh, 8 bits each from bit 0
	vec4 ranges;    // outer distance of LOD 0 / 1 / 2 / 3 (m); past the last one the plant is not drawn
	float fade;     // cross-fade width (m): within it either side of a range the plant is written
	                // to BOTH LODs, and their shaders dissolve one into the other. 0 = hard switch
	float pad0;
	float pad1;
	float pad2;
} pc;

const uint CMD_STRIDE = 5u; // uints per surface in a MultiMesh's indirect command buffer

// Appends the plant to one LOD: the slot from the first surface's instance count, the other
// surfaces' counts raised with it.
#define APPEND(INST, CMD, SHIFT) { \
	uint surfaces = (pc.surfaces >> SHIFT) & 255u; \
	uint o = atomicAdd(CMD.cmd[1], 1u) * 3u; \
	for (uint s = 1u; s < surfaces; s++) { \
		atomicAdd(CMD.cmd[s * CMD_STRIDE + 1u], 1u); \
	} \
	INST.data[o] = r0; \
	INST.data[o + 1u] = r1; \
	INST.data[o + 2u] = r2; \
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.count) {
		return;
	}
	vec4 r0 = src.rows[i * 3u];
	vec4 r1 = src.rows[i * 3u + 1u];
	vec4 r2 = src.rows[i * 3u + 2u];
	vec3 pos = vec3(r0.w, r1.w, r2.w);

	// LOD k is drawn from the range before it to its own, each end widened by the fade where
	// another LOD follows or precedes.
	float d = distance(pos, frame.v[6].xyz);
	int last = int(pc.lod_count) - 1;
	bool in0 = d < pc.ranges[0] + (last > 0 ? pc.fade : 0.0);
	bool in1 = last >= 1 && d >= pc.ranges[0] - pc.fade && d < pc.ranges[1] + (last > 1 ? pc.fade : 0.0);
	bool in2 = last >= 2 && d >= pc.ranges[1] - pc.fade && d < pc.ranges[2] + (last > 2 ? pc.fade : 0.0);
	bool in3 = last >= 3 && d >= pc.ranges[2] - pc.fade && d < pc.ranges[3];
	if (!(in0 || in1 || in2 || in3)) {
		return;
	}

	// x the plant's scale: its longest basis column (logs and rocks may not be scaled evenly).
	float r = pc.radius * sqrt(max(dot(vec3(r0.x, r1.x, r2.x), vec3(r0.x, r1.x, r2.x)),
		max(dot(vec3(r0.y, r1.y, r2.y), vec3(r0.y, r1.y, r2.y)), dot(vec3(r0.z, r1.z, r2.z), vec3(r0.z, r1.z, r2.z)))));
	for (int k = 0; k < 6; k++) {
		vec4 pl = frame.v[k];
		if (dot(pl.xyz, pos) - pl.w > r) {
			return;
		}
	}

	if (in0) APPEND(inst0, cmd0, 0u)
	if (in1) APPEND(inst1, cmd1, 8u)
	if (in2) APPEND(inst2, cmd2, 16u)
	if (in3) APPEND(inst3, cmd3, 24u)
}
