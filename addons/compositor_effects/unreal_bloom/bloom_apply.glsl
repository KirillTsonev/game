#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D bloom_tex;
layout(rgba16f, set = 1, binding = 0) uniform restrict image2D color_img;
// [sky-occlusion] 2026-09-24 local edit: scene depth (sky == 0 in Godot's reversed-Z)
layout(set = 2, binding = 0) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform PushConstant {
    float intensity;
    float sky_occlusion;  // [sky-occlusion] was pad0
    float pad1; float pad2;
    float pad3; float pad4; float pad5; float pad6;
} pc;

void main() {
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 dest_size = imageSize(color_img);
    if (coord.x >= dest_size.x || coord.y >= dest_size.y) return;

    vec2 norm_uv = (vec2(coord) + 0.5) / vec2(dest_size);
    vec4 bloom = texture(bloom_tex, norm_uv);

    // [sky-occlusion] On solid pixels, remove the part of the glow that came from the sky
    // (e.g. the moon disc behind a trunk). Sky pixels keep their full halo, and glow from
    // bright geometry (torches, lit surfaces) is untouched.
    float solid = texelFetch(depth_tex, coord, 0).r < 1e-6 ? 0.0 : 1.0;
    float total = dot(bloom.rgb, vec3(1.0 / 3.0));
    float sky_share = clamp(bloom.a / max(total, 1e-5), 0.0, 1.0);
    float keep = 1.0 - pc.sky_occlusion * solid * sky_share;

    vec3 color = imageLoad(color_img, coord).rgb;

    color += bloom.rgb * pc.intensity * keep;

    imageStore(color_img, coord, vec4(color, 1.0));
}
