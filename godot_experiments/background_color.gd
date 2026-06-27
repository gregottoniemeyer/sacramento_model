extends ColorRect

@export var transition_seconds: float = 1.0

var current_color: Color
var start_color: Color
var target_color: Color
var transition_elapsed: float = 1.0
var last_speed: float = -1.0

const SPEED_STEP_PX: float = 20.0
const COLORS: Array[Color] = [
	Color("#d2b48c"),
	Color("#f2ca00"),
	Color("#ff7a47"),
	Color("#f9596f"),
	Color("#d44c8d"),
	Color("#a14e9a"),
	Color("#674f95"),
	Color("#31497e"),
	Color("#003d5c"),
	Color("#043832"),
]

func _ready():
	current_color = color
	start_color = current_color
	target_color = current_color
	last_speed = _read_group_speed()
	_set_target_color_for_speed(last_speed, true)

func _process(delta: float):
	var speed := _read_group_speed()
	if not is_equal_approx(speed, last_speed):
		last_speed = speed
		_set_target_color_for_speed(speed, false)

	_update_interpolated_color(delta)

func _read_group_speed() -> float:
	for node in get_tree().get_nodes_in_group("speed_controlled"):
		if node.has_method("get_target_speed"):
			return float(node.get_target_speed())
	return 0.0

func _set_target_color_for_speed(speed: float, immediate: bool):
	var speed_step: int = clampi(roundi(speed / SPEED_STEP_PX), 0, COLORS.size() - 1)
	start_color = current_color
	target_color = COLORS[speed_step]
	transition_elapsed = 0.0

	if immediate:
		current_color = target_color
		color = current_color
		transition_elapsed = transition_seconds

func _update_interpolated_color(delta: float):
	if transition_elapsed >= transition_seconds:
		current_color = target_color
		color = current_color
		return

	transition_elapsed = min(transition_elapsed + delta, transition_seconds)
	var t: float = transition_elapsed / transition_seconds
	var eased_t: float = t * t * (3.0 - 2.0 * t)
	current_color = start_color.lerp(target_color, eased_t)
	color = current_color
