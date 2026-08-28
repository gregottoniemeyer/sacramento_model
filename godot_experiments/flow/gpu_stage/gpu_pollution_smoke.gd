extends Node

## Standalone CPU-visible API and wiring smoke for GPUPollution2D. Particle
## state intentionally remains GPU-only; shader contracts and resident
## allocations are checked without readback.

const POLLUTION_SCRIPT := preload("res://flow/gpu_stage/gpu_pollution_2d.gd")
const REUSED_LEAF_DRAW_SHADER := preload("res://flow/gpu_stage/gpu_leaf_draw.gdshader")

var _signal_call_count := 0
var _signal_requested_count := -1
var _signal_scheduled_count := -1
var _signal_release_serial := -1
var _signal_source_ids: Array[String] = []


func _ready() -> void:
	var pollution: GPUPollution2D = POLLUTION_SCRIPT.new()
	add_child(pollution)
	pollution.pollution_released.connect(_on_pollution_released)
	pollution.set_water_texture(_make_test_water_texture())
	var configured := pollution.configure({
		"stage_size": Vector2(1920.0, 1080.0),
		"simulation_fps": 30,
		"release_stagger_interval_seconds": 0.12,
		"free_speed_pixels": 120.0,
		"flow_speed_pixels": 300.0,
		"speed_variation": 0.20,
		"velocity_response": 8.0,
		"free_water_search_radius_pixels": 120.0,
		"free_water_steering_strength": 0.35,
		"water_alpha_threshold": 0.001,
		"contact_radius_pixels": 12.0,
		"follow_probe_min_pixels": 8.0,
		"follow_probe_max_pixels": 56.0,
		"follow_turn_degrees": 35.0,
		"follow_resample_interval_seconds": 0.12,
		"center_recheck_interval_seconds": 0.50,
		"center_hold_seconds": 8.0,
		"center_fade_seconds": 2.0,
		"occupancy_flip_y": false,
		"disk_diameter_pixels": 10.0,
		"radius_variation": 0.40,
		"pollution_color": Color(0.42, 0.42, 0.42, 0.2),
		"heat_pollution_color": Color(1.0, 0.0, 0.0, 0.2),
		"z_index": 12,
	})
	_assert_or_quit(configured, "known pollution configuration keys were rejected")
	if get_tree().root == null:
		return

	var sources: Array[Dictionary] = [
		{
			"source_id": "gold_mine",
			"position_pixels": Vector2(300.0, 500.0),
			"inward_direction_pixels": Vector2(0.0, 2.0),
			"pollution_class": "material",
			"count": 2,
		},
		{
			"source_id": "data_center_north",
			"position_pixels": Vector2(700.0, 510.0),
			"inward_direction_pixels": Vector2(0.0, -4.0),
			"pollution_class": "heat",
			"count": 3,
		},
	]
	var scheduled := pollution.release_from_sources(sources)
	_assert_or_quit(scheduled == 5, "two valid sources did not schedule five disks")
	_assert_or_quit(
		_signal_call_count == 1
		and _signal_requested_count == 5
		and _signal_scheduled_count == 5
		and _signal_release_serial == 1
		and _signal_source_ids == ["gold_mine", "data_center_north"],
		"pollution_released signal did not preserve exact counts and source IDs"
	)
	if get_tree().root == null:
		return

	# Give the renderer time to parse both the pollution process shader and the
	# reused leaf antialiased-disk draw shader.
	for frame_index in range(4):
		await get_tree().process_frame

	var summary := pollution.runtime_summary()
	_assert_or_quit(
		int(summary.get("capacity", 0)) == 96
		and int(summary.get("control_texture_rows", 0)) == 2
		and int(summary.get("release_serial", 0)) == 1
		and int(summary.get("total_scheduled", 0)) == 5
		and int(summary.get("last_scheduled_count", 0)) == 5
		and int(summary.get("next_write_slot", -1)) == 5,
		"fixed-pool release counters are incorrect"
	)
	_assert_or_quit(
		Array(summary.get("last_source_ids", []))
			== ["gold_mine", "data_center_north"]
		and int(summary.get("last_source_release_counts", {}).get("gold_mine", 0)) == 2
		and int(summary.get("last_source_release_counts", {}).get(
			"data_center_north", 0
		)) == 3
		and int(summary.get("total_scheduled_by_source", {}).get("gold_mine", 0)) == 2
		and int(summary.get("resident_command_slots", 0)) == 5,
		"source IDs or per-source counters were not retained"
	)
	_assert_or_quit(
		bool(summary.get("water_texture_assigned", false))
		and String(summary.get("source_position_contract", ""))
			== "EXACT_SOURCE_PIXELS_WITH_INWARD_DIRECTION"
		and String(summary.get("command_contract", ""))
			== "SOURCE_ID_POSITION_INWARD_DIRECTION_CLASS_AND_OPTIONAL_COUNT"
		and String(summary.get("initial_state", "")) == "FREE_SEEKING"
		and String(summary.get("free_search_policy", ""))
			== "NEARBY_2D_INWARD_WATER_STEERING_TO_CENTERLINE"
		and String(summary.get("free_search_stop", ""))
			== "CENTER_RECHECK_THEN_FADE"
		and int(summary.get("contact_axis_samples", 0)) == 9
		and int(summary.get("free_search_axis_samples", 0)) == 17
		and String(summary.get("free_search_backward_samples", "")) == "REJECTED"
		and is_equal_approx(
			float(summary.get("free_search_centerline_y_pixels", 0.0)),
			540.0
		)
		and String(summary.get("water_attachment", "")) == "IRREVERSIBLE"
		and String(summary.get("water_gap_behavior", ""))
			== "KEEP_CACHED_HEADING_AND_FULL_OPACITY"
		and is_equal_approx(
			float(summary.get("center_recheck_interval_seconds", 0.0)),
			0.50
		)
		and is_equal_approx(float(summary.get("center_hold_seconds", 0.0)), 8.0)
		and is_equal_approx(float(summary.get("center_fade_seconds", 0.0)), 2.0)
		and is_equal_approx(float(summary.get("center_max_visible_seconds", 0.0)), 10.0)
		and String(summary.get("center_recheck_policy", ""))
			== "THROTTLED_CONTACT_ONLY_DETERMINISTIC_PHASE"
		and String(summary.get("fade_behavior", ""))
			== "CENTER_MISS_SMOOTH_AFTER_HOLD"
		and String(summary.get("retirement", ""))
			== "LATCHED_RIGHT_EDGE_OR_CENTER_TIMEOUT_OR_EXPLICIT_RESET"
		and String(summary.get("latched_retirement", ""))
			== "RIGHT_EDGE_AFTER_COMPLETE_DISK"
		and String(summary.get("miss_retirement", ""))
			== "CENTER_RECHECK_HOLD_THEN_FADE_TO_INACTIVE"
		and bool(summary.get("free_water_search_gpu", false)),
		"bounded free-seek, late-water reacquisition, or fade contract is missing"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("source_alpha", 0.0)), 1.0)
		and String(summary.get("material_pollution_color", "")) == "#6B6B6BFF"
		and String(summary.get("heat_pollution_color", "")) == "#FF0000FF"
		and String(summary.get("pollution_color_routing", ""))
			== "MATERIAL_GREY_HEAT_BRIGHT_RED"
		and Array(summary.get("pollution_classes", [])) == ["material", "heat"]
		and is_equal_approx(float(summary.get("disk_diameter_pixels", 0.0)), 10.0)
		and is_equal_approx(float(summary.get("disk_radius_pixels", 0.0)), 5.0)
		and is_equal_approx(float(summary.get("maximum_disk_radius_pixels", 0.0)), 7.0)
		and String(summary.get("spatial_alpha_profile", ""))
			== "RADIAL_ANTIALIASED_DISK_EDGE"
		and String(summary.get("draw_shader_reused", ""))
			== "res://flow/gpu_stage/gpu_leaf_draw.gdshader",
		"opaque material/heat disk appearance contract is incorrect"
	)

	var control_image := pollution.get("_control_image") as Image
	var control_texture := pollution.get("_control_texture") as Texture2D
	var slot_source_ids: Array[String] = pollution.get("_slot_source_ids")
	_assert_or_quit(
		control_image != null
		and control_texture != null
		and control_image.get_size() == Vector2i(96, 2)
		and control_texture.get_size() == Vector2(96.0, 2.0),
		"pollution command texture is not the fixed 96x2 allocation"
	)
	_assert_or_quit(
		slot_source_ids.slice(0, 5)
			== [
				"gold_mine",
				"data_center_north",
				"gold_mine",
				"data_center_north",
				"data_center_north",
			]
		and Vector2(
			control_image.get_pixel(0, 0).g,
			control_image.get_pixel(0, 0).b
		) == Vector2(300.0, 500.0)
		and Vector2(
			control_image.get_pixel(1, 0).g,
			control_image.get_pixel(1, 0).b
		) == Vector2(700.0, 510.0)
		and is_equal_approx(control_image.get_pixel(0, 0).a, 1.0)
		and is_equal_approx(control_image.get_pixel(1, 0).a, 2.0)
		and Vector2(
			control_image.get_pixel(0, 1).b,
			control_image.get_pixel(0, 1).a
		) == Vector2(0.0, 1.0)
		and Vector2(
			control_image.get_pixel(1, 1).b,
			control_image.get_pixel(1, 1).a
		) == Vector2(0.0, -1.0)
		and _release_delays_are_strictly_increasing(control_image, 5),
		"source commands lost order, positions, class tags, inward vectors, or staggering"
	)

	var heads := pollution.get_node_or_null("GPUPollutionHeads") as GPUParticles2D
	_assert_or_quit(
		heads != null
		and pollution.get_child_count() == 1
		and heads.amount == 96
		and not heads.trail_enabled,
		"pollution does not use one bounded resident disk-head pool"
	)
	if get_tree().root == null:
		return
	var process_material := heads.process_material as ShaderMaterial
	var draw_material := heads.material as ShaderMaterial
	_assert_or_quit(
		process_material != null
		and draw_material != null
		and draw_material.shader == REUSED_LEAF_DRAW_SHADER,
		"pollution did not reuse the leaf antialiased-disk draw shader"
	)
	var process_code := process_material.shader.code
	_assert_or_quit(
		process_code.contains("STATE_FREE")
		and process_code.contains("STATE_WATER_LATCHED")
		and process_code.contains("STATE_CENTER_STOPPED")
		and process_code.contains("TRANSFORM[3].xy = control.gb")
		and process_code.contains("safe_direction(command.ba)")
		and process_code.contains("touches_water")
		and process_code.contains("CONTACT_AXIS_SAMPLES = 9")
		and process_code.contains("find_nearby_water_direction")
		and process_code.contains("FREE_SEARCH_AXIS_SAMPLES = 17")
		and process_code.contains("inward_alignment < 0.0")
		and process_code.contains("TRANSFORM[3].y = stage_size.y * 0.5")
		and process_code.contains("center_recheck_interval_seconds")
		and process_code.contains("CUSTOM.z >= CUSTOM.w")
		and process_code.contains("touches_water(TRANSFORM[3].xy)")
		and process_code.contains("CUSTOM.y = STATE_WATER_LATCHED")
		and process_code.contains("smoothstep(0.0, 1.0, fade_progress)")
		and process_code.contains("hold_seconds + fade_seconds")
		and process_code.contains("CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, 0.0)")
		and process_code.contains("bool start_latched = control.a >= 2.5")
		and process_code.contains("abs(control.a - 4.0) < 0.25")
		and process_code.contains("heat_pollution_color.rgb")
		and process_code.contains("COLOR = vec4(resolved_color, 1.0)")
		and process_code.contains("find_follow_direction")
		and process_code.contains("next_point.x > stage_size.x + disk_radius_pixels")
		and not process_code.contains("STATE_STOPPED_FADING")
		and draw_material.shader.code.contains("disk_alpha"),
		"process shader lacks bounded seeking, reacquisition, fading, or following"
	)
	_assert_or_quit(
		is_equal_approx(
			float(process_material.get_shader_parameter(&"free_speed_pixels")),
			120.0
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(
				&"free_water_search_radius_pixels"
			)),
			120.0
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(
				&"free_water_steering_strength"
			)),
			0.35
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(&"flow_speed_pixels")),
			300.0
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(&"disk_diameter_pixels")),
			10.0
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(
				&"center_recheck_interval_seconds"
			)),
			0.50
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(&"center_hold_seconds")),
			8.0
		)
		and is_equal_approx(
			float(process_material.get_shader_parameter(&"center_fade_seconds")),
			2.0
		)
		and (process_material.get_shader_parameter(&"pollution_color") as Color).a == 1.0
		and (process_material.get_shader_parameter(
			&"heat_pollution_color"
		) as Color).is_equal_approx(Color(1.0, 0.0, 0.0, 1.0))
		and heads.z_index == 12,
		"configured motion, two-color palette, opacity, or z-index did not reach the GPU"
	)

	# Invalid source commands do not advance the GPU generation or emit a signal.
	var invalid_sources: Array[Dictionary] = [
		{"source_id": "", "position_pixels": Vector2(100.0, 100.0)},
		{
			"source_id": "missing_direction",
			"position_pixels": Vector2(100.0, 100.0),
			"pollution_class": "material",
		},
		{
			"source_id": "missing_class",
			"position_pixels": Vector2(100.0, 100.0),
			"inward_direction_pixels": Vector2.DOWN,
		},
		{
			"source_id": "outside",
			"position_pixels": Vector2(-1.0, 100.0),
			"inward_direction_pixels": Vector2.DOWN,
		},
		{
			"source_id": "zero_direction",
			"position_pixels": Vector2(100.0, 100.0),
			"inward_direction_pixels": Vector2.ZERO,
		},
		{
			"source_id": "horizontal_direction",
			"position_pixels": Vector2(100.0, 100.0),
			"inward_direction_pixels": Vector2.RIGHT,
		},
		{
			"source_id": "unknown_class",
			"position_pixels": Vector2(100.0, 100.0),
			"inward_direction_pixels": Vector2.DOWN,
			"pollution_class": "unknown",
		},
	]
	_assert_or_quit(
		pollution.release_from_sources(invalid_sources) == 0
		and _signal_call_count == 1
		and int(pollution.runtime_summary().get("release_serial", 0)) == 1,
		"invalid sources changed a resident generation or emitted a release signal"
	)

	# A confluence command may start already attached, which is the only safe
	# horizontal-entry path because the legacy miss policy seeks a Y centerline.
	var confluence_source: Array[Dictionary] = [{
		"source_id": "confluence_mount_shasta",
		"position_pixels": Vector2(12.0, 240.0),
		"inward_direction_pixels": Vector2.RIGHT,
		"pollution_class": "material",
		"start_latched": true,
	}]
	_assert_or_quit(
		pollution.release_from_sources(confluence_source) == 1
		and is_equal_approx(control_image.get_pixel(5, 0).a, 3.0)
		and Vector2(
			control_image.get_pixel(5, 1).b,
			control_image.get_pixel(5, 1).a
		) == Vector2.RIGHT,
		"latched left-edge confluence pollution command was not encoded"
	)

	# Reset must clear every visible command and reproduce deterministic control
	# data for the same first release.
	var first_delays := _release_delays(control_image, 5)
	pollution.set_paused(true)
	_assert_or_quit(pollution.is_paused(), "pause state did not latch")
	pollution.reset_pollution()
	summary = pollution.runtime_summary()
	_assert_or_quit(
		int(summary.get("release_serial", -1)) == 0
		and int(summary.get("total_scheduled", -1)) == 0
		and int(summary.get("resident_command_slots", -1)) == 0
		and Array(summary.get("last_source_ids", ["unexpected"])).is_empty(),
		"explicit pollution reset did not clear commands and counters"
	)
	_assert_or_quit(
		pollution.release_from_sources(sources) == 5
		and _float_arrays_equal(_release_delays(control_image, 5), first_delays),
		"reset did not reproduce deterministic source staggering"
	)

	# More commands than free slots overwrite only the fixed circular pool. No
	# node, texture, material, or generation array is allowed to grow.
	var allocation_before := _allocation_snapshot(pollution)
	var full_source: Array[Dictionary] = [{
		"source_id": "data_center_east",
		"position_pixels": Vector2(900.0, 520.0),
		"inward_direction_pixels": Vector2.UP,
		"pollution_class": "heat",
		"count": 96,
	}]
	_assert_or_quit(
		pollution.release_from_sources(full_source) == 96,
		"capacity-sized release did not fill the fixed pool"
	)
	var wrap_sources: Array[Dictionary] = [
		{
			"source_id": "gold_mine",
			"position_pixels": Vector2(300.0, 500.0),
			"inward_direction_pixels": Vector2.DOWN,
			"pollution_class": "material",
		},
		{
			"source_id": "data_center_north",
			"position_pixels": Vector2(700.0, 510.0),
			"inward_direction_pixels": Vector2.UP,
			"pollution_class": "heat",
		},
	]
	_assert_or_quit(
		pollution.release_from_sources(wrap_sources) == 2,
		"two-command wrap release was rejected"
	)
	summary = pollution.runtime_summary()
	var allocation_difference := _first_snapshot_difference(
		allocation_before,
		_allocation_snapshot(pollution)
	)
	_assert_or_quit(
		int(summary.get("resident_command_slots", 0)) == 96
		and int(summary.get("next_write_slot", -1)) == 7
		and int(summary.get("overwritten_command_slots", 0)) == 7
		and allocation_difference.is_empty(),
		"circular reuse changed a resident allocation: %s" % allocation_difference
	)
	_assert_or_quit(
		not pollution.configure({"unsupported_key": true}),
		"unknown configuration key was silently accepted"
	)

	print("GPU_POLLUTION_SMOKE_PASS ", JSON.stringify(summary))
	get_tree().quit(0)


func _on_pollution_released(
	requested_count: int,
	scheduled_count: int,
	release_serial: int,
	source_ids: Array[String]
) -> void:
	_signal_call_count += 1
	_signal_requested_count = requested_count
	_signal_scheduled_count = scheduled_count
	_signal_release_serial = release_serial
	_signal_source_ids = source_ids.duplicate()


func _make_test_water_texture() -> ImageTexture:
	var image := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for x in range(192):
		var y := 52 + roundi(sin(float(x) * 0.05) * 5.0)
		image.fill_rect(Rect2i(x, y - 2, 1, 5), Color.WHITE)
	return ImageTexture.create_from_image(image)


func _release_delays(control_image: Image, count: int) -> PackedFloat32Array:
	var delays := PackedFloat32Array()
	for index in range(count):
		delays.append(control_image.get_pixel(index, 1).r)
	return delays


func _release_delays_are_strictly_increasing(
	control_image: Image,
	count: int
) -> bool:
	var delays := _release_delays(control_image, count)
	if delays.is_empty() or not is_zero_approx(delays[0]):
		return false
	for index in range(1, delays.size()):
		if delays[index] <= delays[index - 1]:
			return false
	return true


func _float_arrays_equal(
	left: PackedFloat32Array,
	right: PackedFloat32Array
) -> bool:
	if left.size() != right.size():
		return false
	for index in range(left.size()):
		if not is_equal_approx(left[index], right[index]):
			return false
	return true


func _allocation_snapshot(pollution: GPUPollution2D) -> Dictionary:
	var heads := pollution.get_node("GPUPollutionHeads") as GPUParticles2D
	var control_image := pollution.get("_control_image") as Image
	var control_texture := pollution.get("_control_texture") as Texture2D
	var empty_water_texture := pollution.get("_empty_water_texture") as Texture2D
	var supplied_water_texture := pollution.get("_supplied_water_texture") as Texture2D
	var generations: PackedInt32Array = pollution.get("_slot_generations")
	var enabled: PackedByteArray = pollution.get("_slot_enabled")
	var source_ids: Array[String] = pollution.get("_slot_source_ids")
	return {
		"child_count": pollution.get_child_count(),
		"head_node_id": heads.get_instance_id(),
		"head_amount": heads.amount,
		"control_image_id": control_image.get_instance_id(),
		"control_image_size": control_image.get_size(),
		"control_texture_id": control_texture.get_instance_id(),
		"control_texture_rid": control_texture.get_rid(),
		"empty_water_texture_id": empty_water_texture.get_instance_id(),
		"supplied_water_texture_id": supplied_water_texture.get_instance_id(),
		"process_material_id": heads.process_material.get_instance_id(),
		"draw_material_id": heads.material.get_instance_id(),
		"head_texture_id": heads.texture.get_instance_id(),
		"generation_count": generations.size(),
		"enabled_count": enabled.size(),
		"source_id_slot_count": source_ids.size(),
	}


func _first_snapshot_difference(before: Dictionary, after: Dictionary) -> String:
	for key: Variant in before:
		if not after.has(key) or before[key] != after[key]:
			return String(key)
	return "" if before.size() == after.size() else "field_count"


func _assert_or_quit(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("GPU_POLLUTION_SMOKE_FAIL: %s" % message)
	get_tree().quit(1)
