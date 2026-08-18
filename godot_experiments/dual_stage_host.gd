extends Node

const STAGE_CONTENT_SIZE := Vector2i(1920, 1080)
const ALLOWED_STAGE_PATHS: Array[String] = [
	"res://scene_1.tscn",
	"res://scene_2.tscn",
	"res://scene_3.tscn",
	"res://scene_4.tscn",
	"res://scene_5.tscn",
	"res://scene_6.tscn",
	"res://scene_7.tscn",
]
const DEFAULT_STAGE_A := {
	"title": "Mount Shasta",
	"path": "res://scene_1.tscn",
}
const DEFAULT_STAGE_B := {
	"title": "McCloud-Pit Rivers",
	"path": "res://scene_2.tscn",
}

var _stage_a_definition: Dictionary = {}
var _stage_b_definition: Dictionary = {}
var _configured: bool = false
var _secondary_window: Window
var _preview_viewports: Array[SubViewport] = []
var _preview_frames: Array[PanelContainer] = []
var _preview_labels: Array[Label] = []
var _preview_active_index: int = 0
var _returning_to_selector: bool = false


func configure(stage_a: Dictionary, stage_b: Dictionary) -> bool:
	if is_inside_tree() or not _valid_stage_definition(stage_a):
		return false
	if not _valid_stage_definition(stage_b):
		return false
	if String(stage_a["path"]) == String(stage_b["path"]):
		return false
	_stage_a_definition = stage_a.duplicate(true)
	_stage_b_definition = stage_b.duplicate(true)
	_configured = true
	return true


func _ready() -> void:
	if not _configured:
		# Direct scene launches cannot use configure(), whose pre-tree guard protects
		# selector handoff from mutating a live host. Install the validated defaults
		# locally before any stage is instantiated.
		_stage_a_definition = DEFAULT_STAGE_A.duplicate(true)
		_stage_b_definition = DEFAULT_STAGE_B.duplicate(true)
		_configured = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().set_auto_accept_quit(false)

	var root_window := get_window()
	root_window.close_requested.connect(_request_return_to_selector)
	root_window.window_input.connect(_on_window_input.bind(root_window))

	var stage_a := _instantiate_stage(_stage_a_definition)
	var stage_b := _instantiate_stage(_stage_b_definition)
	if stage_a == null or stage_b == null:
		if stage_a != null:
			stage_a.queue_free()
		if stage_b != null:
			stage_b.queue_free()
		push_error("DualStageHost could not instantiate both selected stages.")
		_request_return_to_selector()
		return

	var screen_count := maxi(DisplayServer.get_screen_count(), 1)
	var screen_a := _current_or_primary_screen(screen_count)
	if screen_count >= 2:
		var screen_b := _first_other_screen(screen_a, screen_count)
		_build_native_windows(stage_a, stage_b, screen_a, screen_b)
	else:
		_build_single_monitor_preview(stage_a, stage_b, screen_a)


func _input(event: InputEvent) -> void:
	if _is_escape_press(event):
		get_viewport().set_input_as_handled()
		_request_return_to_selector()


func _unhandled_input(event: InputEvent) -> void:
	if _preview_viewports.is_empty() or _is_escape_press(event):
		return
	var key_event := event as InputEventKey
	if key_event == null:
		return
	_preview_viewports[_preview_active_index].push_unhandled_input(event, false)
	get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	if get_tree() != null:
		get_tree().set_auto_accept_quit(true)


func _valid_stage_definition(definition: Dictionary) -> bool:
	if not definition.has("path"):
		return false
	var path := String(definition["path"])
	return ALLOWED_STAGE_PATHS.has(path) and ResourceLoader.exists(path, "PackedScene")


func _instantiate_stage(definition: Dictionary) -> Node:
	var packed := load(String(definition["path"])) as PackedScene
	return packed.instantiate() if packed != null else null


func _build_native_windows(
	stage_a: Node,
	stage_b: Node,
	screen_a: int,
	screen_b: int
) -> void:
	var root_window := get_window()
	_configure_native_window(root_window, screen_a)
	root_window.title = "Water Council — A — %s" % _stage_title(_stage_a_definition)
	add_child(stage_a)

	_secondary_window = Window.new()
	_secondary_window.name = "StageBWindow"
	_secondary_window.title = (
		"Water Council — B — %s" % _stage_title(_stage_b_definition)
	)
	_secondary_window.force_native = true
	_secondary_window.transient = false
	_secondary_window.exclusive = false
	_secondary_window.visible = false
	add_child(_secondary_window)
	_configure_native_window(_secondary_window, screen_b)
	_secondary_window.close_requested.connect(_request_return_to_selector)
	_secondary_window.window_input.connect(
		_on_window_input.bind(_secondary_window)
	)
	_secondary_window.add_child(stage_b)
	_secondary_window.show()


func _build_single_monitor_preview(
	stage_a: Node,
	stage_b: Node,
	screen_index: int
) -> void:
	var root_window := get_window()
	_configure_native_window(root_window, screen_index)
	root_window.title = "Water Council — Two-stage preview"

	var stage_nodes: Array[Node] = [stage_a, stage_b]
	for stage_node: Node in stage_nodes:
		var viewport := SubViewport.new()
		viewport.size = STAGE_CONTENT_SIZE
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		viewport.world_2d = World2D.new()
		add_child(viewport)
		viewport.add_child(stage_node)
		_preview_viewports.append(viewport)

	var background := ColorRect.new()
	background.color = Color("05090d")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override(&"margin_left", 18)
	margin.add_theme_constant_override(&"margin_top", 18)
	margin.add_theme_constant_override(&"margin_right", 18)
	margin.add_theme_constant_override(&"margin_bottom", 18)
	add_child(margin)

	var vertical_layout := VBoxContainer.new()
	vertical_layout.add_theme_constant_override(&"separation", 12)
	margin.add_child(vertical_layout)

	var instruction := Label.new()
	instruction.text = (
		"Single-monitor preview · click a stage to direct its local controls · "
		+ "Esc returns to the selector"
	)
	instruction.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	instruction.add_theme_font_size_override(&"font_size", 22)
	instruction.add_theme_color_override(&"font_color", Color("4ab0e1"))
	vertical_layout.add_child(instruction)

	var stage_row := HBoxContainer.new()
	stage_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage_row.add_theme_constant_override(&"separation", 14)
	vertical_layout.add_child(stage_row)

	var definitions: Array[Dictionary] = [
		_stage_a_definition,
		_stage_b_definition,
	]
	for stage_index in range(_preview_viewports.size()):
		var frame := PanelContainer.new()
		frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
		frame.mouse_filter = Control.MOUSE_FILTER_STOP
		frame.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		frame.gui_input.connect(_on_preview_frame_input.bind(stage_index))
		stage_row.add_child(frame)
		_preview_frames.append(frame)

		var frame_content := VBoxContainer.new()
		frame_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(frame_content)

		var stage_label := Label.new()
		stage_label.text = "%s · %s" % [
			"A" if stage_index == 0 else "B",
			_stage_title(definitions[stage_index]),
		]
		stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		stage_label.add_theme_font_size_override(&"font_size", 20)
		stage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame_content.add_child(stage_label)
		_preview_labels.append(stage_label)

		var texture_rect := TextureRect.new()
		texture_rect.texture = _preview_viewports[stage_index].get_texture()
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame_content.add_child(texture_rect)

	_set_preview_active(0)


func _configure_native_window(window: Window, screen_index: int) -> void:
	window.mode = Window.MODE_WINDOWED
	window.borderless = true
	window.unresizable = true
	window.initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
	window.content_scale_size = STAGE_CONTENT_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.current_screen = screen_index
	window.position = DisplayServer.screen_get_position(screen_index)
	var screen_size := DisplayServer.screen_get_size(screen_index)
	if screen_size.x <= 0 or screen_size.y <= 0:
		screen_size = STAGE_CONTENT_SIZE
	window.size = screen_size


func _current_or_primary_screen(screen_count: int) -> int:
	var current := get_window().current_screen
	if current >= 0 and current < screen_count:
		return current
	var primary := DisplayServer.get_primary_screen()
	return primary if primary >= 0 and primary < screen_count else 0


func _first_other_screen(screen_a: int, screen_count: int) -> int:
	for screen_index in range(screen_count):
		if screen_index != screen_a:
			return screen_index
	return screen_a


func _stage_title(definition: Dictionary) -> String:
	var title := String(definition.get("title", "")).strip_edges()
	if not title.is_empty():
		return title
	return String(definition.get("path", "Stage")).get_file().get_basename()


func _on_window_input(event: InputEvent, window: Window) -> void:
	if not _is_escape_press(event):
		return
	window.set_input_as_handled()
	_request_return_to_selector()


func _on_preview_frame_input(event: InputEvent, stage_index: int) -> void:
	var mouse_event := event as InputEventMouseButton
	if (
		mouse_event == null
		or not mouse_event.pressed
		or mouse_event.button_index != MOUSE_BUTTON_LEFT
	):
		return
	_set_preview_active(stage_index)
	get_viewport().set_input_as_handled()


func _set_preview_active(stage_index: int) -> void:
	if stage_index < 0 or stage_index >= _preview_frames.size():
		return
	_preview_active_index = stage_index
	for index in range(_preview_frames.size()):
		var active := index == _preview_active_index
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.0, 0.0, 0.0, 1.0)
		style.border_color = (
			Color("4ab0e1") if active else Color(0.16, 0.30, 0.34, 1.0)
		)
		style.set_border_width_all(4 if active else 1)
		style.set_corner_radius_all(8)
		style.content_margin_left = 8.0
		style.content_margin_top = 8.0
		style.content_margin_right = 8.0
		style.content_margin_bottom = 8.0
		_preview_frames[index].add_theme_stylebox_override(&"panel", style)
		_preview_labels[index].modulate = (
			Color.WHITE if active else Color(0.55, 0.62, 0.64, 1.0)
		)


func _is_escape_press(event: InputEvent) -> bool:
	var key_event := event as InputEventKey
	return (
		key_event != null
		and key_event.pressed
		and not key_event.echo
		and key_event.keycode == KEY_ESCAPE
	)


func _request_return_to_selector() -> void:
	if _returning_to_selector:
		return
	_returning_to_selector = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _secondary_window != null and is_instance_valid(_secondary_window):
		_secondary_window.hide()
	call_deferred(&"_return_to_selector")


func _return_to_selector() -> void:
	get_tree().set_auto_accept_quit(true)
	get_window().title = "Water Council"
	var error := get_tree().change_scene_to_file("res://startup_selector.tscn")
	if error != OK:
		_returning_to_selector = false
		push_error("Could not return to startup selector: %s" % error_string(error))
