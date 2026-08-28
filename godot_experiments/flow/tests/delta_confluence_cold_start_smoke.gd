extends Node

## Real-renderer regression for Delta's asynchronous water-state cold start.
## Run without --headless so WaterOnlyViewport can be read back.

const STAGE_SCENE := preload("res://flow/gpu_stage/gpu_flow_stage_2d.tscn")
const SAMPLE_STRIDE_PIXELS := 4
const ALPHA_THRESHOLD := 0.001
const SETTLE_FRAMES := 12
const WAKE_FRAMES := 90


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var stage := STAGE_SCENE.instantiate()
	stage.set(&"screen_id", &"delta")
	stage.set(&"stage_index", 7)
	stage.set(&"delta_confluence_enabled", true)
	stage.set(&"regime_profile_physics_enabled", false)
	stage.set(&"watershed_data_drives_flow_rate", false)
	stage.set(&"particle_slots", 120)
	add_child(stage)

	for frame_index in range(SETTLE_FRAMES):
		await get_tree().process_frame
	var cold_visible_pixels := _visible_sample_count(stage.get_water_texture())

	var accepted := bool(stage.call(
		&"set_confluence_water_state",
		"mount_shasta",
		{
			"flow_rate": 1.0,
			"active_heads": 120,
			"speed_pixels": 300.0,
			"paused": false,
		},
	))
	var peak_visible_pixels := 0
	var first_visible_frame := -1
	for frame_index in range(WAKE_FRAMES):
		await get_tree().process_frame
		if (frame_index + 1) % 3 != 0:
			continue
		var visible_pixels := _visible_sample_count(stage.get_water_texture())
		peak_visible_pixels = maxi(peak_visible_pixels, visible_pixels)
		if first_visible_frame < 0 and visible_pixels > 0:
			first_visible_frame = frame_index + 1

	print("DELTA_CONFLUENCE_COLD_START: accepted=%s cold=%d peak=%d first_frame=%d" % [
		accepted,
		cold_visible_pixels,
		peak_visible_pixels,
		first_visible_frame,
	])
	if not accepted:
		push_error("Delta rejected the first live source state.")
		get_tree().quit(1)
		return
	if cold_visible_pixels != 0:
		push_error("Zero-source Delta was not visually dormant.")
		get_tree().quit(1)
		return
	if peak_visible_pixels <= 0:
		push_error("Delta produced no visible water after its first positive source state.")
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _visible_sample_count(texture: Texture2D) -> int:
	if texture == null:
		return 0
	RenderingServer.force_sync()
	var image := texture.get_image()
	if image == null or image.is_empty():
		return 0
	var visible_pixels := 0
	for y in range(0, image.get_height(), SAMPLE_STRIDE_PIXELS):
		for x in range(0, image.get_width(), SAMPLE_STRIDE_PIXELS):
			if image.get_pixel(x, y).a > ALPHA_THRESHOLD:
				visible_pixels += 1
	return visible_pixels
