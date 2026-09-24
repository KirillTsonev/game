#[compute]
#version 450

// Glare pass 1/3: bright-pass + downsample.
// Reads the full-res frame in DIVxDIV blocks, applies the same soft threshold
// as the original glare.glsl per texel, writes the block average to a
// reduced-resolution "bright" texture.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D source_image;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D bright_image;
// [sky-occlusion] 2026-09-24 local edit: scene depth (sky == 0 in Godot's reversed-Z)
layout(set = 2, binding = 0) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform PushConstant {
    float threshold;
    float knee;
    float divisor;
    float pad;
} pc;

float soft_threshold(float luma, float thr, float kn) {
    float k = max(kn, 0.0001);
    float lo = thr - k * 0.5;
    float hi = thr + k * 0.5;
    if (luma < lo) return 0.0;
    if (luma > hi) return luma - thr;
    float t = (luma - lo) / (hi - lo);
    return t * t * (luma - thr);
}

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 out_size = imageSize(bright_image);
    if (coord.x >= out_size.x || coord.y >= out_size.y) return;

    ivec2 src_size = imageSize(source_image);
    int div = max(int(pc.divisor), 1);
    ivec2 base = coord * div;

    vec3 acc = vec3(0.0);
    float sky_acc = 0.0;  // [sky-occlusion] sky-sourced amount (mean of rgb), same units as acc
    float n = 0.0;
    for (int y = 0; y < div; y++) {
        for (int x = 0; x < div; x++) {
            ivec2 p = min(base + ivec2(x, y), src_size - 1);
            vec3 c = imageLoad(source_image, p).rgb;
            float luma = max(c.r, max(c.g, c.b));
            float h = soft_threshold(luma, pc.threshold, pc.knee);
            if (h > 0.0) {
                vec3 contrib = c * (h / max(luma, 0.0001));
                acc += contrib;
                // [sky-occlusion] count it as sky-sourced if nothing is rendered at this pixel
                if (texelFetch(depth_tex, p, 0).r < 1e-6) sky_acc += dot(contrib, vec3(1.0 / 3.0));
            }
            n += 1.0;
        }
    }
    // [sky-occlusion] alpha now carries the sky-sourced amount (was forced to 1.0)
    imageStore(bright_image, coord, vec4(acc / max(n, 1.0), sky_acc / max(n, 1.0)));
}
