#[compute]
#version 450

// Glare pass 2/3: ray streaks, at reduced resolution.
// Same math as the original glare.glsl, but samples the pre-thresholded
// bright texture with hardware bilinear filtering (1 fetch instead of 4
// imageLoads + a threshold per tap). Distances stay in FULL-RES pixels so
// glare_size means the same streak length as before.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D bright_tex;
layout(rgba16f, set = 1, binding = 0) uniform restrict writeonly image2D glare_image;

layout(push_constant, std430) uniform PushConstant {
    float glare_size;
    float samples;
    float ray_count;
    float base_angle;

    float color_r;
    float color_g;
    float color_b;
    float falloff;

    float chroma_shift;
    float rotation_speed;
    float time;
    float asymmetry;

    float intensity;
    float divisor;
    float full_w;
    float full_h;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 out_size = imageSize(glare_image);
    if (coord.x >= out_size.x || coord.y >= out_size.y) return;

    vec2 full_size = vec2(pc.full_w, pc.full_h);
    vec2 inv_full = 1.0 / full_size;
    // centre of this low-res pixel, in full-res pixel units
    vec2 p = (vec2(coord) + 0.5) * pc.divisor;

    int rays = max(int(pc.ray_count), 1);
    float angle_step = 3.14159265 / float(rays);
    int half_samples = max(int(pc.samples), 1);
    float step_size = max(pc.glare_size / float(half_samples), 0.0);
    float animated_angle = pc.base_angle + pc.time * pc.rotation_speed;
    float chroma = pc.chroma_shift;
    bool use_chroma = chroma > 0.0;

    vec3 acc = vec3(0.0);
    float sky_acc = 0.0;  // [sky-occlusion] 2026-09-24 local edit: sky-sourced amount, same weights
    for (int r = 0; r < rays; r++) {
        float ray_angle = animated_angle + float(r) * angle_step;
        vec2 dir = vec2(cos(ray_angle), -sin(ray_angle));
        float rr = float(r) / float(max(rays - 1, 1));
        float scale_fwd = 1.0 + pc.asymmetry * rr;
        float scale_bck = 1.0 - pc.asymmetry * rr;

        for (int i = 1; i <= half_samples; i++) {
            float t = float(i) / float(half_samples);
            float weight = pow(1.0 - t, pc.falloff);
            vec2 df = dir * (float(i) * step_size * scale_fwd);
            vec2 db = dir * (float(i) * step_size * scale_bck);

            vec3 f;
            vec3 b;
            // [sky-occlusion] the unshifted (green-channel) taps also carry the sky amount in .a
            vec4 fc = textureLod(bright_tex, (p + df) * inv_full, 0.0);
            vec4 bc = textureLod(bright_tex, (p - db) * inv_full, 0.0);
            if (use_chroma) {
                f.r = textureLod(bright_tex, (p + df * (1.0 - chroma)) * inv_full, 0.0).r;
                f.g = fc.g;
                f.b = textureLod(bright_tex, (p + df * (1.0 + chroma)) * inv_full, 0.0).b;
                b.r = textureLod(bright_tex, (p - db * (1.0 - chroma)) * inv_full, 0.0).r;
                b.g = bc.g;
                b.b = textureLod(bright_tex, (p - db * (1.0 + chroma)) * inv_full, 0.0).b;
            } else {
                f = fc.rgb;
                b = bc.rgb;
            }
            acc += (f + b) * weight;
            sky_acc += (fc.a + bc.a) * weight;
        }
    }

    acc *= step_size;
    sky_acc *= step_size;
    float norm = 2.0 / float(rays);
    vec3 tint = vec3(pc.color_r, pc.color_g, pc.color_b);
    float k = pc.intensity * 0.05 * norm;
    // [sky-occlusion] alpha = sky-sourced amount in the same units as mean(rgb) (tint averaged)
    imageStore(glare_image, coord, vec4(acc * tint * k, sky_acc * dot(tint, vec3(1.0 / 3.0)) * k));
}
