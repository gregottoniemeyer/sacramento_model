extends Node

## Standalone API/instantiation smoke for the isolated GPU leaf subsystem.
## It validates only CPU-visible configuration and wiring; particle state is
## deliberately never read back from the GPU.

const LEAF_SCRIPT := preload("res://flow/gpu_stage/gpu_leaf_2d.gd")
const EXPECTED_PALETTE: Array[String] = [
	"#8C3F0A",
	"#A95412",
	"#C47A12",
	"#C29A18",
	"#8A8F2A",
	"#4F772D",
	"#365F32",
]
const EXPECTED_DEFAULT_SPAN_SECONDS := 5.926469187061627
const EXPECTED_DEFAULT_TOP_LANE_ORDER := [
	12, 10, 4, 6, 13, 1, 3, 14, 7, 5, 11, 2, 9, 0, 8,
]
const EXPECTED_DEFAULT_BOTTOM_LANE_ORDER := [
	7, 0, 11, 2, 9, 12, 5, 8, 10, 6, 1, 4, 3, 13, 14,
]
const STRESS_RELEASE_CALLS := 500
const STRESS_RELEASE_COUNT_PER_SIDE := 7
const RENDER_FENCED_RELEASE_CALLS := 60


func _ready() -> void:
	var leaves: GPULeaf2D = LEAF_SCRIPT.new()
	add_child(leaves)
	leaves.set_water_texture(_make_test_water_texture())

	var configured := leaves.configure({
		"stage_size": Vector2(1920.0, 1080.0),
		"simulation_fps": 30,
		"release_stagger_interval_seconds": 0.20,
		"free_speed_pixels": 120.0,
		"flow_speed_pixels": 300.0,
		"speed_variation": 0.0,
		"velocity_response": 8.0,
		"free_sway_amplitude_min_pixels": 2.0,
		"free_sway_amplitude_max_pixels": 6.0,
		"free_sway_period_min_seconds": 1.2,
		"free_sway_period_max_seconds": 2.8,
		"free_water_search_radius_pixels": 120.0,
		"free_water_steering_strength": 0.35,
		"free_search_max_distance_pixels": 256.0,
		"stopped_fade_seconds": 0.50,
		"water_alpha_threshold": 0.001,
		"contact_radius_pixels": 12.0,
		"follow_probe_min_pixels": 8.0,
		"follow_probe_max_pixels": 56.0,
		"follow_turn_degrees": 35.0,
		"follow_resample_interval_seconds": 0.12,
		"streak_width_pixels": 10.0,
		"line_width_variation": 1.0,
		"occupancy_flip_y": false,
	})
	_assert_or_quit(configured, "known configuration keys were rejected")
	if get_tree().root == null:
		return

	var released := leaves.release_leaves()
	_assert_or_quit(released == 30, "default release did not schedule 15 per side")
	if get_tree().root == null:
		return

	# Give the renderer time to compile the head simulation and disk draw shaders.
	for frame_index in range(4):
		await get_tree().process_frame

	var summary: Dictionary = leaves.runtime_summary()
	_assert_or_quit(int(summary.get("capacity", 0)) == 300, "capacity is not 300")
	_assert_or_quit(
		int(summary.get("release_serial", 0)) == 1,
		"release serial did not advance"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled_top", 0)) == 15,
		"top cohort did not schedule exactly 15"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled_bottom", 0)) == 15,
		"bottom cohort did not schedule exactly 15"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled", 0)) == 30,
		"default total is not 30"
	)
	_assert_or_quit(
		int(summary.get("last_scheduled_per_side", 0)) == 15,
		"last per-side count is not 15"
	)
	var first_default_span_seconds := float(
		summary.get("last_release_stagger_span_seconds", 0.0)
	)
	var control_image := leaves.get("_control_image") as Image
	_assert_or_quit(control_image != null, "CPU release command image is unavailable")
	if get_tree().root == null:
		return
	var first_top_lane_order := _release_lane_ranks(control_image, 0, 15, 0, 1)
	var first_bottom_lane_order := _release_lane_ranks(control_image, 0, 15, 1, 1)
	var first_release_delays := _release_delays(control_image, 0, 30)
	_assert_or_quit(
		int(summary.get("control_texture_rows", 0)) == 2
		and is_equal_approx(
			float(summary.get("release_stagger_interval_seconds", 0.0)),
			0.20
		)
		and is_equal_approx(float(summary.get("release_gap_multiplier_min", 0.0)), 0.55)
		and is_equal_approx(float(summary.get("release_gap_multiplier_max", 0.0)), 1.45)
		and first_default_span_seconds >= 29.0 * 0.110
		and first_default_span_seconds <= 29.0 * 0.290
		and absf(first_default_span_seconds - EXPECTED_DEFAULT_SPAN_SECONDS) < 0.0001
		and float(summary.get("last_min_release_gap_seconds", 0.0)) >= 0.110
		and float(summary.get("last_max_release_gap_seconds", 0.0)) <= 0.290
		and float(summary.get("last_min_release_gap_seconds", 0.0))
			< float(summary.get("last_max_release_gap_seconds", 0.0))
		and String(summary.get("release_schedule", ""))
			== "ALTERNATING_TOP_BOTTOM_DETERMINISTIC_IRREGULAR_X_SHUFFLED"
		and String(summary.get("release_x_order", ""))
			== "INDEPENDENT_DETERMINISTIC_SHUFFLE_PER_BANK"
		and String(summary.get("release_time_x_correlation", "")) == "DECOUPLED",
		"default 15+15 release is not doubled, shuffled, and irregularly staggered"
	)
	_assert_or_quit(
		Array(first_top_lane_order) == EXPECTED_DEFAULT_TOP_LANE_ORDER
		and Array(first_bottom_lane_order) == EXPECTED_DEFAULT_BOTTOM_LANE_ORDER
		and first_top_lane_order != first_bottom_lane_order
		and _is_complete_lane_permutation(first_top_lane_order, 15)
		and _is_complete_lane_permutation(first_bottom_lane_order, 15)
		and _has_left_and_right_steps(first_top_lane_order)
		and _has_left_and_right_steps(first_bottom_lane_order)
		and _release_sides_alternate(control_image, 0, 30)
		and _delays_are_strictly_increasing(first_release_delays)
		and _delay_gaps_in_range(first_release_delays, 0.110, 0.290)
		and absf(first_release_delays[-1] - first_default_span_seconds) < 0.0001,
		"control texture still correlates shuffled X lanes with launch time"
	)
	_assert_or_quit(
		bool(summary.get("water_texture_assigned", false)),
		"water texture was not retained"
	)
	_assert_or_quit(
		not bool(summary.get("immutable_segments", true))
		and int(summary.get("segment_capacity", -1)) == 0
		and bool(summary.get("head_only_rendering", false))
		and not bool(summary.get("segment_emission", true)),
		"leaf renderer is not a head-only disk with no segment pool"
	)
	_assert_or_quit(
		not bool(summary.get("cpu_readback", true))
		and bool(summary.get("free_water_search_gpu", false))
		and bool(summary.get("stopped_fade_gpu", false))
		and bool(summary.get("spatial_alpha_gpu", false)),
		"smoke detected a CPU-readback path"
	)
	_assert_or_quit(
		String(summary.get("state_transition", ""))
			== "FREE_TO_WATER_LATCHED_IRREVERSIBLE",
		"water attachment is not documented as irreversible"
	)
	_assert_or_quit(
		String(summary.get("release_edges", "")) == "TOP_BOTTOM"
		and String(summary.get("top_free_direction", "")) == "+Y"
		and String(summary.get("bottom_free_direction", "")) == "-Y",
		"free leaves are not scheduled top-down and bottom-up"
	)
	_assert_or_quit(
		String(summary.get("free_sway_axis", "")) == "X",
		"free-flight sway is not perpendicular to vertical travel"
	)
	_assert_or_quit(
		String(summary.get("latched_initial_direction", "")) == "+X",
		"water contact does not adopt the downstream direction"
	)
	_assert_or_quit(
		String(summary.get("latched_follow_reference_axis", ""))
			== "CACHED_WATER_HEADING"
		and String(summary.get("latched_heading_constraint", ""))
			== "LOCAL_CONTINUITY_WITH_DOWNSTREAM_BIAS"
		and String(summary.get("latched_follow_resampling", ""))
			== "PERIODIC_DETERMINISTIC_PHASE"
		and String(summary.get("latched_follow_support", ""))
			== "MULTI_RADIUS_CENTER_AND_FLANK_WATER_SUPPORT"
		and String(summary.get("latched_retirement", ""))
			== "RIGHT_EDGE_AFTER_DISK",
		"attached leaves are not using stable periodic water following"
	)
	_assert_or_quit(
		String(summary.get("miss_behavior", ""))
			== "STOP_AT_INWARD_Y_DISTANCE_THEN_FADE"
		and String(summary.get("miss_state", "")) == "STOPPED_FADING"
		and String(summary.get("miss_retirement", ""))
			== "FREEZE_FADE_THEN_INACTIVE"
		and String(summary.get("free_search_policy", ""))
			== "NEARBY_2D_WATER_STEERING_UNTIL_DISTANCE_BOUND"
		and String(summary.get("free_search_distance_measure", ""))
			== "INWARD_Y_FROM_ORIGIN_BANK"
		and String(summary.get("free_search_backward_samples", "")) == "REJECTED"
		and int(summary.get("free_search_axis_samples", 0)) == 17
		and is_equal_approx(
			float(summary.get("free_water_search_radius_pixels", 0.0)),
			120.0
		)
		and is_equal_approx(
			float(summary.get("free_water_steering_strength", 0.0)),
			0.35
		)
		and is_equal_approx(
			float(summary.get("free_search_max_distance_pixels", 0.0)),
			256.0
		)
		and is_equal_approx(float(summary.get("stopped_fade_seconds", 0.0)), 0.50),
		"free leaves do not use bounded 2D water search and stopped fading"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("streak_width_pixels", 0.0)), 10.0),
		"leaf disk diameter is not 10px"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("line_width_variation", 0.0)), 1.0)
		and is_equal_approx(float(summary.get("leaf_width_scale_min", 0.0)), 1.0)
		and is_equal_approx(float(summary.get("leaf_width_scale_max", 0.0)), 2.0)
		and is_equal_approx(float(summary.get("disk_diameter_pixels", 0.0)), 10.0)
		and is_equal_approx(float(summary.get("disk_radius_pixels", 0.0)), 5.0)
		and is_equal_approx(float(summary.get("minimum_leaf_radius_pixels", 0.0)), 5.0)
		and is_equal_approx(float(summary.get("maximum_leaf_radius_pixels", 0.0)), 10.0)
		and is_equal_approx(float(summary.get("minimum_leaf_diameter_pixels", 0.0)), 10.0)
		and is_equal_approx(float(summary.get("maximum_leaf_diameter_pixels", 0.0)), 20.0)
		and is_equal_approx(float(summary.get("minimum_leaf_width_pixels", 0.0)), 10.0)
		and is_equal_approx(float(summary.get("maximum_leaf_width_pixels", 0.0)), 20.0)
		and bool(summary.get("per_leaf_size_deterministic", false))
		and String(summary.get("size_seed", "")) == "INDEX_AND_RELEASE_GENERATION",
		"deterministic per-leaf disk-radius variation is incorrect"
	)
	_assert_or_quit(
		String(summary.get("spatial_alpha_profile", ""))
			== "RADIAL_ANTIALIASED_DISK_EDGE"
		and String(summary.get("render_primitive", "")) == "ANTIALIASED_DISK_HEAD"
		and String(summary.get("trail_primitive", "")) == "NONE"
		and not bool(summary.get("per_segment_trail_lifetime", true)),
		"leaf renderer is not the antialiased disk-head contract"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("flow_speed_pixels", 0.0)), 300.0)
		and is_equal_approx(float(summary.get("velocity_response", 0.0)), 8.0)
		and is_equal_approx(float(summary.get("follow_probe_max_pixels", 0.0)), 56.0)
		and is_equal_approx(float(summary.get("follow_turn_degrees", 0.0)), 35.0)
		and is_equal_approx(
			float(summary.get("follow_resample_interval_seconds", 0.0)),
			0.12
		),
		"periodic water-follow defaults are incorrect"
	)
	_assert_or_quit(
		_array_strings_equal(summary.get("palette", []), EXPECTED_PALETTE),
		"leaf palette does not match the seven requested colors"
	)
	_assert_or_quit(
		is_equal_approx(
			float(summary.get("free_sway_amplitude_min_pixels", 0.0)),
			2.0
		)
		and is_equal_approx(
			float(summary.get("free_sway_amplitude_max_pixels", 0.0)),
			6.0
		),
		"free-flight sway is not bounded to 2..6px"
	)
	var head_particles := (
		leaves.get_node_or_null("GPULeafHeads") as GPUParticles2D
	)
	var segment_particles := (
		leaves.get_node_or_null("GPULeafTrailSegments") as GPUParticles2D
	)
	_assert_or_quit(head_particles != null, "resident GPU leaf heads are missing")
	_assert_or_quit(
		head_particles != null
		and segment_particles == null
		and leaves.get_child_count() == 1
		and head_particles.sub_emitter.is_empty(),
		"disk leaves unexpectedly retain a trail segment node or sub-emitter"
	)
	if get_tree().root == null:
		return
	var head_material := head_particles.process_material as ShaderMaterial
	var head_draw_material := head_particles.material as ShaderMaterial
	_assert_or_quit(
		head_material != null
		and head_draw_material != null,
		"leaf GPU materials are missing"
	)
	if get_tree().root == null:
		return
	_assert_or_quit(
		is_equal_approx(
			float(head_material.get_shader_parameter(&"flow_speed_pixels")),
			300.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"velocity_response")),
			8.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"follow_probe_max_pixels")),
			56.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"follow_turn_radians")),
			deg_to_rad(35.0)
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"follow_resample_interval_seconds"
			)),
			0.12
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"free_water_search_radius_pixels"
			)),
			120.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"free_water_steering_strength"
			)),
			0.35
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"free_search_max_distance_pixels"
			)),
			256.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"stopped_fade_seconds")),
			0.50
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"streak_width_pixels")),
			10.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"line_width_variation")),
			1.0
		),
		"head material did not receive search, stopped-fade, follow, or disk uniforms"
	)
	var control_texture := (
		head_material.get_shader_parameter(&"leaf_control_texture") as Texture2D
	)
	_assert_or_quit(
		control_texture != null
		and control_texture.get_size() == Vector2(300.0, 2.0),
		"release command texture is not the expected fixed 300x2 allocation"
	)
	var head_shader_code := head_material.shader.code
	var draw_shader_code := head_draw_material.shader.code
	_assert_or_quit(
		head_shader_code.contains("STATE_SCHEDULED")
		and head_shader_code.contains("vec2(control_x, 0.75)")
		and head_shader_code.contains("rotate_direction(prior, angle)")
		and head_shader_code.contains("normalized_support * 3.0")
		and head_shader_code.contains("inward_alignment < 0.0")
		and head_shader_code.contains("follow_resample_interval_seconds")
		and head_shader_code.contains("CUSTOM.w = atan")
		and head_shader_code.contains("STATE_STOPPED_FADING")
		and head_shader_code.contains("find_nearby_water_direction")
		and head_shader_code.contains("free_search_max_distance_pixels")
		and head_shader_code.contains("uniform float line_width_variation = 1.0")
		and head_shader_code.contains("leaf_diameter_pixels")
		and head_shader_code.contains("TRANSFORM[0].xy")
		and head_shader_code.contains(
			"next_point.x > stage_size.x + leaf_radius_pixels"
		)
		and not head_shader_code.contains("emit_subparticle")
		and draw_shader_code.contains("length(UV - vec2(0.5))")
		and draw_shader_code.contains("fwidth(radial_distance)")
		and draw_shader_code.contains("disk_alpha"),
		"shader contracts for search/stop, following, disk size, or radial SDF are missing"
	)
	_assert_or_quit(
		head_particles.texture != null
		and head_particles.texture.get_size() == Vector2.ONE,
		"leaf disk source texture is not the expected 1x1 allocation"
	)

	var second_release_start_slot := int(summary.get("next_write_slot", 0))
	_assert_or_quit(
		leaves.release_leaves() == 30,
		"second default release was rejected"
	)
	var second_top_lane_order := _release_lane_ranks(
		control_image,
		second_release_start_slot,
		15,
		0,
		2
	)
	var second_bottom_lane_order := _release_lane_ranks(
		control_image,
		second_release_start_slot,
		15,
		1,
		2
	)
	_assert_or_quit(
		second_top_lane_order != first_top_lane_order
		and second_bottom_lane_order != first_bottom_lane_order
		and _is_complete_lane_permutation(second_top_lane_order, 15)
		and _is_complete_lane_permutation(second_bottom_lane_order, 15),
		"successive releases reused the same shuffled X order"
	)

	leaves.set_paused(true)
	_assert_or_quit(leaves.is_paused(), "pause state did not latch")
	leaves.reset_leaves()
	summary = leaves.runtime_summary()
	_assert_or_quit(
		int(summary.get("release_serial", -1)) == 0,
		"reset did not clear release serial"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled", -1)) == 0,
		"reset did not clear scheduled total"
	)
	var repeated_default_release := leaves.release_leaves()
	var repeated_control_image := leaves.get("_control_image") as Image
	var repeated_top_lane_order := _release_lane_ranks(
		repeated_control_image,
		0,
		15,
		0,
		1
	)
	var repeated_bottom_lane_order := _release_lane_ranks(
		repeated_control_image,
		0,
		15,
		1,
		1
	)
	var repeated_release_delays := _release_delays(repeated_control_image, 0, 30)
	_assert_or_quit(
		repeated_default_release == 30
		and is_equal_approx(
			float(leaves.runtime_summary().get(
				"last_release_stagger_span_seconds",
				0.0
			)),
			first_default_span_seconds
		)
		and repeated_top_lane_order == first_top_lane_order
		and repeated_bottom_lane_order == first_bottom_lane_order
		and _float_arrays_equal(repeated_release_delays, first_release_delays),
		"reset did not reproduce deterministic delays and shuffled X order"
	)
	leaves.reset_leaves()
	var immediate_release := leaves.release_leaves(4)
	_assert_or_quit(
		immediate_release == 8,
		"paused reset followed by four-per-side release was rejected"
	)
	summary = leaves.runtime_summary()
	_assert_or_quit(
		int(summary.get("release_serial", 0)) == 1,
		"immediate post-reset release did not advance its generation"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled_top", 0)) == 4
		and int(summary.get("total_scheduled_bottom", 0)) == 4,
		"custom release did not preserve exact per-side counts"
	)
	_assert_or_quit(
		float(summary.get("last_release_stagger_span_seconds", 0.0))
			>= 7.0 * 0.110
		and float(summary.get("last_release_stagger_span_seconds", 0.0))
			<= 7.0 * 0.290,
		"custom release did not retain doubled deterministic cadence"
	)

	# Let the GPU consume many successive generations, not merely the final state
	# of a synchronous CPU loop. Resident allocations must remain identical while
	# live generations fall, latch or fade, and recycle.
	var rendered_allocation_before := _allocation_snapshot(leaves)
	leaves.set_paused(false)
	for _release_index in range(RENDER_FENCED_RELEASE_CALLS):
		leaves.release_leaves(STRESS_RELEASE_COUNT_PER_SIDE)
		await get_tree().process_frame
	leaves.set_paused(true)
	var rendered_difference := _first_snapshot_difference(
		rendered_allocation_before,
		_allocation_snapshot(leaves),
	)
	_assert_or_quit(
		rendered_difference.is_empty(),
		"render-fenced releases changed a resident allocation: %s"
			% rendered_difference,
	)
	summary = leaves.runtime_summary()

	# Repeated seasonal releases must only overwrite the resident 300-slot
	# command texture. In particular, the per-release lane orders must replace
	# prior arrays rather than accumulating across calls.
	var allocation_before := _allocation_snapshot(leaves)
	var serial_before := int(summary.get("release_serial", 0))
	var total_top_before := int(summary.get("total_scheduled_top", 0))
	var total_bottom_before := int(summary.get("total_scheduled_bottom", 0))
	var write_slot_before := int(summary.get("next_write_slot", 0))
	var stress_scheduled := 0
	for release_index in range(STRESS_RELEASE_CALLS):
		stress_scheduled += leaves.release_leaves(STRESS_RELEASE_COUNT_PER_SIDE)

	summary = leaves.runtime_summary()
	var allocation_after := _allocation_snapshot(leaves)
	var snapshot_difference := _first_snapshot_difference(
		allocation_before,
		allocation_after
	)
	var generations: PackedInt32Array = leaves.get("_slot_generations")
	var expected_per_bank := (
		STRESS_RELEASE_CALLS * STRESS_RELEASE_COUNT_PER_SIDE
	)
	var expected_stress_total := expected_per_bank * 2
	var expected_write_slot := posmod(
		write_slot_before + expected_stress_total,
		int(summary.get("capacity", 0))
	)
	_assert_or_quit(
		stress_scheduled == expected_stress_total,
		"high-volume release loop rejected one or more leaves"
	)
	_assert_or_quit(
		int(summary.get("release_serial", 0))
			== serial_before + STRESS_RELEASE_CALLS
		and int(summary.get("total_scheduled_top", 0))
			== total_top_before + expected_per_bank
		and int(summary.get("total_scheduled_bottom", 0))
			== total_bottom_before + expected_per_bank
		and int(summary.get("last_scheduled_per_side", 0))
			== STRESS_RELEASE_COUNT_PER_SIDE
		and int(summary.get("last_scheduled_total", 0))
			== STRESS_RELEASE_COUNT_PER_SIDE * 2
		and int(summary.get("next_write_slot", -1)) == expected_write_slot,
		"high-volume releases did not wrap the fixed circular command pool"
	)
	_assert_or_quit(
		generations.size() == int(summary.get("capacity", 0))
		and _generations_are_bounded(generations)
		and (summary.get("last_top_lane_order", []) as Array).size()
			== STRESS_RELEASE_COUNT_PER_SIDE
		and (summary.get("last_bottom_lane_order", []) as Array).size()
			== STRESS_RELEASE_COUNT_PER_SIDE,
		"leaf CPU control state grew beyond the fixed pool or last release"
	)
	_assert_or_quit(
		snapshot_difference.is_empty(),
		"high-volume releases changed a resident allocation: %s"
			% snapshot_difference
	)
	print("GPU_LEAF_SMOKE_PASS ", JSON.stringify(summary))
	get_tree().quit(0)


func _make_test_water_texture() -> ImageTexture:
	# Multiple curving-width bands provide alpha for both contact and periodic
	# downstream probes without depending on the complete stage scene.
	var image := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for x in range(192):
		var first_y := 30 + roundi(sin(float(x) * 0.06) * 4.0)
		var second_y := 77 + roundi(sin(float(x) * 0.04 + 1.7) * 6.0)
		image.fill_rect(Rect2i(x, first_y - 1, 1, 3), Color.WHITE)
		image.fill_rect(Rect2i(x, second_y - 1, 1, 3), Color.WHITE)
	return ImageTexture.create_from_image(image)


func _allocation_snapshot(leaves: GPULeaf2D) -> Dictionary:
	var heads := leaves.get_node_or_null("GPULeafHeads") as GPUParticles2D
	var control_image := leaves.get("_control_image") as Image
	var control_texture := leaves.get("_control_texture") as Texture2D
	var empty_water_texture := leaves.get("_empty_water_texture") as Texture2D
	var supplied_water_texture := leaves.get("_supplied_water_texture") as Texture2D
	var head_material := heads.process_material as Material
	var head_draw_material := heads.material as Material
	var head_texture := heads.texture as Texture2D
	var generations: PackedInt32Array = leaves.get("_slot_generations")
	return {
		"child_count": leaves.get_child_count(),
		"head_node_id": heads.get_instance_id(),
		"head_amount": heads.amount,
		"control_image_id": control_image.get_instance_id(),
		"control_image_size": control_image.get_size(),
		"control_image_format": control_image.get_format(),
		"control_texture_id": control_texture.get_instance_id(),
		"control_texture_rid": control_texture.get_rid(),
		"control_texture_size": control_texture.get_size(),
		"empty_water_texture_id": empty_water_texture.get_instance_id(),
		"empty_water_texture_rid": empty_water_texture.get_rid(),
		"supplied_water_texture_id": supplied_water_texture.get_instance_id(),
		"supplied_water_texture_rid": supplied_water_texture.get_rid(),
		"head_material_id": head_material.get_instance_id(),
		"head_material_rid": head_material.get_rid(),
		"head_draw_material_id": head_draw_material.get_instance_id(),
		"head_draw_material_rid": head_draw_material.get_rid(),
		"head_texture_id": head_texture.get_instance_id(),
		"head_texture_rid": head_texture.get_rid(),
		"generation_count": generations.size(),
	}


func _first_snapshot_difference(before: Dictionary, after: Dictionary) -> String:
	if before.size() != after.size():
		return "snapshot field count"
	for key: Variant in before:
		if not after.has(key):
			return "missing %s" % String(key)
		if before[key] != after[key]:
			return "%s (%s -> %s)" % [key, before[key], after[key]]
	return ""


func _generations_are_bounded(generations: PackedInt32Array) -> bool:
	for generation in generations:
		if generation < 1 or generation > 1000000:
			return false
	return true


func _release_lane_ranks(
	control_image: Image,
	start_slot: int,
	count_per_side: int,
	side_index: int,
	release_serial: int
) -> PackedInt32Array:
	var ranks := PackedInt32Array()
	for release_index in range(count_per_side):
		var slot := start_slot + release_index * 2 + side_index
		var selector := control_image.get_pixel(slot, 0).g
		var rotation := float(release_serial - 1) * 0.031 + float(side_index) * 0.017
		var unrotated_selector := fposmod(selector - rotation, 1.0)
		var lane_rank := roundi(
			unrotated_selector * float(count_per_side) - 0.5
		)
		ranks.append(posmod(lane_rank, count_per_side))
	return ranks


func _release_delays(
	control_image: Image,
	start_slot: int,
	total_count: int
) -> PackedFloat32Array:
	var delays := PackedFloat32Array()
	for sequence_index in range(total_count):
		delays.append(control_image.get_pixel(start_slot + sequence_index, 1).r)
	return delays


func _release_sides_alternate(
	control_image: Image,
	start_slot: int,
	total_count: int
) -> bool:
	for sequence_index in range(total_count):
		var expected_side_code := float(sequence_index % 2 + 1)
		if not is_equal_approx(
			control_image.get_pixel(start_slot + sequence_index, 0).a,
			expected_side_code
		):
			return false
	return true


func _is_complete_lane_permutation(ranks: PackedInt32Array, count: int) -> bool:
	if ranks.size() != count:
		return false
	var sorted_ranks := Array(ranks)
	sorted_ranks.sort()
	for lane_rank in range(count):
		if int(sorted_ranks[lane_rank]) != lane_rank:
			return false
	return true


func _has_left_and_right_steps(ranks: PackedInt32Array) -> bool:
	var moved_left := false
	var moved_right := false
	for index in range(1, ranks.size()):
		moved_left = moved_left or ranks[index] < ranks[index - 1]
		moved_right = moved_right or ranks[index] > ranks[index - 1]
	return moved_left and moved_right


func _delays_are_strictly_increasing(delays: PackedFloat32Array) -> bool:
	if delays.is_empty() or not is_zero_approx(delays[0]):
		return false
	for index in range(1, delays.size()):
		if delays[index] <= delays[index - 1]:
			return false
	return true


func _delay_gaps_in_range(
	delays: PackedFloat32Array,
	minimum_gap: float,
	maximum_gap: float
) -> bool:
	for index in range(1, delays.size()):
		var gap := delays[index] - delays[index - 1]
		if gap < minimum_gap - 0.0001 or gap > maximum_gap + 0.0001:
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


func _array_strings_equal(left_value: Variant, right: Array[String]) -> bool:
	if not left_value is Array:
		return false
	var left: Array = left_value
	if left.size() != right.size():
		return false
	for index in range(right.size()):
		if String(left[index]) != right[index]:
			return false
	return true


func _assert_or_quit(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("GPU_LEAF_SMOKE_FAIL: %s" % message)
	get_tree().quit(1)
