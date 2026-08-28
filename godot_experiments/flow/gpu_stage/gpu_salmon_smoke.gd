extends Node

## Standalone API/instantiation smoke for the isolated GPU salmon subsystem.
## It deliberately performs no particle-state readback.

const SALMON_SCRIPT := preload("res://flow/gpu_stage/gpu_salmon_2d.gd")
const STRESS_RELEASE_CALLS := 2000
const STRESS_RELEASE_COUNT := 7
const RENDER_FENCED_RELEASE_CALLS := 60


func _ready() -> void:
	var salmon: GPUSalmon2D = SALMON_SCRIPT.new()
	add_child(salmon)
	salmon.set_water_texture(_make_test_water_texture())

	var configured := salmon.configure({
		"stage_size": Vector2(1920.0, 1080.0),
		"simulation_fps": 30,
		"upstream_speed_pixels": 300.0,
		"water_alpha_threshold": 0.001,
		"water_lookahead_pixels": 120.0,
		"water_contact_half_height_pixels": 12.0,
		"water_steering_strength": 5.0,
		"streak_length_pixels": 100.0,
		"streak_width_pixels": 3.0,
		"fade_seconds": 0.5,
		"occupancy_flip_y": false,
	})
	_assert_or_quit(configured, "known configuration keys were rejected")
	if get_tree().root == null:
		return

	var released := salmon.release_salmon()
	_assert_or_quit(released == 25, "default release did not schedule 25 salmon")
	if get_tree().root == null:
		return

	# Allow the resident head pool to sample the generation and occupancy textures.
	for frame_index in range(4):
		await get_tree().process_frame

	var summary: Dictionary = salmon.runtime_summary()
	_assert_or_quit(int(summary.get("capacity", 0)) == 300, "capacity is not 300")
	_assert_or_quit(
		int(summary.get("release_serial", 0)) == 1,
		"release serial did not advance"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled", 0)) == 25,
		"scheduled total is not 25"
	)
	_assert_or_quit(
		bool(summary.get("water_texture_assigned", false)),
		"water texture was not retained"
	)
	_assert_or_quit(
		bool(summary.get("immutable_segments", false)),
		"immutable segment path is disabled"
	)
	_assert_or_quit(
		not bool(summary.get("cpu_readback", true)),
		"smoke detected a CPU-readback path"
	)
	_assert_or_quit(
		int(summary.get("segment_capacity", 0)) >= 3750,
		"segment pool is too small for 300 salmon at 30 Hz"
	)
	_assert_or_quit(
		is_equal_approx(
			float(summary.get("effective_trail_length_pixels", 0.0)),
			100.0
		),
		"300px/s motion did not preserve a 100px immutable trail"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("streak_width_pixels", 0.0)), 3.0),
		"salmon trail width is not the requested 3px"
	)
	_assert_or_quit(
		is_equal_approx(float(summary.get("water_lookahead_pixels", 0.0)), 120.0)
		and is_equal_approx(
			float(summary.get("water_contact_half_height_pixels", 0.0)),
			12.0
		)
		and is_equal_approx(float(summary.get("water_steering_strength", 0.0)), 5.0)
		and is_equal_approx(float(summary.get("no_water_fade_seconds", 0.0)), 0.5),
		"2D steering changed the approved 240x24 contact or 0.5s fade contract"
	)
	_assert_or_quit(
		String(summary.get("water_steering_mode", ""))
			== "DETERMINISTIC_2D_CONTACT_FIELD"
		and String(summary.get("water_steering_reference", ""))
			== "CURRENT_SWIM_HEADING",
		"salmon summary does not advertise vicinity-aware 2D steering"
	)

	var head_particles := salmon.get_node_or_null("GPUSalmonHeads") as GPUParticles2D
	_assert_or_quit(head_particles != null, "resident GPU salmon heads are missing")
	if get_tree().root == null:
		return
	var head_material := head_particles.process_material as ShaderMaterial
	_assert_or_quit(head_material != null, "salmon head process material is missing")
	if get_tree().root == null:
		return
	_assert_or_quit(
		is_equal_approx(
			float(head_material.get_shader_parameter(&"water_lookahead_pixels")),
			120.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"water_contact_half_height_pixels"
			)),
			12.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"water_steering_strength")),
			5.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"streak_length_pixels")),
			100.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"streak_width_pixels")),
			3.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"fade_seconds")),
			0.5
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(&"delta_route_turn_pixels")),
			240.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"delta_route_trunk_center_y_pixels"
			)),
			540.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"delta_route_approach_pixels"
			)),
			240.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"delta_route_lookahead_pixels"
			)),
			120.0
		)
		and is_equal_approx(
			float(head_material.get_shader_parameter(
				&"delta_route_spawn_stagger_seconds"
			)),
			2.5
		),
		"2D steering, immutable trail, or Delta rail uniforms missed the shader"
	)
	var head_shader_code := head_material.shader.code
	_assert_or_quit(
		head_shader_code.contains("vec4 contact_and_steering")
		and head_shader_code.contains("contact_and_steering(point, VELOCITY.xy)")
		and head_shader_code.contains("vec2 candidate_direction = offset / offset_length")
		and head_shader_code.contains("dot(candidate_direction, prior)")
		and head_shader_code.contains("float upstream_alignment = -candidate_direction.x")
		and head_shader_code.contains("contact.yz * max(water_steering_strength, 0.0)")
		and head_shader_code.contains("prior_normal * flow_noise(point, seed)")
		and head_shader_code.contains("safe_swim_direction(resolved_velocity) * varied_speed")
		and head_shader_code.contains("vec4 cohort_bezier_rail")
		and head_shader_code.contains("vec2 cohort_immediate_spawn_point")
		and head_shader_code.contains("float cohort_spawn_delay_seconds")
		and head_shader_code.contains("float cohort_group_offset")
		and head_shader_code.contains("max(control.a - 1.0, 0.0)")
		and head_shader_code.contains("vec4 cohort_scheduled_motion")
		and head_shader_code.contains("? vec3(cohort_immediate_spawn_point(")
		and head_shader_code.contains("float next_elapsed = CUSTOM.z + DELTA")
		and head_shader_code.contains("max(next_elapsed - spawn_delay, 0.0)")
		and head_shader_code.contains("next_point = scheduled_next.xy")
		and head_shader_code.contains("float cohort_route_closest_t")
		and head_shader_code.contains("float preview_t = max(route_t - preview_delta_t, 0.0)")
		and head_shader_code.contains("float route_t = 1.0 - branch_progress")
		and head_shader_code.contains("cohort_arrived = scheduled_next.w >= 0.999999")
		and not head_shader_code.contains("cohort_water_direction")
		and not head_shader_code.contains("cohort_exit_cleared")
		and not head_shader_code.contains("float(x_index) * 1000.0")
		and not head_shader_code.contains("contact.y * water_steering_strength"),
		"salmon shader is not deterministically steering from 2D nearby water"
	)
	_assert_delta_route_contract(summary)
	if get_tree().root == null:
		return

	# Routed cohorts must start and complete without any right-edge occupancy.
	# Capture a fast command, then slow the live uniform after release; the GPU
	# must retain the command speed that the CPU handoff bound was built from.
	salmon.set_water_texture(_make_empty_water_texture())
	_assert_or_quit(
		salmon.configure({"upstream_speed_pixels": 600.0}),
		"cold routed-speed configuration was rejected",
	)
	var delta_cohorts: Array[Dictionary] = [
		{
			"source_screen": "Mill Creek",
			"destination_screen": "Mill Creek",
			"destination_anchor_pixels": Vector2(360.0, 1080.0),
			"count": 25,
			"survivor_count": 20,
		},
		{
			"source_screen": "Cottonwood",
			"destination_screen": "Cottonwood",
			"destination_anchor_pixels": Vector2(1200.0, 1080.0),
			"count": 25,
			"survivor_count": 18,
		},
		{
			"source_screen": "Shasta",
			"destination_screen": "Shasta",
			"destination_anchor_pixels": Vector2(0.0, 120.0),
			"count": 25,
			"survivor_count": 16,
		},
		{
			"source_screen": "McCloud",
			"destination_screen": "McCloud",
			"destination_anchor_pixels": Vector2(0.0, 840.0),
			"count": 25,
			"survivor_count": 14,
		},
		{
			"source_screen": "Feather",
			"destination_screen": "Feather",
			"destination_anchor_pixels": Vector2(600.0, 0.0),
			"count": 25,
			"survivor_count": 12,
		},
		{
			"source_screen": "American",
			"destination_screen": "American",
			"destination_anchor_pixels": Vector2(1440.0, 0.0),
			"count": 25,
			"survival_fraction": 0.4,
		},
	]
	var cohort_release := salmon.release_salmon_cohorts(delta_cohorts)
	_assert_or_quit(
		cohort_release == 150,
		"six Delta cohorts did not schedule jointly as 150 salmon",
	)
	if get_tree().root == null:
		return
	summary = salmon.runtime_summary()
	var cohort_summaries: Array = summary.get("last_cohorts", []) as Array
	_assert_or_quit(
		String(summary.get("last_release_mode", "")) == "COHORTS"
		and int(summary.get("last_cohort_count", 0)) == 6
		and int(summary.get("last_cohort_requested_count", 0)) == 150
		and int(summary.get("last_cohort_scheduled_count", 0)) == 150
		and int(summary.get("last_cohort_survivor_count", 0)) == 90
		and int(summary.get("last_cohort_death_count", 0)) == 60
		and cohort_summaries.size() == 6,
		"Delta cohort summary did not preserve six destinations or exact outcomes",
	)
	if get_tree().root == null:
		return
	var expected_survivors: Array[int] = [20, 18, 16, 14, 12, 10]
	var expected_route_indices: Array[int] = [3, 2, 0, 1, 4, 5]
	var expected_merge_x: Array[float] = [720.0, 1440.0, 480.0, 480.0, 960.0, 1680.0]
	var cohort_release_serial := int(summary.get("release_serial", -1))
	var distinct_group_offsets: Dictionary = {}
	var changed_next_release_offsets := 0
	for cohort_index in range(cohort_summaries.size()):
		var cohort_summary: Dictionary = cohort_summaries[cohort_index] as Dictionary
		var route_index := expected_route_indices[cohort_index]
		var group_offset_seconds := float(cohort_summary.get(
			"group_offset_seconds",
			-1.0,
		))
		var repeated_offset := float(salmon.call(
			&"_cohort_group_offset_seconds",
			cohort_release_serial,
			route_index,
		))
		var next_release_offset := float(salmon.call(
			&"_cohort_group_offset_seconds",
			cohort_release_serial + 1,
			route_index,
		))
		distinct_group_offsets[roundi(group_offset_seconds * 1000000.0)] = true
		if not is_equal_approx(group_offset_seconds, next_release_offset):
			changed_next_release_offsets += 1
		_assert_or_quit(
			String(cohort_summary.get("destination_screen", ""))
				== String(delta_cohorts[cohort_index]["destination_screen"])
			and int(cohort_summary.get("scheduled_count", 0)) == 25
			and int(cohort_summary.get("scheduled_survivor_count", -1))
				== expected_survivors[cohort_index]
			and int(cohort_summary.get("destination_route_index", -1))
				== expected_route_indices[cohort_index]
			and is_equal_approx(
				float(cohort_summary.get("destination_merge_x_pixels", -1.0)),
				expected_merge_x[cohort_index]
			)
			and is_equal_approx(
				float(cohort_summary.get("captured_base_speed_pixels", -1.0)),
				600.0,
			)
			and group_offset_seconds >= 0.0
			and group_offset_seconds <= 6.0
			and is_equal_approx(group_offset_seconds, repeated_offset),
			"Delta cohort destination or survivor metadata changed",
		)
		if get_tree().root == null:
			return
	_assert_or_quit(
		cohort_release_serial == 2
		and distinct_group_offsets.size() == 6
		and changed_next_release_offsets == 6,
		(
			"destination offsets were not deterministic, distinct, bounded, "
			+ "and release-varying"
		),
	)
	if get_tree().root == null:
		return
	var control_image: Image = salmon.get("_control_image") as Image
	var routed_commands := 0
	var survivor_commands := 0
	var captured_speed_commands := 0
	var routed_merge_counts: Dictionary = {}
	for slot in range(control_image.get_width()):
		var route_command := control_image.get_pixel(slot, 1)
		if route_command.b >= 0.5:
			routed_commands += 1
			if is_equal_approx(control_image.get_pixel(slot, 0).g, 600.0):
				captured_speed_commands += 1
			var merge_key := roundi(route_command.b)
			routed_merge_counts[merge_key] = int(
				routed_merge_counts.get(merge_key, 0)
			) + 1
			if route_command.a >= 0.5:
				survivor_commands += 1
	# The initial ordinary release occupies slots 0..24 and must retain A=1.
	# The joint release then writes six contiguous 25-fish groups whose encoded
	# row-zero A values all carry the exact destination-level offset.
	var encoded_group_offset_commands := 0
	for ordinary_slot in range(25):
		_assert_or_quit(
			is_equal_approx(control_image.get_pixel(ordinary_slot, 0).a, 1.0),
			"destination timing leaked into ordinary salmon commands",
		)
	for cohort_index in range(cohort_summaries.size()):
		var cohort_summary: Dictionary = cohort_summaries[cohort_index] as Dictionary
		var expected_group_offset := float(cohort_summary["group_offset_seconds"])
		for fish_index in range(25):
			var slot := 25 + cohort_index * 25 + fish_index
			if is_equal_approx(
				control_image.get_pixel(slot, 0).a,
				1.0 + expected_group_offset,
			):
				encoded_group_offset_commands += 1
	_assert_or_quit(
		control_image.get_size() == Vector2i(300, 2)
		and routed_commands == 150
		and captured_speed_commands == 150
		and encoded_group_offset_commands == 150
		and survivor_commands == 90
		and int(routed_merge_counts.get(480, 0)) == 50
		and int(routed_merge_counts.get(720, 0)) == 25
		and int(routed_merge_counts.get(960, 0)) == 25
		and int(routed_merge_counts.get(1440, 0)) == 25
		and int(routed_merge_counts.get(1680, 0)) == 25
		and head_shader_code.contains("vec4 cohort_bezier_rail")
		and head_shader_code.contains("bool commanded_death")
		and head_shader_code.contains("bool cohort_reaches_anchor"),
		"Delta route/survival commands are not encoded in the fixed GPU pool",
	)
	if get_tree().root == null:
		return
	_assert_or_quit(
		salmon.configure({"upstream_speed_pixels": 60.0}),
		"post-release speed-change configuration was rejected",
	)
	control_image = salmon.get("_control_image") as Image
	for slot in range(control_image.get_width()):
		if control_image.get_pixel(slot, 1).b >= 0.5:
			_assert_or_quit(
				is_equal_approx(control_image.get_pixel(slot, 0).g, 600.0),
				"live speed change rewrote a routed generation's captured speed",
			)
	# Let native renderers execute the complete cold/no-water routed schedule,
	# including exact P0 retirement, without particle-state readback.
	for _route_frame in range(350):
		await get_tree().process_frame

	salmon.set_paused(true)
	_assert_or_quit(salmon.is_paused(), "pause state did not latch")
	salmon.reset_salmon()
	summary = salmon.runtime_summary()
	_assert_or_quit(
		int(summary.get("release_serial", -1)) == 0,
		"reset did not clear release serial"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled", -1)) == 0,
		"reset did not clear scheduled total"
	)
	var immediate_release := salmon.release_salmon()
	_assert_or_quit(
		immediate_release == 25,
		"paused reset followed by an immediate release was rejected"
	)
	summary = salmon.runtime_summary()
	_assert_or_quit(
		int(summary.get("release_serial", 0)) == 1,
		"immediate post-reset release did not advance its generation"
	)
	_assert_or_quit(
		int(summary.get("total_scheduled", 0)) == 25,
		"immediate post-reset release did not schedule 25 salmon"
	)
	_assert_or_quit(
		is_equal_approx(
			float(summary.get("water_alpha_threshold", -1.0)),
			0.001
		),
		"nontransparent-water alpha threshold is not 0.001"
	)

	# Let the GPU consume many successive generations, not merely the final state
	# of a synchronous CPU loop. Resident allocations must remain identical while
	# live generations enter, swim, fade, and recycle.
	var rendered_allocation_before := _allocation_snapshot(salmon)
	salmon.set_paused(false)
	for _release_index in range(RENDER_FENCED_RELEASE_CALLS):
		salmon.release_salmon(STRESS_RELEASE_COUNT)
		await get_tree().process_frame
	salmon.set_paused(true)
	var rendered_difference := _first_snapshot_difference(
		rendered_allocation_before,
		_allocation_snapshot(salmon),
	)
	_assert_or_quit(
		rendered_difference.is_empty(),
		"render-fenced releases changed a resident allocation: %s"
			% rendered_difference,
	)
	summary = salmon.runtime_summary()

	# Exercise many years' worth of release commands synchronously. Releases must
	# only overwrite the existing 300 command slots; they must not append nodes,
	# materials, textures, particle capacity, or retained CPU-side state.
	var allocation_before := _allocation_snapshot(salmon)
	var serial_before := int(summary.get("release_serial", 0))
	var total_before := int(summary.get("total_scheduled", 0))
	var write_slot_before := int(summary.get("next_write_slot", 0))
	var stress_scheduled := 0
	for release_index in range(STRESS_RELEASE_CALLS):
		stress_scheduled += salmon.release_salmon(STRESS_RELEASE_COUNT)

	summary = salmon.runtime_summary()
	var allocation_after := _allocation_snapshot(salmon)
	var snapshot_difference := _first_snapshot_difference(
		allocation_before,
		allocation_after
	)
	var generations: PackedInt32Array = salmon.get("_slot_generations")
	var expected_stress_total := STRESS_RELEASE_CALLS * STRESS_RELEASE_COUNT
	var expected_write_slot := posmod(
		write_slot_before + expected_stress_total,
		int(summary.get("capacity", 0))
	)
	_assert_or_quit(
		stress_scheduled == expected_stress_total,
		"high-volume release loop rejected one or more salmon"
	)
	_assert_or_quit(
		int(summary.get("release_serial", 0))
			== serial_before + STRESS_RELEASE_CALLS
		and int(summary.get("total_scheduled", 0))
			== total_before + expected_stress_total
		and int(summary.get("last_scheduled", 0)) == STRESS_RELEASE_COUNT
		and int(summary.get("next_write_slot", -1)) == expected_write_slot,
		"high-volume releases did not wrap the fixed circular command pool"
	)
	_assert_or_quit(
		generations.size() == int(summary.get("capacity", 0))
		and _generations_are_bounded(generations),
		"salmon generation state grew beyond the fixed pool or escaped its bounds"
	)
	_assert_or_quit(
		snapshot_difference.is_empty(),
		"high-volume releases changed a resident allocation: %s"
			% snapshot_difference
	)
	print("GPU_SALMON_SMOKE_PASS ", JSON.stringify(summary))
	get_tree().quit(0)


func _assert_delta_route_contract(summary: Dictionary) -> void:
	var routes: Array = summary.get("cohort_routes", [])
	_assert_or_quit(
		String(summary.get("cohort_route_mode", ""))
			== "DELTA_REVERSE_CUBIC_BEZIER_RAIL"
		and String(summary.get("cohort_route_command_encoding", ""))
			== (
				"ROW0_G_CAPTURED_BASE_SPEED_A_ONE_PLUS_GROUP_OFFSET_"
				+ "ROW1_XY_ANCHOR_B_MERGE_X_A_SURVIVES"
			)
		and String(summary.get("cohort_route_spawn_mode", ""))
			== "IMMEDIATE_RIGHT_TRUNK_NO_WATER_DEPENDENCY"
		and String(summary.get("cohort_route_motion_mode", ""))
			== "TIME_BOUNDED_TRUNK_THEN_EXACT_CUBIC"
		and String(summary.get("cohort_route_arrival_mode", ""))
			== "EXACT_EDGE_ANCHOR_THEN_RETIRE"
		and int(summary.get("cohort_route_count", 0)) == 6
		and routes.size() == 6
		and is_equal_approx(
			float(summary.get("cohort_route_turn_pixels", 0.0)),
			240.0
		)
		and is_equal_approx(
			float(summary.get("cohort_route_trunk_center_y_pixels", 0.0)),
			540.0
		)
		and is_equal_approx(
			float(summary.get("cohort_route_approach_pixels", 0.0)),
			240.0
		)
		and is_equal_approx(
			float(summary.get("cohort_route_lookahead_pixels", 0.0)),
			120.0
		)
		and is_equal_approx(
			float(summary.get("cohort_route_spawn_stagger_seconds", -1.0)),
			2.5
		)
		and is_equal_approx(
			float(summary.get("cohort_route_group_offset_max_seconds", -1.0)),
			6.0
		),
		"Delta route summary does not advertise the fixed reverse-cubic rail",
	)
	if routes.size() != 6:
		return
	var expected_controls: Array = [
		[Vector2(0.0, 120.0), Vector2(210.0, 120.0), Vector2(270.0, 540.0), Vector2(480.0, 540.0)],
		[Vector2(0.0, 840.0), Vector2(180.0, 840.0), Vector2(300.0, 540.0), Vector2(480.0, 540.0)],
		[Vector2(1200.0, 1080.0), Vector2(1200.0, 840.0), Vector2(1260.0, 540.0), Vector2(1440.0, 540.0)],
		[Vector2(360.0, 1080.0), Vector2(360.0, 840.0), Vector2(540.0, 540.0), Vector2(720.0, 540.0)],
		[Vector2(600.0, 0.0), Vector2(600.0, 240.0), Vector2(780.0, 540.0), Vector2(960.0, 540.0)],
		[Vector2(1440.0, 0.0), Vector2(1440.0, 240.0), Vector2(1500.0, 540.0), Vector2(1680.0, 540.0)],
	]
	for route_index in range(routes.size()):
		var route: Dictionary = routes[route_index]
		var controls: Array = expected_controls[route_index]
		var point_0 := Vector2(route.get("point_0", Vector2.INF))
		var point_1 := Vector2(route.get("point_1", Vector2.INF))
		var point_2 := Vector2(route.get("point_2", Vector2.INF))
		var point_3 := Vector2(route.get("point_3", Vector2.INF))
		_assert_or_quit(
			point_0 == Vector2(controls[0])
			and point_1 == Vector2(controls[1])
			and point_2 == Vector2(controls[2])
			and point_3 == Vector2(controls[3])
			and (point_3 - point_2).normalized().is_equal_approx(Vector2.RIGHT)
			and _minimum_cubic_radius(controls, 256) >= 139.5,
			"Delta reverse rail controls/tangent changed for route %d" % route_index,
		)
	var shasta_preview := _cubic_point(expected_controls[0], 0.78)
	var mccloud_preview := _cubic_point(expected_controls[1], 0.78)
	_assert_or_quit(
		absf(shasta_preview.x - mccloud_preview.x) < 12.0
		and absf(shasta_preview.y - mccloud_preview.y) > 80.0
		and shasta_preview.y < 540.0
		and mccloud_preview.y > 540.0,
		"120px reverse lookahead does not split the shared Shasta/McCloud merge",
	)


func _cubic_point(controls: Array, progress: float) -> Vector2:
	var point_0 := Vector2(controls[0])
	var point_1 := Vector2(controls[1])
	var point_2 := Vector2(controls[2])
	var point_3 := Vector2(controls[3])
	var t := clampf(progress, 0.0, 1.0)
	var u := 1.0 - t
	return (
		point_0 * u * u * u
		+ point_1 * 3.0 * u * u * t
		+ point_2 * 3.0 * u * t * t
		+ point_3 * t * t * t
	)


func _minimum_cubic_radius(controls: Array, sample_count: int) -> float:
	var point_0 := Vector2(controls[0])
	var point_1 := Vector2(controls[1])
	var point_2 := Vector2(controls[2])
	var point_3 := Vector2(controls[3])
	var minimum_radius := INF
	for sample_index in range(sample_count + 1):
		var t := float(sample_index) / float(sample_count)
		var u := 1.0 - t
		var derivative := (
			(point_1 - point_0) * 3.0 * u * u
			+ (point_2 - point_1) * 6.0 * u * t
			+ (point_3 - point_2) * 3.0 * t * t
		)
		var second_derivative := (
			(point_2 - point_1 * 2.0 + point_0) * 6.0 * u
			+ (point_3 - point_2 * 2.0 + point_1) * 6.0 * t
		)
		var curvature_numerator := absf(
			derivative.x * second_derivative.y
			- derivative.y * second_derivative.x
		)
		if curvature_numerator <= 0.000001:
			continue
		var radius := pow(derivative.length(), 3.0) / curvature_numerator
		minimum_radius = minf(minimum_radius, radius)
	return minimum_radius


func _make_test_water_texture() -> ImageTexture:
	# Asymmetric lanes exercise the right-edge spawn search without relying on a
	# full stage viewport. Shader sampling is normalized, so this texture can be
	# lower resolution than the 1920 x 1080 stage.
	var image := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for lane_y in [13, 31, 52, 77, 96]:
		image.fill_rect(Rect2i(0, lane_y - 1, 192, 3), Color.WHITE)
	return ImageTexture.create_from_image(image)


func _make_empty_water_texture() -> ImageTexture:
	var image := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	return ImageTexture.create_from_image(image)


func _allocation_snapshot(salmon: GPUSalmon2D) -> Dictionary:
	var heads := salmon.get_node_or_null("GPUSalmonHeads") as GPUParticles2D
	var segments := (
		salmon.get_node_or_null("GPUSalmonTrailSegments") as GPUParticles2D
	)
	var control_image := salmon.get("_control_image") as Image
	var control_texture := salmon.get("_control_texture") as Texture2D
	var empty_water_texture := salmon.get("_empty_water_texture") as Texture2D
	var supplied_water_texture := salmon.get("_supplied_water_texture") as Texture2D
	var head_material := heads.process_material as Material
	var head_texture := heads.texture as Texture2D
	var segment_process_material := segments.process_material as Material
	var segment_draw_material := segments.material as Material
	var segment_texture := segments.texture as Texture2D
	var generations: PackedInt32Array = salmon.get("_slot_generations")
	return {
		"child_count": salmon.get_child_count(),
		"head_node_id": heads.get_instance_id(),
		"segment_node_id": segments.get_instance_id(),
		"head_amount": heads.amount,
		"segment_amount": segments.amount,
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
		"head_texture_id": head_texture.get_instance_id(),
		"head_texture_rid": head_texture.get_rid(),
		"segment_process_material_id": segment_process_material.get_instance_id(),
		"segment_process_material_rid": segment_process_material.get_rid(),
		"segment_draw_material_id": segment_draw_material.get_instance_id(),
		"segment_draw_material_rid": segment_draw_material.get_rid(),
		"segment_texture_id": segment_texture.get_instance_id(),
		"segment_texture_rid": segment_texture.get_rid(),
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


func _assert_or_quit(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("GPU_SALMON_SMOKE_FAIL: %s" % message)
	get_tree().quit(1)
