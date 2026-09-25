// Foliage cutout, back-face culled -- meshes modelled double-layered (fern_02: every frond
// duplicated back-to-back; double-sided drawing makes both layers self-shadow -> black fronds).
// Body: foliage_cutout.gdshaderinc
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/foliage/foliage_cutout.gdshaderinc"
