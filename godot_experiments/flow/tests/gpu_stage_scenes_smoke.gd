extends Node

## Integration smoke test for the seven full-screen GPU flow scenes.
##
## Run from the Godot project directory after scene_1.tscn through
## scene_7.tscn have been migrated to the reusable GPU stage:
##
##     Godot --headless --path . --rendering-method mobile \
##       --scene res://flow/tests/gpu_stage_scenes_smoke.tscn

const EXPECTED_VIEWPORT_SIZE := Vector2i(1920, 1080)
const EXPECTED_LAYER_SLOTS := [43, 43, 43, 43, 43, 43, 42]
const EXPECTED_LAYER_CAPACITIES := [3225, 3225, 3225, 3225, 3225, 3225, 3150]
const EXPECTED_LAYER_Z := [0, 1, 2, 3, 4, 5, 6]
const EXPECTED_TITLE_FONT_PATH := (
	"res://flow/assets/fonts/BarlowCondensed-Medium.ttf"
)
const EXPECTED_TITLE_POSITION := Vector2(40.0, 40.0)
const EXPECTED_TITLE_COLOR := Color("4ab0e1")
const EXPECTED_TITLE_FONT_SIZE := 40
const SCENES: Array[Dictionary] = [
	{
		"path": "res://scene_1.tscn",
		"id": &"mount_shasta",
		"title": "Mount Shasta",
	},
	{
		"path": "res://scene_2.tscn",
		"id": &"mccloud_pit",
		"title": "McCloud-Pit Rivers",
	},
	{
		"path": "res://scene_3.tscn",
		"id": &"cottonwood_creek",
		"title": "Cottonwood Creek",
	},
	{
		"path": "res://scene_4.tscn",
		"id": &"mill_creek",
		"title": "Mill Creek",
	},
	{
		"path": "res://scene_5.tscn",
		"id": &"feather_river",
		"title": "Feather River",
	},
	{
		"path": "res://scene_6.tscn",
		"id": &"american_river",
		"title": "American River",
	},
	{
		"path": "res://scene_7.tscn",
		"id": &"delta",
		"title": "Sacramento-San Joaquin Delta",
	},
]

var _failures := PackedStringArray()
var _seen_ids: Dictionary = {}


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_check_project_configuration()
	for scene_spec in SCENES:
		await _check_scene(scene_spec)
	_expect(
		_seen_ids.size() == SCENES.size(),
		"The seven scenes must expose seven unique screen/stage IDs."
	)
	await _check_two_stage_texture_isolation()
	_finish()


func _check_project_configuration() -> void:
	var rendering_method: String = String(ProjectSettings.get_setting(
		"rendering/renderer/rendering_method",
		""
	))
	_expect(
		rendering_method == "mobile",
		"project.godot must set rendering/renderer/rendering_method to mobile."
	)
	var viewport_size := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	)
	_expect(
		viewport_size == EXPECTED_VIEWPORT_SIZE,
		"The project viewport must be 1920x1080; got %s." % viewport_size
	)


func _check_two_stage_texture_isolation() -> void:
	var first_scene := load(String(SCENES[0]["path"])) as PackedScene
	var second_scene := load(String(SCENES[1]["path"])) as PackedScene
	if first_scene == null or second_scene == null:
		_expect(false, "Two-stage texture isolation scenes must load.")
		return
	var first_root := first_scene.instantiate()
	var second_root := second_scene.instantiate()
	add_child(first_root)
	add_child(second_root)
	await get_tree().process_frame
	await get_tree().process_frame
	var first_stages: Array[Node] = []
	var second_stages: Array[Node] = []
	_collect_gpu_stages(first_root, first_stages)
	_collect_gpu_stages(second_root, second_stages)
	if first_stages.size() == 1 and second_stages.size() == 1:
		var first_stage := first_stages[0]
		var second_stage := second_stages[0]
		var first_viewport := first_stage.get_node_or_null("WaterOnlyViewport") as SubViewport
		var second_viewport := second_stage.get_node_or_null("WaterOnlyViewport") as SubViewport
		_expect(
			first_viewport != null and second_viewport != null,
			"Two simultaneous stages must each own a water-only viewport."
		)
		if first_viewport != null and second_viewport != null:
			_expect(
				first_viewport.get_texture().get_rid()
					!= second_viewport.get_texture().get_rid(),
				"Two simultaneous stages must not share a water texture RID."
			)
		var first_salmon := first_stage.get_node_or_null(
			"GPUSalmonSchool/GPUSalmonHeads"
		) as GPUParticles2D
		var second_salmon := second_stage.get_node_or_null(
			"GPUSalmonSchool/GPUSalmonHeads"
		) as GPUParticles2D
		if first_salmon != null and second_salmon != null:
			var first_material := first_salmon.process_material as ShaderMaterial
			var second_material := second_salmon.process_material as ShaderMaterial
			var first_texture := first_material.get_shader_parameter(
				&"water_occupancy_texture"
			) as Texture2D
			var second_texture := second_material.get_shader_parameter(
				&"water_occupancy_texture"
			) as Texture2D
			_expect(
				first_texture != null
				and second_texture != null
				and first_texture.get_rid() != second_texture.get_rid(),
				"Two salmon schools must bind their own stage texture."
			)
		var first_leaves := first_stage.get_node_or_null(
			"GPULeafField/GPULeafHeads"
		) as GPUParticles2D
		var second_leaves := second_stage.get_node_or_null(
			"GPULeafField/GPULeafHeads"
		) as GPUParticles2D
		if first_leaves != null and second_leaves != null:
			var first_leaf_material := first_leaves.process_material as ShaderMaterial
			var second_leaf_material := second_leaves.process_material as ShaderMaterial
			var first_leaf_texture := first_leaf_material.get_shader_parameter(
				&"water_occupancy_texture"
			) as Texture2D
			var second_leaf_texture := second_leaf_material.get_shader_parameter(
				&"water_occupancy_texture"
			) as Texture2D
			_expect(
				first_leaf_texture != null
				and second_leaf_texture != null
				and first_leaf_texture.get_rid() != second_leaf_texture.get_rid(),
				"Two leaf fields must bind their own stage texture."
			)
		var first_source: Resource = first_stage.call(
			&"get_source_polygon", &"source_test"
		)
		var second_source: Resource = second_stage.call(
			&"get_source_polygon", &"source_test"
		)
		_expect(
			first_source != null
			and second_source != null
			and first_source.get_instance_id() != second_source.get_instance_id(),
			"Default source resources must be local to each stage instance."
		)
	else:
		_expect(false, "Two-stage isolation check could not find both GPU stages.")
	first_root.queue_free()
	second_root.queue_free()
	await get_tree().process_frame


func _check_scene(scene_spec: Dictionary) -> void:
	var scene_path: String = String(scene_spec["path"])
	var expected_id: StringName = scene_spec["id"]
	var expected_title: String = String(scene_spec["title"])
	var packed_scene: PackedScene = load(scene_path) as PackedScene
	_expect(packed_scene != null, "%s must load as a PackedScene." % scene_path)
	if packed_scene == null:
		return

	var scene_root: Node = packed_scene.instantiate()
	_expect(scene_root != null, "%s must instantiate." % scene_path)
	if scene_root == null:
		return
	add_child(scene_root)
	await get_tree().process_frame
	await get_tree().process_frame

	var stages: Array[Node] = []
	_collect_gpu_stages(scene_root, stages)
	_expect(
		stages.size() == 1,
		"%s must contain exactly one GPUFlowStage2D; found %d."
			% [scene_path, stages.size()]
	)
	if stages.size() == 1:
		var stage: Node = stages[0]
		_check_stage_id(stage, expected_id, scene_path)
		_check_stage_size(stage, scene_path)
		_check_stage_title(stage, expected_title, scene_path)
		_check_palette_layers(stage, scene_path)
		_check_ecology(stage, scene_path)
		_check_gate_roundtrip(stage, scene_path)
		await _check_control_route(stage, expected_id, scene_path)

	scene_root.queue_free()
	await get_tree().process_frame


func _collect_gpu_stages(node: Node, stages: Array[Node]) -> void:
	if _looks_like_gpu_stage(node):
		stages.append(node)
	for child in node.get_children():
		_collect_gpu_stages(child, stages)


func _looks_like_gpu_stage(node: Node) -> bool:
	if not node.has_method(&"runtime_summary"):
		return false
	if not node.has_method(&"set_gate_open"):
		return false
	if not node.has_method(&"set_gate_half_width"):
		return false
	if node.is_in_group(&"flow_models"):
		return true
	var script: Script = node.get_script() as Script
	if script == null:
		return false
	var script_path: String = script.resource_path.to_lower()
	return (
		script_path.ends_with("gpu_flow_stage.gd")
		or script_path.ends_with("gpu_flow_stage_2d.gd")
	)


func _check_stage_id(stage: Node, expected_id: StringName, scene_path: String) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	var actual_id: StringName = _stage_id(stage, summary)
	_expect(
		actual_id == expected_id,
		"%s GPU stage ID must be '%s'; got '%s'."
			% [scene_path, expected_id, actual_id]
	)
	if actual_id == &"":
		return
	_expect(
		not _seen_ids.has(actual_id),
		"GPU stage ID '%s' is duplicated across production scenes." % actual_id
	)
	_seen_ids[actual_id] = true


func _stage_id(stage: Node, summary: Dictionary) -> StringName:
	for property_name in [&"screen_id", &"stage_id", &"model_id", &"control_target"]:
		var property_value: Variant = _property_value(stage, property_name)
		if property_value != null and String(property_value) != "":
			return StringName(property_value)
	for summary_key in [&"screen_id", &"stage_id", &"model_id", &"control_target"]:
		var summary_value: Variant = summary.get(summary_key)
		if summary_value != null and String(summary_value) != "":
			return StringName(summary_value)
	return &""


func _check_stage_size(stage: Node, scene_path: String) -> void:
	var size_value: Variant = null
	if stage.has_method(&"get_native_size"):
		size_value = stage.call(&"get_native_size")
	if not _is_expected_size(size_value):
		var summary: Dictionary = stage.call(&"runtime_summary")
		for summary_key in [&"stage_size", &"native_size", &"viewport_size"]:
			size_value = summary.get(summary_key)
			if _is_expected_size(size_value):
				break
	if not _is_expected_size(size_value):
		for property_name in [&"stage_size", &"native_size", &"viewport_size"]:
			size_value = _property_value(stage, property_name)
			if _is_expected_size(size_value):
				break
	if not _is_expected_size(size_value):
		var script: Script = stage.get_script() as Script
		if script != null:
			var constants: Dictionary = script.get_script_constant_map()
			for constant_name in [&"STAGE_SIZE", &"STAGE_NATIVE_SIZE", &"NATIVE_SIZE"]:
				size_value = constants.get(constant_name)
				if _is_expected_size(size_value):
					break
	_expect(
		_is_expected_size(size_value),
		"%s GPU stage must declare a native size of 1920x1080."
			% scene_path
	)


func _check_palette_layers(stage: Node, scene_path: String) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("palette_layer_count", 0)) == 7,
		"%s must expose seven fixed palette layers." % scene_path
	)
	_expect(
		int(summary.get("head_layer_count", 0)) == 7,
		"%s must contain seven head emitters." % scene_path
	)
	_expect(
		int(summary.get("trail_segment_layer_count", 0)) == 7,
		"%s must contain seven immutable trail pools." % scene_path
	)
	_expect(
		Array(summary.get("head_layer_slot_counts", [])) == EXPECTED_LAYER_SLOTS,
		"%s must distribute 300 global heads as 43x6 + 42." % scene_path
	)
	_expect(
		int(summary.get("trail_segment_capacity", 0)) == 22500,
		"%s must retain the full 22,500-segment capacity." % scene_path
	)
	_expect(
		Array(summary.get("trail_segment_capacities", []))
			== EXPECTED_LAYER_CAPACITIES,
		"%s must distribute segment capacity by palette population." % scene_path
	)
	_expect(
		Array(summary.get("head_layer_z_indices", [])) == EXPECTED_LAYER_Z,
		"%s head palette z-indices must be 0 through 6." % scene_path
	)
	_expect(
		Array(summary.get("trail_segment_z_indices", [])) == EXPECTED_LAYER_Z,
		"%s trail palette z-indices must be 0 through 6." % scene_path
	)
	for is_relative: Variant in Array(summary.get("head_layer_z_as_relative", [])):
		_expect(
			not bool(is_relative),
			"%s head palette z must be absolute." % scene_path
		)
	for is_relative: Variant in Array(summary.get("trail_segment_z_as_relative", [])):
		_expect(
			not bool(is_relative),
			"%s trail palette z must be absolute." % scene_path
		)


func _check_stage_title(
	stage: Node,
	expected_title: String,
	scene_path: String
) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	var water_viewport := stage.get_node_or_null("WaterOnlyViewport") as SubViewport
	var background := stage.get_node_or_null("Background") as ColorRect
	var water_display := stage.get_node_or_null("WaterTextureDisplay") as Sprite2D
	var title_layer := stage.get_node_or_null("StageTitleLayer") as Node2D
	var title_label := stage.get_node_or_null("StageTitleLayer/StageTitle") as Label
	_expect(title_layer != null, "%s must expose StageTitleLayer." % scene_path)
	_expect(title_label != null, "%s must expose StageTitleLayer/StageTitle." % scene_path)
	_expect(background != null, "%s must expose its explicit Background." % scene_path)
	_expect(water_display != null, "%s must expose WaterTextureDisplay." % scene_path)
	if title_layer != null:
		_expect(
			title_layer.z_index == -50 and not title_layer.z_as_relative,
			"%s title layer must use absolute z=-50." % scene_path
		)
	if background != null:
		_expect(
			background.z_index == -100 and not background.z_as_relative,
			"%s background must use absolute z=-100." % scene_path
		)
	if water_display != null:
		_expect(
			water_display.z_index == 0 and not water_display.z_as_relative,
			"%s water display must use absolute z=0 above the title." % scene_path
		)
	if title_label == null:
		return
	_expect(
		title_label.text == expected_title,
		"%s title must be '%s'; got '%s'."
			% [scene_path, expected_title, title_label.text]
	)
	_expect(
		title_label.position == EXPECTED_TITLE_POSITION,
		"%s title must be positioned at native (40, 40)." % scene_path
	)
	_expect(
		title_label.get_theme_color(&"font_color").is_equal_approx(
			EXPECTED_TITLE_COLOR
		),
		"%s title color must be #4AB0E1." % scene_path
	)
	_expect(
		title_label.get_theme_font_size(&"font_size") == EXPECTED_TITLE_FONT_SIZE,
		"%s title font size must be 60." % scene_path
	)
	var title_font := title_label.get_theme_font(&"font")
	_expect(
		title_font != null and title_font.resource_path == EXPECTED_TITLE_FONT_PATH,
		"%s title must use the bundled Barlow Condensed Medium font." % scene_path
	)
	_expect(
		water_viewport != null
		and title_layer != null
		and not water_viewport.is_ancestor_of(title_layer)
		and not title_layer.is_ancestor_of(water_viewport),
		"%s title layer and water-only viewport must remain siblings." % scene_path
	)
	_expect(
		String(summary.get("stage_title", "")) == expected_title
		and bool(summary.get("stage_title_visible", false))
		and Vector2(summary.get("stage_title_position", Vector2.ZERO))
			== EXPECTED_TITLE_POSITION
		and Color(summary.get("stage_title_color", Color.TRANSPARENT)).is_equal_approx(
			EXPECTED_TITLE_COLOR
		)
		and int(summary.get("stage_title_font_size", 0))
			== EXPECTED_TITLE_FONT_SIZE
		and String(summary.get("stage_title_font_resource", ""))
			== EXPECTED_TITLE_FONT_PATH
		and bool(summary.get("water_texture_excludes_stage_title", false)),
		"%s runtime summary must expose the complete title contract." % scene_path
	)
	var initial_debug_visible := bool(summary.get("debug_visible", true))
	stage.call(&"set_debug_visible", not initial_debug_visible)
	_expect(
		title_label.visible and title_label.text == expected_title,
		"%s debug visibility must not affect the stage title." % scene_path
	)
	stage.call(&"set_debug_visible", initial_debug_visible)


func _check_ecology(stage: Node, scene_path: String) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("source_polygon_count", 0)) == 1,
		"%s must contain one default addressable water source." % scene_path
	)
	var salmon_summary: Dictionary = summary.get("salmon_summary", {})
	_expect(
		int(salmon_summary.get("capacity", 0)) == 300,
		"%s must contain the 300-slot GPU salmon school." % scene_path
	)
	_expect(
		bool(salmon_summary.get("water_texture_assigned", false)),
		"%s salmon must sample its own water-only texture." % scene_path
	)
	_expect(
		String(salmon_summary.get("water_steering_mode", ""))
			== "DETERMINISTIC_2D_CONTACT_FIELD",
		"%s salmon must steer from nearby water in two dimensions." % scene_path
	)
	var water_viewport := stage.get_node_or_null("WaterOnlyViewport")
	var salmon_school := stage.get_node_or_null("GPUSalmonSchool")
	var leaf_summary: Dictionary = summary.get("leaf_summary", {})
	_expect(
		int(leaf_summary.get("capacity", 0)) == 300,
		"%s must contain the 300-slot GPU leaf field." % scene_path
	)
	_expect(
		int(leaf_summary.get("default_release_count_per_side", 0)) == 15,
		"%s must default to 15 leaves from each top/bottom bank." % scene_path
	)
	_expect(
		String(leaf_summary.get("release_edges", "")) == "TOP_BOTTOM"
		and String(leaf_summary.get("top_free_direction", "")) == "+Y"
		and String(leaf_summary.get("bottom_free_direction", "")) == "-Y"
		and String(leaf_summary.get("free_sway_axis", "")) == "X"
		and String(leaf_summary.get("latched_initial_direction", "")) == "+X"
		and String(leaf_summary.get("latched_follow_reference_axis", ""))
			== "CACHED_WATER_HEADING"
		and String(leaf_summary.get("latched_heading_constraint", ""))
			== "LOCAL_CONTINUITY_WITH_DOWNSTREAM_BIAS"
		and String(leaf_summary.get("latched_follow_resampling", ""))
			== "PERIODIC_DETERMINISTIC_PHASE"
		and String(leaf_summary.get("latched_retirement", ""))
			== "RIGHT_EDGE_AFTER_DISK"
		and String(leaf_summary.get("miss_behavior", ""))
			== "STOP_AT_INWARD_Y_DISTANCE_THEN_FADE",
		"%s must preserve top/bottom leaf motion and downstream attachment."
			% scene_path
	)
	_expect(
		is_equal_approx(float(leaf_summary.get("flow_speed_pixels", 0.0)), 300.0)
		and not bool(leaf_summary.get("per_segment_trail_lifetime", true))
		and int(leaf_summary.get("control_texture_rows", 0)) == 2
		and int(leaf_summary.get("segment_capacity", -1)) == 0
		and bool(leaf_summary.get("head_only_rendering", false))
		and not bool(leaf_summary.get("segment_emission", true))
		and not bool(leaf_summary.get("immutable_segments", true))
		and is_equal_approx(
			float(leaf_summary.get("release_stagger_interval_seconds", 0.0)),
			0.20
		)
		and String(leaf_summary.get("release_schedule", ""))
			== "ALTERNATING_TOP_BOTTOM_DETERMINISTIC_IRREGULAR_X_SHUFFLED"
		and String(leaf_summary.get("release_x_order", ""))
			== "INDEPENDENT_DETERMINISTIC_SHUFFLE_PER_BANK"
		and String(leaf_summary.get("release_time_x_correlation", "")) == "DECOUPLED"
		and is_equal_approx(
			float(leaf_summary.get("follow_resample_interval_seconds", 0.0)),
			0.12
		)
		and is_equal_approx(
			float(leaf_summary.get("follow_probe_max_pixels", 0.0)),
			56.0
		)
		and is_equal_approx(
			float(leaf_summary.get("follow_turn_degrees", 0.0)),
			35.0
		)
		and is_equal_approx(
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
		and is_equal_approx(float(leaf_summary.get("disk_radius_pixels", 0.0)), 5.0)
		and is_equal_approx(
			float(leaf_summary.get("minimum_leaf_radius_pixels", 0.0)),
			5.0
		)
		and is_equal_approx(
			float(leaf_summary.get("maximum_leaf_radius_pixels", 0.0)),
			10.0
		)
		and is_equal_approx(
			float(leaf_summary.get("minimum_leaf_diameter_pixels", 0.0)),
			10.0
		)
		and is_equal_approx(
			float(leaf_summary.get("maximum_leaf_diameter_pixels", 0.0)),
			20.0
		)
		and is_equal_approx(
			float(leaf_summary.get("minimum_leaf_width_pixels", 0.0)),
			10.0
		)
		and is_equal_approx(
			float(leaf_summary.get("maximum_leaf_width_pixels", 0.0)),
			20.0
		)
		and String(leaf_summary.get("render_primitive", ""))
			== "ANTIALIASED_DISK_HEAD"
		and String(leaf_summary.get("spatial_alpha_profile", ""))
			== "RADIAL_ANTIALIASED_DISK_EDGE"
		and String(leaf_summary.get("trail_primitive", "")) == "NONE",
		"%s leaves must keep shuffled, varied, periodically guided downstream disks."
			% scene_path
	)
	_expect(
		bool(leaf_summary.get("water_texture_assigned", false)),
		"%s leaves must sample their own water-only texture." % scene_path
	)
	var leaf_field := stage.get_node_or_null("GPULeafField")
	_expect(
		water_viewport != null and salmon_school != null,
		"%s must expose its water viewport and salmon school." % scene_path
	)
	if water_viewport != null and salmon_school != null:
		_expect(
			not water_viewport.is_ancestor_of(salmon_school),
			"%s salmon must stay outside its water occupancy render." % scene_path
		)
	_expect(
		leaf_field != null,
		"%s must expose its GPU leaf field." % scene_path
	)
	if leaf_field != null:
		var leaf_heads := leaf_field.get_node_or_null("GPULeafHeads") as GPUParticles2D
		_expect(
			leaf_heads != null
			and leaf_field.get_child_count() == 1
			and leaf_field.get_node_or_null("GPULeafTrailSegments") == null
			and leaf_heads.sub_emitter.is_empty(),
			"%s leaf field must contain one disk head pool and no trail pool." % scene_path
		)
	if water_viewport != null and leaf_field != null:
		_expect(
			not water_viewport.is_ancestor_of(leaf_field),
			"%s leaves must stay outside its water occupancy render." % scene_path
		)


func _check_gate_roundtrip(stage: Node, scene_path: String) -> void:
	var before: Dictionary = stage.call(&"runtime_summary")
	var initial_gate_open: bool = bool(before.get("gate_open", true))
	var initial_half_width: float = float(before.get("gate_half_width", 15.0))

	stage.call(&"set_gate_open", false)
	var closed: Dictionary = stage.call(&"runtime_summary")
	_expect(
		not bool(closed.get("gate_open", true)),
		"%s set_gate_open(false) must update runtime_summary()." % scene_path
	)
	var gate_uniform_key: String = (
		"gate_open_uniform" if closed.has("gate_open_uniform") else "gate_uniform"
	)
	if closed.has(gate_uniform_key):
		_expect(
			not bool(closed[gate_uniform_key]),
			"%s gate-open shader uniform must update at runtime." % scene_path
		)

	const TEST_HALF_WIDTH := 42.0
	stage.call(&"set_gate_half_width", TEST_HALF_WIDTH)
	var widened: Dictionary = stage.call(&"runtime_summary")
	_expect(
		is_equal_approx(
			float(widened.get("gate_half_width", NAN)),
			TEST_HALF_WIDTH
		),
		"%s set_gate_half_width() must round-trip through runtime_summary()."
			% scene_path
	)
	if widened.has("gate_half_width_uniform"):
		_expect(
			is_equal_approx(
				float(widened["gate_half_width_uniform"]),
				TEST_HALF_WIDTH
			),
			"%s gate-width shader uniform must update at runtime." % scene_path
		)

	stage.call(&"set_gate_open", initial_gate_open)
	stage.call(&"set_gate_half_width", initial_half_width)


func _check_control_route(
	stage: Node,
	expected_id: StringName,
	scene_path: String
) -> void:
	var bus := get_node_or_null("/root/FlowControlBus")
	_expect(bus != null, "FlowControlBus autoload must exist for %s." % scene_path)
	if bus == null:
		return
	var recipients := int(bus.call(&"route_control_message", {
		"target": String(expected_id),
		"changes": {"flow_rate": 0.60},
		"actions": [],
	}))
	_expect(
		recipients == 1,
		"%s controller target '%s' must route to exactly one GPU stage."
			% [scene_path, expected_id]
	)
	await get_tree().process_frame
	var summary: Dictionary = stage.call(&"runtime_summary")
	_expect(
		is_equal_approx(float(summary.get("flow_rate", 0.0)), 0.60),
		"%s routed flow_rate must reach the GPU stage." % scene_path
	)
	stage.call(&"set_flow_rate", 0.50)

	var source_id := "integration_source_%s" % String(expected_id)
	var salmon_before: Dictionary = summary.get("salmon_summary", {})
	var leaves_before: Dictionary = summary.get("leaf_summary", {})
	recipients = int(bus.call(&"route_control_message", {
		"target": String(expected_id),
		"geometry_ops": [{
			"op": "upsert",
			"kind": "source",
			"id": source_id,
			"value": {
				"vertices": [
					[9.0, 2.0],
					[10.0, 2.0],
					[10.0, 3.0],
					[9.0, 3.0],
				],
				"emission_fraction": 0.20,
				"flow_direction": [1.0, 0.0],
			},
		}],
		"actions": [{
			"name": "release_salmon",
			"arguments": {"count": 3},
		}, {
			"name": "release_leaves",
			"arguments": {"count_per_side": 2},
		}],
	}))
	_expect(
		recipients == 1,
		"%s routed source/salmon packet must reach exactly one stage." % scene_path
	)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("source_polygon_count", 0)) == 2,
		"%s routed source upsert must add to the default source." % scene_path
	)
	var salmon_after: Dictionary = summary.get("salmon_summary", {})
	_expect(
		int(salmon_after.get("release_serial", 0))
			== int(salmon_before.get("release_serial", 0)) + 1,
		"%s routed salmon action must advance its release serial." % scene_path
	)
	_expect(
		int(salmon_after.get("last_scheduled", 0)) == 3,
		"%s routed salmon action must preserve its exact count." % scene_path
	)
	var leaves_after: Dictionary = summary.get("leaf_summary", {})
	_expect(
		int(leaves_after.get("release_serial", 0))
			== int(leaves_before.get("release_serial", 0)) + 1,
		"%s routed leaf action must advance its release serial." % scene_path
	)
	_expect(
		int(leaves_after.get("last_scheduled_per_side", 0)) == 2
		and int(leaves_after.get("last_scheduled_total", 0)) == 4,
		"%s routed leaf action must preserve its per-side count." % scene_path
	)
	_expect(
		int(leaves_after.get("total_scheduled_top", 0))
			== int(leaves_before.get("total_scheduled_top", 0)) + 2
		and int(leaves_after.get("total_scheduled_bottom", 0))
			== int(leaves_before.get("total_scheduled_bottom", 0)) + 2,
		"%s routed leaf action must schedule both top and bottom cohorts."
			% scene_path
	)
	bus.call(&"route_control_message", {
		"target": String(expected_id),
		"geometry_ops": [{
			"op": "remove",
			"kind": "source",
			"id": source_id,
		}],
		"actions": [],
	})
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("source_polygon_count", 0)) == 1,
		"%s routed source removal must restore the default source." % scene_path
	)

	var polygon_id := "integration_%s" % String(expected_id)
	recipients = int(bus.call(&"route_control_message", {
		"target": String(expected_id),
		"geometry_ops": [{
			"op": "upsert",
			"kind": "polygon",
			"id": polygon_id,
			"value": {
				"vertices": [
					[2.0, 1.0],
					[2.8, 1.0],
					[2.8, 1.8],
					[2.0, 1.8],
				],
				"mode": "repel",
				"repellent_force": 0.50,
			},
		}],
		"actions": [],
	}))
	_expect(
		recipients == 1,
		"%s routed polygon upsert must reach exactly one GPU stage." % scene_path
	)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("interaction_polygon_count", 0)) == 3,
		"%s routed polygon upsert must add to the two defaults." % scene_path
	)
	for count_variant: Variant in Array(summary.get("interaction_count_uniforms", [])):
		_expect(
			int(count_variant) == 3,
			"%s routed polygon count must reach every shader layer." % scene_path
		)

	recipients = int(bus.call(&"route_control_message", {
		"target": String(expected_id),
		"changes": {
			"polygon.%s.repellent_force" % polygon_id: 0.75,
		},
		"actions": [],
	}))
	_expect(
		recipients == 1,
		"%s routed polygon field update must reach exactly one stage." % scene_path
	)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	var updated_force := -1.0
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if (
			definition_variant is Dictionary
			and String(definition_variant.get("element_id", "")) == polygon_id
		):
			updated_force = float(definition_variant.get("repellent_force", -1.0))
			break
	_expect(
		is_equal_approx(updated_force, 0.75),
		"%s routed polygon field update must retain its stable ID." % scene_path
	)

	recipients = int(bus.call(&"route_control_message", {
		"target": String(expected_id),
		"geometry_ops": [{
			"op": "remove",
			"kind": "polygon",
			"id": polygon_id,
		}],
		"actions": [],
	}))
	_expect(
		recipients == 1,
		"%s routed polygon removal must reach exactly one stage." % scene_path
	)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	_expect(
		int(summary.get("interaction_polygon_count", 0)) == 2,
		"%s routed polygon removal must restore the two defaults." % scene_path
	)


func _property_value(object: Object, property_name: StringName) -> Variant:
	for property_info_variant in object.get_property_list():
		var property_info: Dictionary = property_info_variant
		if StringName(property_info.get("name", &"")) == property_name:
			return object.get(property_name)
	return null


func _is_expected_size(value: Variant) -> bool:
	if value is Vector2i:
		return value == EXPECTED_VIEWPORT_SIZE
	if value is Vector2:
		return Vector2(value).is_equal_approx(Vector2(EXPECTED_VIEWPORT_SIZE))
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print(
			"GPU_STAGE_SCENES_SMOKE: PASS "
			+ "(7 scenes, unique IDs/titles, 1920x1080, Mobile, "
			+ "gate + routed polygons/sources/salmon/leaves)"
		)
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("GPU_STAGE_SCENES_SMOKE: %s" % failure)
	print("GPU_STAGE_SCENES_SMOKE: FAIL (%d failures)" % _failures.size())
	get_tree().quit(1)
