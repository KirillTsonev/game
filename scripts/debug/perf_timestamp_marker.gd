## DEBUG (dev only): a compositor "effect" that draws nothing and only drops a named GPU timestamp.
## The benchmark (scripts/debug/perf_bench.gd, _measure_post_passes) puts one before the first
## real effect and one after each, so the GPU time between two markers is that effect's cost.
extends CompositorEffect

var label := ""

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT

func _render_callback(_effect_callback_type: int, _render_data: RenderData) -> void:
	RenderingServer.get_rendering_device().capture_timestamp(label)
