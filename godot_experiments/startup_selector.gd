extends Control

const DUAL_STAGE_HOST_SCENE := preload("res://dual_stage_host.tscn")
const SCENES: Array[Dictionary] = [
	{"title": "Mount Shasta", "comment": "snowmelt", "path": "res://scene_1.tscn"},
	{"title": "McCloud-Pit Rivers", "comment": "upper volcanic watershed", "path": "res://scene_2.tscn"},
	{"title": "Cottonwood Creek", "comment": "major undammed west-side tributary", "path": "res://scene_3.tscn"},
	{"title": "Mill Creek", "comment": "east-side mountain tributary", "path": "res://scene_4.tscn"},
	{"title": "Feather River", "comment": "largest Sacramento tributary", "path": "res://scene_5.tscn"},
	{"title": "American River", "comment": "final major tributary at Sacramento", "path": "res://scene_6.tscn"},
	{"title": "Delta", "comment": "tidal action", "path": "res://scene_7.tscn"},
]

var _stage_a_picker: OptionButton
var _stage_b_picker: OptionButton
var _dual_launch_button: Button
var _validation_label: Label


func _ready() -> void:
	get_tree().set_auto_accept_quit(true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_window().title = "Water Council"
	_build_ui()
	_launch_from_command_line.call_deferred()


func _launch_from_command_line() -> void:
	# The fleet controller passes one-based scene numbers after Godot's `--`.
	# Examples: --stages=1 or --stages=1,2
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--stages="):
			continue
		var values := argument.trim_prefix("--stages=").split(",", false)
		if values.is_empty() or values.size() > 2:
			push_error("--stages expects one or two scene numbers from 1 to 7.")
			return

		var indices: Array[int] = []
		for value: String in values:
			if not value.is_valid_int():
				push_error("Invalid stage number: %s" % value)
				return
			var index := value.to_int() - 1
			if index < 0 or index >= SCENES.size():
				push_error("Stage number must be between 1 and %d." % SCENES.size())
				return
			indices.append(index)

		if indices.size() == 1:
			_load_single_scene(indices[0])
			return
		if indices[0] == indices[1]:
			push_error("The two displays must use different stages.")
			return

		_stage_a_picker.select(indices[0])
		_stage_b_picker.select(indices[1])
		_refresh_selection_state()
		_launch_dual_stages()
		return


func _unhandled_input(event: InputEvent) -> void:
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	var keycode: Key = key_event.keycode
	if keycode >= KEY_1 and keycode < KEY_1 + SCENES.size():
		_load_single_scene(int(keycode - KEY_1))
	elif keycode == KEY_ENTER:
		_launch_dual_stages()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("#043832")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(980.0, 600.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.015, 0.075, 0.070, 0.96)
	panel_style.border_color = Color(0.29, 0.69, 0.88, 0.55)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 54.0
	panel_style.content_margin_top = 42.0
	panel_style.content_margin_right = 54.0
	panel_style.content_margin_bottom = 42.0
	panel.add_theme_stylebox_override(&"panel", panel_style)
	center.add_child(panel)

	var content := VBoxContainer.new()
	content.add_theme_constant_override(&"separation", 22)
	panel.add_child(content)

	var title := Label.new()
	title.text = "Water Council"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 48)
	title.add_theme_color_override(&"font_color", Color("4ab0e1"))
	content.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Choose two different river stages for the two displays."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override(&"font_size", 22)
	subtitle.modulate = Color(0.86, 0.92, 0.93, 1.0)
	content.add_child(subtitle)

	var choices := HBoxContainer.new()
	choices.add_theme_constant_override(&"separation", 30)
	choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(choices)

	_stage_a_picker = _build_stage_picker("DISPLAY A", choices)
	_stage_b_picker = _build_stage_picker("DISPLAY B", choices)
	_stage_a_picker.select(0)
	_stage_b_picker.select(1)
	_stage_a_picker.item_selected.connect(_on_selection_changed)
	_stage_b_picker.item_selected.connect(_on_selection_changed)

	_validation_label = Label.new()
	_validation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_validation_label.add_theme_font_size_override(&"font_size", 18)
	_validation_label.custom_minimum_size.y = 30.0
	content.add_child(_validation_label)

	var launch_row := HBoxContainer.new()
	launch_row.alignment = BoxContainer.ALIGNMENT_CENTER
	launch_row.add_theme_constant_override(&"separation", 18)
	content.add_child(launch_row)

	var single_launch_button := Button.new()
	single_launch_button.text = "Launch Display A Only"
	single_launch_button.custom_minimum_size = Vector2(300.0, 58.0)
	single_launch_button.add_theme_font_size_override(&"font_size", 20)
	single_launch_button.pressed.connect(_launch_stage_a_only)
	launch_row.add_child(single_launch_button)

	_dual_launch_button = Button.new()
	_dual_launch_button.text = "Launch Two Displays"
	_dual_launch_button.custom_minimum_size = Vector2(360.0, 66.0)
	_dual_launch_button.add_theme_font_size_override(&"font_size", 23)
	_dual_launch_button.pressed.connect(_launch_dual_stages)
	launch_row.add_child(_dual_launch_button)

	var help := Label.new()
	help.text = (
		"On one monitor, both stages appear in a side-by-side preview. "
		+ "Number keys 1–7 still launch a single stage directly."
	)
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override(&"font_size", 17)
	help.modulate = Color(0.67, 0.76, 0.77, 1.0)
	content.add_child(help)

	_refresh_selection_state()


func _build_stage_picker(caption: String, parent: Container) -> OptionButton:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override(&"separation", 10)
	parent.add_child(column)

	var label := Label.new()
	label.text = caption
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", 20)
	label.add_theme_color_override(&"font_color", Color("4ab0e1"))
	column.add_child(label)

	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(410.0, 58.0)
	picker.add_theme_font_size_override(&"font_size", 21)
	for scene: Dictionary in SCENES:
		picker.add_item(String(scene["title"]))
	column.add_child(picker)
	return picker


func _on_selection_changed(_selected_index: int) -> void:
	_refresh_selection_state()


func _refresh_selection_state() -> void:
	if (
		_stage_a_picker == null
		or _stage_b_picker == null
		or _dual_launch_button == null
		or _validation_label == null
	):
		return
	var duplicate := _stage_a_picker.selected == _stage_b_picker.selected
	_dual_launch_button.disabled = duplicate
	if duplicate:
		_validation_label.text = "Display A and Display B must use different stages."
		_validation_label.modulate = Color(1.0, 0.54, 0.42, 1.0)
	else:
		_validation_label.text = "Ready for two displays."
		_validation_label.modulate = Color(0.41, 0.87, 0.60, 1.0)


func _launch_stage_a_only() -> void:
	_load_single_scene(_stage_a_picker.selected)


func _launch_dual_stages() -> void:
	if _stage_a_picker == null or _stage_b_picker == null:
		return
	var stage_a_index := _stage_a_picker.selected
	var stage_b_index := _stage_b_picker.selected
	if (
		stage_a_index < 0
		or stage_b_index < 0
		or stage_a_index >= SCENES.size()
		or stage_b_index >= SCENES.size()
		or stage_a_index == stage_b_index
	):
		_refresh_selection_state()
		return

	var host := DUAL_STAGE_HOST_SCENE.instantiate()
	if host == null or not bool(host.call(
		&"configure",
		SCENES[stage_a_index].duplicate(true),
		SCENES[stage_b_index].duplicate(true),
	)):
		if host != null:
			host.queue_free()
		_validation_label.text = "The two-display host could not be configured."
		_validation_label.modulate = Color(1.0, 0.54, 0.42, 1.0)
		return

	var tree := get_tree()
	var previous_scene := tree.current_scene
	tree.root.add_child(host)
	tree.current_scene = host
	if previous_scene != null and previous_scene != host:
		previous_scene.queue_free()


func _load_single_scene(index: int) -> void:
	if index < 0 or index >= SCENES.size():
		return
	get_tree().set_auto_accept_quit(true)
	get_tree().change_scene_to_file(String(SCENES[index]["path"]))
