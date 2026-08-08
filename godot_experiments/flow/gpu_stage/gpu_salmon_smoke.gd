extends Node

## Standalone API/instantiation smoke for the isolated GPU salmon subsystem.
## It deliberately performs no particle-state readback.

const SALMON_SCRIPT := preload("res://flow/gpu_stage/gpu_salmon_2d.gd")


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


func _assert_or_quit(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("GPU_SALMON_SMOKE_FAIL: %s" % message)
	get_tree().quit(1)
