#[compute]
#version 450

// Classic 4-region Kuwahara filter (2026-10-05). Each region's sum is ONE read of the box-sum
// image (box_sum_h.glsl + box_sum_v.glsl), where the summed-area table this replaced
// (kuwahara_sat.glsl, deleted; in git before 2026-10-05) needed four: box_img(x, y) = the sum over the (r+1) x (r+1) box whose
// bottom-right corner is pixel (x, y), and the image is r pixels larger than the frame on both
// axes so the boxes reaching right / down from a pixel are stored at x + r / y + r.
//
// orig_img is a clean copy of the frame made before this pass (see
// post_process_painterly_sat.gd) -- the edge detection reads neighbouring pixels while other
// invocations write their result into dest_img.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D box_img;
layout(rgba16f, set = 1, binding = 0) uniform restrict readonly image2D orig_img;
layout(rgba16f, set = 2, binding = 0) uniform restrict writeonly image2D dest_img;

layout(push_constant, std430) uniform PushConstant {
    float radius;
    float intensity;
    float edge_sharpness;
    float _pad0;
} pc;

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

        // The region's bottom-right corner (unclamped) is where its box sum is stored.
        vec4 s = imageLoad(box_img, b.zw);
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
