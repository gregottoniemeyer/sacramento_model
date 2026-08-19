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
		),
		"2D steering or immutable trail uniforms did not reach the salmon shader"
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
		and not head_shader_code.contains("float(x_index) * 1000.0")
		and not head_shader_code.contains("contact.y * water_steering_strength"),
		"salmon shader is not deterministically steering from 2D nearby water"
	)

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


func _make_test_water_texture() -> ImageTexture:
	# Asymmetric lanes exercise the right-edge spawn search without relying on a
	# full stage viewport. Shader sampling is normalized, so this texture can be
	# lower resolution than the 1920 x 1080 stage.
	var image := Image.create(192, 108, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for lane_y in [13, 31, 52, 77, 96]:
		image.fill_rect(Rect2i(0, lane_y - 1, 192, 3), Color.WHITE)
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
