extends Node

const FLOW_STAGE := preload("res://flow/gpu_prototype/gpu_flow_stage.gd")
const STAGE_NATIVE_SIZE := Vector2i(1920, 1080)
const STAGE_ASPECT := 16.0 / 9.0
const STAGE_COUNT := 2

var _background: ColorRect
var _outputs: Array[TextureRect] = []
var _subviewports: Array[SubViewport] = []
var _stages: Array[Node2D] = []
var _paused: bool = false


func _ready() -> void:
	_build_background()
	for stage_index in range(STAGE_COUNT):
		_build_stage(stage_index)
	get_viewport().size_changed.connect(_layout_outputs)
	_layout_outputs()
	if OS.get_cmdline_user_args().has("--gpu-flow-smoke"):
		call_deferred(&"_run_smoke_test")


func _exit_tree() -> void:
	if get_viewport().size_changed.is_connected(_layout_outputs):
		get_viewport().size_changed.disconnect(_layout_outputs)


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	match key_event.keycode:
		KEY_G:
			for stage in _stages:
				stage.call(&"toggle_gate")
		KEY_SPACE:
			_paused = not _paused
			for stage in _stages:
				stage.call(&"set_paused", _paused)
		KEY_BRACKETLEFT:
			for stage in _stages:
				stage.call(&"adjust_gate_half_width", -6.0)
		KEY_BRACKETRIGHT:
			for stage in _stages:
				stage.call(&"adjust_gate_half_width", 6.0)
		_:
			return
	get_viewport().set_input_as_handled()


func _build_background() -> void:
	_background = ColorRect.new()
	_background.name = "LetterboxBackground"
	_background.color = Color("010204")
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)


func _build_stage(stage_index: int) -> void:
	var subviewport := SubViewport.new()
	subviewport.name = "Native1920x1080"
	subviewport.size = STAGE_NATIVE_SIZE
	subviewport.disable_3d = true
	subviewport.transparent_bg = false
	subviewport.msaa_2d = Viewport.MSAA_4X
	subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(subviewport)
	_subviewports.append(subviewport)

	var stage := FLOW_STAGE.new() as Node2D
	stage.name = "GPUFlowStage%d" % (stage_index + 1)
	stage.set(&"stage_index", stage_index)
	subviewport.add_child(stage)
	_stages.append(stage)

	# TextureRect scales the fixed native SubViewport for a compact side-by-side
	# preview. SubViewportContainer would silently resize the simulations to the
	# preview rectangles, putting native-pixel shader geometry offscreen.
	var output := TextureRect.new()
	output.name = "StageOutput%d" % (stage_index + 1)
	output.texture = subviewport.get_texture()
	output.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	output.stretch_mode = TextureRect.STRETCH_SCALE
	output.mouse_filter = Control.MOUSE_FILTER_IGNORE
	output.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(output)
	_outputs.append(output)


func _layout_outputs() -> void:
	var window_size := get_viewport().get_visible_rect().size
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return
	_background.position = Vector2.ZERO
	_background.size = window_size
	var panel_size := Vector2(window_size.x / float(STAGE_COUNT), window_size.y)
	var output_size: Vector2
	if panel_size.x / panel_size.y > STAGE_ASPECT:
		output_size = Vector2(panel_size.y * STAGE_ASPECT, panel_size.y)
	else:
		output_size = Vector2(panel_size.x, panel_size.x / STAGE_ASPECT)
	for stage_index in range(_outputs.size()):
		var panel_origin := Vector2(panel_size.x * float(stage_index), 0.0)
		_outputs[stage_index].position = panel_origin + (panel_size - output_size) * 0.5
		_outputs[stage_index].size = output_size


func _run_smoke_test() -> void:
	# Give resources and particle nodes several frames to initialize. The test
	# checks scene/shader/resource wiring; only a non-headless run can time GPU work.
	for _frame in range(8):
		await get_tree().process_frame
	var errors: PackedStringArray = []
	if _stages.size() != STAGE_COUNT:
		errors.append("expected %d stages, got %d" % [STAGE_COUNT, _stages.size()])
	var total_head_slots := 0
	var total_segment_slots := 0
	for stage in _stages:
		var summary: Dictionary = stage.call(&"runtime_summary")
		if summary.is_empty():
			errors.append("stage did not create GPUParticles2D")
			continue
		total_head_slots += int(summary["amount"])
		total_segment_slots += int(summary["trail_segment_capacity"])
		if int(summary["amount"]) != 300:
			errors.append("particle amount is not 300")
		if not is_equal_approx(float(summary["amount_ratio"]), 0.5):
			errors.append("amount_ratio is not 0.5")
		if int(summary["active_heads_approx"]) != 150:
			errors.append("active head count is not approximately 150")
		if int(summary["fixed_fps"]) != 0:
			errors.append("head simulation is not render-paced")
		if not bool(summary["interpolate"]):
			errors.append("interpolation is disabled")
		if bool(summary["trail_enabled"]):
			errors.append("native head trails are enabled")
		if String(summary["trail_mode"]) != "immutable_gpu_segments":
			errors.append("immutable segment trail mode is not active")
		if int(summary["trail_segment_capacity"]) != 22500:
			errors.append("segment capacity is not 22500")
		if bool(summary["trail_segment_native_trail_enabled"]):
			errors.append("native trails are enabled on segment particles")
		if bool(summary["trail_segment_autonomous_emission"]):
			errors.append("segment sub-emitter pool is emitting autonomously")
		if int(summary["trail_segment_fixed_fps"]) != 0:
			errors.append("segment simulation is not render-paced")
		if bool(summary["trail_segment_interpolate"]):
			errors.append("segment interpolation is enabled")
		if bool(summary["trail_segment_fract_delta"]):
			errors.append("segment fractional delta is enabled")
		if not bool(summary["trail_segment_process_shader_matches"]):
			errors.append("stationary segment process shader is not connected")
		if not bool(summary["trail_draw_shader_matches"]):
			errors.append("immutable segment draw shader is not connected")
		if Vector2(summary["trail_segment_texture_size"]) != Vector2(1.0, 8.0):
			errors.append("segment texture is not the production 1x8 layout")
		if not is_equal_approx(float(summary["trail_segment_lifetime"]), 2.0):
			errors.append("segment lifetime is not 2 seconds")
		if not is_equal_approx(
			float(summary["trail_segment_lifetime_uniform"]), 2.0
		):
			errors.append("segment lifetime shader uniform is not 2 seconds")
		if not bool(summary["heads_hidden"]):
			errors.append("simulation heads are not using the hidden-head material")
			if not bool(summary["trail_recording_enabled_uniform"]):
				errors.append("trail recording did not start after head prewarm")
			if not bool(summary["reservoir_admission_enabled_uniform"]):
				errors.append("reservoir admission did not start after empty prewarm")
		if Vector2(summary["head_texture_size"]) != Vector2.ONE:
			errors.append("head texture is not the production 1x1 layout")
			if int(summary["shader_uniform_count"]) < 10:
				errors.append("particle shader uniforms did not load")
			if int(summary["interaction_count_uniform"]) != 0:
				errors.append("prototype unexpectedly enabled production polygons")
			if not bool(summary["interaction_data_texture_bound"]):
				errors.append("prototype did not bind the empty polygon geometry texture")
			if not bool(summary["interaction_admission_enabled_uniform"]):
				errors.append("prototype polygon prewarm guard did not finish")
	if not _stages.is_empty():
		_stages[0].call(&"set_paused", true)
		var paused_summary: Dictionary = _stages[0].call(&"runtime_summary")
		if (
			not is_zero_approx(float(paused_summary["head_speed_scale"]))
			or not is_zero_approx(
				float(paused_summary["trail_segment_speed_scale"])
			)
		):
			errors.append("pause did not stop both heads and trail segments")
		_stages[0].call(&"set_paused", false)
		var running_summary: Dictionary = _stages[0].call(&"runtime_summary")
		if (
			not is_equal_approx(float(running_summary["head_speed_scale"]), 1.0)
			or not is_equal_approx(
				float(running_summary["trail_segment_speed_scale"]), 1.0
			)
		):
			errors.append("resume did not restart both heads and trail segments")
		_stages[0].call(&"set_gate_open", false)
		var closed_summary: Dictionary = _stages[0].call(&"runtime_summary")
		if bool(closed_summary["gate_open"]) or bool(closed_summary["gate_uniform"]):
			errors.append("gate uniform did not update at runtime")
		_stages[0].call(&"set_gate_open", true)
		_stages[0].call(&"set_gate_half_width", 42.0)
		var width_summary: Dictionary = _stages[0].call(&"runtime_summary")
		if (
			not is_equal_approx(float(width_summary["gate_half_width"]), 42.0)
			or not is_equal_approx(float(width_summary["gate_half_width_uniform"]), 42.0)
		):
			errors.append("gate width uniform did not update at runtime")
		_stages[0].call(&"set_gate_half_width", 15.0)
	if errors.is_empty():
		if OS.get_cmdline_user_args().has("--gpu-flow-capture"):
			var capture: Image = get_viewport().get_texture().get_image()
			var capture_error := capture.save_png("/tmp/gpu_flow_prototype.png")
			if capture_error != OK:
				push_error("GPU_FLOW_SMOKE: preview capture failed (%d)" % capture_error)
				get_tree().quit(1)
				return
			for stage_index in range(_subviewports.size()):
				var stage_capture: Image = _subviewports[stage_index].get_texture().get_image()
				stage_capture.save_png(
					"/tmp/gpu_flow_stage_%d.png" % (stage_index + 1)
				)
			print("GPU_FLOW_CAPTURE: /tmp/gpu_flow_prototype.png")
		print(
			(
				"GPU_FLOW_SMOKE_OK: stages=%d head_slots_per_stage=300 "
				+ "active_heads_per_stage=~150 total_head_slots=%d "
				+ "segment_slots_per_stage=22500 total_segment_slots=%d "
				+ "render_paced=true max_fps=30 interpolation=true native_trails=false "
					+ "immutable_segments=true hidden_heads=true pause_both=true "
					+ "runtime_gate_and_width_uniforms=true empty_polygon_binding=true"
			) % [STAGE_COUNT, total_head_slots, total_segment_slots]
		)
		get_tree().quit(0)
		return
	for error in errors:
		push_error("GPU_FLOW_SMOKE: %s" % error)
	get_tree().quit(1)
