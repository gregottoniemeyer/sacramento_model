extends Node

@export var csv_path: String = "res://speed_sequence.txt"
@export var interval_seconds: float = 12.0
@export var speed_multiplier: float = 20.0

var speed_values: Array[int] = []
var elapsed: float = 0.0
var index: int = 0

func _ready():
	_load_speed_values()
	_apply_current_speed()

func _process(delta: float):
	if speed_values.is_empty():
		return

	elapsed += delta
	if elapsed < interval_seconds:
		return

	elapsed = fmod(elapsed, interval_seconds)
	index = (index + 1) % speed_values.size()
	_apply_current_speed()

func _load_speed_values():
	speed_values.clear()
	if not FileAccess.file_exists(csv_path):
		speed_values.append(0)
		return

	var file := FileAccess.open(csv_path, FileAccess.READ)
	if file == null:
		speed_values.append(0)
		return

	var text := file.get_as_text()
	text = text.replace("\r", ",").replace("\n", ",")
	for token in text.split(",", false):
		var value := clampi(int(token.strip_edges()), 0, 9)
		speed_values.append(value)

	if speed_values.is_empty():
		speed_values.append(0)

func _apply_current_speed():
	var speed_px := speed_values[index] * speed_multiplier
	for node in get_tree().get_nodes_in_group("speed_controlled"):
		if node.has_method("set_target_speed"):
			node.set_target_speed(speed_px)
