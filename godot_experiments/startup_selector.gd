extends Control

const SCENES: Array[Dictionary] = [
	{"title": "Mount Shasta", "comment": "snowmelt", "path": "res://scene_1.tscn"},
	{"title": "McCloud-Pit Rivers", "comment": "upper volcanic watershed", "path": "res://scene_2.tscn"},
	{"title": "Cottonwood Creek", "comment": "major undammed west-side tributary", "path": "res://scene_3.tscn"},
	{"title": "Mill Creek", "comment": "east-side mountain tributary", "path": "res://scene_4.tscn"},
	{"title": "Feather River", "comment": "largest Sacramento tributary", "path": "res://scene_5.tscn"},
	{"title": "American River", "comment": "final major tributary at Sacramento", "path": "res://scene_6.tscn"},
	{"title": "Sacramento-San Joaquin Delta", "comment": "tidal action", "path": "res://scene_7.tscn"},
]

func _ready():
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()

func _unhandled_input(event: InputEvent):
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return

	var keycode: Key = key_event.keycode
	if keycode >= KEY_1 and keycode < KEY_1 + SCENES.size():
		_load_scene(int(keycode - KEY_1))

func _build_ui():
	var background := ColorRect.new()
	background.color = Color("#043832")
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var panel := VBoxContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_top = 0.5
	panel.anchor_right = 1.0
	panel.anchor_bottom = 0.5
	panel.offset_left = -980.0
	panel.offset_top = -304.0
	panel.offset_right = -120.0
	panel.offset_bottom = 304.0
	panel.add_theme_constant_override("separation", 10)
	add_child(panel)

	var title := Label.new()
	title.text = "Select Scene"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	panel.add_child(title)

	for index in range(SCENES.size()):
		var button := Button.new()
		button.text = ""
		button.custom_minimum_size = Vector2(860, 62)
		button.pressed.connect(_load_scene.bind(index))
		panel.add_child(button)

		var labels := VBoxContainer.new()
		labels.set_anchors_preset(Control.PRESET_FULL_RECT)
		labels.offset_left = 18
		labels.offset_top = 8
		labels.offset_right = -18
		labels.offset_bottom = -8
		labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_theme_constant_override("separation", 0)
		button.add_child(labels)

		var title_label := Label.new()
		title_label.text = SCENES[index]["title"]
		title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		title_label.add_theme_font_size_override("font_size", 23)
		title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(title_label)

		var comment_label := Label.new()
		comment_label.text = SCENES[index]["comment"]
		comment_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		comment_label.add_theme_font_size_override("font_size", 16)
		comment_label.modulate = Color(0.78, 0.84, 0.86, 1.0)
		comment_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(comment_label)

func _load_scene(index: int):
	if index < 0 or index >= SCENES.size():
		return

	get_tree().change_scene_to_file(SCENES[index]["path"])
