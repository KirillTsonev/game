#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source_img;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D dest_img;
// [sky-occlusion] 2026-09-24 local edit: scene depth, to tell sky pixels (depth == 0 in
// Godot's reversed-Z) from solid geometry.
layout(set = 2, binding = 0) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform PushConstant {
    float threshold;
    float knee;
    float pad0; float pad1;
    float pad2; float pad3; float pad4; float pad5;
} pc;

// [sky-occlusion] 1.0 if this full-res pixel is sky (nothing rendered there), else 0.0
float is_sky(ivec2 p, ivec2 src_size) {
    return texelFetch(depth_tex, clamp(p, ivec2(0), src_size - 1), 0).r < 1e-6 ? 1.0 : 0.0;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dest_size = imageSize(dest_img);
    if (coord.x >= dest_size.x || coord.y >= dest_size.y) return;

    ivec2 src_coord = coord * 2;
    ivec2 src_size = imageSize(source_img);

    vec3 c00 = imageLoad(source_img, clamp(src_coord, ivec2(0), src_size - 1)).rgb;
    vec3 c10 = imageLoad(source_img, clamp(src_coord + ivec2(1,0), ivec2(0), src_size - 1)).rgb;
    vec3 c01 = imageLoad(source_img, clamp(src_coord + ivec2(0,1), ivec2(0), src_size - 1)).rgb;
    vec3 c11 = imageLoad(source_img, clamp(src_coord + ivec2(1,1), ivec2(0), src_size - 1)).rgb;

    vec3 avg = (c00 + c10 + c01 + c11) * 0.25;

    float luma = max(avg.r, max(avg.g, avg.b));
    float rq = clamp(luma - pc.threshold + pc.knee, 0.0, pc.knee * 2.0);
    float val = max(luma - pc.threshold, (rq * rq) / (4.0 * pc.knee + 0.0001));
    avg = avg * (val / max(luma, 0.0001));

    // [sky-occlusion] alpha = the sky-sourced amount of this glow (mean of rgb x sky fraction).
    // Linear, so it blurs in exact proportion to rgb through the down/up passes.
    float sky_frac = (is_sky(src_coord, src_size) + is_sky(src_coord + ivec2(1,0), src_size)
        + is_sky(src_coord + ivec2(0,1), src_size) + is_sky(src_coord + ivec2(1,1), src_size)) * 0.25;
    float sky_amount = dot(avg, vec3(1.0 / 3.0)) * sky_frac;

    imageStore(dest_img, coord, vec4(avg, sky_amount));
}
