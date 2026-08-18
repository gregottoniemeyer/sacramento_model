extends Node
## Process-persistent authority for the shared model calendar.
##
## The timeline stores elapsed real seconds within one synthetic, non-leap
## model year. Calendar fields are derived from that continuous year phase so
## changing the duration never changes the currently displayed model date.

signal timeline_changed(state: Dictionary)

const DAY_COUNT: int = 365
const MINUTES_PER_DAY: int = 1440
const YEAR_MINUTE_COUNT: int = DAY_COUNT * MINUTES_PER_DAY
const DEFAULT_YEAR_DURATION_SECONDS: float = 720.0
const DEFAULT_START_DAY_INDEX: int = 181
const MIN_YEAR_DURATION_SECONDS: float = 1.0
const MAX_YEAR_DURATION_SECONDS: float = 86400.0
const CALENDAR_MINUTE_SNAP_EPSILON: float = 0.000001

var _initialized: bool = false
var _elapsed_seconds: float = 0.0
var _year_duration_seconds: float = DEFAULT_YEAR_DURATION_SECONDS
var _start_day_index: int = DEFAULT_START_DAY_INDEX
var _auto_advance: bool = true
var _paused: bool = false
var _source: StringName = &"internal_clock"
var _revision: int = 0


func _ready() -> void:
	# Autoloads survive current-scene replacement. Explicit timeline pause is
	# authoritative, so SceneTree pause and selector navigation do not stop it.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if not _initialized or _paused or not _auto_advance or delta <= 0.0:
		return
	_elapsed_seconds = fposmod(
		_elapsed_seconds + delta,
		_year_duration_seconds
	)
	_publish_change()


func configure_if_needed(
	year_duration_seconds: float,
	start_day_index: int,
	auto_advance: bool,
	initially_paused: bool
) -> bool:
	## Initialize exactly once. Later stages cannot reconfigure or reset a clock
	## that is already running; they consume snapshot() instead.
	if _initialized:
		return false
	if not _valid_year_duration(year_duration_seconds):
		return false
	if not _valid_day_index(start_day_index):
		return false

	_initialized = true
	_elapsed_seconds = 0.0
	_year_duration_seconds = _clamped_year_duration(year_duration_seconds)
	_start_day_index = start_day_index
	_auto_advance = auto_advance
	_paused = initially_paused
	_source = &"internal_clock" if _auto_advance else &"manual_hold"
	_publish_change()
	return true


func snapshot() -> Dictionary:
	var calendar_position := _calendar_position()
	return {
		"initialized": _initialized,
		"elapsed_seconds": _elapsed_seconds,
		"day_index": calendar_position.x,
		"minute_of_day": calendar_position.y,
		"year_duration_seconds": _year_duration_seconds,
		"start_day_index": _start_day_index,
		"auto_advance": _auto_advance,
		"paused": _paused,
		"source": String(_source),
		"year_progress": _year_progress(),
		"revision": _revision,
	}


func set_paused(value: bool) -> void:
	var initialized_now := _ensure_initialized()
	if _paused == value:
		if initialized_now:
			_publish_change()
		return
	_paused = value
	_publish_change()


func set_auto_advance(value: bool) -> void:
	var initialized_now := _ensure_initialized()
	if _auto_advance == value:
		if initialized_now:
			_publish_change()
		return
	_auto_advance = value
	if _auto_advance:
		_source = &"internal_clock"
	elif _source == &"internal_clock":
		_source = &"manual_hold"
	_publish_change()


func set_date(
	day_index: int,
	minute_of_day: int = 0,
	source: StringName = &"external_date"
) -> bool:
	## Set an absolute non-leap calendar date and hold it until auto-advance is
	## explicitly enabled again. This preserves the production external-date
	## handoff semantics.
	if not _valid_day_index(day_index) or not _valid_minute(minute_of_day):
		return false
	_ensure_initialized()

	var relative_day: int = posmod(day_index - _start_day_index, DAY_COUNT)
	var relative_minute: int = relative_day * MINUTES_PER_DAY + minute_of_day
	_elapsed_seconds = (
		float(relative_minute)
		/ float(YEAR_MINUTE_COUNT)
		* _year_duration_seconds
	)
	_auto_advance = false
	_source = source if not String(source).is_empty() else &"external_date"
	_publish_change()
	return true


func set_year_duration(year_duration_seconds: float) -> bool:
	## Preserve the exact year phase while changing playback speed.
	if not _valid_year_duration(year_duration_seconds):
		return false
	var initialized_now := _ensure_initialized()
	var next_duration := _clamped_year_duration(year_duration_seconds)
	if is_equal_approx(_year_duration_seconds, next_duration):
		if initialized_now:
			_publish_change()
		return true
	var preserved_progress := _year_progress()
	_year_duration_seconds = next_duration
	_elapsed_seconds = preserved_progress * _year_duration_seconds
	_publish_change()
	return true


func set_start_day_index(
	start_day_index: int,
	reset_timeline: bool = false
) -> bool:
	## With reset_timeline=false, changing the cycle origin preserves the
	## absolute displayed date and minute. With true, the new origin is shown at
	## midnight immediately.
	if not _valid_day_index(start_day_index):
		return false
	var initialized_now := _ensure_initialized()

	if reset_timeline:
		_start_day_index = start_day_index
		reset()
		return true

	var current_position := _calendar_position()
	if _start_day_index == start_day_index:
		if initialized_now:
			_publish_change()
		return true
	_start_day_index = start_day_index
	var relative_day: int = posmod(
		current_position.x - _start_day_index,
		DAY_COUNT
	)
	var relative_minute: int = (
		relative_day * MINUTES_PER_DAY + current_position.y
	)
	_elapsed_seconds = (
		float(relative_minute)
		/ float(YEAR_MINUTE_COUNT)
		* _year_duration_seconds
	)
	_publish_change()
	return true


func reset() -> void:
	## Reset only calendar position. Pause and auto-advance modes are preserved.
	_ensure_initialized()
	_elapsed_seconds = 0.0
	_source = &"internal_clock" if _auto_advance else &"manual_hold"
	_publish_change()


func _ensure_initialized() -> bool:
	if _initialized:
		return false
	_initialized = true
	_elapsed_seconds = 0.0
	_year_duration_seconds = DEFAULT_YEAR_DURATION_SECONDS
	_start_day_index = DEFAULT_START_DAY_INDEX
	_auto_advance = true
	_paused = false
	_source = &"internal_clock"
	return true


func _publish_change() -> void:
	_revision += 1
	timeline_changed.emit(snapshot())


func _year_progress() -> float:
	if not _initialized or _year_duration_seconds <= 0.0:
		return 0.0
	return clampf(
		_elapsed_seconds / _year_duration_seconds,
		0.0,
		0.999999999
	)


func _calendar_position() -> Vector2i:
	# set_date() starts with an exact integer model minute, but the round trip
	# through elapsed seconds can land a few ulps below that minute. Snap only
	# those near-integer values so midnight never reconstructs as 23:59.
	var relative_model_minute_float := (
		_year_progress() * float(YEAR_MINUTE_COUNT)
	)
	var nearest_model_minute := roundi(relative_model_minute_float)
	if absf(
		relative_model_minute_float - float(nearest_model_minute)
	) <= CALENDAR_MINUTE_SNAP_EPSILON:
		relative_model_minute_float = float(nearest_model_minute)
	var relative_model_minute := mini(
		floori(relative_model_minute_float),
		YEAR_MINUTE_COUNT - 1
	)
	var relative_day: int = relative_model_minute / MINUTES_PER_DAY
	return Vector2i(
		posmod(_start_day_index + relative_day, DAY_COUNT),
		relative_model_minute % MINUTES_PER_DAY
	)


func _valid_year_duration(value: float) -> bool:
	return is_finite(value) and value > 0.0


func _clamped_year_duration(value: float) -> float:
	return clampf(
		value,
		MIN_YEAR_DURATION_SECONDS,
		MAX_YEAR_DURATION_SECONDS
	)


func _valid_day_index(value: int) -> bool:
	return value >= 0 and value < DAY_COUNT


func _valid_minute(value: int) -> bool:
	return value >= 0 and value < MINUTES_PER_DAY
