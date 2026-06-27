extends Sprite2D

var focused_panel = 0
var panels = []

func _ready():
	set_process_input(true)
	panels = [$ColorRect_Slow, $ColorRect_Fast]
	panels[0].focused = true
	panels[1].focused = false

func _input(event: InputEvent):
	if event is InputEventKey and event.pressed and not event.echo:
		var key_map = {
			KEY_0: 0, KEY_1: 1, KEY_2: 2, KEY_3: 3, KEY_4: 4,
			KEY_5: 5, KEY_6: 6, KEY_7: 7, KEY_8: 8, KEY_9: 9
		}
		if event.keycode in key_map:
			panels[focused_panel].set_speed(key_map[event.keycode])
		if event.keycode == KEY_TAB:
			panels[focused_panel].focused = false
			focused_panel = 1 - focused_panel
			panels[focused_panel].focused = true
