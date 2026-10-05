#[compute]
#version 450

// Horizontal half of the Kuwahara box sums (2026-10-05, replaces the summed-area-table build).
// dest(x, y) = sum of (color.rgb, luma^2) over source x-r .. x on row y, pixels outside the
// image skipped. dest is r pixels WIDER than the source, so the box that starts at a pixel and
// reaches r to its right is stored too (at x + r). Every pixel is independent: r + 1 reads.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source_img;
layout(rgba32f, set = 1, binding = 0) uniform restrict writeonly image2D dest_img;

layout(push_constant, std430) uniform PushConstant {
    float radius;
    float _pad0;
    float _pad1;
    float _pad2;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dest_size = imageSize(dest_img);
    if (coord.x >= dest_size.x || coord.y >= dest_size.y) return;

    int width = imageSize(source_img).x;
    int r = max(int(pc.radius), 1);
    vec4 acc = vec4(0.0);
    for (int x = max(coord.x - r, 0); x <= min(coord.x, width - 1); x++) {
        vec3 c = imageLoad(source_img, ivec2(x, coord.y)).rgb;
        float luma = dot(c, vec3(0.299, 0.587, 0.114));
        acc += vec4(c, luma * luma);
    }
    imageStore(dest_img, coord, acc);
}
