extends Node

const STAGE_SCENE := preload(
	"res://flow/gpu_stage/gpu_flow_stage_2d.tscn"
)
const EXPECTED_LAYER_SLOTS := [43, 43, 43, 43, 43, 43, 42]
const EXPECTED_ACTIVE_HALF := [22, 22, 22, 21, 21, 21, 21]
const EXPECTED_LAYER_CAPACITIES := [3225, 3225, 3225, 3225, 3225, 3225, 3150]
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


func _ready() -> void:
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
	stage.set(&"screen_id", &"smoke_screen")
	stage.set(&"control_target", &"smoke_target")
	stage.set(&"stage_title", "Smoke River")
	stage.set(&"regime_panel_visible", true)
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
	var background := stage.get_node_or_null("Background") as ColorRect
	var title_layer := stage.get_node_or_null("StageTitleLayer") as Node2D
	var title_label := stage.get_node_or_null("StageTitleLayer/StageTitle") as Label
	var date_label := stage.get_node_or_null("StageTitleLayer/ModelDate") as Label
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
	if title_label == null:
		errors.append("stage title Label is missing")
	else:
		if title_label.text != "Smoke River":
			errors.append("stage title text did not use the exported title")
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
		var title_font := title_label.get_theme_font(&"font")
		if title_font == null or title_font.resource_path != EXPECTED_TITLE_FONT_PATH:
			errors.append("stage title does not use the bundled Barlow Condensed font")
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
			errors.append("model date does not use a date-only font variation")
		else:
			var tnum_tag := TextServerManager.get_primary_interface().name_to_tag(
				EXPECTED_DATE_OPENTYPE_FEATURE
			)
			if int(date_font.opentype_features.get(tnum_tag, 0)) != 1:
				errors.append("model date does not enable tabular numerals")
			if (
				date_font.base_font == null
				or date_font.base_font.resource_path != EXPECTED_TITLE_FONT_PATH
			):
				errors.append("model date variation does not retain the Barlow base font")
	if not (
		bool(summary.get("stage_date_tabular_numerals", false))
		and String(summary.get("stage_date_opentype_feature", ""))
			== EXPECTED_DATE_OPENTYPE_FEATURE
	):
		errors.append("runtime summary does not report tabular date numerals")
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
				256.0
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
			"STOP_AT_INWARD_Y_DISTANCE_THEN_FADE"
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

	# 1-7 toggle the shared regimes; 0/8/9 retain the water-rate test shortcuts.
	# Neither input path may rebuild, retune, or release either ecology pool.
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
	var flow_before_regime_toggle := float(nine_summary.get("flow_rate", -1.0))
	var one_key := InputEventKey.new()
	one_key.pressed = true
	one_key.keycode = KEY_1
	stage.call(&"_unhandled_input", one_key)
	var one_summary: Dictionary = stage.call(&"runtime_summary")
	if Array(one_summary.get("active_regime_names", [])) != ["Kinship"]:
		errors.append("1 key did not toggle Kinship on")
	if not is_equal_approx(
		float(one_summary.get("flow_rate", -1.0)),
		flow_before_regime_toggle,
	):
		errors.append("regime key unexpectedly changed the water flow rate")
	stage.call(&"_unhandled_input", one_key)
	var one_off_summary: Dictionary = stage.call(&"runtime_summary")
	if not Array(one_off_summary.get("active_regime_names", [])).is_empty():
		errors.append("1 key did not toggle Kinship back off")
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
	if int(summary.get("amount", 0)) != 300:
		errors.append("expected 300 particle slots")
	if int(summary.get("active_heads_approx", 0)) != 150:
		errors.append("expected about 150 active particles")
	if int(summary.get("palette_layer_count", 0)) != 7:
		errors.append("expected seven fixed palette layers")
	if int(summary.get("head_layer_count", 0)) != 7:
		errors.append("expected seven independent head emitters")
	if int(summary.get("trail_segment_layer_count", 0)) != 7:
		errors.append("expected seven independent immutable segment pools")
	if Array(summary.get("head_layer_slot_counts", [])) != EXPECTED_LAYER_SLOTS:
		errors.append("global 300 head slots are not distributed 43x6 + 42")
	if Array(summary.get("active_head_layer_counts", [])) != EXPECTED_ACTIVE_HALF:
		errors.append("50% flow does not activate exactly 150 interleaved heads")
	if Array(summary.get("trail_segment_capacities", [])) != EXPECTED_LAYER_CAPACITIES:
		errors.append("22,500 segment slots are not divided by palette population")
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
	if int(summary.get("trail_segment_capacity", 0)) != 22500:
		errors.append("expected 22,500 immutable segment slots")
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
	if int(summary.get("interaction_polygon_count", 0)) != 2:
		errors.append("expected the default absorber and repeller polygons")
	if int(summary.get("interaction_overlay_count", 0)) != 2:
		errors.append("debug overlay did not receive both default polygons")
	if not bool(summary.get("interaction_data_texture_bound", false)):
		errors.append("polygon geometry texture is not bound")
	if Vector2(summary.get("interaction_data_texture_size", Vector2.ZERO)) != Vector2(
		128.0, 1.0
	):
		errors.append("polygon geometry texture is not the 128x1 production layout")
	if int(summary.get("shoreline_count", 0)) != 2:
		errors.append("expected dedicated top and bottom shoreline obstacles")
	if int(summary.get("shoreline_vertex_count", 0)) != 17:
		errors.append("shoreline obstacles do not span all 17 model-grid columns")
	var shoreline_ids := Array(summary.get("shoreline_ids", []))
	if (
		shoreline_ids.size() != 2
		or not shoreline_ids.has("shoreline_obstacle_top")
		or not shoreline_ids.has("shoreline_obstacle_bottom")
	):
		errors.append("shoreline obstacle IDs are not stable")
	if not bool(summary.get("shoreline_data_texture_bound", false)):
		errors.append("shoreline geometry texture is not bound")
	if Vector2(summary.get("shoreline_data_texture_size", Vector2.ZERO)) != Vector2(
		40.0, 1.0
	):
		errors.append("shoreline geometry texture is not the dedicated 40x1 layout")
	if int(summary.get("shoreline_overlay_count", 0)) != 2:
		errors.append("debug overlay did not receive both shoreline banks")
	if not bool(summary.get("shoreline_preserves_interaction_capacity", false)):
		errors.append("shorelines unexpectedly consume addressable polygon capacity")
	for shoreline_count: Variant in Array(
		summary.get("shoreline_count_uniforms", [])
	):
		if int(shoreline_count) != 2:
			errors.append("shoreline banks did not reach all seven head shaders")
			break
	for shoreline_bound: Variant in Array(
		summary.get("shoreline_texture_bound_uniforms", [])
	):
		if not bool(shoreline_bound):
			errors.append("a head shader is missing the shoreline texture")
			break
	if int(summary.get("source_polygon_count", 0)) != 1:
		errors.append("expected one default water source polygon")
	if int(summary.get("source_overlay_count", 0)) != 1:
		errors.append("debug overlay did not receive the default source")
	if not bool(summary.get("source_data_texture_bound", false)):
		errors.append("source geometry texture is not bound")
	if Vector2(summary.get("source_data_texture_size", Vector2.ZERO)) != Vector2(
		128.0, 1.0
	):
		errors.append("source geometry texture is not the 128x1 production layout")
	for source_count: Variant in Array(summary.get("source_count_uniforms", [])):
		if int(source_count) != 1:
			errors.append("default source did not reach all seven head shaders")
			break
	for polygon_count: Variant in Array(summary.get("interaction_count_uniforms", [])):
		if int(polygon_count) != 2:
			errors.append("default polygons did not reach all seven head shaders")
			break
	if Vector2(summary.get("stage_size", Vector2.ZERO)) != Vector2(1920.0, 1080.0):
		errors.append("stage is not native 1920 x 1080")
	if not bool(stage.call(&"accepts_control_target", "smoke_screen")):
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
	if int(stage.call(&"release_salmon", 25)) != 25:
		errors.append("public salmon release did not schedule exactly 25")
	summary = stage.call(&"runtime_summary")
	var released_salmon_summary: Dictionary = summary.get("salmon_summary", {})
	if int(released_salmon_summary.get("release_serial", 0)) != 1:
		errors.append("public salmon release serial did not advance")
	if int(released_salmon_summary.get("total_scheduled", 0)) != 25:
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
	if int(summary.get("trail_segment_capacity", 0)) != 22500:
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
	if bool(summary.get("debug_visible", true)):
		errors.append("debug overlay did not hide")
	if bool(summary.get("debug_overlay_visible", true)):
		errors.append("V/debug state did not hide polygon and reservoir outlines")
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
			{"name": "release_salmon", "arguments": {"count": 7}},
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
	if not is_equal_approx(float(summary.get("amount_ratio", 0.0)), 0.75):
		errors.append("controller flow_rate did not update active population")
	if int(summary.get("active_heads_approx", 0)) != 225:
		errors.append("75% flow does not activate exactly 225 global heads")
	if Array(summary.get("active_head_layer_counts", [])) != [
		33, 32, 32, 32, 32, 32, 32
	]:
		errors.append("75% flow does not preserve exact interleaved activation")
	if not is_equal_approx(float(summary.get("base_speed_uniform", 0.0)), 450.0):
		errors.append("controller flow_rate did not update core speed")
	if not is_equal_approx(float(summary.get("velocity_response_uniform", 0.0)), 14.0):
		errors.append("controller velocity response did not reach particle shader")
	for amount_ratio: Variant in Array(summary.get("head_layer_amount_ratios", [])):
		if not is_equal_approx(float(amount_ratio), 0.75):
			errors.append("controller flow ratio did not reach every head layer")
			break
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
	if int(summary.get("trail_segment_capacity", 0)) != 22500:
		errors.append("flow-rate change unexpectedly resized immutable segment pool")
	if not bool(summary.get("paused", false)):
		errors.append("controller action dictionary did not pause")
	var controller_salmon_summary: Dictionary = summary.get("salmon_summary", {})
	if int(controller_salmon_summary.get("release_serial", 0)) != 2:
		errors.append("controller salmon action did not advance release serial")
	if int(controller_salmon_summary.get("total_scheduled", 0)) != 32:
		errors.append("controller salmon count argument was not scheduled exactly")
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
			480.0
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
	if int(summary.get("interaction_polygon_count", 0)) != 3:
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
	if int(summary.get("interaction_polygon_count", 0)) != 2:
		errors.append("controller polygon removal did not restore default object count")
	if int(summary.get("trail_segment_capacity", 0)) != 22500:
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
	if int(summary.get("interaction_polygon_count", 0)) != 2:
		errors.append("plural-kind polygon removal did not restore defaults")

	var source_packer_before: Dictionary = summary.get("source_texture_packer", {})
	var source_revision_before := int(source_packer_before.get("revision", -1))
	stage.call(&"queue_control_message", {
		"geometry_ops": [{
			"op": "upsert",
			"kind": "source_polygon",
			"id": "smoke_source",
			"value": {
				"id": "payload_must_not_rename_source",
				"vertices": [
					[10.0, 3.0],
					[11.0, 3.0],
					[11.0, 4.0],
					[10.0, 4.0],
				],
				"emission_fraction": 0.25,
				"flow_direction": [1.0, 0.0],
			},
		}],
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	var source_packer_after: Dictionary = summary.get("source_texture_packer", {})
	if int(source_packer_after.get("revision", -1)) != source_revision_before + 1:
		errors.append("one source controller batch did not produce exactly one upload")
	if int(summary.get("source_polygon_count", 0)) != 2:
		errors.append("controller source upsert did not add an addressable source")
	var source_ids: Array[String] = []
	for source_variant: Variant in Array(summary.get("source_polygons", [])):
		if source_variant is Dictionary:
			source_ids.append(String(source_variant.get("element_id", "")))
	if not source_ids.has("smoke_source"):
		errors.append("source operation ID was not authoritative")
	if source_ids.has("payload_must_not_rename_source"):
		errors.append("source payload overrode its stable operation ID")
	for source_count: Variant in Array(summary.get("source_count_uniforms", [])):
		if int(source_count) != 2:
			errors.append("controller source did not reach all seven head shaders")
			break
	stage.call(&"queue_control_message", {
		"geometry_ops": [{
			"op": "remove",
			"kind": "sources",
			"element_id": "smoke_source",
		}],
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	if int(summary.get("source_polygon_count", 0)) != 1:
		errors.append("controller source removal did not restore the default source")

	# Width appears before radius on purpose. The raw request must survive its
	# temporary clamp against the old radius, then become a true full aperture
	# after an arbitrary runtime radius larger than the editor's 600 px hint.
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
	await _check_stage_title_reset_independence(stage, errors)

	if errors.is_empty():
		print(
			"GPU_STAGE_SMOKE_OK: one_stage=true native=1920x1080 "
			+ "slots=300 active=~150 render_paced=true max_fps=30 interpolation=true "
				+ "immutable_segments=22500 palette_layers=7 fixed_z=true "
				+ "identity=true gate=true pause=true "
				+ "debug=true title=true regimes=true controller=true "
				+ "polygons=true salmon=true leaves=true"
		)
		get_tree().quit(0)
		return
	for error in errors:
		push_error("GPU_STAGE_SMOKE: %s" % error)
	get_tree().quit(1)


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
		errors.append("stage is not bound to the persistent ModelRegimes autoload")
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
		if label.text != EXPECTED_REGIME_NAMES[index]:
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
	if not is_equal_approx(
		float(active_summary.get("shoreline_randomness", -1.0)),
		0.15,
	):
		errors.append("Agriculture + Tech shoreline weights were not normalized to 0.15")
	if _shoreline_geometry_from_summary(active_summary) != shoreline_geometry:
		errors.append("regime activation regenerated the fixed shoreline geometry")
	var active_inlet_range := Vector2(active_summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	))
	if (
		active_inlet_range.x <= 28.0
		or active_inlet_range.y >= 1052.0
		or active_inlet_range.x >= active_inlet_range.y
	):
		errors.append("active shoreline did not constrain inlet lanes to open water")
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
	stage.call(&"set_active_regime_names", [])
	var cleared_summary: Dictionary = stage.call(&"runtime_summary")
	if not is_zero_approx(float(cleared_summary.get("shoreline_randomness", -1.0))):
		errors.append("clearing regimes did not disable shoreline force")
	if _shoreline_geometry_from_summary(cleared_summary) != shoreline_geometry:
		errors.append("clearing regimes regenerated the fixed shoreline geometry")
	if Vector2(cleared_summary.get(
		"shoreline_inlet_y_range_pixels",
		Vector2.ZERO,
	)) != Vector2(28.0, 1052.0):
		errors.append("clearing shoreline force did not restore the full inlet range")


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
	if title_label.text != "Runtime Smoke River" or title_label.visible:
		errors.append("runtime title text/visibility did not update the Label directly")
	if not (
		String(changed.get("stage_title", "")) == "Runtime Smoke River"
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
	if bool(debug_toggled.get("debug_visible", true)):
		errors.append("V key did not toggle debug geometry for title independence test")
	if not title_label.visible or title_label.text != "Smoke River":
		errors.append("V/debug toggle changed the stage title")
	stage.call(&"_unhandled_input", v_key)

	stage.call(&"set_paused", true)
	var paused_title_summary: Dictionary = stage.call(&"runtime_summary")
	if not (
		title_label.visible
		and title_label.text == "Smoke River"
		and String(paused_title_summary.get("stage_title", "")) == "Smoke River"
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
	if not (
		title_label.visible
		and title_label.text == "Smoke River"
		and String(reset_summary.get("stage_title", "")) == "Smoke River"
		and bool(reset_summary.get("stage_title_visible", false))
	):
		errors.append("simulation reset changed the stage title")
	if water_viewport.get_texture().get_rid() != water_texture_rid:
		errors.append("pause/reset replaced the water texture while preserving title")
