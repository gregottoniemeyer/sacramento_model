extends Node

## Focused regression test for the precipitation input and extraction budget.

const BasinBudgetModel := preload("res://flow/basin_budget.gd")

var _failures := PackedStringArray()


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var packed_scene := load("res://scene_7.tscn") as PackedScene
	_expect(packed_scene != null, "Delta production scene must load.")
	if packed_scene == null:
		_finish()
		return
	var screen := packed_scene.instantiate()
	add_child(screen)
	await _settle()
	var stage := screen.get_node_or_null("FlowModel2D") as GPUFlowStage2D
	_expect(stage != null, "Delta GPUFlowStage2D must instantiate.")
	if stage == null:
		_finish()
		return

	var summary := stage.runtime_summary()
	var extraction_breakdown := BasinBudgetModel.extraction_breakdown(
		[false, false, false, true, false, false, false]
	)
	_expect(
		String(extraction_breakdown[3].get("label", "")) == "DIVERT",
		"Water-project extraction must be named DIVERT in the Delta budget."
	)
	var divert_definition := {}
	for definition: Dictionary in BasinBudgetModel.extractor_definitions():
		if String(definition.get("element_id", "")) == "water_project_export":
			divert_definition = definition
			break
	_expect(
		String(divert_definition.get("label", "")) == "DIVERT",
		"The water-project extractor geometry must be labeled DIVERT."
	)
	_expect(
		Array(summary.get("active_regime_names", [])) == ["Kinship"],
		"A new process must open in Kinship by default."
	)
	_expect(
		bool(summary.get("debug_visible", false)),
		"Production stages must show active geometry by default."
	)
	_expect(
		int(summary.get("watershed_data_row_count", 0)) == 720,
		"Delta precipitation input must contain exactly 720 samples."
	)
	_expect(
		String(summary.get("basin_input_kind", ""))
		== "precipitation+snowmelt+humidity+fog",
		"Runtime must identify the new atmospheric basin input."
	)
	_expect(
		String(summary.get("basin_input_buffer_mode", ""))
		== "TRAILING_CYCLIC_RUNNING_AVERAGE"
		and is_equal_approx(
			float(summary.get("basin_input_running_average_days", 0.0)),
			30.0,
		)
		and int(summary.get("basin_input_running_average_sample_count", 0)) == 59
		and is_equal_approx(
			float(summary.get("basin_input_minimum_percent", 0.0)),
			2.0,
		)
		and bool(summary.get("basin_input_floor_applied_after_fog", false)),
		"Basin input must use 30-day hydrologic memory and a post-fog 2% floor."
	)
	for stage_id in [
		"shasta", "mccloud", "cottonwood", "mill_creek",
		"feather", "american", "delta",
	]:
		_expect(
			_count_runtime_rows(
				"res://flow/data/water_pipeline/%s_720.txt" % stage_id
			) == 720,
			"%s runtime input must contain 720 rows." % stage_id
		)

	stage.set_model_date_time("01/15-00:00")
	stage.set_active_regime_names(["Kinship"])
	await _settle()
	summary = stage.runtime_summary()
	var winter_input := float(summary.get("basin_input_rate", 0.0))
	_expect(winter_input >= 0.02, "Data-driven basin input must never fall below 2%.")
	_expect(
		is_zero_approx(float(summary.get("total_extraction_fraction", -1.0))),
		"Kinship must not extract basin water."
	)
	_expect(
		is_equal_approx(
			float(summary.get("basin_remaining_rate", -1.0)),
			winter_input,
		),
		"Kinship remainder must equal atmospheric input."
	)
	_expect(
		bool(summary.get("kinship_delta_floodplain_visible", false)),
		"Kinship must expose the Delta floodplain."
	)
	_expect(
		String(summary.get("kinship_delta_flood_render_style", ""))
		== "BORDERLESS_45_DEGREE_HATCH"
		and not bool(summary.get("kinship_delta_flood_solid_fill", true))
		and Color(summary.get("kinship_delta_flood_hatch_color", Color.TRANSPARENT))
		== Color("4ab0e1")
		and is_equal_approx(
			float(summary.get("kinship_delta_flood_hatch_angle_degrees", 0.0)),
			45.0,
		)
		and is_equal_approx(
			float(summary.get("kinship_delta_flood_hatch_line_width_pixels", 0.0)),
			3.0,
		)
		and is_equal_approx(
			float(summary.get("kinship_delta_flood_hatch_gap_pixels", 0.0)),
			6.0,
		)
		and is_equal_approx(
			float(summary.get("kinship_delta_flood_hatch_alpha", 0.0)),
			0.33,
		)
		and String(summary.get("kinship_delta_flood_hatch_line_caps", ""))
		== "ROUND"
		and is_equal_approx(
			float(summary.get(
				"kinship_delta_flood_label_hatch_clearance_pixels",
				0.0,
			)),
			6.0,
		),
		"Kinship floodwater must use the shared borderless, capped hatch style."
	)
	_expect(
		bool(summary.get("delta_tide_visible", false)),
		"Kinship must expose the incoming Delta tide."
	)
	_expect(
		String(summary.get("delta_tide_data_status", "")) == "READY"
		and int(summary.get("delta_tide_data_row_count", 0)) == 8760,
		"Delta must load all 8,760 hourly NOAA San Francisco tide samples."
	)
	_expect(
		String(summary.get("delta_tide_station_id", "")) == "9414290"
		and String(summary.get("delta_tide_animation_direction", ""))
		== "BOTTOM_TO_TOP",
		"Delta tide must identify the NOAA station and move forward bottom-to-top."
	)
	_expect(
		String(summary.get("delta_tide_render_style", ""))
		== "RIGHT_ANCHORED_CENTERED_96H_FIFO_HATCHED_AREA"
		and String(summary.get("delta_tide_area_shape", ""))
		== "RIGHT_ANCHORED_HOURLY_TIDE_POLYGON"
		and int(summary.get("delta_tide_series_sample_count", 0)) == 8760
		and int(summary.get("delta_tide_visible_line_count", 0)) == 120
		and is_equal_approx(float(summary.get("delta_tide_first_line_y", 0.0)), 4.5)
		and is_equal_approx(float(summary.get("delta_tide_last_line_y", 0.0)), 1075.5)
		and is_equal_approx(
			float(summary.get("delta_tide_current_sample_screen_y", 0.0)),
			540.0,
		)
		and bool(summary.get("delta_tide_current_sample_centered", false))
		and int(summary.get("delta_tide_history_capacity", 0)) == 97
		and String(summary.get("delta_tide_history_update_mode", ""))
		== "WRAPPED_LINEAR_HOURLY_FIFO_WINDOW"
		and String(summary.get("delta_tide_history_order", ""))
		== "OLDEST_TOP_NEWEST_BOTTOM"
		and is_equal_approx(
			float(summary.get("delta_tide_migration_pixels_per_sample", 0.0)),
			11.25,
		)
		and String(summary.get("delta_tide_bar_value_dimension", ""))
		== "POLYGON_LEFT_BOUNDARY_X_FROM_TIDE_HEIGHT"
		and Vector2(summary.get("delta_tide_line_length_range_pixels", Vector2.ZERO))
		== Vector2(40.8, 306.0)
		and is_equal_approx(
			float(summary.get("delta_tide_line_length_scale", 0.0)),
			0.34
		)
		and is_equal_approx(
			float(summary.get("delta_tide_line_length_reduction_percent", 0.0)),
			66.0
		)
		and String(summary.get("delta_tide_length_source", ""))
		== "NORMALIZED_TIDE_HEIGHT"
		and String(summary.get("delta_tide_origin_side", "")) == "RIGHT"
		and Color(summary.get("delta_tide_line_color", Color.TRANSPARENT))
		== Color.WHITE
		and String(summary.get("delta_tide_line_color_name", "")) == "WHITE"
		and is_equal_approx(float(summary.get("delta_tide_line_alpha", 0.0)), 0.20)
		and bool(summary.get("delta_budget_percentage_tabular_numerals", false))
		and String(summary.get("delta_budget_percentage_font_resource", ""))
		== "res://flow/assets/fonts/BarlowCondensed-Medium.ttf"
		and bool(summary.get("delta_tide_below_text", false))
		and not summary.has("delta_tide_colors_randomized")
		and not summary.has("delta_tide_color_random_seed")
		and not bool(summary.get("delta_tide_arrowheads", true))
		and is_equal_approx(
			float(summary.get("delta_tide_fill_line_width_pixels", 0.0)),
			3.0,
		)
		and is_equal_approx(
			float(summary.get("delta_tide_fill_line_gap_pixels", 0.0)),
			6.0,
		)
		and is_equal_approx(
			float(summary.get("delta_tide_fill_line_period_pixels", 0.0)),
			9.0,
		)
		and is_equal_approx(float(summary.get("delta_tide_window_hours", 0.0)), 96.0)
		and is_equal_approx(float(summary.get("delta_tide_window_past_hours", 0.0)), 48.0)
		and is_equal_approx(float(summary.get("delta_tide_window_future_hours", 0.0)), 48.0)
		and int(summary.get("delta_tide_window_sample_count", 0)) == 97
		and bool(summary.get("delta_tide_wrap_enabled", false))
		and String(summary.get("delta_tide_timeline_source", ""))
		== "SHARED_MODEL_YEAR_PROGRESS"
		and bool(summary.get("delta_tide_skips_screen_boundary_gridlines", false))
		and not bool(summary.get("delta_tide_boundary_visible", true))
		and not bool(summary.get("delta_tide_label_visible", true)),
		"Delta tide must draw a wrapped, right-anchored centered 96-hour white-hatched FIFO area."
	)
	_expect(
		is_zero_approx(float(summary.get("interaction_count_uniform", -1.0)))
		and int(summary.get("interaction_overlay_visible_count", -1)) == 0
		and not bool(summary.get("reservoir_overlay_visible", true)),
		"Kinship must remove reservoirs, drains, and obstacle geometry."
	)
	var tide_overlay := stage.get_node_or_null("DeltaTideOverlay")
	_expect(tide_overlay != null, "Delta must expose its FIFO tide overlay.")
	if tide_overlay != null:
		var percentage_font := tide_overlay.get("_tabular_font") as FontVariation
		var tabular_tag := TextServerManager.get_primary_interface().name_to_tag(
			"tnum"
		)
		_expect(
			percentage_font != null
			and int(percentage_font.opentype_features.get(tabular_tag, 0)) == 1,
			"Delta budget percentages must use tabular numerals."
		)
		var history_before := Array(tide_overlay.get("tide_fifo_values")).duplicate()
		var tide_polygon: PackedVector2Array = tide_overlay.call(&"_tide_area_polygon")
		_expect(
			tide_polygon.size() == 99
			and tide_polygon[0] == Vector2(1920.0, 0.0)
			and tide_polygon[98] == Vector2(1920.0, 1080.0)
			and is_equal_approx(tide_polygon[49].y, 540.0)
			and tide_polygon[49].x < 1920.0,
			"The tide area must anchor to the right edge with its live profile on the left."
		)
		stage.set_model_date_time("01/15-01:00")
		await _settle()
		var history_after := Array(tide_overlay.get("tide_fifo_values")).duplicate()
		_expect(
			history_before.size() == 97 and history_after.size() == 97,
			"The centered tide FIFO must retain exactly 97 hourly boundary values."
		)
		if history_before.size() == 97 and history_after.size() == 97:
			for history_index in range(96):
				_expect(
					is_equal_approx(
						float(history_before[history_index + 1]),
						float(history_after[history_index]),
					),
					"One model hour must shift the wrapped FIFO by exactly one hourly sample."
				)
		stage.set_model_date_time("06/30-23:00")
		await _settle()
		var year_end_window := Array(tide_overlay.get("tide_fifo_values")).duplicate()
		stage.set_model_date_time("07/01-00:00")
		await _settle()
		var year_start_window := Array(tide_overlay.get("tide_fifo_values")).duplicate()
		_expect(
			year_end_window.size() == 97 and year_start_window.size() == 97,
			"The tide FIFO must remain populated across the annual boundary."
		)
		if year_end_window.size() == 97 and year_start_window.size() == 97:
			for history_index in range(96):
				_expect(
					is_equal_approx(
						float(year_end_window[history_index + 1]),
						float(year_start_window[history_index]),
					),
					"The hourly tide FIFO must wrap without a year-end gap."
				)
	_expect(
		is_equal_approx(
			float(summary.get("overlay_text_rotation_degrees", 0.0)),
			-90.0,
		),
		"Every basin-overlay text element must rotate -90 degrees."
	)

	stage.set_active_regime_names(["Ranch", "Gold Rush", "Tech"])
	await _settle()
	summary = stage.runtime_summary()
	_expect(
		bool(summary.get("delta_tide_visible", false))
		and bool(summary.get("delta_tide_visible_in_all_regimes", false))
		and not bool(summary.get("kinship_delta_floodplain_visible", true)),
		"Delta tide must remain visible in extractive regimes without the Kinship floodplain."
	)
	_expect(
		is_equal_approx(float(summary.get("total_extraction_fraction", 0.0)), 1.0),
		"Agriculture + Gold Rush + Tech must reach 100% extraction."
	)
	_expect(
		is_zero_approx(float(summary.get("basin_remaining_rate", -1.0))),
		"A 100% extraction budget must leave no modeled Delta remainder."
	)
	_expect(
		int(summary.get("active_regime_extractor_count", 0)) == 5,
		"Ranch + Gold Rush + Tech must activate two fields, one mine, and two data centers."
	)
	_expect(
		String(summary.get("field_shape", "")) == "rectangle"
		and String(summary.get("data_center_shape", "")) == "rectangle",
		"Fields and data centers must use rectangle geometry."
	)
	_expect(
		is_equal_approx(float(summary.get("extractor_hatch_angle_degrees", 0.0)), 45.0)
		and is_equal_approx(float(summary.get("extractor_hatch_line_width_pixels", 0.0)), 3.0)
		and is_equal_approx(float(summary.get("extractor_hatch_gap_pixels", 0.0)), 6.0),
		"Extractor hatching must be 45 degrees with 3 px strokes and 6 px gaps."
	)
	_expect(
		is_equal_approx(float(summary.get("extractor_hatch_max_alpha", 0.0)), 0.33)
		and is_equal_approx(float(summary.get("geometry_hatch_alpha", 0.0)), 0.33)
		and Color(summary.get("field_hatch_color", Color.TRANSPARENT))
		== Color("6fbf73")
		and String(summary.get("geometry_hatch_alpha_mode", "")) == "FIXED_UNIFORM"
		and String(summary.get("repeller_display_term", "")) == "CITY"
		and String(summary.get("geometry_label_background", ""))
		== "TRANSPARENT_HATCH_KNOCKOUT"
		and is_equal_approx(
			float(summary.get("geometry_label_hatch_clearance_pixels", 0.0)),
			6.0,
		),
		"Geometry hatches must use green fields, share 33% alpha, and clear six pixels around labels."
	)
	_expect(
		bool(summary.get("geometry_below_water", false)),
		"Field and extractor graphics must render below the water layer."
	)
	_expect(
		String(summary.get("delta_budget_panel_background", "")) == "TRANSPARENT"
		and is_zero_approx(float(summary.get("delta_budget_panel_background_alpha", -1.0))),
		"The Delta extraction legend must have a clear background."
	)
	_expect(
		not bool(summary.get("geometry_outline_borders", true))
		and String(summary.get("geometry_hatch_line_caps", "")) == "ROUND",
		"Active geometry must use capped hatching with no outline border."
	)
	_expect(
		bool(summary.get("field_bank_connected", false))
		and bool(summary.get("field_water_withdrawal_enabled", false))
		and int(summary.get("interaction_overlay_visible_count", 0)) >= 5,
		"Active extractors must be visible bank-connected water withdrawals."
	)
	for definition: Dictionary in BasinBudgetModel.extractor_definitions():
		var rectangle: Rect2 = definition["rect_world"]
		_expect(
			is_zero_approx(rectangle.position.y)
			or is_equal_approx(rectangle.end.y, 9.0),
			"%s must touch the top or bottom screen bank."
			% String(definition["element_id"])
		)

	stage.set_model_date_time("01/15-06:30")
	await _settle()
	summary = stage.runtime_summary()
	_expect(
		is_equal_approx(float(summary.get("fog_baseline_mm_day", 0.0)), 0.05)
		and bool(summary.get("fog_morning_active", false))
		and float(summary.get("fog_morning_pulse_multiplier", 0.0)) > 1.0
		and float(summary.get("basin_input_rate", 0.0))
		> float(summary.get("watershed_buffered_flow_rate", 0.0)),
		"Every model morning must add the conservative 0.05 mm/day fog pulse."
	)

	stage.set_active_regime_names([])
	var bus := get_node_or_null("/root/FlowControlBus")
	_expect(bus != null, "FlowControlBus autoload must exist for chair testing.")
	if bus != null:
		var accepted: bool = bool(bus.call(
			&"submit_packet",
			{
				"speed": 9,
				"target": "delta",
				"chairs": [0, 1, 1, 0, 0, 1, 0],
			},
			"basin-budget-smoke",
			0,
		))
		_expect(accepted, "Legacy chair packet must be accepted.")
		await _settle()
		summary = stage.runtime_summary()
		_expect(
			Array(summary.get("active_regime_names", []))
			== ["Agriculture", "Gold Rush", "Tech"],
			"Chair occupancy must set the three extractive regimes absolutely."
		)
		_expect(
			is_equal_approx(float(summary.get("total_extraction_fraction", 0.0)), 1.0),
			"Chair-driven Agriculture + Gold Rush + Tech must report 100% extraction."
		)

		accepted = bool(bus.call(
			&"submit_packet",
			{
				"speed": 9,
				"target": "delta",
				"chairs": [0, 0, 0, 0, 0, 0, 0],
			},
			"basin-budget-smoke",
			0,
		))
		_expect(accepted, "Released-chair packet must be accepted.")
		await _settle()
		summary = stage.runtime_summary()
		_expect(
			Array(summary.get("active_regime_names", [])) == ["Kinship"],
			"Releasing every chair must reset the system to Kinship."
		)
		_expect(
			is_zero_approx(float(summary.get("total_extraction_fraction", -1.0))),
			"The released-chair Kinship reset must clear extraction."
		)

	stage.set_flow_rate(0.01)
	await _settle()
	summary = stage.runtime_summary()
	_expect(
		int(summary.get("amount", 0)) == 1000
		and int(summary.get("active_heads_approx", 0)) == 20
		and String(summary.get("water_line_density_mapping", ""))
		== "1_PERCENT_20__100_PERCENT_1000",
		"One-percent water must render as 20 lines from the 1,000-line pool."
	)
	_expect(
		String(summary.get("head_emission_timing", ""))
		== "EVENLY_PHASED_DIRECT_RECYCLE_CONTINUOUS"
		and String(summary.get("head_native_amount_ratio_strategy", ""))
		== "FULL_CYCLE_SHADER_GATED"
		and not bool(summary.get("head_reentry_waits_for_native_cycle", true)),
		"Low-flow heads must be evenly phased and recycle without native-cycle gaps."
	)
	_expect(
		String(summary.get("water_coverage_model", ""))
		== "CENTER_BAND_SYMMETRIC_FLOW_PERCENT"
		and is_equal_approx(
			float(summary.get("water_inlet_band_center_y_pixels", 0.0)),
			540.0,
		)
		and Vector2(
			summary.get("water_inlet_band_y_range_pixels", Vector2.ZERO)
		).is_equal_approx(Vector2(534.88, 545.12)),
		"One-percent water must originate in a narrow band centered at y=540."
	)
	for native_ratio: Variant in Array(summary.get("head_layer_amount_ratios", [])):
		_expect(
			is_equal_approx(float(native_ratio), 1.0),
			"Every native emitter must retain a complete, non-batched cycle."
		)
	for active_count: Variant in Array(
		summary.get("active_particle_count_uniforms", [])
	):
		_expect(
			is_equal_approx(float(active_count), 20.0),
			"Every head shader must receive the exact one-percent active count."
		)
	for coverage_fraction: Variant in Array(
		summary.get("water_coverage_fraction_uniforms", [])
	):
		_expect(
			is_equal_approx(float(coverage_fraction), 0.01),
			"Every head shader must receive one-percent center-band coverage."
		)
	for speed_variant: Variant in Array(summary.get("base_speed_uniforms", [])):
		_expect(
			is_equal_approx(float(speed_variant), 150.0),
			"One-percent water lines must retain the 150 px/s long-line baseline."
		)

	stage.set_flow_rate(0.02)
	await _settle()
	summary = stage.runtime_summary()
	_expect(
		int(summary.get("active_heads_approx", 0)) == 30
		and Vector2(
			summary.get("water_inlet_band_y_range_pixels", Vector2.ZERO)
		).is_equal_approx(Vector2(529.76, 550.24)),
		"Two-percent water must remain visible and widen equally above and below center."
	)

	stage.set_flow_rate(1.0)
	await _settle()
	summary = stage.runtime_summary()
	_expect(
		int(summary.get("active_heads_approx", 0)) == 1000
		and is_equal_approx(float(summary.get("amount_ratio", 0.0)), 1.0)
		and Vector2(
			summary.get("water_inlet_band_y_range_pixels", Vector2.ZERO)
		).is_equal_approx(Vector2(28.0, 1052.0)),
		"One-hundred-percent water must render all 1,000 lines."
	)

	_finish()


func _count_runtime_rows(path: String) -> int:
	var count := 0
	for line_variant in FileAccess.get_file_as_string(path).split("\n", false):
		var line := String(line_variant)
		if not line.is_empty() and line[0].is_valid_int():
			count += 1
	return count


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("BASIN_BUDGET_SMOKE: PASS")
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("BASIN_BUDGET_SMOKE: %s" % failure)
	print("BASIN_BUDGET_SMOKE: FAIL (%d failures)" % _failures.size())
	get_tree().quit(1)
