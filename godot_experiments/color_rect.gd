extends ColorRect

const SPEED_TRANSITION_SECONDS: float = 1.0

var animation_offset_px: float = 0.0
var current_speed_px: float = 0.0
var start_speed_px: float = 0.0
var target_speed_px: float = 0.0
var transition_elapsed: float = SPEED_TRANSITION_SECONDS

func _ready():
	_update_shader_size()
	if material:
		current_speed_px = float(material.get_shader_parameter("speed_px"))
		start_speed_px = current_speed_px
		target_speed_px = current_speed_px

func _notification(what):
	if what == NOTIFICATION_RESIZED:
		_update_shader_size()

func _update_shader_size():
	if material:
		material.set_shader_parameter("rect_size_px", size)

func _process(delta: float):
	if not material:
		return
	_update_speed_from_number_keys()
	_update_interpolated_speed(delta)
	animation_offset_px += current_speed_px * delta
	material.set_shader_parameter("animation_offset_px", animation_offset_px)

func _update_speed_from_number_keys():
	for digit in range(10):
		if Input.is_key_pressed(KEY_0 + digit):
			set_target_speed(digit * 20.0)

func set_target_speed(speed_px: float):
	if is_equal_approx(speed_px, target_speed_px):
		return
	start_speed_px = current_speed_px
	target_speed_px = speed_px
	transition_elapsed = 0.0
	material.set_shader_parameter("speed_px", target_speed_px)

func _update_interpolated_speed(delta: float):
	if transition_elapsed >= SPEED_TRANSITION_SECONDS:
		current_speed_px = target_speed_px
		return

	transition_elapsed = min(transition_elapsed + delta, SPEED_TRANSITION_SECONDS)
	var t := transition_elapsed / SPEED_TRANSITION_SECONDS
	var eased_t := t * t * (3.0 - 2.0 * t)
	current_speed_px = lerp(start_speed_px, target_speed_px, eased_t)
