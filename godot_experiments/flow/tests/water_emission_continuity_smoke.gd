extends Node

## Visual-temporal smoke test for low-flow water emission.
##
## Samples the water-only viewport once per second for 24 seconds at 2% flow.
## This spans more than one slow head traversal/recycle lifecycle and catches
## the former native-cycle blank interval that scalar runtime tests cannot see.
## Run with the real Mobile renderer, not --headless's dummy rendering backend.

const STAGE_SCENE := preload(
	"res://flow/gpu_stage/gpu_flow_stage_2d.tscn"
)
const TEST_FLOW_RATE := 0.02
const TEST_SECONDS := 24
const FRAMES_PER_SECOND := 30
const SAMPLE_STRIDE_PIXELS := 6
const VISIBLE_ALPHA_THRESHOLD := 0.02


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var stage := STAGE_SCENE.instantiate()
	stage.watershed_data_drives_flow_rate = false
	stage.flow_rate = TEST_FLOW_RATE
	stage.auto_start = true
	add_child(stage)
	stage.set_flow_rate(TEST_FLOW_RATE)

	var sample_coverages: Array[float] = []
	var sample_y_ranges: Array[Vector2] = []
	for frame_index in range(TEST_SECONDS * FRAMES_PER_SECOND):
		await get_tree().process_frame
		if (frame_index + 1) % FRAMES_PER_SECOND != 0:
			continue
		RenderingServer.force_sync()
		var water_image: Image = stage.get_water_texture().get_image()
		var sample := _sample_water_image(water_image)
		sample_coverages.append(float(sample["coverage"]))
		sample_y_ranges.append(Vector2(sample["y_range"]))

	var minimum_coverage := 1.0
	var maximum_coverage := 0.0
	var blank_sample_count := 0
	var steady_coverage_total := 0.0
	var steady_coverage_count := 0
	for sample_index in range(sample_coverages.size()):
		var coverage := float(sample_coverages[sample_index])
		minimum_coverage = minf(minimum_coverage, coverage)
		maximum_coverage = maxf(maximum_coverage, coverage)
		if coverage <= 0.0:
			blank_sample_count += 1
		if sample_index >= 2:
			steady_coverage_total += coverage
			steady_coverage_count += 1
	var steady_average_coverage := (
		steady_coverage_total / float(maxi(steady_coverage_count, 1))
	)
	print(
		"WATER_EMISSION_CONTINUITY: flow=%.3f samples=%d blank=%d min=%.6f max=%.6f steady_average=%.6f y=%s"
		% [
			float(stage.runtime_summary().get("flow_rate", -1.0)),
			sample_coverages.size(),
			blank_sample_count,
			minimum_coverage,
			maximum_coverage,
			steady_average_coverage,
			sample_y_ranges,
		]
	)
	if blank_sample_count > 0:
		push_error("Two-percent water texture became blank during steady emission.")
		get_tree().quit(1)
		return
	if steady_average_coverage < 0.01 or steady_average_coverage > 0.04:
		push_error(
			"Two-percent water coverage left its calibrated one-to-four-percent visual band."
		)
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _sample_water_image(image: Image) -> Dictionary:
	if image == null or image.is_empty():
		return {"coverage": 0.0, "y_range": Vector2.ZERO}
	var visible_count := 0
	var sampled_count := 0
	var minimum_y := image.get_height()
	var maximum_y := -1
	for y in range(0, image.get_height(), SAMPLE_STRIDE_PIXELS):
		for x in range(0, image.get_width(), SAMPLE_STRIDE_PIXELS):
			sampled_count += 1
			if image.get_pixel(x, y).a <= VISIBLE_ALPHA_THRESHOLD:
				continue
			visible_count += 1
			minimum_y = mini(minimum_y, y)
			maximum_y = maxi(maximum_y, y)
	return {
		"coverage": float(visible_count) / float(maxi(sampled_count, 1)),
		"y_range": (
			Vector2(float(minimum_y), float(maximum_y))
			if maximum_y >= minimum_y
			else Vector2.ZERO
		),
	}
