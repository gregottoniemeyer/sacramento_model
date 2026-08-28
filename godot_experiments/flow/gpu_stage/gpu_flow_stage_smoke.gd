extends Node

const STAGE_SCENE := preload(
	"res://flow/gpu_stage/gpu_flow_stage_2d.tscn"
)
const EXPECTED_LAYER_SLOTS := [143, 143, 143, 143, 143, 143, 142]
const EXPECTED_ACTIVE_HALF := [72, 72, 72, 73, 72, 72, 72]
const EXPECTED_LAYER_CAPACITIES := [10725, 10725, 10725, 10725, 10725, 10725, 10650]
const EXPECTED_LAYER_Z := [0, 1, 2, 3, 4, 5, 6]
const EXPECTED_TITLE_FONT_PATH := (
	"res://flow/assets/fonts/BarlowCondensed-Medium.ttf"
)
const EXPECTED_TITLE_POSITION := Vector2(60.0, 540.0)
const EXPECTED_DATE_POSITION := Vector2(1860.0, 540.0)
const EXPECTED_TITLE_COLOR := Color("4ab0e1")
const EXPECTED_TITLE_FONT_SIZE := 60
const EXPECTED_DATE_FONT_SIZE := 48
const EXPECTED_DATE_OPENTYPE_FEATURE := "tnum"
const EXPECTED_TEMPERATURE_DATA_PATH := (
	"res://flow/data/water_pipeline/water_temperature_all_rivers_720.txt"
)
const EXPECTED_DELTA_TEMPERATURE_COLUMN := "delta_freeport_temp_c"
const EXPECTED_TEMPERATURE_ROW_COUNT := 720
const EXPECTED_TEMPERATURE_INTERPOLATION := "HALF_OPEN_ANNUAL_LINEAR_WRAP"
const WATERSHED_AI_SMOKE_CACHE_DIRECTORY := (
	"user://watershed_ai/gpu_stage_smoke_last_successful"
)
const WATERSHED_AI_SMOKE_CACHE_PATH := (
	WATERSHED_AI_SMOKE_CACHE_DIRECTORY + "/delta.json"
)
const EXPECTED_REGIME_SLOT_CAPACITIES := {
	"drain": 5,
	"obstacle": 2,
}
const EXPECTED_REGIME_PANEL_POSITION := Vector2(1324.0, 1050.0)
const EXPECTED_REGIME_NAMES := [
	"Kinship",
	"Agriculture",
	"Gold Rush",
	"Water Projects",
	"Hydropower",
	"Tech",
	"Watershed",
]
const EXPECTED_PALETTE := [
	Color(1.0, 1.0, 1.0, 1.0),
	Color(0.918, 0.969, 0.933, 1.0),
	Color(0.827, 0.937, 0.863, 1.0),
	Color(0.675, 0.882, 0.686, 1.0),
	Color(0.482, 0.812, 0.769, 1.0),
	Color(0.290, 0.690, 0.882, 1.0),
	Color(0.118, 0.565, 1.0, 1.0),
]


class DuplicateWatershedAIRecipient:
	extends Node

	func get_screen_id() -> StringName:
		return &"delta"

	func queue_control_message(_message: Dictionary) -> void:
		pass

	func validate_watershed_ai_control_message(_message: Dictionary) -> Dictionary:
		return {"ok": true}


func _remove_watershed_ai_smoke_cache() -> void:
	for path: String in [
		WATERSHED_AI_SMOKE_CACHE_PATH,
		WATERSHED_AI_SMOKE_CACHE_PATH + ".tmp",
	]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		WATERSHED_AI_SMOKE_CACHE_DIRECTORY
	))


func _ready() -> void:
	_remove_watershed_ai_smoke_cache()
	var model_regimes := get_node_or_null("/root/ModelRegimes")
	if model_regimes != null:
		model_regimes.call(&"clear_regimes")
	var stage := STAGE_SCENE.instantiate()
	if stage == null:
		push_error("GPU_STAGE_SMOKE: reusable stage did not instantiate")
		get_tree().quit(1)
		return
	stage.set(&"stage_index", 3)
	stage.set(&"model_id", &"smoke_model")
	stage.set(&"screen_id", &"delta")
	stage.set(&"delta_confluence_enabled", true)
	stage.set(&"control_target", &"smoke_target")
	stage.set(&"stage_title", "Smoke River")
	stage.set(&"regime_panel_visible", true)
	stage.set(&"regime_profile_physics_enabled", true)
	stage.set(&"model_start_day_index", 181)
	stage.set(&"stage_temperature_visible", true)
	stage.set(&"temperature_data_path", EXPECTED_TEMPERATURE_DATA_PATH)
	stage.set(&"temperature_data_column", EXPECTED_DELTA_TEMPERATURE_COLUMN)
	stage.set(&"watershed_ai_persist_last_successful", true)
	stage.set(
		&"watershed_ai_last_successful_cache_directory",
		WATERSHED_AI_SMOKE_CACHE_DIRECTORY,
	)
	add_child(stage)
	var startup_summary: Dictionary = stage.call(&"runtime_summary")
	for admission_enabled: Variant in Array(
		startup_summary.get("reservoir_admission_enabled_uniforms", [])
	):
		if bool(admission_enabled):
			push_error(
				"GPU_STAGE_SMOKE: reservoir admission was enabled during prewarm"
			)
			get_tree().quit(1)
			return
	for interaction_enabled: Variant in Array(
		startup_summary.get("interaction_admission_enabled_uniforms", [])
	):
		if bool(interaction_enabled):
			push_error(
				"GPU_STAGE_SMOKE: polygon interaction was enabled during prewarm"
			)
			get_tree().quit(1)
			return
	for _frame in range(8):
		await get_tree().process_frame

	var errors := PackedStringArray()
	var summary: Dictionary = stage.call(&"runtime_summary")
	var expected_title_text := String(summary.get(
		"stage_title_display_text",
		"Smoke River",
	))
	if summary.is_empty():
		errors.append("runtime summary is empty")
	if not bool(summary.get("model_timeline_shared", false)):
		errors.append("stage is not bound to the persistent ModelTimeline autoload")
	if String(summary.get("model_timeline_scope", "")) != "GODOT_PROCESS":
		errors.append("shared model timeline does not report process scope")
	var water_viewport := stage.get_node_or_null("WaterOnlyViewport") as SubViewport
	var water_display := stage.get_node_or_null("WaterTextureDisplay") as Sprite2D
	var salmon_school := stage.get_node_or_null("GPUSalmonSchool") as GPUSalmon2D
	var leaf_field := stage.get_node_or_null("GPULeafField") as GPULeaf2D
	var pollution_field := stage.get_node_or_null(
		"GPUPollutionField"
	) as GPUPollution2D
	var background := stage.get_node_or_null("Background") as ColorRect
	var title_layer := stage.get_node_or_null("StageTitleLayer") as Node2D
	var title_label := stage.get_node_or_null("StageTitleLayer/StageTitle") as Label
	var date_label := stage.get_node_or_null("StageTitleLayer/ModelDate") as Label
	var separate_temperature_label := stage.get_node_or_null(
		"StageTitleLayer/WaterTemperature"
	)
	var regime_panel := stage.get_node_or_null(
		"StageTitleLayer/ActiveRegimes"
	) as Node2D
	var regime_heading := stage.get_node_or_null(
		"StageTitleLayer/ActiveRegimes/Heading"
	) as Label
	var water_canvas: Node2D = null
	if water_viewport != null:
		water_canvas = water_viewport.get_node_or_null("WaterOnlyCanvas") as Node2D
	if water_viewport == null:
		errors.append("water-only SubViewport is missing")
	elif water_viewport.size != Vector2i(1920, 1080):
		errors.append("water-only texture is not native 1920 x 1080")
	elif not water_viewport.transparent_bg:
		errors.append("water-only texture is not transparent")
	if water_canvas == null:
		errors.append("water-only canvas is missing")
	elif water_canvas.find_children("*", "GPUParticles2D", true, false).size() != 14:
		errors.append("water-only canvas does not own all fourteen water pools")
	if water_display == null or water_display.texture == null:
		errors.append("water texture is not composited back onto the stage")
	elif water_viewport != null and water_display.texture.get_rid() != water_viewport.get_texture().get_rid():
		errors.append("display does not use its own water-only viewport texture")
	if pollution_field == null:
		errors.append("separate GPU pollution field is missing")
	elif water_viewport != null and water_viewport.is_ancestor_of(pollution_field):
		errors.append("pollution field feeds back into water occupancy")
	elif leaf_field != null and (
		pollution_field.get("_head_particles") == leaf_field.get("_head_particles")
		or pollution_field.get("_control_texture") == leaf_field.get("_control_texture")
	):
		errors.append("pollution and seasonal leaves share a particle pool")
	if not bool(summary.get("water_texture_bound", false)):
		errors.append("runtime summary reports no water texture")
	if Vector2(summary.get("water_texture_size", Vector2.ZERO)) != Vector2(1920.0, 1080.0):
		errors.append("runtime water texture size is incorrect")
	if not bool(summary.get("water_texture_excludes_background", false)):
		errors.append("water texture includes the stage background")
	if not bool(summary.get("water_texture_excludes_debug_overlay", false)):
		errors.append("water texture includes debug geometry")
	if title_layer == null:
		errors.append("stage title Node2D layer is missing")
	elif title_layer.z_index != -50 or title_layer.z_as_relative:
		errors.append("stage title layer is not absolute z=-50")
	if background == null:
		errors.append("explicit black Background ColorRect is missing")
	elif background.z_index != -100 or background.z_as_relative:
		errors.append("background is not absolute z=-100 below the title")
	if water_display != null and (
		water_display.z_index != 0 or water_display.z_as_relative
	):
		errors.append("water display is not absolute z=0 above the title")
	var title_font: FontVariation = null
	if title_label == null:
		errors.append("stage title Label is missing")
	else:
		if title_label.text != expected_title_text:
			errors.append("stage title did not include the measured temperature")
		if not (title_label.position + title_label.pivot_offset).is_equal_approx(
			EXPECTED_TITLE_POSITION
		):
			errors.append("stage title is not centered on the left-edge centerline")
		if not is_equal_approx(title_label.rotation_degrees, -90.0):
			errors.append("stage title is not rotated -90 degrees")
		if not title_label.get_theme_color(&"font_color").is_equal_approx(
			EXPECTED_TITLE_COLOR
		):
			errors.append("stage title color is not #4AB0E1")
		if title_label.get_theme_font_size(&"font_size") != EXPECTED_TITLE_FONT_SIZE:
			errors.append("stage title font size is not 60")
		title_font = title_label.get_theme_font(&"font") as FontVariation
		var title_tnum_tag := TextServerManager.get_primary_interface().name_to_tag(
			EXPECTED_DATE_OPENTYPE_FEATURE
		)
		if (
			title_font == null
			or title_font.base_font == null
			or title_font.base_font.resource_path != EXPECTED_TITLE_FONT_PATH
			or int(title_font.opentype_features.get(title_tnum_tag, 0)) != 1
		):
			errors.append("stage title does not use Barlow tabular numerals")
	if date_label == null:
		errors.append("model date Label is missing")
	else:
		if not (date_label.position + date_label.pivot_offset).is_equal_approx(
			EXPECTED_DATE_POSITION
		):
			errors.append("model date is not centered on the right-edge centerline")
		if not is_equal_approx(date_label.rotation_degrees, -90.0):
			errors.append("model date is not rotated -90 degrees")
		if date_label.get_theme_font_size(&"font_size") != EXPECTED_DATE_FONT_SIZE:
			errors.append("model date font size is not 48")
		var date_font := date_label.get_theme_font(&"font") as FontVariation
		if date_font == null:
			errors.append("model date does not use a FontVariation")
		else:
			var tnum_tag := TextServerManager.get_primary_interface().name_to_tag(
				EXPECTED_DATE_OPENTYPE_FEATURE
			)
			if int(date_font.opentype_features.get(tnum_tag, 0)) != 1:
				errors.append("model date does not enable tabular numerals")
			if (
				title_font == null
				or date_font.get_instance_id() != title_font.get_instance_id()
				or date_font.base_font == null
				or date_font.base_font.resource_path != EXPECTED_TITLE_FONT_PATH
			):
				errors.append("title and date do not share the Barlow tnum font")
	if not (
		bool(summary.get("stage_date_tabular_numerals", false))
		and String(summary.get("stage_date_opentype_feature", ""))
			== EXPECTED_DATE_OPENTYPE_FEATURE
	):
		errors.append("runtime summary does not report tabular date numerals")
	_check_water_temperature_title(
		stage,
		water_viewport,
		title_label,
		separate_temperature_label,
		summary,
		errors,
	)
	_check_regime_panel(
		stage,
		water_viewport,
		regime_panel,
		regime_heading,
		errors,
	)
	if (
		water_viewport != null
		and title_layer != null
		and (
			water_viewport.is_ancestor_of(title_layer)
			or title_layer.is_ancestor_of(water_viewport)
		)
	):
		errors.append("stage title layer and water-only viewport are not siblings")
	if not (
		String(summary.get("stage_title", "")) == "Smoke River"
		and String(summary.get("stage_title_display_text", ""))
			== expected_title_text
		and bool(summary.get("stage_title_visible", false))
		and Vector2(summary.get("stage_title_position", Vector2.ZERO))
			== EXPECTED_TITLE_POSITION
		and String(summary.get("stage_title_position_anchor", "")) == "CENTERLINE"
		and is_equal_approx(
			float(summary.get("stage_title_rotation_degrees", 0.0)),
			-90.0
		)
		and Color(summary.get("stage_title_color", Color.TRANSPARENT)).is_equal_approx(
			EXPECTED_TITLE_COLOR
		)
		and int(summary.get("stage_title_font_size", 0))
			== EXPECTED_TITLE_FONT_SIZE
		and String(summary.get("stage_title_font_resource", ""))
			== EXPECTED_TITLE_FONT_PATH
		and int(summary.get("stage_title_font_instance_id", 0))
			== int(title_font.get_instance_id() if title_font != null else 0)
		and bool(summary.get("stage_title_tabular_numerals", false))
		and String(summary.get("stage_title_opentype_feature", ""))
			== EXPECTED_DATE_OPENTYPE_FEATURE
		and bool(summary.get("stage_title_temperature_integrated", false))
		and bool(summary.get("stage_title_temperature_visible", false))
		and bool(summary.get("water_texture_excludes_stage_title", false))
	):
		errors.append("runtime summary does not expose the complete stage-title contract")
	await _check_stage_title_runtime_independence(
		stage,
		water_viewport,
		title_label,
		errors,
	)
	summary = stage.call(&"runtime_summary")
	if salmon_school == null:
		errors.append("GPU salmon school is missing")
	elif water_canvas != null and water_canvas.is_ancestor_of(salmon_school):
		errors.append("salmon is inside the water-only viewport feedback loop")
	else:
		var salmon_summary: Dictionary = summary.get("salmon_summary", {})
		if int(salmon_summary.get("capacity", 0)) != 300:
			errors.append("salmon pool capacity is not 300")
		if not bool(salmon_summary.get("water_texture_assigned", false)):
			errors.append("salmon did not receive the water-only texture")
		if not is_equal_approx(
			float(salmon_summary.get("effective_trail_length_pixels", 0.0)),
			100.0
		):
			errors.append("salmon immutable trail is not approximately 100 px")
		if not is_equal_approx(
			float(salmon_summary.get("streak_width_pixels", 0.0)),
			3.0
		):
			errors.append("salmon trail width is not the requested 3 px")
		if int(salmon_summary.get("segment_capacity", 0)) < 3750:
			errors.append("salmon segment pool is too small for a 100 px trail")
		if not (
			String(salmon_summary.get("water_steering_mode", ""))
				== "DETERMINISTIC_2D_CONTACT_FIELD"
			and String(salmon_summary.get("water_steering_reference", ""))
				== "CURRENT_SWIM_HEADING"
		):
			errors.append("salmon do not steer from nearby water in two dimensions")
	if leaf_field == null:
		errors.append("GPU leaf field is missing")
	elif water_canvas != null and water_canvas.is_ancestor_of(leaf_field):
		errors.append("leaves are inside the water-only viewport feedback loop")
	else:
		var leaf_summary: Dictionary = summary.get("leaf_summary", {})
		if int(leaf_summary.get("capacity", 0)) != 300:
			errors.append("leaf pool capacity is not 300")
		if not bool(leaf_summary.get("water_texture_assigned", false)):
			errors.append("leaves did not receive the water-only texture")
		if int(leaf_summary.get("default_release_count_per_side", 0)) != 15:
			errors.append("leaf default release is not 15 per side")
		if not is_equal_approx(
			float(leaf_summary.get("streak_width_pixels", 0.0)),
			10.0
		):
			errors.append("leaf disk diameter is not the requested 10 px")
		if String(leaf_summary.get("state_transition", "")) != (
			"FREE_TO_WATER_LATCHED_IRREVERSIBLE"
		):
			errors.append("leaf water attachment is not an irreversible latch")
		if String(leaf_summary.get("release_edges", "")) != "TOP_BOTTOM":
			errors.append("leaf release edges are not top and bottom")
		if String(leaf_summary.get("top_free_direction", "")) != "+Y":
			errors.append("top-origin leaves do not move down into the stage")
		if String(leaf_summary.get("bottom_free_direction", "")) != "-Y":
			errors.append("bottom-origin leaves do not move up into the stage")
		if String(leaf_summary.get("free_sway_axis", "")) != "X":
			errors.append("leaf free-flight sway is not horizontal")
		if String(leaf_summary.get("latched_initial_direction", "")) != "+X":
			errors.append("attached leaves do not turn downstream")
		if String(leaf_summary.get("latched_follow_reference_axis", "")) != (
			"CACHED_WATER_HEADING"
		):
			errors.append("attached leaves do not retain a cached local water heading")
		if String(leaf_summary.get("latched_heading_constraint", "")) != (
			"LOCAL_CONTINUITY_WITH_DOWNSTREAM_BIAS"
		):
			errors.append("attached leaf heading does not balance curves and continuity")
		if String(leaf_summary.get("latched_follow_resampling", "")) != (
			"PERIODIC_DETERMINISTIC_PHASE"
		):
			errors.append("attached leaf water heading is not periodically resampled")
		if String(leaf_summary.get("latched_retirement", "")) != (
			"RIGHT_EDGE_AFTER_DISK"
		):
			errors.append("attached leaf disks can retire before clearing downstream")
		if not (
			int(leaf_summary.get("segment_capacity", -1)) == 0
			and bool(leaf_summary.get("head_only_rendering", false))
			and not bool(leaf_summary.get("segment_emission", true))
			and not bool(leaf_summary.get("immutable_segments", true))
			and not bool(leaf_summary.get("per_segment_trail_lifetime", true))
		):
			errors.append("leaf renderer still allocates or emits trail segments")
		if not is_equal_approx(
			float(leaf_summary.get("flow_speed_pixels", 0.0)),
			300.0
		):
			errors.append("attached leaves are not swept downstream at 300 px/s")
		if not is_equal_approx(
			float(leaf_summary.get("release_stagger_interval_seconds", 0.0)),
			0.20
		):
			errors.append("leaf release stagger base is not 0.20 seconds")
		if not (
			is_equal_approx(
				float(leaf_summary.get("follow_probe_max_pixels", 0.0)),
				56.0
			)
			and is_equal_approx(
				float(leaf_summary.get("follow_turn_degrees", 0.0)),
				35.0
			)
			and is_equal_approx(
				float(leaf_summary.get("follow_resample_interval_seconds", 0.0)),
				0.12
			)
		):
			errors.append("leaf water-vicinity follow defaults are incorrect")
		if not (
			is_equal_approx(
				float(leaf_summary.get("free_water_search_radius_pixels", 0.0)),
				120.0
			)
			and is_equal_approx(
				float(leaf_summary.get("free_water_steering_strength", 0.0)),
				0.35
			)
			and is_equal_approx(
				float(leaf_summary.get("free_search_max_distance_pixels", 0.0)),
				540.0
			)
			and is_equal_approx(
				float(leaf_summary.get("stopped_fade_seconds", 0.0)),
				0.50
			)
		):
			errors.append("free leaves do not search nearby water then stop/fade")
		if not (
			is_equal_approx(float(leaf_summary.get("disk_radius_pixels", 0.0)), 5.0)
			and is_equal_approx(float(leaf_summary.get("minimum_leaf_radius_pixels", 0.0)), 5.0)
			and is_equal_approx(float(leaf_summary.get("maximum_leaf_radius_pixels", 0.0)), 10.0)
			and is_equal_approx(float(leaf_summary.get("minimum_leaf_diameter_pixels", 0.0)), 10.0)
			and is_equal_approx(float(leaf_summary.get("maximum_leaf_diameter_pixels", 0.0)), 20.0)
			and is_equal_approx(float(leaf_summary.get("minimum_leaf_width_pixels", 0.0)), 10.0)
			and is_equal_approx(float(leaf_summary.get("maximum_leaf_width_pixels", 0.0)), 20.0)
		):
			errors.append("leaf disk-radius variation range is incorrect")
		if String(leaf_summary.get("miss_behavior", "")) != (
			"REACH_SCREEN_MIDLINE_THEN_FADE"
		):
			errors.append("unattached leaves do not stop and fade after a bounded search")
		if not (
			String(leaf_summary.get("spatial_alpha_profile", ""))
				== "RADIAL_ANTIALIASED_DISK_EDGE"
			and String(leaf_summary.get("render_primitive", ""))
				== "ANTIALIASED_DISK_HEAD"
			and String(leaf_summary.get("trail_primitive", "")) == "NONE"
		):
			errors.append("leaf renderer is not the antialiased disk-head primitive")
		if leaf_field.get_node_or_null("GPULeafHeads") == null:
			errors.append("leaf disk head pool is missing")
		if leaf_field.get_node_or_null("GPULeafTrailSegments") != null:
			errors.append("leaf field still contains the removed trail segment pool")

	# The Governator now owns regime keys 1-7. Godot retains only 0/8/9 as
	# water-rate shortcuts, and neither path may retune or release ecology pools.
	var salmon_before_digits: Dictionary = summary.get("salmon_summary", {}).duplicate(true)
	var leaves_before_digits: Dictionary = summary.get("leaf_summary", {}).duplicate(true)
	var zero_key := InputEventKey.new()
	zero_key.pressed = true
	zero_key.keycode = KEY_0
	stage.call(&"_unhandled_input", zero_key)
	var zero_summary: Dictionary = stage.call(&"runtime_summary")
	if not is_zero_approx(float(zero_summary.get("flow_rate", -1.0))):
		errors.append("0 key did not set the water flow rate to zero")
	var nine_key := InputEventKey.new()
	nine_key.pressed = true
	nine_key.keycode = KEY_9
	stage.call(&"_unhandled_input", nine_key)
	var nine_summary: Dictionary = stage.call(&"runtime_summary")
	if not is_equal_approx(float(nine_summary.get("flow_rate", -1.0)), 1.0):
		errors.append("9 key did not set the water flow rate to one")
	var flow_before_ignored_regime_key := float(nine_summary.get("flow_rate", -1.0))
	var active_before_ignored_regime_key := Array(
		nine_summary.get("active_regime_names", [])
	).duplicate()
	var one_key := InputEventKey.new()
	one_key.pressed = true
	one_key.keycode = KEY_1
	stage.call(&"_unhandled_input", one_key)
	var one_summary: Dictionary = stage.call(&"runtime_summary")
	if Array(one_summary.get("active_regime_names", [])) != (
		active_before_ignored_regime_key
	):
		errors.append("Godot still handles the Governator-owned regime keys")
	if not is_equal_approx(
		float(one_summary.get("flow_rate", -1.0)),
		flow_before_ignored_regime_key,
	):
		errors.append("ignored regime key unexpectedly changed the water flow rate")
	var salmon_after_digits: Dictionary = nine_summary.get("salmon_summary", {})
	for key: String in [
		"upstream_speed_pixels",
		"segment_capacity",
		"trail_lifetime_seconds",
		"release_serial",
		"total_scheduled",
	]:
		if salmon_after_digits.get(key) != salmon_before_digits.get(key):
			errors.append("digit key unexpectedly changed salmon %s" % key)
	var leaves_after_digits: Dictionary = nine_summary.get("leaf_summary", {})
	for key: String in [
		"free_speed_pixels",
		"flow_speed_pixels",
		"free_water_search_radius_pixels",
		"free_water_steering_strength",
		"free_search_max_distance_pixels",
		"stopped_fade_seconds",
		"release_stagger_interval_seconds",
		"follow_resample_interval_seconds",
		"line_width_variation",
		"disk_radius_pixels",
		"minimum_leaf_radius_pixels",
		"maximum_leaf_radius_pixels",
		"render_primitive",
		"head_only_rendering",
		"segment_emission",
		"segment_capacity",
		"release_serial",
		"total_scheduled",
	]:
		if leaves_after_digits.get(key) != leaves_before_digits.get(key):
			errors.append("digit key unexpectedly changed leaves %s" % key)
	stage.call(&"set_flow_rate", 0.50)
	summary = stage.call(&"runtime_summary")
	if int(summary.get("amount", 0)) != 1000:
		errors.append("expected 1,000 particle slots")
	if int(summary.get("active_heads_approx", 0)) != 505:
		errors.append("expected 505 active particles at half flow")
	if int(summary.get("palette_layer_count", 0)) != 7:
		errors.append("expected seven fixed palette layers")
	if int(summary.get("head_layer_count", 0)) != 7:
		errors.append("expected seven independent head emitters")
	if int(summary.get("trail_segment_layer_count", 0)) != 7:
		errors.append("expected seven independent immutable segment pools")
	if Array(summary.get("head_layer_slot_counts", [])) != EXPECTED_LAYER_SLOTS:
		errors.append("global 1,000 head slots are not distributed 143x6 + 142")
	if String(summary.get("head_emission_timing", "")) != (
		"EVENLY_PHASED_DIRECT_RECYCLE_CONTINUOUS"
	):
		errors.append("head emission does not advertise continuous desynchronized timing")
	if String(summary.get("head_native_amount_ratio_strategy", "")) != (
		"FULL_CYCLE_SHADER_GATED"
	):
		errors.append("native amount-ratio batching remains enabled")
	if bool(summary.get("head_reentry_waits_for_native_cycle", true)):
		errors.append("head recycling still waits for a batch-prone native cycle")
	if String(summary.get("water_coverage_model", "")) != (
		"CENTER_BAND_SYMMETRIC_FLOW_PERCENT"
	):
		errors.append("water coverage does not widen symmetrically from center")
	if not Vector2(
		summary.get("water_inlet_band_y_range_pixels", Vector2.ZERO)
	).is_equal_approx(Vector2(284.0, 796.0)):
		errors.append("50% water does not occupy the centered half-height inlet band")
	var preprocess_values := Array(summary.get("head_layer_preprocess_seconds", []))
	if preprocess_values.size() != 7:
		errors.append("expected a pre-process phase on every palette emitter")
	for layer_index in range(preprocess_values.size()):
		var expected_preprocess := 16.0 + float(layer_index) * 8.0 / 1000.0
		if not is_equal_approx(
			float(preprocess_values[layer_index]),
			expected_preprocess,
		):
			errors.append("palette emitter pre-process phases are not interleaved")
			break
	for active_count_uniform: Variant in Array(
		summary.get("active_particle_count_uniforms", [])
	):
		if not is_equal_approx(float(active_count_uniform), 505.0):
			errors.append("50% active count did not reach every head shader")
			break
	for coverage_uniform: Variant in Array(
		summary.get("water_coverage_fraction_uniforms", [])
	):
		if not is_equal_approx(float(coverage_uniform), 0.5):
			errors.append("50% center-band coverage did not reach every head shader")
			break
	var head_layer_randomness := Array(summary.get("head_layer_randomness", []))
	if head_layer_randomness.size() != 7:
		errors.append("expected timing randomness on all seven palette emitters")
	for timing_randomness: Variant in head_layer_randomness:
		if not is_zero_approx(float(timing_randomness)):
			errors.append("a palette emitter randomizes the exact continuous schedule")
			break
	var head_layer_explosiveness := Array(summary.get("head_layer_explosiveness", []))
	if head_layer_explosiveness.size() != 7:
		errors.append("expected explosiveness state on all seven palette emitters")
	for explosiveness: Variant in head_layer_explosiveness:
		if not is_zero_approx(float(explosiveness)):
			errors.append("a palette emitter uses burst emission")
			break
	var fixed_seed_states := Array(summary.get("head_layer_fixed_seed_enabled", []))
	if fixed_seed_states.size() != 7:
		errors.append("expected fixed-seed state on all seven palette emitters")
	for fixed_seed_enabled: Variant in fixed_seed_states:
		if not bool(fixed_seed_enabled):
			errors.append("a palette emitter lost deterministic fixed seeding")
			break
	var head_layer_seeds := Array(summary.get("head_layer_seeds", []))
	var unique_head_layer_seeds: Dictionary = {}
	for head_layer_seed: Variant in head_layer_seeds:
		unique_head_layer_seeds[int(head_layer_seed)] = true
	if head_layer_seeds.size() != 7 or unique_head_layer_seeds.size() != 7:
		errors.append("palette emitters do not have seven distinct timing seeds")
	if Array(summary.get("active_head_layer_counts", [])) != EXPECTED_ACTIVE_HALF:
		errors.append("50% flow does not activate exactly 505 interleaved heads")
	if Array(summary.get("trail_segment_capacities", [])) != EXPECTED_LAYER_CAPACITIES:
		errors.append("75,000 segment slots are not divided by palette population")
	if Array(summary.get("head_layer_z_indices", [])) != EXPECTED_LAYER_Z:
		errors.append("head palette layers do not have stable z-indices 0 through 6")
	if Array(summary.get("trail_segment_z_indices", [])) != EXPECTED_LAYER_Z:
		errors.append("trail palette layers do not have stable z-indices 0 through 6")
	for is_relative: Variant in Array(summary.get("head_layer_z_as_relative", [])):
		if bool(is_relative):
			errors.append("a head palette layer still has relative z enabled")
			break
	for is_relative: Variant in Array(summary.get("trail_segment_z_as_relative", [])):
		if bool(is_relative):
			errors.append("a trail palette layer still has relative z enabled")
			break
	if Array(summary.get("forced_palette_color_uniforms", [])) != EXPECTED_PALETTE:
		errors.append("fixed palette colors did not reach all seven head shaders")
	for force_palette: Variant in Array(summary.get("force_palette_color_uniforms", [])):
		if not bool(force_palette):
			errors.append("a production head shader did not force its palette color")
			break
	if Array(summary.get("particle_index_offset_uniforms", [])) != [
		0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0
	]:
		errors.append("palette layers do not use interleaved global identities")
	if Array(summary.get("particle_index_stride_uniforms", [])) != [
		7.0, 7.0, 7.0, 7.0, 7.0, 7.0, 7.0
	]:
		errors.append("palette layers do not use the seven-way identity stride")
	if int(summary.get("fixed_fps", -1)) != 0:
		errors.append("head simulation is not render-paced")
	if not bool(summary.get("interpolate", false)):
		errors.append("particle interpolation is off")
	if String(summary.get("trail_mode", "")) != "immutable_gpu_segments":
		errors.append("immutable segment trail mode is not active")
	if bool(summary.get("trail_enabled", true)):
		errors.append("native trails remain enabled on the heads")
	if bool(summary.get("trail_segment_native_trail_enabled", true)):
		errors.append("native trails remain enabled on immutable segments")
	if bool(summary.get("trail_segment_autonomous_emission", true)):
		errors.append("immutable segment pool is also emitting autonomously")
	if String(summary.get("trail_segment_emitter_path", "")).is_empty():
		errors.append("heads are not wired to the immutable segment sub-emitter")
	if int(summary.get("trail_segment_fixed_fps", -1)) != 0:
		errors.append("immutable segment simulation is not render-paced")
	if bool(summary.get("trail_segment_interpolate", true)):
		errors.append("immutable segment transforms are being interpolated")
	if Vector2(summary.get("trail_segment_texture_size", Vector2.ZERO)) != Vector2(1.0, 8.0):
		errors.append("immutable segment texture is not the expected 1x8 envelope")
	if Vector2(summary.get("head_texture_size", Vector2.ZERO)) != Vector2.ONE:
		errors.append("hidden head texture is not the expected 1x1 source")
	if int(summary.get("trail_segment_capacity", 0)) != 75000:
		errors.append("expected 75,000 immutable segment slots")
	if not is_equal_approx(
		float(summary.get("trail_segment_lifetime_uniform", 0.0)),
		2.0
	):
		errors.append("segment draw lifetime did not reach shader")
	if not is_equal_approx(
		float(summary.get("trail_segment_process_lifetime_uniform", 0.0)),
		2.0
	):
		errors.append("segment process lifetime did not reach shader")
	if not is_equal_approx(
		float(summary.get("trail_segment_max_length_pixels_uniform", 0.0)),
		96.0
	):
		errors.append("segment discontinuity bound did not reach head shader")
	if not bool(summary.get("trail_recording_enabled_uniform", false)):
		errors.append("immutable trail recording did not start after head prewarm")
	for admission_enabled: Variant in Array(
		summary.get("reservoir_admission_enabled_uniforms", [])
	):
		if not bool(admission_enabled):
			errors.append("reservoir admission did not start after empty prewarm")
			break
	for interaction_enabled: Variant in Array(
		summary.get("interaction_admission_enabled_uniforms", [])
	):
		if not bool(interaction_enabled):
			errors.append("polygon interaction did not start after empty prewarm")
			break
	if int(summary.get("interaction_polygon_count", 0)) != 7:
		errors.append("expected seven resident drain/obstacle slots")
	if int(summary.get("interaction_overlay_count", 0)) != 2:
		errors.append("debug overlay did not receive both active fallback polygons")
	if not bool(summary.get("interaction_data_texture_bound", false)):
		errors.append("polygon geometry texture is not bound")
	if Vector2(summary.get("interaction_data_texture_size", Vector2.ZERO)) != Vector2(
		128.0, 1.0
	):
		errors.append("polygon geometry texture is not the 128x1 production layout")
	if String(summary.get("shoreline_effect_mode", "")) != "EDGE_TURBULENCE":
		errors.append("shoreline weight is not implemented as edge turbulence")
	if (
		int(summary.get("shoreline_count", -1)) != 0
		or int(summary.get("shoreline_vertex_count", -1)) != 0
		or not Array(summary.get("shoreline_ids", [])).is_empty()
		or not Array(summary.get("shoreline_obstacles", [])).is_empty()
		or int(summary.get("shoreline_overlay_count", -1)) != 0
	):
		errors.append("legacy shoreline geometry or overlay banks are still resident")
	if bool(summary.get("shoreline_data_texture_bound", true)):
		errors.append("legacy shoreline geometry texture is still bound")
	if Vector2(summary.get("shoreline_data_texture_size", Vector2.ONE)) != Vector2.ZERO:
		errors.append("legacy shoreline geometry texture still has an allocation")
	if not bool(summary.get("shoreline_preserves_interaction_capacity", false)):
		errors.append("edge turbulence unexpectedly consumes polygon capacity")
	for shoreline_count: Variant in Array(
		summary.get("shoreline_count_uniforms", [])
	):
		if int(shoreline_count) != 0:
			errors.append("legacy shoreline collision is active in a head shader")
			break
	for shoreline_bound: Variant in Array(
		summary.get("shoreline_texture_bound_uniforms", [])
	):
		if bool(shoreline_bound):
			errors.append("a head shader still binds the legacy shoreline texture")
			break
	_check_edge_turbulence_contract(summary, 0.0, errors)
	for removed_source_key: String in [
		"source_polygon_count",
		"source_polygons",
		"source_overlay_count",
		"source_count_uniforms",
		"source_data_texture_bound",
		"source_data_texture_size",
		"source_texture_packer",
		"regime_source_override_enabled_uniforms",
		"regime_source_weight_uniforms",
	]:
		if summary.has(removed_source_key):
			errors.append(
				"removed supplemental-source diagnostic is still exposed: %s"
					% removed_source_key
			)
	if stage.has_method(&"get_source_polygon"):
		errors.append("removed supplemental-source API is still exposed")
	for removed_regime_source_spec: Array in [
		["regime_effective_features", "source_area_fraction"],
		["regime_effective_feature_state", "source_area_fraction"],
		["regime_applied_feature_budgets", "source_area_fraction"],
		["regime_applied_feature_overrides", "source"],
		["regime_feature_presence", "source"],
		["regime_feature_slot_capacities", "source"],
		["regime_feature_slot_counts_desired", "source"],
		["regime_feature_slot_counts_rendered", "source"],
		["regime_feature_slot_counts_resident", "source"],
	]:
		var collection := Dictionary(summary.get(
			String(removed_regime_source_spec[0]),
			{},
		))
		if collection.has(String(removed_regime_source_spec[1])):
			errors.append(
				"removed regime source field is still exposed: %s.%s"
					% removed_regime_source_spec
			)
	for polygon_count: Variant in Array(summary.get("interaction_count_uniforms", [])):
		if int(polygon_count) != 2:
			errors.append("the two authored fallback polygons did not reach every shader")
			break
	if Dictionary(summary.get("regime_feature_slot_capacities", {})) != (
		EXPECTED_REGIME_SLOT_CAPACITIES
	):
		errors.append("regime feature slot capacities are not 5 drains and 2 obstacles")
	if Dictionary(summary.get("regime_feature_slot_counts_resident", {})) != (
		EXPECTED_REGIME_SLOT_CAPACITIES
	):
		errors.append(
			"the complete fixed feature bank was not allocated at startup: %s"
				% summary.get("regime_feature_slot_counts_resident", {})
		)
	if Dictionary(summary.get("regime_feature_controller_spare_capacity", {})) != {
		"interaction": 1,
	}:
		errors.append("the fixed banks did not preserve controller spare capacity")
	if Dictionary(summary.get("regime_feature_slot_counts_desired", {})) != {
		"drain": 1,
		"obstacle": 1,
	}:
		errors.append("undefined baseline state did not request one authored interaction slot per feature")
	if Dictionary(summary.get("regime_feature_slot_counts_rendered", {})) != {
		"drain": 1,
		"obstacle": 1,
	}:
		errors.append(
			"undefined baseline state did not render one authored interaction slot per feature: %s"
				% summary.get("regime_feature_slot_counts_rendered", {})
		)
	if Vector2(summary.get("stage_size", Vector2.ZERO)) != Vector2(1920.0, 1080.0):
		errors.append("stage is not native 1920 x 1080")
	var confluence_summary: Dictionary = summary.get("confluence_summary", {})
	var confluence_sources: Dictionary = confluence_summary.get("sources", {})
	var expected_confluence_sources := {
		"mount_shasta": [Vector2(0.0, 120.0), Vector2.RIGHT, 480.0],
		"mccloud_pit": [Vector2(0.0, 840.0), Vector2.RIGHT, 480.0],
		"cottonwood_creek": [Vector2(1200.0, 1080.0), Vector2.UP, 1440.0],
		"mill_creek": [Vector2(360.0, 1080.0), Vector2.UP, 720.0],
		"feather_river": [Vector2(600.0, 0.0), Vector2.DOWN, 960.0],
		"american_river": [Vector2(1440.0, 0.0), Vector2.DOWN, 1680.0],
	}
	if (
		not bool(confluence_summary.get("enabled", false))
		or not bool(confluence_summary.get("is_delta", false))
		or int(confluence_summary.get("source_count", 0)) != 6
		or int(confluence_summary.get("cohort_size", 0)) != 25
	):
		errors.append("Delta confluence identity or six-source contract is missing")
	for source_id: String in expected_confluence_sources:
		var source_state: Dictionary = confluence_sources.get(source_id, {})
		var expected: Array = expected_confluence_sources[source_id]
		if (
			Vector2(source_state.get("anchor_pixels", Vector2.INF)) != expected[0]
			or Vector2(source_state.get(
				"inward_direction_pixels",
				Vector2.INF,
			)) != expected[1]
			or not is_equal_approx(
				float(source_state.get("merge_x_pixels", -1.0)),
				float(expected[2]),
			)
		):
			errors.append("Delta confluence inlet is incorrect for %s" % source_id)
	for material_variant: Variant in stage.get("_process_material_layers"):
		var material := material_variant as ShaderMaterial
		if material == null or not bool(material.get_shader_parameter(
			&"confluence_mode"
		)):
			errors.append("Delta confluence mode did not reach every water shader")
			break
	if not (
		String(confluence_summary.get("curve_mode", ""))
			== "CUBIC_BEZIER_TO_SHARED_TRUNK"
		and String(confluence_summary.get("trunk_width_model", ""))
			== "BOUNDED_QUADRATURE_SOURCE_WIDTHS"
		and String(confluence_summary.get("source_width_model", ""))
			== "DELAYED_UPSTREAM_EXIT_WIDTH_PIXELS"
		and is_equal_approx(float(confluence_summary.get(
			"trunk_maximum_full_flow_width_pixels",
			0.0,
		)), 1024.0)
	):
		errors.append("Delta confluence is not a smooth, cumulatively widening trunk")
	if not bool(stage.call(&"accepts_control_target", "delta")):
		errors.append("screen identity does not address stage")
	if not bool(stage.call(&"accepts_control_target", "smoke_model")):
		errors.append("model identity does not address stage")
	if not bool(stage.call(&"accepts_control_target", "smoke_target")):
		errors.append("control target does not address stage")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_incidence", 0.0)),
		0.50
	):
		errors.append("default reservoir entry incidence is not 0.50")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_incidence_uniform", 0.0)),
		0.50
	):
		errors.append("default reservoir entry incidence did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_pull_strength", 0.0)),
		3.50
	):
		errors.append("default reservoir entry pull is not 3.50")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_pull_strength_uniform", 0.0)),
		3.50
	):
		errors.append("default reservoir entry pull did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_inward_speed_ratio_uniform", 0.0)),
		0.30
	):
		errors.append("default minimum inward entry speed did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_gate_staging_radius_ratio_uniform", 0.0)),
		0.86
	):
		errors.append("default gate staging radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_radius_min_ratio_uniform", 0.0)),
		0.05
	):
		errors.append("default inner reservoir orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_radius_max_ratio_uniform", 0.0)),
		0.78
	):
		errors.append("default outer reservoir orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_full_speed_ratio_uniform", 0.0)),
		0.46
	):
		errors.append("default full-speed orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_max_angular_speed_uniform", 0.0)),
		1.50
	):
		errors.append("default maximum orbit angular speed did not reach shader")
	var expected_default_aperture_fraction := 15.0 / 223.71
	if not is_equal_approx(
		float(summary.get("gate_aperture_fraction", 0.0)),
		expected_default_aperture_fraction
	):
		errors.append("default gate width did not produce its aperture fraction")
	if not is_equal_approx(
		float(summary.get("gate_release_probability_effective", 0.0)),
		expected_default_aperture_fraction
	):
		errors.append("default release probability is not driven by gate aperture")
	var salmon_before_public: Dictionary = summary.get("salmon_summary", {})
	var salmon_release_serial_before := int(salmon_before_public.get(
		"release_serial",
		0,
	))
	var salmon_total_before := int(salmon_before_public.get("total_scheduled", 0))
	if int(stage.call(&"release_salmon", 25)) != 25:
		errors.append("public salmon release did not schedule exactly 25")
	summary = stage.call(&"runtime_summary")
	var released_salmon_summary: Dictionary = summary.get("salmon_summary", {})
	if int(released_salmon_summary.get("release_serial", 0)) != (
		salmon_release_serial_before + 1
	):
		errors.append("public salmon release serial did not advance")
	if int(released_salmon_summary.get("total_scheduled", 0)) != (
		salmon_total_before + 25
	):
		errors.append("public salmon release total is not 25")
	if int(stage.call(&"release_leaves", 15)) != 30:
		errors.append("public leaf release did not schedule 15 from each bank")
	summary = stage.call(&"runtime_summary")
	var released_leaf_summary: Dictionary = summary.get("leaf_summary", {})
	if int(released_leaf_summary.get("release_serial", 0)) != 1:
		errors.append("public leaf release serial did not advance")
	if int(released_leaf_summary.get("total_scheduled_top", 0)) != 15:
		errors.append("public leaf release did not schedule 15 top-origin leaves")
	if int(released_leaf_summary.get("total_scheduled_bottom", 0)) != 15:
		errors.append("public leaf release did not schedule 15 bottom-origin leaves")
	if not (
		String(released_leaf_summary.get("release_schedule", ""))
			== "ALTERNATING_TOP_BOTTOM_DETERMINISTIC_IRREGULAR_X_SHUFFLED"
		and String(released_leaf_summary.get("release_x_order", ""))
			== "INDEPENDENT_DETERMINISTIC_SHUFFLE_PER_BANK"
		and String(released_leaf_summary.get("release_time_x_correlation", ""))
			== "DECOUPLED"
		and float(released_leaf_summary.get("last_release_stagger_span_seconds", 0.0)) > 5.0
		and float(released_leaf_summary.get("last_release_stagger_span_seconds", 0.0)) < 7.0
		and float(released_leaf_summary.get("last_min_release_gap_seconds", 0.0)) >= 0.110
		and float(released_leaf_summary.get("last_max_release_gap_seconds", 0.0)) <= 0.290
		and float(released_leaf_summary.get("last_min_release_gap_seconds", 0.0)) > 0.0
		and float(released_leaf_summary.get("last_max_release_gap_seconds", 0.0))
			> float(released_leaf_summary.get("last_min_release_gap_seconds", 0.0))
	):
		errors.append("public leaf release is not doubled, shuffled, and irregularly staggered")
	stage.call(&"set_gate_width", &"reservoir_main", 10.0)
	summary = stage.call(&"runtime_summary")
	var expected_full_gate_width := 223.71 * 2.0 / 120.0
	if int(summary.get("trail_segment_capacity", 0)) != 75000:
		errors.append("gate geometry unexpectedly changed trail capacity")
	if not is_equal_approx(
		float(summary.get("gate_width", 0.0)),
		expected_full_gate_width
	):
		errors.append("gate width did not clamp to the reservoir diameter")
	if not is_equal_approx(
		float(summary.get("gate_half_width_uniform", 0.0)),
		223.71
	):
		errors.append("full gate did not send the reservoir radius to the shader")
	if not is_equal_approx(
		float(summary.get("gate_release_probability_effective", 0.0)),
		1.0
	):
		errors.append("fully open aperture does not produce release probability 1.0")
	if not bool(summary.get("gate_fully_open", false)):
		errors.append("diameter-wide gate did not enter the hard-drain state")

	stage.call(&"set_gate_open", &"reservoir_main", false)
	stage.call(&"set_gate_width", &"reservoir_main", 0.50)
	stage.call(&"set_paused", true)
	stage.call(&"set_debug_visible", false)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if bool(summary.get("gate_open", true)):
		errors.append("runtime gate state did not change")
	if not is_equal_approx(float(summary.get("gate_width", 0.0)), 0.50):
		errors.append("runtime gate width did not change")
	if not is_equal_approx(
		float(summary.get("gate_half_width_uniform", 0.0)), 30.0
	):
		errors.append("world-unit gate width did not map to native pixels")
	if not is_zero_approx(
		float(summary.get("gate_release_probability_effective", 1.0))
	):
		errors.append("closed gate does not produce release probability 0.0")
	if not bool(summary.get("paused", false)):
		errors.append("runtime pause did not change")
	if not bool(summary.get("debug_visible", false)):
		errors.append("geometry visibility accepted a hidden state")
	if not bool(summary.get("debug_overlay_visible", false)):
		errors.append("polygon and reservoir geometry did not remain visible")
	for speed_scale: Variant in Array(summary.get("head_layer_speed_scales", [])):
		if not is_zero_approx(float(speed_scale)):
			errors.append("pause did not stop every head palette layer")
			break
	for speed_scale: Variant in Array(summary.get("trail_segment_speed_scales", [])):
		if not is_zero_approx(float(speed_scale)):
			errors.append("pause did not stop every trail palette layer")
			break
	for gate_uniform: Variant in Array(summary.get("gate_open_uniforms", [])):
		if bool(gate_uniform):
			errors.append("closed gate state did not reach every head shader")
			break

	stage.call(&"queue_control_message", {
		"changes": {
			"debug.geometry_visible": true,
			"flow_rate": 0.75,
			"velocity_response": 14.0,
			"reservoir.reservoir_main.gate_open": true,
			"reservoir.reservoir_main.outlet_width": 0.70,
			"reservoir_center_pixels": Vector2(1280.0, 700.0),
			"reservoir_radius_pixels": 180.0,
			"reservoir_capture_y_ratio": 0.95,
			"reservoir_capture_edge_softness_pixels": 18.0,
			"reservoir.reservoir_main.entry_min_incidence": 0.62,
			"reservoir.reservoir_main.entry_pull_strength": 4.25,
			"reservoir.reservoir_main.entry_min_inward_speed_ratio": 0.38,
			"reservoir.reservoir_main.gate_staging_radius_ratio": 0.90,
			"reservoir.reservoir_main.orbit_radius_min_ratio": 0.12,
			"reservoir.reservoir_main.orbit_radius_max_ratio": 0.84,
			"reservoir.reservoir_main.orbit_full_speed_ratio": 0.52,
			"reservoir.reservoir_main.orbit_max_angular_speed": 1.75,
			"trail_segment_overlap_pixels": 1.5,
			"trail_segment_max_length_pixels": 72.0,
			"salmon.water_steering_strength": 7.0,
			"leaves.free_speed_pixels": 140.0,
			"leaves.flow_speed_pixels": 180.0,
			"leaves.free_water_search_radius_pixels": 96.0,
			"leaves.free_water_steering_strength": 0.42,
			"leaves.free_search_max_distance_pixels": 480.0,
			"leaves.stopped_fade_seconds": 0.65,
			"leaves.contact_radius_pixels": 14.0,
			"leaves.release_stagger_interval_seconds": 0.12,
			"leaves.follow_probe_max_pixels": 64.0,
			"leaves.follow_turn_degrees": 40.0,
			"leaves.follow_resample_interval_seconds": 0.11,
			"leaves.disk_radius_pixels": 4.0,
			"leaves.radius_variation": 0.35,
		},
		"geometry_ops": [{
			"op": "upsert",
			"kind": "polygon",
			"id": "smoke_absorber",
			"value": {
				"vertices": [
					[4.0, 2.0],
					[5.0, 2.0],
					[5.0, 3.0],
					[4.0, 3.0],
				],
				"mode": "absorb",
				"absorption_fraction": 0.75,
				"repellent_force": 0.20,
			},
		}],
		"actions": [
			{"name": "pause"},
			{
				"name": "release_salmon",
				"arguments": {
					"destination_screen": "mill_creek",
					"survivor_count": 7,
				},
			},
			{
				"name": "release_leaves",
				"arguments": {"count_per_side": 4},
			},
		],
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if not is_equal_approx(float(summary.get("flow_rate", 0.0)), 0.75):
		errors.append("queued controller flow_rate did not update")
	if not bool(summary.get("debug_visible", false)):
		errors.append("absolute controller debug geometry visibility did not update")
	if not is_equal_approx(float(summary.get("amount_ratio", 0.0)), 753.0 / 1000.0):
		errors.append("controller flow_rate did not update active population")
	if int(summary.get("active_heads_approx", 0)) != 753:
		errors.append("75% flow does not activate exactly 753 global heads")
	if Array(summary.get("active_head_layer_counts", [])) != [
		108, 107, 108, 108, 107, 109, 106
	]:
		errors.append("75% flow does not preserve exact evenly phased activation")
	if not is_equal_approx(float(summary.get("base_speed_uniform", 0.0)), 450.0):
		errors.append("controller flow_rate did not update core speed")
	if not is_equal_approx(float(summary.get("velocity_response_uniform", 0.0)), 14.0):
		errors.append("controller velocity response did not reach particle shader")
	for native_amount_ratio: Variant in Array(
		summary.get("head_layer_amount_ratios", [])
	):
		if not is_equal_approx(float(native_amount_ratio), 1.0):
			errors.append("a native palette emitter still uses batch-prone amount ratio")
			break
	var expected_layer_amount_ratios := [
		108.0 / 143.0,
		107.0 / 143.0,
		108.0 / 143.0,
		108.0 / 143.0,
		107.0 / 143.0,
		109.0 / 143.0,
		106.0 / 142.0,
	]
	var actual_layer_amount_ratios := Array(
		summary.get("head_layer_logical_active_ratios", [])
	)
	for layer_index in range(expected_layer_amount_ratios.size()):
		if (
			layer_index >= actual_layer_amount_ratios.size()
			or not is_equal_approx(
				float(actual_layer_amount_ratios[layer_index]),
				float(expected_layer_amount_ratios[layer_index]),
			)
		):
			errors.append("controller logical flow ratio did not reach every head layer")
			break
	for active_count_uniform: Variant in Array(
		summary.get("active_particle_count_uniforms", [])
	):
		if not is_equal_approx(float(active_count_uniform), 753.0):
			errors.append("controller active head count did not reach every shader")
			break
	for coverage_uniform: Variant in Array(
		summary.get("water_coverage_fraction_uniforms", [])
	):
		if not is_equal_approx(float(coverage_uniform), 0.75):
			errors.append("controller center-band coverage did not reach every shader")
			break
	if not Vector2(
		summary.get("water_inlet_band_y_range_pixels", Vector2.ZERO)
	).is_equal_approx(Vector2(156.0, 924.0)):
		errors.append("75% water does not widen symmetrically around screen center")
	for base_speed: Variant in Array(summary.get("base_speed_uniforms", [])):
		if not is_equal_approx(float(base_speed), 450.0):
			errors.append("controller flow speed did not reach every head shader")
			break
	for response: Variant in Array(summary.get("velocity_response_uniforms", [])):
		if not is_equal_approx(float(response), 14.0):
			errors.append("controller velocity response did not reach every head shader")
			break
	if not bool(summary.get("gate_open", false)):
		errors.append("queued controller gate state did not update")
	if not is_equal_approx(float(summary.get("gate_half_width_uniform", 0.0)), 42.0):
		errors.append("queued controller gate width did not update")
	if not is_equal_approx(
		float(summary.get("gate_release_probability_effective", 0.0)),
		42.0 / 180.0
	):
		errors.append("queued aperture width did not update release probability")
	for gate_uniform: Variant in Array(summary.get("gate_open_uniforms", [])):
		if not bool(gate_uniform):
			errors.append("open gate state did not reach every head shader")
			break
	for half_width: Variant in Array(summary.get("gate_half_width_uniforms", [])):
		if not is_equal_approx(float(half_width), 42.0):
			errors.append("gate width did not reach every head shader")
			break
	if Vector2(summary.get("reservoir_center_uniform", Vector2.ZERO)) != Vector2(
		1280.0, 700.0
	):
		errors.append("runtime reservoir center did not reach the particle simulation")
	if not is_equal_approx(
		float(summary.get("reservoir_radius_uniform", 0.0)),
		180.0
	):
		errors.append("runtime reservoir radius did not reach the particle simulation")
	for center: Variant in Array(summary.get("reservoir_center_uniforms", [])):
		if Vector2(center) != Vector2(1280.0, 700.0):
			errors.append("reservoir center did not reach every head shader")
			break
	for radius: Variant in Array(summary.get("reservoir_radius_uniforms", [])):
		if not is_equal_approx(float(radius), 180.0):
			errors.append("reservoir radius did not reach every head shader")
			break
	if not is_equal_approx(
		float(summary.get("reservoir_capture_y_ratio_uniform", 0.0)),
		0.95
	):
		errors.append("reservoir vertical capture ratio did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_capture_edge_softness_uniform", 0.0)),
		18.0
	):
		errors.append("reservoir vertical edge softness did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_incidence", 0.0)),
		0.62
	):
		errors.append("reservoir entry incidence geometry alias did not update")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_incidence_uniform", 0.0)),
		0.62
	):
		errors.append("reservoir entry incidence did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_pull_strength", 0.0)),
		4.25
	):
		errors.append("reservoir entry pull geometry alias did not update")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_pull_strength_uniform", 0.0)),
		4.25
	):
		errors.append("reservoir entry pull did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_entry_min_inward_speed_ratio_uniform", 0.0)),
		0.38
	):
		errors.append("minimum inward entry speed did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_gate_staging_radius_ratio_uniform", 0.0)),
		0.90
	):
		errors.append("gate staging radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_radius_min_ratio_uniform", 0.0)),
		0.12
	):
		errors.append("inner reservoir orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_radius_max_ratio_uniform", 0.0)),
		0.84
	):
		errors.append("outer reservoir orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_full_speed_ratio_uniform", 0.0)),
		0.52
	):
		errors.append("full-speed orbit radius did not reach shader")
	if not is_equal_approx(
		float(summary.get("reservoir_orbit_max_angular_speed_uniform", 0.0)),
		1.75
	):
		errors.append("maximum orbit angular speed did not reach shader")
	if not is_equal_approx(
		float(summary.get("trail_segment_overlap_pixels_uniform", 0.0)),
		1.5
	):
		errors.append("trail segment overlap did not reach head shader")
	if not is_equal_approx(
		float(summary.get("trail_segment_max_length_pixels_uniform", 0.0)),
		72.0
	):
		errors.append("trail discontinuity bound did not reach head shader")
	if int(summary.get("trail_segment_capacity", 0)) != 75000:
		errors.append("flow-rate change unexpectedly resized immutable segment pool")
	if not bool(summary.get("paused", false)):
		errors.append("controller action dictionary did not pause")
	var controller_salmon_summary: Dictionary = summary.get("salmon_summary", {})
	if int(controller_salmon_summary.get("release_serial", 0)) != (
		salmon_release_serial_before + 2
	):
		errors.append("controller salmon action did not advance release serial")
	if int(controller_salmon_summary.get("total_scheduled", 0)) != (
		salmon_total_before + 50
	):
		errors.append("controller destination cohort was not scheduled as 25 salmon")
	var controller_cohorts: Array = controller_salmon_summary.get("last_cohorts", [])
	if (
		controller_cohorts.size() != 1
		or String(Dictionary(controller_cohorts[0]).get("destination_screen", ""))
			!= "mill_creek"
		or int(Dictionary(controller_cohorts[0]).get("survivor_count", -1)) != 7
	):
		errors.append("controller salmon destination or survivor count was not retained")
	if not is_equal_approx(
		float(controller_salmon_summary.get("water_steering_strength", 0.0)),
		7.0
	):
		errors.append("controller salmon vicinity steering did not reach the GPU school")
	if not bool(controller_salmon_summary.get("paused", false)):
		errors.append("stage pause did not pause salmon simulation")
	var controller_leaf_summary: Dictionary = summary.get("leaf_summary", {})
	if int(controller_leaf_summary.get("release_serial", 0)) != 2:
		errors.append("controller leaf action did not advance release serial")
	if int(controller_leaf_summary.get("total_scheduled", 0)) != 38:
		errors.append("controller leaf per-side count was not scheduled exactly")
	if int(controller_leaf_summary.get("last_scheduled_per_side", 0)) != 4:
		errors.append("controller leaf action did not preserve its per-side count")
	if not bool(controller_leaf_summary.get("paused", false)):
		errors.append("stage pause did not pause leaf simulation")
	if not is_equal_approx(
		float(controller_leaf_summary.get("free_speed_pixels", 0.0)),
		140.0
	):
		errors.append("controller leaf free speed did not reach GPU leaf system")
	if not is_equal_approx(
		float(controller_leaf_summary.get("flow_speed_pixels", 0.0)),
		180.0
	):
		errors.append("controller leaf flow speed did not reach GPU leaf system")
	if not is_equal_approx(
		float(controller_leaf_summary.get("contact_radius_pixels", 0.0)),
		14.0
	):
		errors.append("controller leaf contact radius did not reach GPU leaf system")
	if not (
		is_equal_approx(
			float(controller_leaf_summary.get("free_water_search_radius_pixels", 0.0)),
			96.0
		)
		and is_equal_approx(
			float(controller_leaf_summary.get("free_water_steering_strength", 0.0)),
			0.42
		)
		and is_equal_approx(
			float(controller_leaf_summary.get("free_search_max_distance_pixels", 0.0)),
			540.0
		)
		and is_equal_approx(
			float(controller_leaf_summary.get("stopped_fade_seconds", 0.0)),
			0.65
		)
	):
		errors.append("controller leaf water-search or miss-fade controls did not apply")
	if not is_equal_approx(
		float(controller_leaf_summary.get("release_stagger_interval_seconds", 0.0)),
		0.12
	):
		errors.append("controller leaf release stagger did not reach GPU leaf system")
	if not is_equal_approx(
		float(controller_leaf_summary.get("follow_resample_interval_seconds", 0.0)),
		0.11
	):
		errors.append("controller leaf resample interval did not reach GPU leaf system")
	if not (
		is_equal_approx(
			float(controller_leaf_summary.get("follow_probe_max_pixels", 0.0)),
			64.0
		)
		and is_equal_approx(
			float(controller_leaf_summary.get("follow_turn_degrees", 0.0)),
			40.0
		)
	):
		errors.append("controller leaf follow controls did not apply")
	if not (
		is_equal_approx(float(summary.get("leaf_disk_radius_pixels", 0.0)), 4.0)
		and is_equal_approx(float(summary.get("leaf_radius_variation", 0.0)), 0.35)
		and is_equal_approx(float(controller_leaf_summary.get("line_width_variation", 0.0)), 0.35)
		and is_equal_approx(float(controller_leaf_summary.get("disk_radius_pixels", 0.0)), 4.0)
		and is_equal_approx(
			float(controller_leaf_summary.get("maximum_leaf_radius_pixels", 0.0)),
			5.40
		)
		and String(controller_leaf_summary.get("render_primitive", ""))
			== "ANTIALIASED_DISK_HEAD"
	):
		errors.append("controller leaf radius variation did not reach disk renderer")
	if int(summary.get("interaction_polygon_count", 0)) != 8:
		errors.append("controller polygon upsert did not add an addressable object")
	for polygon_count: Variant in Array(summary.get("interaction_count_uniforms", [])):
		if int(polygon_count) != 3:
			errors.append("controller polygon did not reach all seven head shaders")
			break
	var smoke_polygon: Dictionary = {}
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if not definition_variant is Dictionary:
			continue
		if String(definition_variant.get("element_id", "")) == "smoke_absorber":
			smoke_polygon = definition_variant
			break
	if smoke_polygon.is_empty():
		errors.append("controller polygon stable ID was not retained")
	else:
		if String(smoke_polygon.get("mode", "")) != "absorb":
			errors.append("controller polygon mode was not retained")
		if not is_equal_approx(
			float(smoke_polygon.get("absorption_fraction", 0.0)),
			0.75
		):
			errors.append("controller polygon absorption was not retained")
		if not is_equal_approx(
			float(smoke_polygon.get("repellent_force", 0.0)),
			0.20
		):
			errors.append("controller polygon repellent force was not retained")
		var native_vertices: PackedVector2Array = smoke_polygon.get(
			"vertices_pixels",
			PackedVector2Array()
		)
		if native_vertices.is_empty() or native_vertices[0] != Vector2(480.0, 840.0):
			errors.append("world polygon vertices did not map to native Y-down pixels")

	stage.call(&"queue_control_message", {
		"changes": {
			"polygon.smoke_absorber.absorption_fraction": 1.0,
			"polygon.smoke_absorber.repellent_force": 0.0,
			"polygon.smoke_absorber.vertices": [
				[6.0, 1.5],
				[7.0, 1.5],
				[7.0, 2.5],
				[6.0, 2.5],
			],
		}
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if not definition_variant is Dictionary:
			continue
		if String(definition_variant.get("element_id", "")) != "smoke_absorber":
			continue
		if not is_equal_approx(
			float(definition_variant.get("absorption_fraction", 0.0)),
			1.0
		):
			errors.append("addressed polygon absorption field did not update")
		if not is_zero_approx(float(definition_variant.get("repellent_force", 1.0))):
			errors.append("addressed polygon repellent field did not update")
		var updated_vertices: PackedVector2Array = definition_variant.get(
			"vertices_pixels",
			PackedVector2Array()
		)
		if updated_vertices.is_empty() or updated_vertices[0] != Vector2(720.0, 900.0):
			errors.append("addressed polygon reshape did not update GPU geometry")
	stage.call(&"queue_control_message", {
		"geometry_ops": [{
			"op": "remove",
			"kind": "polygon",
			"id": "smoke_absorber",
		}]
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if int(summary.get("interaction_polygon_count", 0)) != 7:
		errors.append("controller polygon removal did not restore the resident slot bank")
	if int(summary.get("trail_segment_capacity", 0)) != 75000:
		errors.append("polygon geometry edits unexpectedly changed trail capacity")

	# The operation ID is authoritative even if a hostile or stale payload also
	# carries either accepted ID alias. This also exercises case-insensitive plural
	# kinds and operation names used by external controllers.
	stage.call(&"queue_control_message", {
		"geometry_ops": [{
			"op": "ADD",
			"kind": "Absorbers",
			"id": "stable_guard",
			"value": {
				"id": "payload_alias",
				"element_id": "payload_element",
				"vertices": [
					[4.0, 1.0],
					[5.0, 1.0],
					[5.0, 2.0],
					[4.0, 2.0],
				],
				"absorption_fraction": 0.5,
			},
		}]
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	var interaction_ids: Array[String] = []
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if definition_variant is Dictionary:
			interaction_ids.append(String(definition_variant.get("element_id", "")))
	if not interaction_ids.has("stable_guard"):
		errors.append("operation ID was not authoritative for polygon upsert")
	if interaction_ids.has("payload_alias") or interaction_ids.has("payload_element"):
		errors.append("polygon payload overrode its stable operation ID")
	stage.call(&"queue_control_message", {
		"geometry_ops": [{
			"op": "DELETE",
			"kind": "POLYGONS",
			"element_id": "stable_guard",
		}]
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if int(summary.get("interaction_polygon_count", 0)) != 7:
		errors.append("plural-kind polygon removal did not restore the slot bank")

	# Width appears before radius on purpose. The raw request must survive its
	# temporary clamp against the old radius, then become a true full aperture
	# after an arbitrary runtime radius larger than the editor's 600 px hint.
	var native_radius_revision_before := int(summary.get(
		"reservoir_geometry_revision",
		-1,
	))
	stage.call(&"queue_control_message", {
		"changes": {
			"reservoir.reservoir_main.outlet_width": 12.0,
			"reservoir_radius_pixels": 700.0,
		}
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if not is_equal_approx(float(summary.get("gate_width_requested", 0.0)), 12.0):
		errors.append("batched raw gate width request was lost before reservoir resize")
	if not is_equal_approx(
		float(summary.get("gate_width", 0.0)),
		700.0 * 2.0 / 120.0
	):
		errors.append("gate width did not re-clamp to enlarged runtime diameter")
	if not is_equal_approx(float(summary.get("gate_half_width_uniform", 0.0)), 700.0):
		errors.append("large runtime reservoir could not send a full-width gate")
	if not bool(summary.get("gate_fully_open", false)):
		errors.append("large runtime reservoir could not reach hard-drain state")
	var native_radius_revision_after := int(summary.get(
		"reservoir_geometry_revision",
		-1,
	))
	if native_radius_revision_after != (native_radius_revision_before + 1) % 1000000:
		errors.append("native reservoir_radius_pixels did not invalidate ownership once")
	for revision_uniform: Variant in Array(summary.get(
		"reservoir_geometry_revision_uniforms",
		[],
	)):
		if not is_equal_approx(
			float(revision_uniform),
			float(native_radius_revision_after),
		):
			errors.append("native reservoir resize revision missed a water shader")
			break
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"reservoir_radius_pixels",
		700.0,
	)):
		errors.append("idempotent native reservoir radius was rejected")
	var unchanged_radius_summary: Dictionary = stage.call(&"runtime_summary")
	if int(unchanged_radius_summary.get("reservoir_geometry_revision", -2)) != (
		native_radius_revision_after
	):
		errors.append("idempotent native reservoir radius flushed ownership")
	_check_kinship_ecology_schedule(stage, errors)
	await _check_regime_runtime_stability(stage, errors)
	await _check_watershed_ai_control(stage, errors)
	_check_controller_ownership_regression(stage, errors)
	await _check_stage_title_reset_independence(stage, errors)
	await _check_watershed_ai_invalid_cache(stage, errors)
	_remove_watershed_ai_smoke_cache()

	if errors.is_empty():
		print(
			"GPU_STAGE_SMOKE_OK: one_stage=true native=1920x1080 "
			+ "slots=1000 active=505 render_paced=true max_fps=30 interpolation=true "
				+ "immutable_segments=75000 palette_layers=7 fixed_z=true "
				+ "identity=true gate=true pause=true "
				+ "debug=true title=true temperature=true regimes=true controller=true "
				+ "polygons=true salmon=true leaves=true pollution=true"
		)
		get_tree().quit(0)
		return
	for error in errors:
		push_error("GPU_STAGE_SMOKE: %s" % error)
	get_tree().quit(1)


func _check_watershed_ai_invalid_cache(
	stage: Node,
	errors: PackedStringArray,
) -> void:
	var regimes := get_node_or_null("/root/ModelRegimes")
	if regimes == null:
		errors.append("invalid Watershed cache smoke requires ModelRegimes")
		return
	regimes.call(&"set_active_names", ["Kinship"])
	await get_tree().process_frame
	var file := FileAccess.open(WATERSHED_AI_SMOKE_CACHE_PATH, FileAccess.WRITE)
	if file == null:
		errors.append("invalid Watershed cache smoke could not write its fixture")
		return
	file.store_string("{\"invalid\":true}\n")
	file.close()
	stage.set(&"_watershed_ai_last_successful_state", {})
	stage.set(&"_watershed_ai_last_successful_decision_id", "")
	stage.set(&"_watershed_ai_last_successful_state_hash", "")
	stage.call(&"_load_watershed_ai_last_successful_cache")
	var invalid: Dictionary = stage.call(&"runtime_summary")
	if not (
		String(invalid.get(
			"watershed_ai_last_successful_cache_status",
			"",
		)) == "INVALID"
		and not bool(invalid.get(
			"watershed_ai_last_successful_available",
			true,
		))
	):
		errors.append("corrupt last-successful cache did not fail closed")
	regimes.call(&"set_active_names", ["Watershed"])
	await get_tree().process_frame
	var cold_fallback: Dictionary = stage.call(&"runtime_summary")
	var budget_overlay := stage.get_node_or_null(
		"BasinBudgetCanvas/BasinBudgetOverlay"
	)
	if not (
		not bool(cold_fallback.get("watershed_ai_applied", true))
		and String(cold_fallback.get("watershed_ai_applied_source", "")) == "NONE"
		and budget_overlay != null
		and String(budget_overlay.call(&"_formatted_extraction_percentage")) == "—"
	):
		errors.append("corrupt cache did not retain the safe cold Watershed baseline")
	regimes.call(&"clear_regimes")
	await get_tree().process_frame


func _check_watershed_ai_control(
	stage: Node,
	errors: PackedStringArray,
) -> void:
	var bus := get_node_or_null("/root/FlowControlBus")
	var regimes := get_node_or_null("/root/ModelRegimes")
	if bus == null or regimes == null:
		errors.append("Watershed AI smoke requires both control autoloads")
		return
	regimes.call(&"clear_regimes")
	stage.call(
		&"set_runtime_parameter",
		&"watershed.drives_flow_rate",
		true,
	)
	var baseline: Dictionary = stage.call(&"runtime_summary")
	var baseline_gate_open := bool(baseline.get("gate_open_authored", true))
	var baseline_input_rate := float(baseline.get("basin_input_rate", -1.0))
	var baseline_node_count := _recursive_node_count(stage)
	var baseline_pool_signature := _particle_pool_signature(stage)
	var baseline_texture_signature := _stage_texture_signature(stage)
	var baseline_feature_signature := _feature_resource_signature(stage)
	var state := _watershed_ai_smoke_state("watershed-smoke-1")
	var packet := _watershed_ai_smoke_packet(state)
	var inactive_stage_validation: Dictionary = stage.call(
		&"validate_watershed_ai_control_message",
		packet,
	)
	if bool(inactive_stage_validation.get("ok", false)):
		errors.append("GPU stage accepted Watershed AI outside exclusive Watershed")
	if bool(bus.call(&"submit_packet", packet, "smoke-test", 0)):
		errors.append("Watershed AI packet was accepted while Watershed was inactive")

	regimes.call(&"set_active_names", ["Watershed"])
	await get_tree().process_frame
	var budget_overlay := stage.get_node_or_null(
		"BasinBudgetCanvas/BasinBudgetOverlay"
	)
	if (
		budget_overlay == null
		or String(budget_overlay.call(&"_formatted_extraction_percentage")) != "—"
	):
		errors.append("pending Watershed AI state misleadingly reports 0% extraction")
	var unloaded_target_packet: Dictionary = packet.duplicate(true)
	unloaded_target_packet["target"] = "feather_river"
	if bool(bus.call(
		&"submit_packet",
		unloaded_target_packet,
		"smoke-test",
		0,
	)):
		errors.append("Watershed AI packet accepted zero loaded recipients")
	var duplicate_recipient := DuplicateWatershedAIRecipient.new()
	add_child(duplicate_recipient)
	duplicate_recipient.add_to_group(&"flow_models")
	if bool(bus.call(&"submit_packet", packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted multiple loaded recipients")
	duplicate_recipient.queue_free()
	await get_tree().process_frame
	var wildcard_packet: Dictionary = packet.duplicate(true)
	wildcard_packet["target"] = "*"
	if bool(bus.call(&"submit_packet", wildcard_packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted a wildcard target")
	var action_packet: Dictionary = packet.duplicate(true)
	action_packet["actions"] = ["release_salmon"]
	if bool(bus.call(&"submit_packet", action_packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted an action")
	var geometry_packet: Dictionary = packet.duplicate(true)
	geometry_packet["geometry_ops"] = [{"op": "remove", "id": "reservoir_main"}]
	if bool(bus.call(&"submit_packet", geometry_packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted a geometry operation")
	var malformed_packet: Dictionary = packet.duplicate(true)
	var malformed_changes: Dictionary = Dictionary(
		malformed_packet["changes"]
	).duplicate(true)
	var malformed_state: Dictionary = Dictionary(
		malformed_changes["watershed.ai.state"]
	).duplicate(true)
	malformed_state["atmospheric_input_rate"] = INF
	malformed_changes["watershed.ai.state"] = malformed_state
	malformed_packet["changes"] = malformed_changes
	if bool(bus.call(&"submit_packet", malformed_packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted a non-finite state")
	var out_of_range_packet: Dictionary = packet.duplicate(true)
	var out_of_range_changes: Dictionary = Dictionary(
		out_of_range_packet["changes"]
	).duplicate(true)
	var out_of_range_state: Dictionary = Dictionary(
		out_of_range_changes["watershed.ai.state"]
	).duplicate(true)
	out_of_range_state["city_fraction"] = 1.01
	out_of_range_changes["watershed.ai.state"] = out_of_range_state
	out_of_range_packet["changes"] = out_of_range_changes
	if bool(bus.call(&"submit_packet", out_of_range_packet, "smoke-test", 0)):
		errors.append("Watershed AI packet accepted an out-of-range state")
	var excessive_extraction_packet: Dictionary = packet.duplicate(true)
	var excessive_extraction_changes: Dictionary = Dictionary(
		excessive_extraction_packet["changes"]
	).duplicate(true)
	var excessive_extraction_state: Dictionary = Dictionary(
		excessive_extraction_changes["watershed.ai.state"]
	).duplicate(true)
	excessive_extraction_state["extraction_fraction"] = 0.60
	excessive_extraction_state["remaining_rate"] = 0.28
	excessive_extraction_state["salmon_fraction"] = 0.25
	excessive_extraction_state["floodplain_fraction"] = 0.15
	excessive_extraction_state["agriculture_fraction"] = 0.25
	excessive_extraction_state["data_center_fraction"] = 0.20
	excessive_extraction_state["city_fraction"] = 0.15
	excessive_extraction_changes["watershed.ai.state"] = excessive_extraction_state
	excessive_extraction_packet["changes"] = excessive_extraction_changes
	if bool(bus.call(
		&"submit_packet",
		excessive_extraction_packet,
		"smoke-test",
		0,
	)):
		errors.append("Watershed AI packet accepted extraction above 50%")
	var before_apply: Dictionary = stage.call(&"runtime_summary")
	if not String(before_apply.get(
		"watershed_ai_applied_decision_id",
		"",
	)).is_empty():
		errors.append("rejected Watershed AI packets changed applied state")

	if not bool(bus.call(&"submit_packet", packet, "smoke-test", 0)):
		errors.append("valid Watershed AI packet was rejected")
	await get_tree().process_frame
	var applied: Dictionary = stage.call(&"runtime_summary")
	var applied_state: Dictionary = applied.get("watershed_ai_applied_state", {})
	var applied_hash := String(applied.get("watershed_ai_applied_state_hash", ""))
	_expect_pollution_sources(
		applied,
		["data_center_north", "data_center_east"],
		"AI Watershed",
		errors,
	)
	var ai_reveal_states := Dictionary(applied.get("extractor_reveal_states", {}))
	if not (
		bool(applied.get("extractor_reveal_ai_watershed_bypass", false))
		and not bool(Dictionary(ai_reveal_states.get("gold_rush", {})).get(
			"active",
			true,
		))
		and Array(Dictionary(ai_reveal_states.get("gold_rush", {})).get(
			"sites",
			["unexpected"],
		)).is_empty()
		and not bool(Dictionary(ai_reveal_states.get("tech", {})).get("active", true))
		and Array(Dictionary(ai_reveal_states.get("tech", {})).get(
			"sites",
			["unexpected"],
		)).is_empty()
	):
		errors.append("AI Watershed incorrectly inherited the historical site reveal")
	var expected_ai_data_center_width := 1.90 * 120.0 * sqrt(0.15 / 0.20)
	for source_variant: Variant in Array(applied.get(
		"pollution_active_sources",
		[],
	)):
		if source_variant is Dictionary:
			var source: Dictionary = source_variant
			var mouth_start := Vector2(source.get(
				"mouth_start_pixels",
				Vector2.ZERO,
			))
			var mouth_end := Vector2(source.get(
				"mouth_end_pixels",
				Vector2.ZERO,
			))
			if not is_equal_approx(
				mouth_end.x - mouth_start.x,
				expected_ai_data_center_width,
			):
				errors.append("AI Watershed pollution ignored scaled Data Center geometry")
	if applied_hash != (
		"abfc3b0a9327e7d9c4403dcd15e475a74c4223427eb9de96d0aeea03a2e4f5f9"
	):
		errors.append("Watershed AI state hash changed from the cross-language fixture")
	if not (
		bool(applied.get("watershed_ai_applied", false))
		and bool(applied.get("watershed_ai_exclusive_active", false))
		and String(applied.get("watershed_ai_applied_decision_id", ""))
			== "watershed-smoke-1"
		and applied_hash.length() == 64
		and applied_state == state
		and not bool(applied.get("watershed_data_drives_flow_rate", true))
		and is_equal_approx(float(applied.get("flow_rate", -1.0)), 0.42)
		and is_equal_approx(
			float(applied.get("total_extraction_fraction", -1.0)),
			0.40,
		)
		and is_equal_approx(
			float(applied.get("basin_remaining_rate", -1.0)),
			0.42,
		)
		and bool(applied.get("gate_open", false))
	):
		errors.append("valid Watershed AI state did not apply atomically")
	if (
		budget_overlay == null
		or String(budget_overlay.call(&"_formatted_extraction_percentage"))
		!= "40.0%"
	):
		errors.append("applied Watershed AI extraction is absent from the Delta budget")
	if not FileAccess.file_exists(WATERSHED_AI_SMOKE_CACHE_PATH):
		errors.append("accepted Watershed AI state did not create its persistent cache")
	stage.set(&"_watershed_ai_last_successful_state", {})
	stage.set(&"_watershed_ai_last_successful_decision_id", "")
	stage.set(&"_watershed_ai_last_successful_state_hash", "")
	stage.call(&"_load_watershed_ai_last_successful_cache")
	var cache_reloaded: Dictionary = stage.call(&"runtime_summary")
	if not (
		String(cache_reloaded.get(
			"watershed_ai_last_successful_cache_status",
			"",
		)) == "LOADED"
		and String(cache_reloaded.get(
			"watershed_ai_last_successful_decision_id",
			"",
		)) == "watershed-smoke-1"
		and String(cache_reloaded.get(
			"watershed_ai_last_successful_state_hash",
			"",
		)) == applied_hash
	):
		errors.append("a fresh stage could not reload its last successful AI state")
	var applied_budgets: Dictionary = applied.get(
		"regime_applied_feature_budgets",
		{},
	)
	var expected_ai_budgets := {
		"reservoir_area_fraction": 0.50,
		"reservoir_gate_aperture_fraction": 0.40,
		"drain_area_fraction": 0.30,
		"drain_power": 0.30,
		"obstacle_area_fraction": 0.10,
		"obstacle_power": 0.10,
		"shoreline_randomness": 0.0,
	}
	for field: String in expected_ai_budgets:
		if not is_equal_approx(
			float(applied_budgets.get(field, -1.0)),
			float(expected_ai_budgets[field]),
		):
			errors.append("Watershed AI did not derive visual field '%s'" % field)
	if not is_equal_approx(
		float(applied_budgets.get("reservoir_count_raw", -1.0)),
		1.0,
	):
		errors.append("Watershed AI did not overlay reservoir_count")
	var desired_counts: Dictionary = applied.get(
		"regime_feature_slot_counts_desired",
		{},
	)
	var rendered_counts: Dictionary = applied.get(
		"regime_feature_slot_counts_rendered",
		{},
	)
	if not (
		int(desired_counts.get("drain", -1)) == 2
		and int(desired_counts.get("obstacle", -1)) == 1
		and int(rendered_counts.get("drain", -1)) == 2
		and int(rendered_counts.get("obstacle", -1)) == 1
	):
		errors.append("Watershed AI did not modulate the resident feature banks")
	if (
		_recursive_node_count(stage) != baseline_node_count
		or _particle_pool_signature(stage) != baseline_pool_signature
		or _stage_texture_signature(stage) != baseline_texture_signature
		or _feature_resource_signature(stage) != baseline_feature_signature
	):
		errors.append("Watershed AI replaced a fixed runtime resource")

	var acknowledgement: Dictionary = bus.call(
		&"_protocol_acknowledgement",
		packet,
		1,
		true,
		"",
	)
	var acknowledged_states: Dictionary = acknowledgement.get(
		"recipient_watershed_ai_state",
		{},
	)
	var delta_ack: Dictionary = acknowledged_states.get("delta", {})
	var observation: Dictionary = delta_ack.get("current_observation", {})
	if not (
		String(acknowledgement.get("control_scope", "")) == "watershed-ai/2"
		and Array(acknowledgement.get("regime_active_indices", [])) == [6]
		and String(delta_ack.get("applied_decision_id", ""))
			== "watershed-smoke-1"
		and String(delta_ack.get("applied_state_hash", "")) == applied_hash
		and String(observation.get("screen_id", "")) == "delta"
		and bool(observation.get("temperature_valid", false))
	):
		errors.append("Watershed AI acknowledgement omitted applied state or observation")

	var apply_count := int(applied.get("watershed_ai_apply_count", -1))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		WATERSHED_AI_SMOKE_CACHE_PATH
	))
	stage.set(&"_watershed_ai_last_successful_cache_status", "ERROR")
	if not bool(bus.call(&"submit_packet", packet, "smoke-test", 0)):
		errors.append("identical Watershed AI retry was rejected")
	await get_tree().process_frame
	var deduplicated: Dictionary = stage.call(&"runtime_summary")
	if (
		int(deduplicated.get("watershed_ai_apply_count", -2)) != apply_count
		or int(deduplicated.get("watershed_ai_deduplicated_count", 0)) < 1
		or not FileAccess.file_exists(WATERSHED_AI_SMOKE_CACHE_PATH)
		or String(deduplicated.get(
			"watershed_ai_last_successful_cache_status",
			"",
		)) != "SAVED"
	):
		errors.append("identical Watershed AI retry did not recover persistence")

	var conflict_packet: Dictionary = packet.duplicate(true)
	var conflict_changes: Dictionary = Dictionary(
		conflict_packet["changes"]
	).duplicate(true)
	var conflict_state: Dictionary = Dictionary(
		conflict_changes["watershed.ai.state"]
	).duplicate(true)
	conflict_state["atmospheric_input_rate"] = 0.50
	conflict_state["available_supply_rate"] = 0.60
	conflict_state["remaining_rate"] = 0.36
	conflict_changes["watershed.ai.state"] = conflict_state
	conflict_packet["changes"] = conflict_changes
	if bool(bus.call(&"submit_packet", conflict_packet, "smoke-test", 0)):
		errors.append("Watershed AI reused a decision ID with different state")
	var after_conflict: Dictionary = stage.call(&"runtime_summary")
	if not is_equal_approx(float(after_conflict.get("flow_rate", -1.0)), 0.42):
		errors.append("rejected Watershed AI conflict partially changed the stage")

	var same_state_new_id := state.duplicate(true)
	same_state_new_id["decision_id"] = "watershed-smoke-2"
	var same_state_packet := _watershed_ai_smoke_packet(same_state_new_id)
	if not bool(bus.call(&"submit_packet", same_state_packet, "smoke-test", 0)):
		errors.append("new Watershed AI decision ID with identical state was rejected")
	await get_tree().process_frame
	var id_only: Dictionary = stage.call(&"runtime_summary")
	if not (
		String(id_only.get("watershed_ai_applied_decision_id", ""))
			== "watershed-smoke-2"
		and int(id_only.get("watershed_ai_apply_count", -2)) == apply_count
	):
		errors.append("identical Watershed AI visual state repeated GPU work")

	regimes.call(&"set_active_names", ["Tech"])
	await get_tree().process_frame
	var restored: Dictionary = stage.call(&"runtime_summary")
	var restored_features: Dictionary = restored.get(
		"regime_effective_feature_state",
		{},
	)
	var restored_drain: Dictionary = restored_features.get(
		"drain_area_fraction",
		{},
	)
	if not (
		not bool(restored.get("watershed_ai_applied", true))
		and String(restored.get("watershed_ai_applied_state_hash", "")).is_empty()
		and String(restored.get("watershed_ai_applied_source", "")) == "NONE"
		and bool(restored.get(
			"watershed_ai_last_successful_available",
			false,
		))
		and String(restored.get(
			"watershed_ai_last_successful_decision_id",
			"",
		)) == "watershed-smoke-2"
		and String(restored.get(
			"watershed_ai_last_successful_state_hash",
			"",
		)) == applied_hash
		and bool(restored.get("watershed_data_drives_flow_rate", false))
		and is_equal_approx(
			float(restored.get("basin_input_rate", -2.0)),
			baseline_input_rate
		)
		and is_equal_approx(
			float(restored.get("flow_rate", -2.0)),
			baseline_input_rate * 0.75
		)
		and bool(restored.get("gate_open_authored", not baseline_gate_open))
			== baseline_gate_open
		and Array(restored_drain.get("contributor_ids", [])) == ["tech"]
	):
		errors.append("leaving exclusive Watershed did not restore profile/timeline state")

	regimes.call(&"set_active_names", ["Watershed"])
	await get_tree().process_frame
	var replayed: Dictionary = stage.call(&"runtime_summary")
	var replayed_counts: Dictionary = replayed.get(
		"regime_feature_slot_counts_desired",
		{},
	)
	if not (
		bool(replayed.get("watershed_ai_applied", false))
		and String(replayed.get("watershed_ai_applied_decision_id", ""))
			== "watershed-smoke-2"
		and String(replayed.get("watershed_ai_applied_state_hash", ""))
			== applied_hash
		and String(replayed.get("watershed_ai_applied_source", ""))
			== "LAST_SUCCESSFUL_FALLBACK"
		and int(replayed.get("watershed_ai_fallback_replay_count", 0)) >= 1
		and is_equal_approx(float(replayed.get("basin_input_rate", -1.0)), 0.60)
		and is_equal_approx(
			float(replayed.get("total_extraction_fraction", -1.0)),
			0.40,
		)
		and int(replayed_counts.get("drain", -1)) == 2
		and budget_overlay != null
		and String(budget_overlay.call(&"_formatted_extraction_percentage"))
			== "40.0%"
	):
		errors.append("Watershed did not immediately replay its last successful state")
	var replayed_active_head_count := float(replayed.get(
		"active_heads_approx",
		-1.0,
	))
	for active_count_uniform: Variant in Array(replayed.get(
		"active_particle_count_uniforms",
		[],
	)):
		if not is_equal_approx(
			float(active_count_uniform),
			replayed_active_head_count,
		):
			errors.append("replayed Watershed flow count missed a water shader")
			break
	for coverage_uniform: Variant in Array(replayed.get(
		"water_coverage_fraction_uniforms",
		[],
	)):
		if not is_equal_approx(float(coverage_uniform), 0.42):
			errors.append("replayed Watershed coverage missed a water shader")
			break
	for base_speed_uniform: Variant in Array(replayed.get(
		"base_speed_uniforms",
		[],
	)):
		if not is_equal_approx(float(base_speed_uniform), 252.0):
			errors.append("replayed Watershed speed missed a water shader")
			break
	if not bool(bus.call(&"submit_packet", same_state_packet, "smoke-test", 0)):
		errors.append("current decision did not confirm the replayed Watershed state")
	await get_tree().process_frame
	var replay_confirmed: Dictionary = stage.call(&"runtime_summary")
	if not (
		String(replay_confirmed.get("watershed_ai_applied_decision_id", ""))
			== "watershed-smoke-2"
		and String(replay_confirmed.get("watershed_ai_applied_source", ""))
			== "CURRENT_DECISION"
		and int(replay_confirmed.get("watershed_ai_apply_count", -1)) == apply_count
	):
		errors.append("exact current decision did not confirm without repeated GPU work")
	for coverage_uniform: Variant in Array(replay_confirmed.get(
		"water_coverage_fraction_uniforms",
		[],
	)):
		if not is_equal_approx(float(coverage_uniform), 0.42):
			errors.append("confirmed Watershed replay lost its water coverage")
			break

	var replacement_state := state.duplicate(true)
	replacement_state["decision_id"] = "watershed-smoke-3"
	replacement_state["atmospheric_input_rate"] = 0.40
	replacement_state["reservoir_release_rate"] = 0.0
	replacement_state["available_supply_rate"] = 0.40
	replacement_state["extraction_fraction"] = 0.50
	replacement_state["remaining_rate"] = 0.20
	replacement_state["salmon_fraction"] = 0.20
	replacement_state["floodplain_fraction"] = 0.30
	replacement_state["agriculture_fraction"] = 0.05
	replacement_state["data_center_fraction"] = 0.15
	replacement_state["city_fraction"] = 0.30
	replacement_state["reservoir_storage_fraction"] = 0.20
	var replacement_packet := _watershed_ai_smoke_packet(replacement_state)
	if not bool(bus.call(
		&"submit_packet",
		replacement_packet,
		"smoke-test",
		0,
	)):
		errors.append("a current Watershed decision did not replace the replayed fallback")
	await get_tree().process_frame
	var replaced: Dictionary = stage.call(&"runtime_summary")
	var replaced_counts: Dictionary = replaced.get(
		"regime_feature_slot_counts_desired",
		{},
	)
	if not (
		String(replaced.get("watershed_ai_applied_decision_id", ""))
			== "watershed-smoke-3"
		and String(replaced.get("watershed_ai_applied_source", ""))
			== "CURRENT_DECISION"
		and String(replaced.get("watershed_ai_applied_state_hash", ""))
			!= applied_hash
		and String(replaced.get(
			"watershed_ai_last_successful_decision_id",
			"",
		)) == "watershed-smoke-3"
		and int(replaced.get("watershed_ai_apply_count", -1)) == apply_count + 1
		and is_equal_approx(float(replaced.get("basin_input_rate", -1.0)), 0.40)
		and is_equal_approx(
			float(replaced.get("total_extraction_fraction", -1.0)),
			0.50,
		)
		and is_equal_approx(float(replaced.get("basin_remaining_rate", -1.0)), 0.20)
		and not bool(replaced.get("gate_open", true))
		and int(replaced_counts.get("drain", -1)) == 1
		and _managed_active_feature_layout(replayed, "drain") != (
			_managed_active_feature_layout(replaced, "drain")
		)
		and String(replaced.get(
			"watershed_ai_last_successful_cache_status",
			"",
		)) == "SAVED"
		and FileAccess.file_exists(WATERSHED_AI_SMOKE_CACHE_PATH)
	):
		errors.append("today's Watershed decision did not fully replace the fallback")
	regimes.call(&"clear_regimes")


func _watershed_ai_smoke_state(decision_id: String) -> Dictionary:
	return {
		"schema_version": 2,
		"decision_id": decision_id,
		"atmospheric_input_rate": 0.60,
		"reservoir_release_rate": 0.10,
		"available_supply_rate": 0.70,
		"extraction_fraction": 0.40,
		"remaining_rate": 0.42,
		"salmon_fraction": 0.35,
		"floodplain_fraction": 0.25,
		"agriculture_fraction": 0.15,
		"data_center_fraction": 0.15,
		"city_fraction": 0.10,
		"reservoir_storage_fraction": 0.50,
		"hydropower_fraction": 0.0,
		"water_project_fraction": 0.0,
	}


func _watershed_ai_smoke_packet(state: Dictionary) -> Dictionary:
	return {
		"protocol": "ink-flow/1",
		"control_scope": "watershed-ai/2",
		"target": "delta",
		"changes": {"watershed.ai.state": state.duplicate(true)},
		"geometry_ops": [],
		"actions": [],
		"metadata": {
			"source": "gpu-stage-smoke",
			"request_id": String(state.get("decision_id", "")),
		},
	}


func _check_water_temperature_title(
	stage: Node,
	water_viewport: SubViewport,
	title_label: Label,
	separate_temperature_label: Node,
	summary: Dictionary,
	errors: PackedStringArray
) -> void:
	if separate_temperature_label != null:
		errors.append("water temperature still has a separate Label")
	if title_label == null:
		errors.append("temperature-bearing stage title is missing")
		return
	if not title_label.visible:
		errors.append("Delta temperature-bearing stage title is not visible")
	if water_viewport != null and water_viewport.is_ancestor_of(title_label):
		errors.append("temperature-bearing title is inside the water-only viewport")
	if not bool(summary.get("water_texture_excludes_stage_temperature", false)):
		errors.append("water texture does not exclude the temperature label")
	if not (
		bool(summary.get("water_temperature_visible", false))
		and bool(summary.get("water_temperature_value_valid", false))
		and bool(summary.get("water_temperature_data_loaded", false))
		and String(summary.get("water_temperature_data_error", "")).is_empty()
		and String(summary.get("water_temperature_data_path", ""))
			== EXPECTED_TEMPERATURE_DATA_PATH
		and String(summary.get("water_temperature_data_column", ""))
			== EXPECTED_DELTA_TEMPERATURE_COLUMN
		and int(summary.get("water_temperature_data_row_count", 0))
			== EXPECTED_TEMPERATURE_ROW_COUNT
		and String(summary.get("water_temperature_interpolation_mode", ""))
			== EXPECTED_TEMPERATURE_INTERPOLATION
	):
		errors.append("runtime summary does not expose the loaded Delta temperature")
	if not (
		Vector2(summary.get(
			"water_temperature_position",
			Vector2.ZERO,
		)) == EXPECTED_TITLE_POSITION
		and String(summary.get("water_temperature_position_anchor", ""))
			== "CENTERLINE"
		and is_equal_approx(
			float(summary.get("water_temperature_rotation_degrees", 0.0)),
			-90.0,
		)
		and Color(summary.get(
			"water_temperature_color",
			Color.TRANSPARENT,
		)).is_equal_approx(EXPECTED_TITLE_COLOR)
		and int(summary.get("water_temperature_font_size", 0))
			== EXPECTED_TITLE_FONT_SIZE
		and String(summary.get("water_temperature_font_resource", ""))
			== EXPECTED_TITLE_FONT_PATH
		and bool(summary.get("water_temperature_font_shared_with_date", false))
		and bool(summary.get("water_temperature_font_shared_with_title", false))
		and bool(summary.get("water_temperature_tabular_numerals", false))
		and String(summary.get("water_temperature_opentype_feature", ""))
			== EXPECTED_DATE_OPENTYPE_FEATURE
		and String(summary.get("water_temperature_node_path", ""))
			== "StageTitleLayer/StageTitle"
		and bool(summary.get(
			"water_temperature_integrated_with_stage_title",
			false,
		))
		and String(summary.get("water_temperature_format", "")) == "%.1f °C"
		and String(summary.get("water_temperature_fallback_text", "")) == "— °C"
	):
		errors.append("runtime summary does not expose temperature typography")

	var fixture_values := _load_temperature_fixture_column(
		EXPECTED_DELTA_TEMPERATURE_COLUMN,
		errors,
	)
	if fixture_values.size() != EXPECTED_TEMPERATURE_ROW_COUNT:
		return
	var row_index := int(summary.get("water_temperature_data_row_index", -1))
	var row_fraction := float(summary.get(
		"water_temperature_data_row_fraction",
		-1.0,
	))
	var timeline := get_node_or_null("/root/ModelTimeline")
	if timeline == null:
		errors.append("temperature check cannot find the shared timeline")
		return
	var timeline_snapshot: Dictionary = timeline.call(&"snapshot")
	var row_position := (
		float(timeline_snapshot.get("year_progress", 0.0))
		* float(EXPECTED_TEMPERATURE_ROW_COUNT)
	)
	var expected_row := mini(
		floori(row_position),
		EXPECTED_TEMPERATURE_ROW_COUNT - 1,
	)
	var expected_fraction := row_position - floorf(row_position)
	if row_index != expected_row or not is_equal_approx(
		row_fraction,
		expected_fraction,
	):
		errors.append("temperature row is not synchronized to ModelTimeline")
		return
	var following_row := (row_index + 1) % EXPECTED_TEMPERATURE_ROW_COUNT
	var expected_value := lerpf(
		float(fixture_values[row_index]),
		float(fixture_values[following_row]),
		row_fraction,
	)
	var actual_value := float(summary.get("water_temperature_value_c", NAN))
	if not is_equal_approx(actual_value, expected_value):
		errors.append("Delta temperature does not interpolate its selected column")
	var expected_temperature_text := "%.1f °C" % expected_value
	var expected_title_text := "Smoke River (%s)" % expected_temperature_text
	if title_label.text != expected_title_text:
		errors.append(
			"temperature-bearing title must be '%s'; got '%s'"
				% [expected_title_text, title_label.text]
		)
	if (
		String(summary.get("water_temperature_text", ""))
			!= expected_temperature_text
		or String(summary.get("stage_title_display_text", ""))
			!= expected_title_text
	):
		errors.append("runtime summary does not match the temperature-bearing title")

	if not bool(stage.call(
		&"set_runtime_parameter",
		&"temperature.visible",
		false,
	)):
		errors.append("temperature.visible=false was rejected")
	var hidden_summary: Dictionary = stage.call(&"runtime_summary")
	if (
		title_label.text != "Smoke River"
		or bool(hidden_summary.get("water_temperature_visible", true))
		or bool(hidden_summary.get("stage_title_temperature_visible", true))
	):
		errors.append("hiding temperature did not restore the title-only display")
	stage.call(&"set_runtime_parameter", &"temperature.visible", true)

	if bool(stage.call(
		&"set_runtime_parameter",
		&"temperature.data_column",
		"",
	)):
		errors.append("empty temperature column unexpectedly reported READY")
	var fallback_summary: Dictionary = stage.call(&"runtime_summary")
	if (
		title_label.text != "Smoke River (— °C)"
		or String(fallback_summary.get("water_temperature_text", "")) != "— °C"
		or String(fallback_summary.get("water_temperature_fallback_text", ""))
			!= "— °C"
		or bool(fallback_summary.get("water_temperature_value_valid", true))
	):
		errors.append("missing temperature did not use the in-title fallback")
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"temperature.data_column",
		EXPECTED_DELTA_TEMPERATURE_COLUMN,
	)):
		errors.append("restoring the Delta temperature column failed")
	var restored_summary: Dictionary = stage.call(&"runtime_summary")
	if (
		title_label.text != expected_title_text
		or String(restored_summary.get("stage_title_display_text", ""))
			!= expected_title_text
	):
		errors.append("restoring temperature did not restore the combined title")


func _load_temperature_fixture_column(
	column_name: String,
	errors: PackedStringArray
) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	if not FileAccess.file_exists(EXPECTED_TEMPERATURE_DATA_PATH):
		errors.append("temperature fixture is missing")
		return values
	var column_index := -1
	for raw_line: String in FileAccess.get_file_as_string(
		EXPECTED_TEMPERATURE_DATA_PATH
	).split("\n", false):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var delimiter := "," if line.contains(",") else "\t"
		var columns := line.split(delimiter, false)
		if column_index < 0:
			column_index = columns.find(column_name)
			if column_index < 0:
				errors.append(
					"temperature fixture is missing column %s" % column_name
				)
				return values
			continue
		if columns.size() <= column_index or not String(
			columns[column_index]
		).is_valid_float():
			errors.append("temperature fixture contains an invalid data row")
			return PackedFloat64Array()
		values.append(float(columns[column_index]))
	if values.size() != EXPECTED_TEMPERATURE_ROW_COUNT:
		errors.append(
			"temperature fixture must contain exactly 720 rows; got %d"
				% values.size()
		)
	return values


func _check_regime_panel(
	stage: Node,
	water_viewport: SubViewport,
	regime_panel: Node2D,
	regime_heading: Label,
	errors: PackedStringArray
) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	var shoreline_geometry := _shoreline_geometry_from_summary(summary)
	if Vector2(summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	)) != Vector2(28.0, 1052.0):
		errors.append("inactive shoreline unexpectedly narrowed the water inlet")
	if not bool(summary.get("regime_state_shared", false)):
		errors.append("stage is not bound to the in-memory ModelRegimes autoload")
	if not (
		bool(summary.get("regime_profiles_loaded", false))
		and int(summary.get("regime_profile_count", 0)) == 7
	):
		errors.append("stage did not load all seven regime profiles")
	if Array(summary.get("regime_names", [])) != EXPECTED_REGIME_NAMES:
		errors.append("regime names are not in the required historical order")
	if regime_panel == null:
		errors.append("active-regime panel is missing")
		return
	if regime_panel.position != EXPECTED_REGIME_PANEL_POSITION:
		errors.append("active-regime panel is not anchored to the lower centerlines")
	if not is_equal_approx(regime_panel.rotation_degrees, -90.0):
		errors.append("active-regime panel is not rotated -90 degrees")
	if not regime_panel.visible:
		errors.append("explicitly enabled active-regime panel is hidden")
	if regime_heading == null:
		errors.append("active-regime heading is missing")
	else:
		if regime_heading.text != "Regime":
			errors.append("active-regime heading text is incorrect")
		if regime_heading.get_theme_font_size(&"font_size") != 48:
			errors.append("active-regime heading is not 48 px")
		if not regime_heading.get_theme_color(&"font_color").is_equal_approx(
			EXPECTED_TITLE_COLOR
		):
			errors.append("active-regime heading is not full-alpha #4AB0E1")
	if water_viewport != null and water_viewport.is_ancestor_of(regime_panel):
		errors.append("active-regime panel is inside the water occupancy texture")
	for index in range(EXPECTED_REGIME_NAMES.size()):
		var label := stage.get_node_or_null(
			"StageTitleLayer/ActiveRegimes/Regime%d" % (index + 1)
		) as Label
		if label == null:
			errors.append("active-regime label %d is missing" % (index + 1))
			continue
		var expected_label: String = EXPECTED_REGIME_NAMES[index]
		if index == 3:
			expected_label = "Water Project"
		elif index == 6:
			expected_label = "AI Watershed"
		if label.text != expected_label:
			errors.append("active-regime label order is incorrect")
		if label.get_theme_font_size(&"font_size") != EXPECTED_TITLE_FONT_SIZE:
			errors.append("regime name font does not match the title/date")
		var initial_color := label.get_theme_color(&"font_color")
		if not is_equal_approx(initial_color.a, 0.25):
			errors.append("inactive regime is not rendered at 25% alpha")
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"regimes.active_names",
		["Agriculture", "Tech"],
	)):
		errors.append("absolute active-regime controller path was rejected")
	var active_summary: Dictionary = stage.call(&"runtime_summary")
	if Array(active_summary.get("active_regime_names", [])) != ["Agriculture", "Tech"]:
		errors.append("absolute active-regime set did not reach shared state")
	_expect_pollution_sources(
		active_summary,
		["data_center_east"],
		"Agriculture + Tech",
		errors,
	)
	if not is_equal_approx(
		float(active_summary.get("shoreline_randomness", -1.0)),
		0.0,
	):
		errors.append("Delta Agriculture + Tech shoreline was not explicitly straight")
	if not bool(active_summary.get("regime_profile_physics_enabled", false)):
		errors.append("per-river regime physics is not enabled")
	var active_budgets: Dictionary = active_summary.get(
		"regime_applied_feature_budgets",
		{}
	)
	for budget_spec: Array in [
		["reservoir_area_fraction", 0.475],
		["reservoir_count_raw", 2.0],
		["drain_area_fraction", 0.75],
		["drain_power", 1.0],
		["obstacle_area_fraction", 0.1],
	]:
		if not is_equal_approx(
			float(active_budgets.get(String(budget_spec[0]), -1.0)),
			float(budget_spec[1])
		):
			errors.append("normalized regime feature budget is incorrect: %s" % budget_spec[0])
	for uniform_spec: Array in [
		["regime_reservoir_weight_uniforms", 0.475],
		["regime_drain_weight_uniforms", 0.75],
		["regime_drain_power_uniforms", 1.0],
		["regime_obstacle_weight_uniforms", 0.1],
	]:
		var uniform_values := Array(active_summary.get(String(uniform_spec[0]), []))
		if uniform_values.size() != 7:
			errors.append("regime budget did not reach all seven water shaders")
			continue
		for uniform_value: Variant in uniform_values:
			if not is_equal_approx(float(uniform_value), float(uniform_spec[1])):
				errors.append("regime budget shader uniform is inconsistent")
				break
	if _shoreline_geometry_from_summary(active_summary) != shoreline_geometry:
		errors.append("regime activation unexpectedly created shoreline geometry")
	_check_edge_turbulence_contract(active_summary, 0.0, errors)
	_expect_regime_slot_counts(
		active_summary,
		{"drain": 4, "obstacle": 1},
		"Agriculture + Tech",
		errors,
	)
	var active_inlet_range := Vector2(active_summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	))
	if active_inlet_range != Vector2(28.0, 1052.0):
		errors.append("straight/disabled shoreline did not retain the full inlet range")
	for inlet_uniform: Variant in Array(active_summary.get(
		"shoreline_inlet_y_range_uniforms",
		[],
	)):
		if not Vector2(inlet_uniform).is_equal_approx(active_inlet_range):
			errors.append("shoreline inlet range did not reach every water head shader")
			break
	for index in range(EXPECTED_REGIME_NAMES.size()):
		var label := stage.get_node_or_null(
			"StageTitleLayer/ActiveRegimes/Regime%d" % (index + 1)
		) as Label
		if label == null:
			continue
		var expected_alpha := 1.0 if index in [1, 5] else 0.25
		if not is_equal_approx(
			label.get_theme_color(&"font_color").a,
			expected_alpha,
		):
			errors.append("active/inactive regime alpha did not refresh")
	_expect_regime_feature_values(
		active_summary,
		"Agriculture + Tech",
		[
			["reservoir_area_fraction", 0.475],
			["reservoir_count", 2.0],
			["drain_area_fraction", 0.75],
			["drain_power", 1.0],
			["obstacle_area_fraction", 0.1],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	_check_delta_regime_profile_contracts(stage, errors)
	var control_bus := get_node_or_null("/root/FlowControlBus") as Node
	if control_bus == null:
		errors.append("FlowControlBus is unavailable for the Kinship packet check")
	else:
		var packet_applied := bool(control_bus.call(
			&"submit_packet",
			{
				"protocol": "ink-flow/1",
				"target": "*",
				"changes": {"regimes.active_indices": [0]},
			},
			"smoke-test",
			0,
		))
		if not packet_applied:
			errors.append("FlowControlBus rejected the Kinship regime packet")
	var kinship_summary: Dictionary = stage.call(&"runtime_summary")
	if Array(kinship_summary.get("active_regime_indices", [])) != [0]:
		errors.append("Kinship packet did not update the stage regime state")
	_expect_pollution_sources(kinship_summary, [], "Kinship", errors)
	var kinship_label := stage.get_node_or_null(
		"StageTitleLayer/ActiveRegimes/Regime1"
	) as Label
	if (
		kinship_label == null
		or not is_equal_approx(
			kinship_label.get_theme_color(&"font_color").a,
			1.0,
		)
	):
		errors.append("Kinship packet did not highlight the Delta regime label")
	var kinship_features: Dictionary = kinship_summary.get(
		"regime_effective_features",
		{}
	)
	for kinship_spec: Array in [
		["reservoir_area_fraction", 0.0],
		["drain_area_fraction", 0.0],
		["obstacle_area_fraction", 0.0],
		["shoreline_randomness", 1.0],
		["salmon_activity", 1.0],
		["leaf_activity", 1.0],
	]:
		if not is_equal_approx(
			float(kinship_features.get(String(kinship_spec[0]), -1.0)),
			float(kinship_spec[1])
		):
			errors.append("Kinship profile value is incorrect: %s" % kinship_spec[0])
	var active_schedules: Dictionary = kinship_summary.get(
		"regime_active_schedules",
		{}
	)
	var kinship_schedule: Dictionary = active_schedules.get("kinship", {})
	if not (
		String(kinship_schedule.get("salmon_start_mm_dd", "")) == "04/15"
		and String(kinship_schedule.get("salmon_end_mm_dd", "")) == "08/15"
		and String(kinship_schedule.get("salmon_interval_days", "")) == "1"
		and String(kinship_schedule.get("leaf_start_mm_dd", "")) == "10/01"
		and String(kinship_schedule.get("leaf_end_mm_dd", "")) == "10/31"
		and String(kinship_schedule.get("leaf_interval_days", "")) == "2"
	):
		errors.append("Kinship seasonal schedule was not loaded from the profile table")
	var kinship_presence: Dictionary = kinship_summary.get(
		"regime_feature_presence",
		{},
	)
	if (
		bool(kinship_presence.get("reservoir", true))
		or bool(kinship_presence.get("drain", true))
		or bool(kinship_presence.get("obstacle", true))
	):
		errors.append("Kinship did not remove reservoirs, drains, and obstacles")
	if bool(kinship_summary.get("reservoir_overlay_visible", true)):
		errors.append("Kinship did not hide the reservoir diagnostic overlay")
	if int(kinship_summary.get("interaction_overlay_visible_count", -1)) != 0:
		errors.append("Kinship did not hide drain and obstacle diagnostic overlays")
	_expect_regime_slot_counts(
		kinship_summary,
		{"drain": 0, "obstacle": 0},
		"Kinship",
		errors,
	)
	_check_edge_turbulence_contract(kinship_summary, 1.0, errors)
	for reservoir_present: Variant in Array(
		kinship_summary.get("regime_reservoir_present_uniforms", [])
	):
		if bool(reservoir_present):
			errors.append("Kinship reservoir removal did not reach every water shader")
			break
	stage.call(&"set_active_regime_names", [])
	var cleared_summary: Dictionary = stage.call(&"runtime_summary")
	if not is_zero_approx(float(cleared_summary.get("shoreline_randomness", -1.0))):
		errors.append("clearing regimes did not disable shoreline force")
	if _shoreline_geometry_from_summary(cleared_summary) != shoreline_geometry:
		errors.append("clearing regimes unexpectedly created shoreline geometry")
	_check_edge_turbulence_contract(cleared_summary, 0.0, errors)
	_expect_regime_slot_counts(
		cleared_summary,
		{"drain": 1, "obstacle": 1},
		"cleared regime fallback",
		errors,
	)
	if Vector2(cleared_summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	)) != Vector2(28.0, 1052.0):
		errors.append("clearing shoreline force did not restore the full inlet range")
	var cleared_presence: Dictionary = cleared_summary.get(
		"regime_feature_presence",
		{},
	)
	if (
		not bool(cleared_presence.get("reservoir", false))
		or not bool(cleared_presence.get("drain", false))
		or not bool(cleared_presence.get("obstacle", false))
		or not bool(cleared_summary.get("reservoir_overlay_visible", false))
		or int(cleared_summary.get("interaction_overlay_visible_count", -1)) != 2
	):
		errors.append("clearing regimes did not restore authored feature visibility")


func _check_delta_regime_profile_contracts(
	stage: Node,
	errors: PackedStringArray
) -> void:
	var geometry_overlay := stage.get_node_or_null("ReservoirAndStatusOverlay")
	if geometry_overlay == null:
		errors.append("extractor geometry overlay is unavailable for hatch clipping")
	else:
		var clipped: PackedVector2Array = geometry_overlay.call(
			&"_clipped_segment_to_rect",
			Vector2(-5.0, 10.0),
			Vector2(15.0, -10.0),
			Rect2(0.0, 0.0, 10.0, 10.0),
		)
		var missed: PackedVector2Array = geometry_overlay.call(
			&"_clipped_segment_to_rect",
			Vector2(-5.0, -5.0),
			Vector2(-1.0, -1.0),
			Rect2(0.0, 0.0, 10.0, 10.0),
		)
		if not (
			clipped == PackedVector2Array([Vector2(0.0, 5.0), Vector2(5.0, 0.0)])
			and missed.is_empty()
		):
			errors.append("extractor hatch lattice is not clipped to site bounds")
		var data_center_geometry_color: Color = geometry_overlay.call(
			&"_geometry_color",
			"data_center",
			"absorb",
		)
		var mine_geometry_color: Color = geometry_overlay.call(
			&"_geometry_color",
			"mine",
			"absorb",
		)
		if not (
			data_center_geometry_color.is_equal_approx(Color("ff0000"))
			and mine_geometry_color.is_equal_approx(Color("d4af37"))
		):
			errors.append("Data Center/Mine hatch colors are not red/gold")
	stage.call(&"set_active_regime_names", ["Agriculture"])
	var agriculture: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(agriculture, [], "Agriculture Delta", errors)
	_expect_regime_feature_values(
		agriculture,
		"Agriculture Delta",
		[
			["drain_area_fraction", 0.75],
			["obstacle_area_fraction", 0.10],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	_expect_regime_slot_counts(
		agriculture,
		{"drain": 4, "obstacle": 1},
		"Agriculture Delta",
		errors,
	)
	_check_edge_turbulence_contract(agriculture, 0.0, errors)

	stage.call(&"set_active_regime_names", ["Gold Rush"])
	var gold_rush: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(
		gold_rush,
		[],
		"Gold Rush Delta",
		errors,
	)
	_expect_extractor_reveal_state(
		gold_rush,
		"gold_rush",
		false,
		[],
		["gold_mine"],
		"Gold Rush initial",
		errors,
	)
	var gold_pollution_accumulator := float(gold_rush.get(
		"pollution_emission_accumulator",
		-1.0,
	))
	stage.call(&"_advance_extractor_reveal", 29.999)
	var gold_before_reveal: Dictionary = stage.call(&"runtime_summary")
	_expect_extractor_reveal_state(
		gold_before_reveal,
		"gold_rush",
		false,
		[],
		["gold_mine"],
		"Gold Rush before 30-second reveal",
		errors,
	)
	if not is_equal_approx(
		float(gold_before_reveal.get("pollution_emission_accumulator", -2.0)),
		gold_pollution_accumulator,
	):
		errors.append("Gold Rush reveal timer reset the pollution cadence early")
	stage.call(&"_advance_extractor_reveal", 0.001)
	_expect_extractor_reveal_state(
		stage.call(&"runtime_summary"),
		"gold_rush",
		true,
		["gold_mine"],
		[],
		"Gold Rush expanded cohort",
		errors,
	)
	var gold_rush_geometry := _regime_geometry_snapshot(gold_rush)
	if String(gold_rush.get("regime_geometry_mode", "")) != (
		"GENERATION_SALTED_BOUNDED_SLOT_BANKS"
	):
		errors.append("regime geometry does not use generation-salted fixed slot banks")
	if _regime_geometry_snapshot(agriculture) == gold_rush_geometry:
		errors.append("Gold Rush reused the Agriculture feature placement")
	_expect_regime_slot_counts(
		gold_rush,
		{"drain": 2, "obstacle": 1},
		"Gold Rush Delta",
		errors,
	)
	_check_edge_turbulence_contract(gold_rush, 1.0, errors)
	var gold_rush_presence: Dictionary = gold_rush.get(
		"regime_feature_presence",
		{},
	)
	if (
		not bool(gold_rush_presence.get("reservoir", false))
		or int(gold_rush.get("regime_reservoir_count_rendered", 0)) != 1
	):
		errors.append("Gold Rush blank reservoir_count did not preserve its area reservoir")

	stage.call(&"set_active_regime_names", ["Hydropower"])
	var hydropower: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(hydropower, [], "Hydropower Delta", errors)
	var hydropower_geometry := _regime_geometry_snapshot(hydropower)
	if hydropower_geometry == gold_rush_geometry:
		errors.append("Hydropower reused the Gold Rush feature placement")
	_expect_feature_layouts_differ(
		gold_rush,
		hydropower,
		"Gold Rush",
		"Hydropower",
		errors,
	)
	if int(hydropower.get("reservoir_geometry_revision", 0)) == int(
		gold_rush.get("reservoir_geometry_revision", 0)
	):
		errors.append("regime switch did not flush live reservoir ownership")
	for revision_uniform: Variant in Array(hydropower.get(
		"reservoir_geometry_revision_uniforms",
		[],
	)):
		if not is_equal_approx(
			float(revision_uniform),
			float(hydropower.get("reservoir_geometry_revision", -1)),
		):
			errors.append("reservoir geometry revision missed a water shader")
			break
	_expect_regime_slot_counts(
		hydropower,
		{"drain": 2, "obstacle": 1},
		"Hydropower Delta",
		errors,
	)
	_check_edge_turbulence_contract(hydropower, 0.0, errors)
	_expect_regime_feature_values(
		hydropower,
		"Hydropower Delta",
		[
			["reservoir_area_fraction", 0.50],
			["reservoir_count", 2.0],
			["reservoir_gate_aperture_fraction", 0.33],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	_expect_applied_regime_values(
		hydropower,
		"Hydropower Delta",
		[
			["reservoir_area_fraction", 0.50],
			["reservoir_count_raw", 2.0],
			["reservoir_gate_aperture_fraction", 0.33],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	var schedules_by_screen: Dictionary = hydropower.get(
		"regime_active_schedules_by_screen",
		{},
	)
	var delta_schedules: Dictionary = schedules_by_screen.get("delta", {})
	var hydropower_schedule: Dictionary = delta_schedules.get("hydropower", {})
	if not (
		String(hydropower_schedule.get(
			"reservoir_gate_open_start_mm_dd",
			"",
		)) == "01/01"
		and String(hydropower_schedule.get(
			"reservoir_gate_open_end_mm_dd",
			"",
		)) == "12/31"
	):
		errors.append("Hydropower Delta gate is not scheduled year-round")
	if not (
		bool(hydropower.get("gate_open", false))
		and bool(hydropower.get("gate_open_regime_override_enabled", false))
		and is_equal_approx(
			float(hydropower.get("gate_aperture_fraction", -1.0)),
			0.33,
		)
		and is_equal_approx(
			float(hydropower.get("gate_release_probability_effective", -1.0)),
			0.33,
		)
	):
		errors.append("Hydropower Delta gate did not apply its year-round 0.33 aperture")

	stage.call(&"set_active_regime_names", ["Water Projects"])
	var water_projects: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(water_projects, [], "Water Projects Delta", errors)
	_expect_regime_slot_counts(
		water_projects,
		{"drain": 3, "obstacle": 1},
		"Water Projects Delta",
		errors,
	)
	_check_edge_turbulence_contract(water_projects, 0.0, errors)
	_expect_regime_feature_values(
		water_projects,
		"Water Projects Delta",
		[
			["reservoir_area_fraction", 0.33],
			["reservoir_count", 1.0],
			["drain_area_fraction", 0.50],
			["shoreline_randomness", 0.0],
			["leaf_activity", 0.0],
		],
		errors,
	)
	_expect_applied_regime_values(
		water_projects,
		"Water Projects Delta",
		[
			["reservoir_area_fraction", 0.33],
			["reservoir_count_raw", 1.0],
			["drain_area_fraction", 0.50],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	if not is_zero_approx(float(water_projects.get("regime_leaf_activity", -1.0))):
		errors.append("Water Projects Delta did not keep leaf activity disabled")

	stage.call(&"set_active_regime_names", ["Tech"])
	var tech: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(
		tech,
		["data_center_east"],
		"Tech Delta",
		errors,
	)
	_expect_extractor_reveal_state(
		tech,
		"tech",
		false,
		["data_center_east"],
		["data_center_north"],
		"Tech initial",
		errors,
	)
	var tech_elapsed_before_pause := float(
		Dictionary(Dictionary(tech.get("extractor_reveal_states", {})).get(
			"tech",
			{},
		)).get("elapsed_seconds", -1.0)
	)
	stage.call(&"set_paused", true)
	stage.call(&"_advance_extractor_reveal", 60.0)
	var tech_paused: Dictionary = stage.call(&"runtime_summary")
	var tech_paused_state: Dictionary = Dictionary(
		Dictionary(tech_paused.get("extractor_reveal_states", {})).get("tech", {})
	)
	if not is_equal_approx(
		float(tech_paused_state.get("elapsed_seconds", -2.0)),
		tech_elapsed_before_pause,
	):
		errors.append("paused Tech site reveal timer continued")
	stage.call(&"set_paused", false)
	stage.call(&"_advance_extractor_reveal", 29.999)
	var tech_before_reveal: Dictionary = stage.call(&"runtime_summary")
	_expect_extractor_reveal_state(
		tech_before_reveal,
		"tech",
		false,
		["data_center_east"],
		["data_center_north"],
		"Tech before 30-second reveal",
		errors,
	)
	stage.call(&"set_active_regime_names", ["Kinship", "Tech"])
	_expect_extractor_reveal_state(
		stage.call(&"runtime_summary"),
		"tech",
		false,
		["data_center_east"],
		["data_center_north"],
		"Tech preserved across unrelated regime change",
		errors,
	)
	stage.call(&"set_active_regime_names", ["Tech"])
	var tech_accumulator_before_reveal := float(
		Dictionary(stage.call(&"runtime_summary")).get(
			"pollution_emission_accumulator",
			-1.0,
		)
	)
	stage.call(&"_advance_extractor_reveal", 0.001)
	var tech_expanded: Dictionary = stage.call(&"runtime_summary")
	_expect_pollution_sources(
		tech_expanded,
		["data_center_north", "data_center_east"],
		"Tech expanded Delta",
		errors,
	)
	_expect_extractor_reveal_state(
		tech_expanded,
		"tech",
		true,
		["data_center_north", "data_center_east"],
		[],
		"Tech expanded sites",
		errors,
	)
	if not is_equal_approx(
		float(tech_expanded.get("pollution_emission_accumulator", -2.0)),
		tech_accumulator_before_reveal,
	):
		errors.append("Tech reveal reset the established pollution cadence")
	stage.call(&"set_active_regime_names", ["Hydropower"])
	stage.call(&"set_active_regime_names", ["Tech"])
	_expect_extractor_reveal_state(
		stage.call(&"runtime_summary"),
		"tech",
		false,
		["data_center_east"],
		["data_center_north"],
		"Tech reactivation reset",
		errors,
	)
	stage.call(&"_advance_extractor_reveal", 30.0)
	# Refresh the fixture after the intentional edge tests so the existing
	# Tech -> Agriculture generation assertions compare adjacent transitions.
	tech = stage.call(&"runtime_summary")
	var pollution_before_burst: Dictionary = tech.get("pollution_summary", {})
	var pollution_total_before := int(pollution_before_burst.get(
		"total_scheduled",
		0,
	))
	if int(stage.call(&"_release_pollution_burst")) != 2:
		errors.append("Tech pollution did not release one disk per Data Center")
	var pollution_after_burst: Dictionary = Dictionary(
		stage.call(&"runtime_summary").get("pollution_summary", {})
	)
	if not (
		int(pollution_after_burst.get("total_scheduled", 0))
			== pollution_total_before + 2
		and Dictionary(pollution_after_burst.get(
			"last_source_release_counts",
			{},
		)) == {
			"data_center_north": 1,
			"data_center_east": 1,
		}
	):
		errors.append("Tech pollution cadence is not one disk per active source")
	var pollution_total_before_stall := int(
		pollution_after_burst.get("total_scheduled", 0)
	)
	stage.set(&"_pollution_emission_accumulator", 5.25)
	stage.call(&"_advance_pollution_emission", 0.01)
	var after_stall: Dictionary = stage.call(&"runtime_summary")
	var after_stall_pollution := Dictionary(after_stall.get(
		"pollution_summary",
		{},
	))
	var after_stall_total := int(after_stall_pollution.get("total_scheduled", 0))
	stage.call(&"_advance_pollution_emission", 0.01)
	var after_next_frame: Dictionary = stage.call(&"runtime_summary")
	if not (
		after_stall_total == pollution_total_before_stall + 8
		and float(after_stall.get("pollution_emission_accumulator", -1.0)) < 1.0
		and int(Dictionary(after_next_frame.get(
			"pollution_summary",
			{},
		)).get("total_scheduled", 0)) == after_stall_total
	):
		errors.append("pollution stall guard replayed more than four bursts")
	var tech_geometry := _regime_geometry_snapshot(tech)
	var tech_generation := int(tech.get("regime_layout_generation", -1))
	var tech_update_count := int(tech.get("regime_geometry_update_count", -1))
	var tech_fields := _managed_active_feature_layout(tech, "drain")
	var tech_obstacles := _managed_active_feature_layout(tech, "obstacle")
	var tech_resource_signature := _feature_resource_signature(stage)
	if tech_geometry == hydropower_geometry:
		errors.append("Tech reused the Hydropower feature placement")
	_expect_feature_layouts_differ(
		hydropower,
		tech,
		"Hydropower",
		"Tech",
		errors,
	)
	_expect_regime_slot_counts(
		tech,
		{"drain": 4, "obstacle": 1},
		"Tech Delta",
		errors,
	)
	_check_edge_turbulence_contract(tech, 0.0, errors)
	_expect_regime_feature_values(
		tech,
		"Tech Delta",
		[
			["reservoir_area_fraction", 0.75],
			["reservoir_count", 2.0],
			["drain_area_fraction", 0.75],
			["drain_power", 1.0],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	_expect_applied_regime_values(
		tech,
		"Tech Delta",
		[
			["reservoir_area_fraction", 0.75],
			["reservoir_count_raw", 2.0],
			["drain_area_fraction", 0.75],
			["drain_power", 1.0],
			["shoreline_randomness", 0.0],
		],
		errors,
	)
	_expect_undefined_regime_fallbacks(
		tech,
		"Tech Delta",
		[
			["obstacle_area_fraction", "obstacle_area", "obstacle_area_fraction"],
		],
		errors,
	)

	# Every real active-set transition gets a fresh placement generation. Tech and
	# Agriculture deliberately request the same four fields and one obstacle, so
	# this direct transition catches the visually stale-layout regression without
	# relying on changed keys, inactive bank slots, or controller-owned geometry.
	stage.call(&"set_active_regime_names", ["Agriculture"])
	var agriculture_after_tech: Dictionary = stage.call(&"runtime_summary")
	var agriculture_generation := int(agriculture_after_tech.get(
		"regime_layout_generation",
		-1,
	))
	var agriculture_update_count := int(agriculture_after_tech.get(
		"regime_geometry_update_count",
		-1,
	))
	var agriculture_fields := _managed_active_feature_layout(
		agriculture_after_tech,
		"drain",
	)
	var agriculture_obstacles := _managed_active_feature_layout(
		agriculture_after_tech,
		"obstacle",
	)
	if agriculture_generation != tech_generation + 1:
		errors.append("Tech -> Agriculture did not advance layout generation once")
	if agriculture_update_count != tech_update_count + 1:
		errors.append("Tech -> Agriculture did not upload fresh geometry exactly once")
	if _feature_resource_signature(stage) != tech_resource_signature:
		errors.append("Tech -> Agriculture replaced a fixed feature resource")
	_expect_regime_slot_counts(
		agriculture_after_tech,
		{"drain": 4, "obstacle": 1},
		"Agriculture after Tech",
		errors,
	)
	_check_agriculture_field_contract(
		agriculture_after_tech,
		"Agriculture after Tech",
		errors,
	)
	_expect_meaningful_layout_change(
		tech_fields,
		agriculture_fields,
		"Tech",
		"Agriculture",
		"drain",
		errors,
	)
	_expect_meaningful_layout_change(
		tech_obstacles,
		agriculture_obstacles,
		"Tech",
		"Agriculture",
		"obstacle",
		errors,
	)

	# Replaying the same absolute state is a strict no-op.
	var agriculture_regime_revision := int(agriculture_after_tech.get(
		"regime_revision",
		-1,
	))
	stage.call(&"set_active_regime_names", ["Agriculture"])
	var agriculture_idempotent: Dictionary = stage.call(&"runtime_summary")
	if not (
		int(agriculture_idempotent.get("regime_revision", -2))
			== agriculture_regime_revision
		and int(agriculture_idempotent.get("regime_layout_generation", -2))
			== agriculture_generation
		and int(agriculture_idempotent.get("regime_geometry_update_count", -2))
			== agriculture_update_count
		and _managed_active_feature_layout(agriculture_idempotent, "drain")
			== agriculture_fields
		and _managed_active_feature_layout(agriculture_idempotent, "obstacle")
			== agriculture_obstacles
	):
		errors.append("replaying Agriculture respawned or republished its layout")

	# Reloading profile data may publish a new general model revision, but an
	# unchanged active set must not consume a visual layout generation.
	var model_regimes := get_node_or_null("/root/ModelRegimes")
	if model_regimes == null:
		errors.append("ModelRegimes is unavailable for the profile-reload layout check")
	else:
		if not bool(model_regimes.call(&"reload_profiles", true)):
			errors.append("profile reload failed during the layout-generation check")
		var agriculture_reloaded: Dictionary = stage.call(&"runtime_summary")
		if not (
			int(agriculture_reloaded.get("regime_layout_generation", -2))
				== agriculture_generation
			and int(agriculture_reloaded.get("regime_geometry_update_count", -2))
				== agriculture_update_count
			and _managed_active_feature_layout(agriculture_reloaded, "drain")
				== agriculture_fields
			and _managed_active_feature_layout(agriculture_reloaded, "obstacle")
				== agriculture_obstacles
		):
			errors.append("profile reload respawned an unchanged active regime set")

	# Returning to Tech is another real transition, so it must not restore the
	# first Tech pose even though the contributor IDs are identical.
	stage.call(&"set_active_regime_names", ["Tech"])
	var tech_return: Dictionary = stage.call(&"runtime_summary")
	var tech_return_fields := _managed_active_feature_layout(tech_return, "drain")
	var tech_return_obstacles := _managed_active_feature_layout(
		tech_return,
		"obstacle",
	)
	if int(tech_return.get("regime_layout_generation", -1)) != (
		agriculture_generation + 1
	):
		errors.append("returning to Tech did not advance layout generation once")
	if int(tech_return.get("regime_geometry_update_count", -1)) != (
		agriculture_update_count + 1
	):
		errors.append("returning to Tech did not upload fresh geometry exactly once")
	if tech_return_fields == tech_fields or tech_return_obstacles == tech_obstacles:
		errors.append("returning to Tech restored its previous feature placement")
	if (
		tech_return_fields == agriculture_fields
		or tech_return_obstacles == agriculture_obstacles
	):
		errors.append("returning to Tech retained the Agriculture feature placement")
	if _feature_resource_signature(stage) != tech_resource_signature:
		errors.append("returning to Tech replaced a fixed feature resource")

	stage.call(&"set_active_regime_names", ["Watershed"])
	var watershed: Dictionary = stage.call(&"runtime_summary")
	_expect_regime_slot_counts(
		watershed,
		{"drain": 1, "obstacle": 1},
		"undefined Watershed Delta",
		errors,
	)
	_check_edge_turbulence_contract(watershed, 0.0, errors)
	_expect_undefined_regime_fallbacks(
		watershed,
		"Watershed Delta",
		[
			["reservoir_area_fraction", "reservoir", "reservoir_area_fraction"],
			["drain_area_fraction", "drain_area", "drain_area_fraction"],
			["drain_power", "drain_power", "drain_power"],
			["obstacle_area_fraction", "obstacle_area", "obstacle_area_fraction"],
			["obstacle_power", "obstacle_power", "obstacle_power"],
		],
		errors,
	)
	var watershed_features: Dictionary = watershed.get(
		"regime_effective_feature_state",
		{},
	)
	var watershed_shoreline: Dictionary = watershed_features.get(
		"shoreline_randomness",
		{},
	)
	if (
		not bool(watershed_shoreline.get("defined", false))
		and not is_zero_approx(float(watershed.get("shoreline_randomness", -1.0)))
	):
		errors.append("undefined Watershed shoreline did not retain the baseline")
	var watershed_presence: Dictionary = watershed.get(
		"regime_feature_presence",
		{},
	)
	if (
		not bool(watershed_presence.get("reservoir", false))
		or not bool(watershed_presence.get("drain", false))
		or not bool(watershed_presence.get("obstacle", false))
	):
		errors.append("undefined Watershed features did not restore authored presence")
	var watershed_geometry := _regime_geometry_snapshot(watershed)
	var watershed_update_count := int(watershed.get(
		"regime_geometry_update_count",
		-1,
	))
	stage.call(&"set_active_regime_names", [])
	var cleared_after_watershed: Dictionary = stage.call(&"runtime_summary")
	if _regime_geometry_snapshot(cleared_after_watershed) != watershed_geometry:
		errors.append("no-op Watershed did not retain the authored fallback layout")
	if int(cleared_after_watershed.get("regime_geometry_update_count", -2)) != (
		watershed_update_count
	):
		errors.append("clearing no-op Watershed redundantly uploaded geometry")

func _check_controller_ownership_regression(
	stage: Node,
	errors: PackedStringArray,
) -> void:
	# Once the controller reshapes an authored object, that exact resource becomes
	# controller-owned. Later regime placement must leave the edited vertices alone.
	var controller_interaction_vertices := [
		[2.0, 2.0],
		[3.0, 2.0],
		[3.0, 3.0],
		[2.0, 3.0],
	]
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"polygon.absorber_test.vertices",
		controller_interaction_vertices,
	)):
		errors.append("controller could not reshape the authored interaction slot")
	for regime_name: String in ["Tech", "Agriculture", "Tech"]:
		stage.call(&"set_active_regime_names", [regime_name])
		_expect_controller_geometry_vertices(
			stage.call(&"runtime_summary"),
			regime_name,
			controller_interaction_vertices,
			errors,
		)
	stage.call(&"set_active_regime_names", [])
	_expect_controller_geometry_vertices(
		stage.call(&"runtime_summary"),
		"cleared regimes",
		controller_interaction_vertices,
		errors,
	)

	# Structural controller edits transfer exact resource ownership. Disabled
	# controller records remain packed, including a custom ID that happens to use
	# the internal-looking `regime_` prefix.
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"polygon.absorber_test.mode",
		"repel",
	)):
		errors.append("controller could not change an authored polygon mode")
	if not bool(stage.call(
		&"set_runtime_parameter",
		&"polygon.absorber_test.enabled",
		false,
	)):
		errors.append("controller could not disable an authored polygon")
	var guard_id := &"regime_controller_guard"
	if not bool(stage.call(
		&"_upsert_interaction_polygon",
		{
			"id": String(guard_id),
			"value": {
				"enabled": false,
				"mode": "repel",
				"vertices": [
					[4.0, 1.0],
					[4.5, 1.0],
					[4.5, 1.5],
					[4.0, 1.5],
				],
			},
		},
		"polygon",
	)):
		errors.append("controller could not add the regime_-prefixed guard polygon")
	for state_name: String in ["Tech", "Hydropower"]:
		stage.call(&"set_active_regime_names", [state_name])
		_expect_disabled_controller_records_packed(
			stage.call(&"runtime_summary"),
			state_name,
			errors,
		)
	stage.call(&"set_active_regime_names", [])
	_expect_disabled_controller_records_packed(
		stage.call(&"runtime_summary"),
		"cleared regimes",
		errors,
	)
	if not bool(stage.call(&"_remove_interaction_polygon", guard_id)):
		errors.append("controller could not remove the regime_-prefixed guard polygon")


func _regime_geometry_snapshot(summary: Dictionary) -> Dictionary:
	return {
		"reservoir_center": summary.get("reservoir_center_pixels", Vector2.ZERO),
		"interactions": Array(summary.get("interaction_polygons", [])).duplicate(true),
		"keys": Dictionary(summary.get("regime_geometry_keys", {})).duplicate(true),
	}


func _expect_feature_layouts_differ(
	before: Dictionary,
	after: Dictionary,
	before_label: String,
	after_label: String,
	errors: PackedStringArray,
) -> void:
	for feature_kind: String in ["drain", "obstacle"]:
		if _managed_active_feature_layout(before, feature_kind) == (
			_managed_active_feature_layout(
				after,
				feature_kind,
			)
		):
			errors.append(
				"%s reused the %s %s layout"
					% [after_label, before_label, feature_kind]
			)


func _managed_active_feature_layout(
	summary: Dictionary,
	feature_kind: String,
) -> Array:
	var result: Array = []
	var expected_mode := "absorb" if feature_kind == "drain" else "repel"
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if (
			definition_variant is Dictionary
			and String(definition_variant.get("mode", "")) == expected_mode
			and bool(definition_variant.get("enabled", false))
			and bool(definition_variant.get("regime_managed", false))
		):
			result.append([
				String(definition_variant.get("element_id", "")),
				Array(definition_variant.get("vertices", [])).duplicate(true),
			])
	return result


func _expect_meaningful_layout_change(
	before: Array,
	after: Array,
	before_label: String,
	after_label: String,
	feature_kind: String,
	errors: PackedStringArray,
) -> void:
	if before.is_empty() or before.size() != after.size():
		errors.append(
			"%s -> %s cannot compare the visible %s cohort"
				% [before_label, after_label, feature_kind]
		)
		return
	var before_by_id: Dictionary = {}
	for record_variant: Variant in before:
		if record_variant is Array and Array(record_variant).size() >= 2:
			var record: Array = record_variant
			before_by_id[String(record[0])] = record
	var minimum_displacement: float = INF
	var matching_count := 0
	for record_variant: Variant in after:
		if not record_variant is Array or Array(record_variant).size() < 2:
			continue
		var record: Array = record_variant
		var element_id := String(record[0])
		if not before_by_id.has(element_id):
			continue
		var previous: Array = before_by_id[element_id]
		minimum_displacement = minf(
			minimum_displacement,
			_layout_record_centroid(previous).distance_to(
				_layout_record_centroid(record),
			),
		)
		matching_count += 1
	if matching_count != before.size():
		errors.append(
			"%s -> %s replaced a fixed %s slot ID"
				% [before_label, after_label, feature_kind]
		)
	elif minimum_displacement < 1.0:
		errors.append(
			"%s -> %s moved a visible %s by less than 120 px"
				% [before_label, after_label, feature_kind]
		)


func _layout_record_centroid(record: Array) -> Vector2:
	if record.size() < 2 or not record[1] is Array:
		return Vector2.ZERO
	var vertices: Array = record[1]
	if vertices.is_empty():
		return Vector2.ZERO
	var centroid := Vector2.ZERO
	for point_variant: Variant in vertices:
		if point_variant is Array and Array(point_variant).size() >= 2:
			var point: Array = point_variant
			centroid += Vector2(float(point[0]), float(point[1]))
	return centroid / float(vertices.size())


func _check_agriculture_field_contract(
	summary: Dictionary,
	label: String,
	errors: PackedStringArray,
) -> void:
	if not (
		String(summary.get("field_intake_mode", ""))
			== "BANK_CONNECTED_LATERAL_SUCTION"
		and String(summary.get("field_absorption_edge_mode", ""))
			== "RIVER_FACING_MOUTH"
		and String(summary.get("field_turn_mode", ""))
			== "SHARP_QUARTER_TURN_AT_MOUTH"
		and String(summary.get("field_draining_state_policy", ""))
			== "RECORD_THROUGH_FIELD_THEN_RECYCLE_OFFSCREEN"
		and String(summary.get("field_tail_policy", ""))
			== "IMMUTABLE_SEGMENTS_FADE_WITHOUT_TELEPORT"
	):
		errors.append("%s does not expose the bank-field lifecycle contract" % label)
	var bank_counts := Dictionary(summary.get("regime_field_bank_counts", {}))
	if not (
		int(bank_counts.get("enabled", -1)) == 4
		and int(bank_counts.get("top", -1)) == 2
		and int(bank_counts.get("bottom", -1)) == 2
	):
		errors.append("%s does not distribute four fields 2 TOP / 2 BOTTOM" % label)
	var enabled_fields: Array[Dictionary] = []
	for layout_variant: Variant in Array(summary.get("regime_field_bank_layouts", [])):
		if layout_variant is Dictionary and bool(layout_variant.get("enabled", false)):
			enabled_fields.append(layout_variant)
	if enabled_fields.size() != 4:
		errors.append("%s does not expose four enabled bank-field layouts" % label)
	for layout: Dictionary in enabled_fields:
		var bank_side := String(layout.get("bank_side", ""))
		if not (
			String(layout.get("mode", "")) == "absorb"
			and bool(layout.get("regime_managed", false))
			and bool(layout.get("bank_connected", false))
			and bank_side in ["TOP", "BOTTOM"]
		):
			errors.append("%s exposes a non-bank-connected enabled field" % label)
			continue
		var native_vertices := PackedVector2Array(layout.get(
			"vertices_pixels",
			PackedVector2Array(),
		))
		var root_y := 0.0 if bank_side == "TOP" else 1080.0
		var root_vertex_count := 0
		for vertex: Vector2 in native_vertices:
			if is_equal_approx(vertex.y, root_y):
				root_vertex_count += 1
		if root_vertex_count < 2:
			errors.append(
				"%s %s field does not anchor its root at native y=%.0f"
					% [label, bank_side, root_y]
			)
	for uniform_spec: Array in [
		["bank_field_suction_reach_pixels", "bank_field_suction_reach_uniforms", 720.0],
		[
			"bank_field_suction_crossflow_ratio",
			"bank_field_suction_crossflow_uniforms",
			3.0,
		],
		[
			"bank_field_suction_streamwise_ratio",
			"bank_field_suction_streamwise_uniforms",
			0.0,
		],
		[
			"bank_field_min_withdrawal_speed_pixels",
			"bank_field_min_withdrawal_speed_uniforms",
			720.0,
		],
		["bank_field_capture_depth_pixels", "bank_field_capture_depth_uniforms", 18.0],
	]:
		var scalar_name := String(uniform_spec[0])
		var uniform_name := String(uniform_spec[1])
		var expected_value := float(uniform_spec[2])
		var uniform_values := Array(summary.get(uniform_name, []))
		if not is_equal_approx(float(summary.get(scalar_name, NAN)), expected_value):
			errors.append("%s has an incorrect %s" % [label, scalar_name])
		if uniform_values.size() != 7:
			errors.append("%s does not expose seven %s values" % [label, uniform_name])
			continue
		for value_variant: Variant in uniform_values:
			if not is_equal_approx(float(value_variant), expected_value):
				errors.append("%s has an inconsistent %s" % [label, uniform_name])
				break


func _expect_controller_geometry_vertices(
	summary: Dictionary,
	state_label: String,
	expected_interaction_vertices: Array,
	errors: PackedStringArray,
) -> void:
	var controller_definition := _definition_for_element(
		summary,
		"interaction_polygons",
		"absorber_test",
	)
	if Array(controller_definition.get("vertices", [])) != expected_interaction_vertices:
		errors.append(
			"%s regime move overwrote controller interaction vertices" % state_label
		)
	if not (
		String(controller_definition.get("mode", "")) == "absorb"
		and bool(controller_definition.get("enabled", false))
		and not bool(controller_definition.get("regime_managed", true))
		and not bool(controller_definition.get("bank_connected", true))
		and String(controller_definition.get("bank_side", "")) == "NONE"
	):
		errors.append(
			"%s did not preserve the controller-owned interior absorber behavior"
				% state_label
		)


func _definition_for_element(
	summary: Dictionary,
	collection_key: String,
	element_id: String,
) -> Dictionary:
	for definition_variant: Variant in Array(summary.get(collection_key, [])):
		if (
			definition_variant is Dictionary
			and String(definition_variant.get("element_id", "")) == element_id
		):
			return definition_variant
	return {}


func _expect_disabled_controller_records_packed(
	summary: Dictionary,
	state_label: String,
	errors: PackedStringArray,
) -> void:
	var absorber: Dictionary = {}
	var guard: Dictionary = {}
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if not definition_variant is Dictionary:
			continue
		var definition: Dictionary = definition_variant
		match String(definition.get("element_id", "")):
			"absorber_test":
				absorber = definition
			"regime_controller_guard":
				guard = definition
	if (
		absorber.is_empty()
		or bool(absorber.get("enabled", true))
		or String(absorber.get("mode", "")) != "repel"
	):
		errors.append("%s overwrote the controller-owned polygon state" % state_label)
	if guard.is_empty() or bool(guard.get("enabled", true)):
		errors.append("%s lost the disabled regime_-prefixed controller polygon" % state_label)
	var rendered := Dictionary(summary.get("regime_feature_slot_counts_rendered", {}))
	var interaction_packed := int(summary.get("interaction_overlay_count", 0))
	var explicit_extractor_count := int(summary.get(
		"active_regime_extractor_count",
		0,
	))
	# Explicit extractor rectangles replace generic regime drain slots in the
	# GPU texture; obstacles and both controller-owned records remain packed.
	var managed_interaction_count := explicit_extractor_count + int(
		rendered.get("obstacle", 0)
	)
	if explicit_extractor_count == 0:
		managed_interaction_count += int(rendered.get("drain", 0))
	if interaction_packed != managed_interaction_count + 2:
		errors.append("%s compacted a disabled controller polygon" % state_label)
	for count_variant: Variant in Array(summary.get("interaction_count_uniforms", [])):
		if int(count_variant) != interaction_packed:
			errors.append("%s controller polygon packing missed a shader" % state_label)
			break


func _expect_regime_feature_values(
	summary: Dictionary,
	label: String,
	expected: Array,
	errors: PackedStringArray
) -> void:
	var features: Dictionary = summary.get("regime_effective_feature_state", {})
	for spec: Array in expected:
		var feature_name := String(spec[0])
		var feature_state: Dictionary = features.get(feature_name, {})
		if not (
			bool(feature_state.get("defined", false))
			and is_equal_approx(
				float(feature_state.get("value", -1.0)),
				float(spec[1]),
			)
		):
			errors.append("%s feature is incorrect: %s" % [label, feature_name])


func _expect_applied_regime_values(
	summary: Dictionary,
	label: String,
	expected: Array,
	errors: PackedStringArray
) -> void:
	var budgets: Dictionary = summary.get("regime_applied_feature_budgets", {})
	for spec: Array in expected:
		var feature_name := String(spec[0])
		if not is_equal_approx(
			float(budgets.get(feature_name, -1.0)),
			float(spec[1]),
		):
			errors.append("%s applied budget is incorrect: %s" % [label, feature_name])


func _expect_undefined_regime_fallbacks(
	summary: Dictionary,
	label: String,
	specs: Array,
	errors: PackedStringArray
) -> void:
	var features: Dictionary = summary.get("regime_effective_feature_state", {})
	var overrides: Dictionary = summary.get("regime_applied_feature_overrides", {})
	var budgets: Dictionary = summary.get("regime_applied_feature_budgets", {})
	for spec: Array in specs:
		var feature_name := String(spec[0])
		var override_name := String(spec[1])
		var budget_name := String(spec[2])
		var feature_state: Dictionary = features.get(feature_name, {})
		if bool(feature_state.get("defined", false)):
			errors.append("%s unexpectedly defines %s" % [label, feature_name])
		if bool(overrides.get(override_name, false)):
			errors.append("%s unexpectedly overrides %s" % [label, feature_name])
		if not is_equal_approx(float(budgets.get(budget_name, -1.0)), 1.0):
			errors.append("%s did not preserve the %s fallback" % [label, feature_name])


func _expect_regime_slot_counts(
	summary: Dictionary,
	expected: Dictionary,
	label: String,
	errors: PackedStringArray,
) -> void:
	var desired := Dictionary(summary.get("regime_feature_slot_counts_desired", {}))
	var rendered := Dictionary(summary.get("regime_feature_slot_counts_rendered", {}))
	var resident := Dictionary(summary.get("regime_feature_slot_counts_resident", {}))
	if desired != expected:
		errors.append("%s desired slot counts are incorrect" % label)
	if rendered != expected:
		errors.append("%s rendered slot counts are incorrect" % label)
	if resident != EXPECTED_REGIME_SLOT_CAPACITIES:
		errors.append("%s changed the fixed resident feature bank" % label)
	# The rendered slot counts describe the fixed generic regime bank. Active
	# basin extractor rectangles can replace its drain records, so validate the
	# actual GPU count against the overlay's packed record count instead.
	var expected_interactions := int(summary.get("interaction_overlay_count", 0))
	for count_variant: Variant in Array(summary.get("interaction_count_uniforms", [])):
		if int(count_variant) != expected_interactions:
			errors.append("%s interaction slot count missed a water shader" % label)
			break


func _check_edge_turbulence_contract(
	summary: Dictionary,
	expected_amount: float,
	errors: PackedStringArray,
) -> void:
	if not (
		String(summary.get("shoreline_effect_mode", "")) == "EDGE_TURBULENCE"
		and is_equal_approx(
			float(summary.get("edge_turbulence_amount", -1.0)),
			expected_amount,
		)
		and is_equal_approx(
			float(summary.get("edge_turbulence_band_pixels", -1.0)),
			180.0,
		)
		and is_equal_approx(
			float(summary.get("edge_turbulence_wall_band_pixels", -1.0)),
			40.0,
		)
		and is_equal_approx(
			float(summary.get("edge_turbulence_crossflow_ratio", -1.0)),
			0.65,
		)
		and is_equal_approx(
			float(summary.get("edge_turbulence_streamwise_ratio", -1.0)),
			0.08,
		)
		and is_equal_approx(
			float(summary.get("edge_turbulence_inward_ratio", -1.0)),
			0.75,
		)
	):
		errors.append("edge-turbulence scalar contract is incorrect")
	for uniform_spec: Array in [
		["edge_turbulence_amount_uniforms", expected_amount],
		["edge_turbulence_band_uniforms", 180.0],
		["edge_turbulence_wall_band_uniforms", 40.0],
	]:
		var values := Array(summary.get(String(uniform_spec[0]), []))
		if values.size() != 7:
			errors.append("%s did not reach all seven water shaders" % uniform_spec[0])
			continue
		for value: Variant in values:
			if not is_equal_approx(float(value), float(uniform_spec[1])):
				errors.append("%s is inconsistent across water shaders" % uniform_spec[0])
				break
	if Vector2(summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	)) != Vector2(28.0, 1052.0):
		errors.append("edge turbulence narrowed the full-height water inlet")
	for inlet_variant: Variant in Array(
		summary.get("shoreline_inlet_y_range_uniforms", [])
	):
		if Vector2(inlet_variant) != Vector2(28.0, 1052.0):
			errors.append("the full-height inlet did not reach every water shader")
			break
	if int(summary.get("edge_turbulence_parameter_upload_count", 0)) < 1:
		errors.append("edge-turbulence parameters were never uploaded")


func _shoreline_geometry_from_summary(summary: Dictionary) -> Array:
	var geometry: Array = []
	for definition_variant: Variant in Array(
		summary.get("shoreline_obstacles", [])
	):
		if not definition_variant is Dictionary:
			continue
		var definition: Dictionary = definition_variant
		var vertices_variant: Variant = definition.get(
			"vertices_world", PackedVector2Array()
		)
		if vertices_variant is PackedVector2Array:
			var vertices: PackedVector2Array = vertices_variant
			geometry.append(vertices.duplicate())
	return geometry


func _check_kinship_ecology_schedule(
	stage: Node,
	errors: PackedStringArray
) -> void:
	for scale_spec: Array in [
		[25, 0.0, 0],
		[25, 0.5, 13],
		[25, 1.0, 25],
		[15, 0.5, 8],
	]:
		if int(stage.call(
			&"_scaled_regime_release_count",
			int(scale_spec[0]),
			float(scale_spec[1]),
		)) != int(scale_spec[2]):
			errors.append("0-1 regime activity did not scale an ecology batch")
	stage.call(&"set_model_date_mm_dd", "09/30-00:00")
	stage.call(&"set_active_regime_names", ["Kinship"])
	var before: Dictionary = stage.call(&"runtime_summary")
	var salmon_before: Dictionary = before.get("salmon_summary", {})
	var leaves_before: Dictionary = before.get("leaf_summary", {})

	stage.call(&"set_model_date_mm_dd", "10/01-00:00")
	var october_first: Dictionary = stage.call(&"runtime_summary")
	var october_first_leaves: Dictionary = october_first.get("leaf_summary", {})
	if int(october_first_leaves.get("total_scheduled", 0)) != (
		int(leaves_before.get("total_scheduled", 0)) + 30
	):
		errors.append("Kinship did not release 15 leaves per bank on October 1")
	if not is_equal_approx(float(october_first.get("regime_leaf_activity", 0.0)), 1.0):
		errors.append("Kinship leaf activity did not follow the profile weight")

	stage.call(&"set_model_date_mm_dd", "10/02-00:00")
	var october_second: Dictionary = stage.call(&"runtime_summary")
	if int(Dictionary(october_second.get("leaf_summary", {})).get(
		"total_scheduled",
		0
	)) != int(october_first_leaves.get("total_scheduled", 0)):
		errors.append("Kinship leaves released on the off day of the two-day interval")

	stage.call(&"set_model_date_mm_dd", "10/03-00:00")
	var october_third: Dictionary = stage.call(&"runtime_summary")
	if int(Dictionary(october_third.get("leaf_summary", {})).get(
		"total_scheduled",
		0
	)) != int(october_first_leaves.get("total_scheduled", 0)) + 30:
		errors.append("Kinship leaves did not release again on October 3")

	stage.call(&"set_model_date_mm_dd", "04/14-00:00")
	var april_fourteenth: Dictionary = stage.call(&"runtime_summary")
	if not is_zero_approx(float(april_fourteenth.get(
		"regime_salmon_activity",
		-1.0
	))):
		errors.append("Kinship salmon activity began before April 15")
	if int(Dictionary(april_fourteenth.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) != int(salmon_before.get("total_scheduled", 0)):
		errors.append("Kinship released salmon before April 15")

	stage.call(&"set_model_date_mm_dd", "04/15-00:00")
	var april_fifteenth: Dictionary = stage.call(&"runtime_summary")
	var april_salmon: Dictionary = april_fifteenth.get("salmon_summary", {})
	if int(april_salmon.get("total_scheduled", 0)) != (
		int(salmon_before.get("total_scheduled", 0)) + 150
	):
		errors.append("Kinship did not release six 25-salmon Delta cohorts on April 15")
	if (
		int(april_salmon.get("last_cohort_count", 0)) != 6
		or int(april_salmon.get("last_cohort_scheduled_count", 0)) != 150
	):
		errors.append("Kinship Delta release was not six joint 25-salmon cohorts")
	if not is_equal_approx(float(april_fifteenth.get("regime_salmon_activity", 0.0)), 1.0):
		errors.append("Kinship salmon activity did not follow the profile weight")

	stage.call(&"set_model_date_mm_dd", "04/15-12:00")
	var same_day: Dictionary = stage.call(&"runtime_summary")
	if int(Dictionary(same_day.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) != int(april_salmon.get("total_scheduled", 0)):
		errors.append("Kinship salmon released more than once on the same model day")
	stage.call(&"set_active_regime_names", [])
	stage.call(&"set_active_regime_names", ["Kinship"])
	var same_day_reactivated: Dictionary = stage.call(&"runtime_summary")
	if int(Dictionary(same_day_reactivated.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) != int(april_salmon.get("total_scheduled", 0)):
		errors.append("same-day Kinship off/on toggle duplicated a salmon release")

	stage.call(&"set_model_date_mm_dd", "04/16-00:00")
	var next_day: Dictionary = stage.call(&"runtime_summary")
	if not (
		int(next_day.get("model_day_index", -1)) == 105
		and int(next_day.get("model_minute_of_day", -1)) == 0
		and String(next_day.get("stage_date_text", "")) == "2026/04/16"
		and String(next_day.get("stage_date_format", "")) == "YYYY/MM/DD"
		and bool(next_day.get("stage_date_tabular_numerals", false))
	):
		errors.append("ModelTimeline did not reconstruct April 16 midnight exactly")
	var expected_water_year_dates := {
		181: "2025/07/01",
		364: "2025/12/31",
		0: "2026/01/01",
		180: "2026/06/30",
	}
	for day_index: int in expected_water_year_dates:
		if String(stage.call(&"_format_model_display_date", day_index)) != String(
			expected_water_year_dates[day_index]
		):
			errors.append("visible date did not preserve the 2025/2026 water-year boundary")
			break
	stage.call(&"set_model_date_mm_dd", "04/16-12:34")
	var same_visible_day: Dictionary = stage.call(&"runtime_summary")
	if not (
		String(same_visible_day.get("stage_date_text", "")) == "2026/04/16"
		and String(stage.call(&"get_model_date_time")) == "04/16-12:34"
	):
		errors.append("visible date exposed time or the internal minute was discarded")
	stage.call(&"set_model_date_mm_dd", "04/16-00:00")
	if int(Dictionary(next_day.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) != int(april_salmon.get("total_scheduled", 0)) + 150:
		errors.append("Kinship daily salmon release did not repeat on April 16")

	stage.call(&"set_model_date_mm_dd", "08/16-00:00")
	var outside_season: Dictionary = stage.call(&"runtime_summary")
	if not is_zero_approx(float(outside_season.get("regime_salmon_activity", -1.0))):
		errors.append("Kinship salmon activity did not stop after August 15")
	stage.call(&"set_model_date_mm_dd", "04/15-00:00")
	var next_year: Dictionary = stage.call(&"runtime_summary")
	if int(Dictionary(next_year.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) != int(Dictionary(next_day.get("salmon_summary", {})).get(
		"total_scheduled",
		0
	)) + 150:
		errors.append("Kinship salmon schedule did not re-arm for the next model year")
	stage.call(&"set_active_regime_names", [])


func _check_regime_runtime_stability(
	stage: Node,
	errors: PackedStringArray
) -> void:
	# Regime changes must mutate fixed materials/textures in place. They must not
	# leave behind stage nodes or grow any water/salmon/leaf particle pool.
	stage.call(&"set_model_date_mm_dd", "02/01-00:00")
	stage.call(&"set_active_regime_names", [])
	var baseline_node_count := _recursive_node_count(stage)
	var baseline_pool_signature := _particle_pool_signature(stage)
	var baseline_texture_signature := _stage_texture_signature(stage)
	var baseline_feature_resource_signature := _feature_resource_signature(stage)
	var baseline_slot_capacities := Dictionary(
		stage.call(&"runtime_summary").get("regime_feature_slot_counts_resident", {})
	).duplicate(true)
	var baseline_flow_model_count := get_tree().get_nodes_in_group(
		&"flow_models"
	).size()

	# Replaying the same absolute controller state is intentionally idempotent.
	stage.call(&"set_active_regime_names", ["Tech"])
	var before_idempotent: Dictionary = stage.call(&"runtime_summary")
	for _index in range(100):
		stage.call(&"set_active_regime_names", ["Tech"])
	var after_idempotent: Dictionary = stage.call(&"runtime_summary")
	for counter_name: String in [
		"regime_ecology_evaluation_count",
		"gate_state_upload_count",
		"edge_turbulence_parameter_upload_count",
		"regime_geometry_update_count",
		"regime_layout_generation",
	]:
		if after_idempotent.get(counter_name) != before_idempotent.get(counter_name):
			errors.append(
				"identical absolute regime state repeated %s work" % counter_name
			)
	for feature_kind: String in ["drain", "obstacle"]:
		if _managed_active_feature_layout(after_idempotent, feature_kind) != (
			_managed_active_feature_layout(before_idempotent, feature_kind)
		):
			errors.append(
				"identical absolute Tech state respawned its %s layout"
					% feature_kind
			)

	# The timeline publishes a shared state every render frame. Re-consuming an
	# unchanged day may update smooth watershed flow, but must not reparse regime
	# schedules, upload gate uniforms, or redraw gate geometry.
	var timeline := get_node_or_null("/root/ModelTimeline")
	if timeline == null:
		errors.append("shared ModelTimeline is unavailable for stability coverage")
	else:
		var frozen_timeline: Dictionary = timeline.call(&"snapshot")
		var before_timeline: Dictionary = stage.call(&"runtime_summary")
		for _index in range(100):
			stage.call(&"_on_model_timeline_changed", frozen_timeline)
		var after_timeline: Dictionary = stage.call(&"runtime_summary")
		if after_timeline.get("regime_ecology_evaluation_count") != before_timeline.get(
			"regime_ecology_evaluation_count"
		):
			errors.append("same-day timeline frames reevaluated regime ecology")
		if after_timeline.get("gate_state_upload_count") != before_timeline.get(
			"gate_state_upload_count"
		):
			errors.append("same-day timeline frames re-uploaded unchanged gate state")

	# Exercise true state changes, including Kinship's full shoreline and its
	# complete reservoir/drain/obstacle removal, while allowing render frames to
	# consume several transitions.
	for _switch_cycle in range(60):
		stage.call(&"set_active_regime_names", ["Kinship"])
		await get_tree().process_frame
		stage.call(&"set_active_regime_names", ["Tech"])
		await get_tree().process_frame
	stage.call(&"set_active_regime_names", [])
	await get_tree().process_frame

	if _recursive_node_count(stage) != baseline_node_count:
		errors.append("rapid regime switching changed the stage node count")
	if _particle_pool_signature(stage) != baseline_pool_signature:
		errors.append("rapid regime switching replaced or resized a particle pool")
	if _stage_texture_signature(stage) != baseline_texture_signature:
		errors.append("rapid regime switching replaced a resident stage texture")
	if _feature_resource_signature(stage) != baseline_feature_resource_signature:
		errors.append("rapid regime switching replaced a resident feature resource")
	var final_slot_capacities := Dictionary(
		stage.call(&"runtime_summary").get("regime_feature_slot_counts_resident", {})
	)
	if final_slot_capacities != baseline_slot_capacities:
		errors.append("rapid regime switching changed the fixed feature-bank capacities")
	if get_tree().get_nodes_in_group(&"flow_models").size() != baseline_flow_model_count:
		errors.append("rapid regime switching changed the live flow-model count")


func _expect_pollution_sources(
	summary: Dictionary,
	expected_ids: Array,
	context: String,
	errors: PackedStringArray,
) -> void:
	var actual_ids := Array(summary.get("pollution_active_source_ids", []))
	if actual_ids != expected_ids:
		errors.append("%s pollution sources are incorrect: %s" % [
			context,
			actual_ids,
		])
	if int(summary.get("pollution_active_source_count", -1)) != expected_ids.size():
		errors.append("%s pollution source count is incorrect" % context)
	if not (
		int(summary.get("pollution_particles_per_source", 0)) == 1
		and not bool(summary.get("pollution_never_fades", true))
		and String(summary.get("pollution_source_position_contract", ""))
			== "EXACT_EXTRACTOR_MOUTH"
		and String(summary.get("pollution_initial_state", "")) == "FREE_SEEKING"
		and String(summary.get("pollution_center_miss_behavior", ""))
			== "THROTTLED_RECHECK_THEN_FADE"
		and is_equal_approx(
			float(summary.get("pollution_center_recheck_interval_seconds", 0.0)),
			0.50,
		)
		and is_equal_approx(
			float(summary.get("pollution_center_hold_seconds", 0.0)),
			8.0,
		)
		and is_equal_approx(
			float(summary.get("pollution_center_fade_seconds", 0.0)),
			2.0,
		)
		and String(summary.get("pollution_retirement", ""))
			== "LATCHED_RIGHT_EDGE_OR_CENTER_TIMEOUT_OR_FULL_RESET"
		and Color(summary.get(
			"pollution_mine_color",
			Color.TRANSPARENT,
		)).is_equal_approx(Color("7f858a"))
		and Color(summary.get(
			"pollution_data_center_color",
			Color.TRANSPARENT,
		)).is_equal_approx(Color("ff0000"))
		and String(summary.get("pollution_color_routing", ""))
			== "MINE_GREY_DATA_CENTER_BRIGHT_RED_HEAT"
	):
		errors.append("%s pollution lifetime/cadence/color contract changed" % context)
	for source_variant: Variant in Array(summary.get(
		"pollution_active_sources",
		[],
	)):
		if not source_variant is Dictionary:
			errors.append("%s pollution source descriptor is malformed" % context)
			continue
		var source: Dictionary = source_variant
		var source_id := String(source.get("source_id", ""))
		var source_kind := String(source.get("kind", ""))
		var bank_side := String(source.get("bank_side", ""))
		var mouth_start := Vector2(source.get("mouth_start_pixels", Vector2.ZERO))
		var mouth_end := Vector2(source.get("mouth_end_pixels", Vector2.ZERO))
		var water_direction := Vector2(source.get(
			"water_direction_pixels",
			Vector2.ZERO,
		))
		var expected_bank := "BOTTOM" if source_id == "data_center_east" else "TOP"
		var expected_kind := "mine" if source_id == "gold_mine" else "data_center"
		var expected_direction := Vector2(0.0, -1.0) if expected_bank == "BOTTOM" else Vector2(0.0, 1.0)
		if (
			source_kind != expected_kind
			or bank_side != expected_bank
			or not water_direction.is_equal_approx(expected_direction)
			or mouth_end.x <= mouth_start.x
			or not is_equal_approx(mouth_start.y, mouth_end.y)
		):
			errors.append("%s %s has the wrong kind or river-facing mouth" % [
				context,
				source_id,
			])


func _expect_extractor_reveal_state(
	summary: Dictionary,
	state_key: String,
	expected_expanded: bool,
	expected_visible_ids: Array,
	expected_hidden_ids: Array,
	context: String,
	errors: PackedStringArray,
) -> void:
	if not (
		String(summary.get("extractor_reveal_mode", ""))
			== "DISCRETE_FULL_SIZE_SITE_COHORT"
		and is_equal_approx(
			float(summary.get("extractor_reveal_initial_fraction", -1.0)),
			0.50,
		)
		and is_equal_approx(
			float(summary.get("extractor_reveal_delay_seconds", -1.0)),
			30.0,
		)
		and int(summary.get(
			"extractor_reveal_initial_site_cap_per_type_per_screen",
			0,
		)) == 1
		and bool(summary.get("extractor_reveal_ai_watershed_bypass", false))
	):
		errors.append("%s extractor-reveal configuration is incorrect" % context)
		return
	var reveal_states := Dictionary(summary.get("extractor_reveal_states", {}))
	var reveal_state := Dictionary(reveal_states.get(state_key, {}))
	var sites := Array(reveal_state.get("sites", []))
	if (
		not bool(reveal_state.get("active", false))
		or bool(reveal_state.get("expanded", not expected_expanded))
			!= expected_expanded
		or Array(reveal_state.get("visible_site_ids", [])) != expected_visible_ids
		or Array(reveal_state.get("hidden_site_ids", [])) != expected_hidden_ids
		or int(reveal_state.get("visible_site_count", -1)) != expected_visible_ids.size()
		or int(reveal_state.get("hidden_site_count", -1)) != expected_hidden_ids.size()
		or sites.size() != expected_visible_ids.size() + expected_hidden_ids.size()
		or String(reveal_state.get("phase", "")) != (
			"EXPANDED_100_PERCENT" if expected_expanded else "INITIAL_50_PERCENT"
		)
	):
		errors.append("%s extractor-reveal state is incorrect: %s" % [
			context,
			reveal_state,
		])
		return
	var pollution_sources_by_id := {}
	for source_variant: Variant in Array(summary.get(
		"pollution_active_sources",
		[],
	)):
		if source_variant is Dictionary:
			pollution_sources_by_id[String(source_variant.get("source_id", ""))] = (
				source_variant
			)
	for site_variant: Variant in sites:
		if not site_variant is Dictionary:
			errors.append("%s has a malformed site descriptor" % context)
			continue
		var site: Dictionary = site_variant
		var rect: Rect2 = site.get("rect_world", Rect2())
		var bounds: Rect2 = site.get("bounds_pixels", Rect2())
		if not (
			rect.size.x > 0.0
			and rect.size.y > 0.0
			and is_equal_approx(bounds.size.x, rect.size.x * 120.0)
			and is_equal_approx(bounds.size.y, rect.size.y * 120.0)
		):
			errors.append("%s site geometry is not the full authored rectangle" % context)
		var element_id := String(site.get("element_id", ""))
		var source := Dictionary(pollution_sources_by_id.get(element_id, {}))
		var should_be_visible := bool(site.get("visible", false))
		if should_be_visible != expected_visible_ids.has(element_id):
			errors.append("%s visibility flag is wrong for %s" % [context, element_id])
			continue
		if not should_be_visible:
			if not source.is_empty():
				errors.append("%s hidden site %s still emits pollution" % [context, element_id])
			continue
		if source.is_empty():
			errors.append("%s visible site %s has no pollution source" % [context, element_id])
			continue
		var mouth_start := Vector2(source.get(
			"mouth_start_pixels",
			Vector2.ZERO,
		))
		var mouth_end := Vector2(source.get(
			"mouth_end_pixels",
			Vector2.ZERO,
		))
		if not is_equal_approx(mouth_end.x - mouth_start.x, bounds.size.x):
			errors.append("%s pollution mouth does not match full site %s" % [
				context,
				element_id,
			])


func _recursive_node_count(root: Node) -> int:
	var total := 1
	for child: Node in root.get_children():
		total += _recursive_node_count(child)
	return total


func _particle_pool_signature(root: Node) -> Array:
	var signature: Array = []
	for child_variant: Variant in root.find_children(
		"*",
		"GPUParticles2D",
		true,
		false,
	):
		var particles := child_variant as GPUParticles2D
		if particles == null:
			continue
		var process_material_id := 0
		if particles.process_material != null:
			process_material_id = particles.process_material.get_instance_id()
		var draw_material_id := 0
		if particles.material != null:
			draw_material_id = particles.material.get_instance_id()
		var texture_id := 0
		if particles.texture != null:
			texture_id = particles.texture.get_instance_id()
		signature.append([
			String(root.get_path_to(particles)),
			particles.get_instance_id(),
			particles.amount,
			process_material_id,
			draw_material_id,
			texture_id,
		])
	return signature


func _stage_texture_signature(stage: Node) -> Array:
	var signature: Array = []
	for property_name: String in ["_interaction_data_texture"]:
		var texture := stage.get(property_name) as Texture2D
		signature.append([
			property_name,
			texture.get_instance_id() if texture != null else 0,
			texture.get_rid() if texture != null else RID(),
		])
	var water_viewport := stage.get_node_or_null("WaterOnlyViewport") as SubViewport
	var water_texture := (
		water_viewport.get_texture() if water_viewport != null else null
	)
	signature.append([
		"water_viewport_texture",
		water_texture.get_instance_id() if water_texture != null else 0,
		water_texture.get_rid() if water_texture != null else RID(),
	])
	return signature


func _feature_resource_signature(stage: Node) -> Array:
	var signature: Array = []
	for property_name: String in ["interaction_polygons"]:
		var resources := Array(stage.get(property_name))
		var ids: Array = []
		for resource_variant: Variant in resources:
			var resource := resource_variant as Resource
			ids.append(resource.get_instance_id() if resource != null else 0)
		signature.append([property_name, ids])
	return signature


func _check_stage_title_runtime_independence(
	stage: Node,
	water_viewport: SubViewport,
	title_label: Label,
	errors: PackedStringArray
) -> void:
	if water_viewport == null or title_label == null:
		return
	var water_texture_rid := water_viewport.get_texture().get_rid()
	var before: Dictionary = stage.call(&"runtime_summary")
	var temperature_text := String(before.get("water_temperature_text", "— °C"))
	var expected_base_title_text := "Smoke River (%s)" % temperature_text
	var expected_runtime_title_text := "Runtime Smoke River (%s)" % temperature_text
	var salmon_before: Dictionary = before.get("salmon_summary", {}).duplicate(true)
	var leaves_before: Dictionary = before.get("leaf_summary", {}).duplicate(true)

	if not bool(stage.call(
		&"set_runtime_parameter", &"stage.title", "Runtime Smoke River"
	)):
		errors.append("stage.title runtime parameter was rejected")
	if not bool(stage.call(
		&"set_runtime_parameter", &"stage.title_visible", false
	)):
		errors.append("stage.title_visible runtime parameter was rejected")
	var changed: Dictionary = stage.call(&"runtime_summary")
	if title_label.text != expected_runtime_title_text or title_label.visible:
		errors.append("runtime title text/visibility did not update the Label directly")
	if not (
		String(changed.get("stage_title", "")) == "Runtime Smoke River"
		and String(changed.get("stage_title_display_text", ""))
			== expected_runtime_title_text
		and not bool(changed.get("stage_title_visible", true))
	):
		errors.append("runtime title text/visibility did not update the summary")
	if water_viewport.get_texture().get_rid() != water_texture_rid:
		errors.append("presentation-only title update replaced the water texture")
	var salmon_changed: Dictionary = changed.get("salmon_summary", {})
	var leaves_changed: Dictionary = changed.get("leaf_summary", {})
	for counter: String in ["release_serial", "total_scheduled"]:
		if salmon_changed.get(counter) != salmon_before.get(counter):
			errors.append("title update changed salmon %s" % counter)
		if leaves_changed.get(counter) != leaves_before.get(counter):
			errors.append("title update changed leaves %s" % counter)

	stage.call(&"set_runtime_parameter", &"stage.title", "Smoke River")
	stage.call(&"set_runtime_parameter", &"stage.title_visible", true)
	var v_key := InputEventKey.new()
	v_key.pressed = true
	v_key.keycode = KEY_V
	stage.call(&"_unhandled_input", v_key)
	var debug_toggled: Dictionary = stage.call(&"runtime_summary")
	if not bool(debug_toggled.get("debug_visible", false)):
		errors.append("V key hid geometry despite the always-visible invariant")
	if not title_label.visible or title_label.text != expected_base_title_text:
		errors.append("V/debug toggle changed the stage title")
	stage.call(&"_unhandled_input", v_key)

	stage.call(&"set_paused", true)
	var paused_title_summary: Dictionary = stage.call(&"runtime_summary")
	if not (
		title_label.visible
		and title_label.text == expected_base_title_text
		and String(paused_title_summary.get("stage_title", "")) == "Smoke River"
		and String(paused_title_summary.get("stage_title_display_text", ""))
			== expected_base_title_text
		and bool(paused_title_summary.get("stage_title_visible", false))
	):
		errors.append("pause changed the stage title")
	stage.call(&"set_paused", false)


func _check_stage_title_reset_independence(
	stage: Node,
	errors: PackedStringArray
) -> void:
	var water_viewport := stage.get_node_or_null("WaterOnlyViewport") as SubViewport
	var title_label := stage.get_node_or_null("StageTitleLayer/StageTitle") as Label
	if water_viewport == null or title_label == null:
		return
	var water_texture_rid := water_viewport.get_texture().get_rid()
	stage.call(&"queue_control_message", {"actions": ["reset"]})
	await get_tree().process_frame
	var reset_summary: Dictionary = stage.call(&"runtime_summary")
	var expected_display_text := String(reset_summary.get(
		"stage_title_display_text",
		"",
	))
	if not (
		title_label.visible
		and title_label.text == expected_display_text
		and expected_display_text.begins_with("Smoke River (")
		and String(reset_summary.get("stage_title", "")) == "Smoke River"
		and bool(reset_summary.get("stage_title_visible", false))
	):
		errors.append("simulation reset changed the stage title")
	if water_viewport.get_texture().get_rid() != water_texture_rid:
		errors.append("pause/reset replaced the water texture while preserving title")
	var pollution_summary: Dictionary = reset_summary.get("pollution_summary", {})
	if not (
		int(pollution_summary.get("release_serial", -1)) == 0
		and int(pollution_summary.get("total_scheduled", -1)) == 0
		and int(pollution_summary.get("resident_command_slots", -1)) == 0
	):
		errors.append("full reset did not clear the bounded pollution pool")
