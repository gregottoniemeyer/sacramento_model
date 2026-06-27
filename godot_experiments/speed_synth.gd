extends Node

@export var duration_seconds: float = 12.0
@export var attack_seconds: float = 1.0
@export var buffer_seconds: float = 0.2
@export var sample_rate: float = 44100.0
@export var base_volume: float = 0.18

var player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var active: bool = false
var note_time: float = 0.0
var phase: Array[float] = [0.0, 0.0, 0.0, 0.0]
var frequencies: Array[float] = [261.63, 311.13, 392.0, 523.25]
var last_speed: float = -1.0
var chord_volume: float = 0.0

const ROOT_MIDI: Array[int] = [48, 55, 50, 57, 52, 59, 54, 61, 56, 63]
const MINOR_INTERVALS: Array[int] = [0, 3, 7, 12]
const MAJOR_INTERVALS: Array[int] = [0, 4, 7, 12]

func _ready():
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = sample_rate
	stream.buffer_length = buffer_seconds

	player = AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	playback = player.get_stream_playback()

	last_speed = _read_group_speed()
	_trigger_for_speed(last_speed, last_speed)

func _process(_delta: float):
	var speed := _read_group_speed()
	if not is_equal_approx(speed, last_speed):
		_trigger_for_speed(speed, last_speed)
		last_speed = speed

	if playback:
		_fill_audio_buffer()

func _read_group_speed() -> float:
	for node in get_tree().get_nodes_in_group("speed_controlled"):
		if node.has_method("get_target_speed"):
			return float(node.get_target_speed())
	return 0.0

func _trigger_for_speed(speed: float, previous_speed: float):
	var speed_value: int = clampi(roundi(speed / 20.0), 0, 9)
	var intervals: Array[int] = MINOR_INTERVALS if speed_value % 2 == 0 else MAJOR_INTERVALS
	var root: int = ROOT_MIDI[speed_value]

	for i in range(4):
		frequencies[i] = _midi_to_hz(root + intervals[i])
		phase[i] = 0.0

	var delta_speed: float = abs(speed - previous_speed)
	chord_volume = base_volume * clamp(0.35 + delta_speed / 180.0, 0.35, 1.0)
	note_time = 0.0
	active = true

func _fill_audio_buffer():
	var frames: int = playback.get_frames_available()
	for i in range(frames):
		var sample: float = _next_sample()
		playback.push_frame(Vector2(sample, sample))

func _next_sample() -> float:
	if not active:
		return 0.0

	var attack: float = min(note_time / attack_seconds, 1.0)
	var fade: float = max(1.0 - note_time / duration_seconds, 0.0)
	var envelope: float = attack * fade * fade

	var sample: float = 0.0
	for i in range(4):
		phase[i] = fmod(phase[i] + TAU * frequencies[i] / sample_rate, TAU)
		sample += sin(phase[i])

	note_time += 1.0 / sample_rate
	if note_time >= duration_seconds:
		active = false

	return sample * 0.25 * chord_volume * envelope

func _midi_to_hz(note: int) -> float:
	return 440.0 * pow(2.0, (float(note) - 69.0) / 12.0)
