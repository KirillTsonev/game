#[compute]
#version 450

// Vertical half of the Kuwahara box sums. dest(x, y) = sum of the horizontal sums over rows
// y-r .. y, rows outside the image skipped -- so dest(x, y) is the sum of the source over the
// (r+1) x (r+1) box whose bottom-right corner is (x, y). dest is r pixels TALLER than its source.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D source_img;
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

    int height = imageSize(source_img).y;
    int r = max(int(pc.radius), 1);
    vec4 acc = vec4(0.0);
    for (int y = max(coord.y - r, 0); y <= min(coord.y, height - 1); y++) {
        acc += imageLoad(source_img, ivec2(coord.x, y));
    }
    imageStore(dest_img, coord, acc);
}
