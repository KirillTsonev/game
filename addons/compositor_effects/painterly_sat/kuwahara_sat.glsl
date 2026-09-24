#[compute]
#version 450

// Classic 4-region Kuwahara filter, accelerated with a summed-area table.
// Instead of scanning a (2*radius+1)^2 neighborhood per pixel, each of the
// 4 overlapping quadrant regions' mean color and luma variance is read in
// O(1) via inclusion-exclusion on the precomputed SAT. Cost is therefore
// roughly independent of radius, unlike the histogram-based Painterly
// effect this project also has.
//
// orig_img is a clean, untouched copy of the scene made before this pass
// runs (see post_process_painterly_sat.gd) -- needed so edge detection can
// safely read neighboring pixels without racing against other invocations
// writing their own result into dest_img.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D sat_img;
layout(rgba16f, set = 1, binding = 0) uniform restrict readonly image2D orig_img;
layout(rgba16f, set = 2, binding = 0) uniform restrict writeonly image2D dest_img;

layout(push_constant, std430) uniform PushConstant {
    float radius;
    float intensity;
    float edge_sharpness;
    float _pad0;
} pc;

vec4 sat_lookup(ivec2 size, int x, int y) {
    // SAT is conceptually zero-padded outside the image.
    if (x < 0 || y < 0) return vec4(0.0);
    ivec2 c = ivec2(min(x, size.x - 1), min(y, size.y - 1));
    return imageLoad(sat_img, c);
}

vec4 rect_sum(ivec2 size, int x1, int y1, int x2, int y2) {
    x2 = min(x2, size.x - 1);
    y2 = min(y2, size.y - 1);
    vec4 a = sat_lookup(size, x2, y2);
    vec4 b = sat_lookup(size, x1 - 1, y2);
    vec4 c = sat_lookup(size, x2, y1 - 1);
    vec4 d = sat_lookup(size, x1 - 1, y1 - 1);
    return a - b - c + d;
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(orig_img);
    if (coord.x >= size.x || coord.y >= size.y) return;

    int r = max(int(pc.radius), 1);
    vec4 original = imageLoad(orig_img, coord);

    // Four overlapping quadrant regions sharing this pixel as a corner.
    ivec4 bounds[4];
    bounds[0] = ivec4(coord.x - r, coord.y - r, coord.x, coord.y);       // top-left
    bounds[1] = ivec4(coord.x, coord.y - r, coord.x + r, coord.y);       // top-right
    bounds[2] = ivec4(coord.x - r, coord.y, coord.x, coord.y + r);       // bottom-left
    bounds[3] = ivec4(coord.x, coord.y, coord.x + r, coord.y + r);       // bottom-right

    vec3 best_mean = original.rgb;
    float best_variance = 1e20;

    for (int i = 0; i < 4; i++) {
        ivec4 b = bounds[i];
        int x1 = max(b.x, 0);
        int y1 = max(b.y, 0);
        int x2 = min(b.z, size.x - 1);
        int y2 = min(b.w, size.y - 1);
        float area = float(max(x2 - x1 + 1, 1) * max(y2 - y1 + 1, 1));

        vec4 s = rect_sum(size, b.x, b.y, b.z, b.w);
        vec3 mean = s.rgb / area;
        float mean_luma2 = s.a / area;
        float mean_luma = dot(mean, vec3(0.299, 0.587, 0.114));
        float variance = max(mean_luma2 - mean_luma * mean_luma, 0.0);

        if (variance < best_variance) {
            best_variance = variance;
            best_mean = mean;
        }
    }

    vec3 oil_color = best_mean;

    if (pc.edge_sharpness > 0.001) {
        vec3 dx = imageLoad(orig_img, clamp(coord + ivec2(1, 0), ivec2(0), size - 1)).rgb
                - imageLoad(orig_img, clamp(coord - ivec2(1, 0), ivec2(0), size - 1)).rgb;
        vec3 dy = imageLoad(orig_img, clamp(coord + ivec2(0, 1), ivec2(0), size - 1)).rgb
                - imageLoad(orig_img, clamp(coord - ivec2(0, 1), ivec2(0), size - 1)).rgb;
        float edge = length(dx) + length(dy);
        float edge_mask = smoothstep(0.0, 0.3, edge);
        oil_color = mix(oil_color, original.rgb, edge_mask * pc.edge_sharpness);
    }

    vec3 result = mix(original.rgb, oil_color, pc.intensity);
    imageStore(dest_img, coord, vec4(result, original.a));
}
