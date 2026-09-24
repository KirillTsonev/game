#[compute]
#version 450

// Horizontal pass of a 2D summed-area table (integral image) build.
// One thread per ROW: walks left-to-right accumulating a running sum of
// (color.rgb, luma^2) so the vertical pass (and later O(1) rectangle
// queries) has something to build on. This trades per-pixel radius-squared
// sampling for two full-image linear passes done once per frame.

layout(local_size_x = 1, local_size_y = 64, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source_img;
layout(rgba32f, set = 1, binding = 0) uniform restrict writeonly image2D dest_img;

void main() {
    int row = int(gl_GlobalInvocationID.y);
    ivec2 size = imageSize(source_img);
    if (row >= size.y) return;

    vec4 acc = vec4(0.0);
    for (int x = 0; x < size.x; x++) {
        vec4 c = imageLoad(source_img, ivec2(x, row));
        float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
        acc += vec4(c.rgb, luma * luma);
        imageStore(dest_img, ivec2(x, row), acc);
    }
}
