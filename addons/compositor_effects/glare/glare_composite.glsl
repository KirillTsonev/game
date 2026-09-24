#[compute]
#version 450

// Glare pass 3/3: bilinear upsample of the reduced-res glare, blended into
// the full-res frame (same additive / screen blend as the original).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 1, binding = 0) uniform sampler2D glare_tex;
// [sky-occlusion] 2026-09-24 local edit: scene depth (sky == 0 in Godot's reversed-Z)
layout(set = 2, binding = 0) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform PushConstant {
    float blend_mode;
    float sky_occlusion;  // [sky-occlusion] was pad0
    float pad1;
    float pad2;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(color_image);
    if (coord.x >= size.x || coord.y >= size.y) return;

    vec4 original = imageLoad(color_image, coord);
    vec4 gs = textureLod(glare_tex, (vec2(coord) + 0.5) / vec2(size), 0.0);

    // [sky-occlusion] On solid pixels (full-res depth test, so even thin trunks count),
    // remove the part of the glare that came from the sky (moon/sun disc). Sky pixels keep
    // the full streaks; glare from bright geometry is untouched.
    float solid = texelFetch(depth_tex, coord, 0).r < 1e-6 ? 0.0 : 1.0;
    float total = dot(gs.rgb, vec3(1.0 / 3.0));
    float sky_share = clamp(gs.a / max(total, 1e-5), 0.0, 1.0);
    vec3 g = gs.rgb * (1.0 - pc.sky_occlusion * solid * sky_share);

    vec3 result;
    if (int(pc.blend_mode) == 1) {
        result = 1.0 - (1.0 - original.rgb) * (1.0 - g);
    } else {
        result = original.rgb + g;
    }
    imageStore(color_image, coord, vec4(result, original.a));
}
