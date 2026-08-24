class_name BasinBudgetOverlay
extends Node2D

## Screen-space visualization of the basin budget and regime extractors.

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const FONT := preload("res://flow/assets/fonts/BarlowCondensed-Medium.ttf")

const BLUE := Color("4ab0e1")
const DODGER_BLUE := Color("1e90ff")
const WHITE := Color(1.0, 1.0, 1.0, 0.95)
const TYPE_ROTATION_RADIANS := -PI * 0.5
const HATCH_LINE_WIDTH_PIXELS := 3.0
const HATCH_GAP_PIXELS := 6.0
const HATCH_ALPHA := 0.33
const HATCH_PERIOD_PIXELS := HATCH_LINE_WIDTH_PIXELS + HATCH_GAP_PIXELS
const HATCH_AXIS_SCALE := 1.4142135623730951
const LABEL_HATCH_CLEARANCE_PIXELS := 6.0
const TIDE_FILL_LINE_WIDTH_PIXELS := 3.0
const TIDE_LINE_SPACING_PIXELS := 30.0
const TIDE_FIRST_LINE_Y := 30.0
const TIDE_VISIBLE_LINE_COUNT := 35
const TIDE_LINE_MIN_LENGTH_PIXELS := 40.8
const TIDE_LINE_MAX_LENGTH_PIXELS := 306.0
const KINSHIP_FLOOD_LABEL := "KINSHIP FLOODPLAIN"
const KINSHIP_FLOOD_LABEL_ANCHOR := Vector2(690.0, 860.0)
const KINSHIP_FLOOD_LABEL_FONT_SIZE := 34

var screen_id: StringName = &"screen"
var input_rate: float = 0.0
var extraction_fraction: float = 0.0
var remaining_rate: float = 0.0
var active_states: Array = []
var tide_series := PackedFloat32Array()
var tide_sample_position: float = 0.0
var tide_row_fraction: float = 0.0
var tide_history: Array[float] = []
var tide_history_row_index: int = -1
var render_tide: bool = true
var render_floodplain: bool = true
var render_budget: bool = true
var watershed_allocation_state: Dictionary = {}


func set_render_roles(
	p_render_tide: bool,
	p_render_floodplain: bool,
	p_render_budget: bool,
) -> void:
	render_tide = p_render_tide
	render_floodplain = p_render_floodplain
	render_budget = p_render_budget
	queue_redraw()


func configure(
	p_screen_id: StringName,
	p_input_rate: float,
	p_extraction_fraction: float,
	p_remaining_rate: float,
	p_active_states: Array,
	p_tide_series: PackedFloat32Array,
	p_tide_sample_position: float,
	p_watershed_allocation_state: Dictionary = {},
) -> void:
	screen_id = p_screen_id
	input_rate = clampf(p_input_rate, 0.0, 1.0)
	extraction_fraction = clampf(p_extraction_fraction, 0.0, 1.0)
	remaining_rate = clampf(p_remaining_rate, 0.0, 1.0)
	active_states = p_active_states.duplicate()
	watershed_allocation_state = p_watershed_allocation_state.duplicate(true)
	if render_tide:
		_update_tide_history(p_tide_series, p_tide_sample_position)
	queue_redraw()


func _draw() -> void:
	if screen_id == &"delta":
		if render_floodplain and _regime_active(0):
			_draw_floodplain(KINSHIP_FLOOD_LABEL, 0.25)
		elif (
			render_floodplain
			and float(watershed_allocation_state.get(
				"floodplain_fraction",
				0.0,
			)) > 0.000001
		):
			_draw_floodplain(
				"FLOODPLAIN",
				float(watershed_allocation_state["floodplain_fraction"]),
			)
		if render_tide:
			_draw_incoming_tide()
		if render_budget:
			_draw_budget_panel()


func _draw_floodplain(label: String, allocation_fraction: float) -> void:
	var flood_color := BLUE
	flood_color.a = HATCH_ALPHA
	var base_polygon := PackedVector2Array([
		Vector2(250.0, 330.0),
		Vector2(610.0, 245.0),
		Vector2(1050.0, 285.0),
		Vector2(1515.0, 510.0),
		Vector2(1600.0, 790.0),
		Vector2(1260.0, 970.0),
		Vector2(660.0, 920.0),
		Vector2(285.0, 715.0),
	])
	var center := Vector2.ZERO
	for vertex: Vector2 in base_polygon:
		center += vertex
	center /= float(base_polygon.size())
	var area_scale := clampf(
		sqrt(clampf(allocation_fraction, 0.0, 1.0) / 0.25),
		0.45,
		1.35,
	)
	var flood_polygon := PackedVector2Array()
	for vertex: Vector2 in base_polygon:
		flood_polygon.append(center + (vertex - center) * area_scale)
	_draw_hatched_polygon(
		flood_polygon,
		flood_color,
		_vertical_text_rect(
			KINSHIP_FLOOD_LABEL_ANCHOR,
			label,
			KINSHIP_FLOOD_LABEL_FONT_SIZE,
		),
	)
	_draw_vertical_text(
		KINSHIP_FLOOD_LABEL_ANCHOR,
		label,
		-1.0,
		KINSHIP_FLOOD_LABEL_FONT_SIZE,
		Color(BLUE, 0.92),
	)


func _draw_hatched_polygon(
	polygon: PackedVector2Array,
	color: Color,
	label_text_rect: Rect2,
) -> void:
	if polygon.size() < 3:
		return
	var hatch_color := color
	hatch_color.a = HATCH_ALPHA
	var minimum_sum := INF
	var maximum_sum := -INF
	for vertex: Vector2 in polygon:
		var diagonal_sum := vertex.x + vertex.y
		minimum_sum = minf(minimum_sum, diagonal_sum)
		maximum_sum = maxf(maximum_sum, diagonal_sum)
	var step := HATCH_PERIOD_PIXELS * HATCH_AXIS_SCALE
	var diagonal_sum := floorf(minimum_sum / step) * step
	while diagonal_sum <= maximum_sum + step:
		var intersections := PackedVector2Array()
		for vertex_index in range(polygon.size()):
			var start: Vector2 = polygon[vertex_index]
			var finish: Vector2 = polygon[(vertex_index + 1) % polygon.size()]
			var start_sum := start.x + start.y
			var finish_sum := finish.x + finish.y
			var sum_delta := finish_sum - start_sum
			if is_zero_approx(sum_delta):
				continue
			var edge_fraction := (diagonal_sum - start_sum) / sum_delta
			if edge_fraction >= 0.0 and edge_fraction < 1.0:
				intersections.append(start.lerp(finish, edge_fraction))
		if intersections.size() >= 2:
			var line_start := intersections[0]
			var line_finish := intersections[0]
			for intersection: Vector2 in intersections:
				if intersection.x < line_start.x:
					line_start = intersection
				if intersection.x > line_finish.x:
					line_finish = intersection
			_draw_capped_line_around_label(
				line_start,
				line_finish,
				hatch_color,
				HATCH_LINE_WIDTH_PIXELS,
				label_text_rect,
			)
		diagonal_sum += step


func _draw_capped_line_around_label(
	start: Vector2,
	finish: Vector2,
	color: Color,
	width: float,
	label_text_rect: Rect2,
) -> void:
	var exclusion := label_text_rect.grow(
		LABEL_HATCH_CLEARANCE_PIXELS + width * 0.5
	)
	var interval := _segment_rect_interval(start, finish, exclusion)
	if interval.x < 0.0:
		_draw_capped_line(start, finish, color, width)
		return
	if interval.x > 0.0001:
		_draw_capped_line(start, start.lerp(finish, interval.x), color, width)
	if interval.y < 0.9999:
		_draw_capped_line(start.lerp(finish, interval.y), finish, color, width)


func _segment_rect_interval(start: Vector2, finish: Vector2, rectangle: Rect2) -> Vector2:
	var enter := 0.0
	var exit := 1.0
	var delta := finish - start
	for axis in range(2):
		var start_value := start.x if axis == 0 else start.y
		var delta_value := delta.x if axis == 0 else delta.y
		var minimum := rectangle.position.x if axis == 0 else rectangle.position.y
		var maximum := rectangle.end.x if axis == 0 else rectangle.end.y
		if is_zero_approx(delta_value):
			if start_value < minimum or start_value > maximum:
				return Vector2(-1.0, -1.0)
			continue
		var first := (minimum - start_value) / delta_value
		var second := (maximum - start_value) / delta_value
		if first > second:
			var swap := first
			first = second
			second = swap
		enter = maxf(enter, first)
		exit = minf(exit, second)
		if enter >= exit:
			return Vector2(-1.0, -1.0)
	return Vector2(enter, exit)


func _draw_capped_line(
	start: Vector2,
	finish: Vector2,
	color: Color,
	width: float,
) -> void:
	draw_line(start, finish, color, width, true)
	var radius := width * 0.5
	draw_circle(start, radius, color, true)
	draw_circle(finish, radius, color, true)


func _draw_incoming_tide() -> void:
	if tide_series.is_empty() or tide_history.is_empty():
		return
	var migration_offset := tide_row_fraction * TIDE_LINE_SPACING_PIXELS
	for history_index in range(tide_history.size()):
		var line_y := (
			TIDE_FIRST_LINE_Y
			+ float(history_index) * TIDE_LINE_SPACING_PIXELS
			- migration_offset
		)
		_draw_tide_bar(float(tide_history[history_index]), line_y)
	var next_row_index := (tide_history_row_index + 1) % tide_series.size()
	_draw_tide_bar(
		float(tide_series[next_row_index]),
		STAGE_SIZE.y - migration_offset,
	)


func _draw_tide_bar(normalized_height: float, line_y: float) -> void:
	if line_y <= 0.0 or line_y >= STAGE_SIZE.y:
		return
	var line_length := lerpf(
		TIDE_LINE_MIN_LENGTH_PIXELS,
		TIDE_LINE_MAX_LENGTH_PIXELS,
		clampf(normalized_height, 0.0, 1.0),
	)
	draw_line(
		Vector2(STAGE_SIZE.x - line_length, line_y),
		Vector2(STAGE_SIZE.x, line_y),
		DODGER_BLUE,
		TIDE_FILL_LINE_WIDTH_PIXELS,
		false,
	)


func _update_tide_history(
	p_tide_series: PackedFloat32Array,
	p_tide_sample_position: float,
) -> void:
	if p_tide_series.is_empty():
		tide_series = PackedFloat32Array()
		tide_history.clear()
		tide_history_row_index = -1
		tide_row_fraction = 0.0
		return
	if tide_series.size() != p_tide_series.size():
		tide_series = p_tide_series.duplicate()
		tide_history.clear()
		tide_history_row_index = -1
	tide_sample_position = fposmod(
		p_tide_sample_position,
		float(tide_series.size()),
	)
	var current_row_index := floori(tide_sample_position)
	tide_row_fraction = tide_sample_position - floorf(tide_sample_position)
	if tide_history_row_index < 0:
		_rebuild_tide_history(current_row_index)
		return
	if current_row_index == tide_history_row_index:
		return
	var forward_rows := posmod(
		current_row_index - tide_history_row_index,
		tide_series.size(),
	)
	if forward_rows <= 0 or forward_rows > TIDE_VISIBLE_LINE_COUNT:
		_rebuild_tide_history(current_row_index)
		return
	for row_step in range(1, forward_rows + 1):
		if not tide_history.is_empty():
			tide_history.pop_front()
		var pushed_row_index := posmod(
			tide_history_row_index + row_step,
			tide_series.size(),
		)
		tide_history.push_back(float(tide_series[pushed_row_index]))
	tide_history_row_index = current_row_index


func _rebuild_tide_history(current_row_index: int) -> void:
	tide_history.clear()
	for history_offset in range(TIDE_VISIBLE_LINE_COUNT - 1, -1, -1):
		var row_index := posmod(
			current_row_index - history_offset,
			tide_series.size(),
		)
		tide_history.push_back(float(tide_series[row_index]))
	tide_history_row_index = current_row_index


func _draw_budget_panel() -> void:
	_draw_vertical_text(Vector2(1405.0, 205.0), "BASIN WATER BUDGET", -1.0, 24, BLUE)
	_draw_vertical_text(Vector2(1510.0, 205.0), "INPUT", -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1545.0, 205.0), "%5.1f%%" % (input_rate * 100.0), -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1640.0, 205.0), "TOTAL EXTRACTION", -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1675.0, 205.0), "%5.1f%%" % (extraction_fraction * 100.0), -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1770.0, 205.0), "DELTA REMAINDER", -1.0, 24, BLUE)
	_draw_vertical_text(Vector2(1805.0, 205.0), "%5.1f%%" % (remaining_rate * 100.0), -1.0, 24, BLUE)


func _draw_vertical_text(
	anchor: Vector2,
	text: String,
	width: float,
	font_size: int,
	color: Color,
) -> void:
	draw_set_transform(anchor, TYPE_ROTATION_RADIANS, Vector2.ONE)
	draw_string(
		FONT,
		Vector2.ZERO,
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		width,
		font_size,
		color,
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _vertical_text_rect(anchor: Vector2, text: String, font_size: int) -> Rect2:
	var text_width := FONT.get_string_size(
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size,
	).x
	var font_ascent := FONT.get_ascent(font_size)
	var font_descent := FONT.get_descent(font_size)
	return Rect2(
		anchor + Vector2(-font_ascent, -text_width),
		Vector2(font_ascent + font_descent, text_width),
	)


func _regime_active(index: int) -> bool:
	return index >= 0 and index < active_states.size() and bool(active_states[index])
