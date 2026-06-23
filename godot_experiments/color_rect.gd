extends ColorRect

var time_passed: float = 0.0
var running: bool = true

func _process(delta: float):
	if Input.is_action_just_pressed("ui_accept"):
		running = !running

	if running:
		time_passed += delta
		material.set_shader_parameter("custom_time", time_passed)
