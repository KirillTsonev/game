#[compute]
#version 450

// Vertical pass of the summed-area table build. One thread per COLUMN:
// walks top-to-bottom accumulating the row-sums from the horizontal pass
// into a full 2D inclusive prefix sum (SAT(x,y) = sum of everything in
// the rectangle from (0,0) to (x,y)).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D source_img;
layout(rgba32f, set = 1, binding = 0) uniform restrict writeonly image2D dest_img;

void main() {
    int col = int(gl_GlobalInvocationID.x);
    ivec2 size = imageSize(source_img);
    if (col >= size.x) return;

    vec4 acc = vec4(0.0);
    for (int y = 0; y < size.y; y++) {
        vec4 c = imageLoad(source_img, ivec2(col, y));
        acc += c;
        imageStore(dest_img, ivec2(col, y), acc);
    }
}
