extends Node

## Integration smoke test for the seven full-screen GPU flow scenes.
##
## Run from the Godot project directory after scene_1.tscn through
## scene_7.tscn have been migrated to the reusable GPU stage:
##
##     Godot --headless --path . --rendering-method mobile \
##       --scene res://flow/tests/gpu_stage_scenes_smoke.tscn

const EXPECTED_VIEWPORT_SIZE := Vector2i(1920, 1080)
const EXPECTED_LAYER_SLOTS := [143, 143, 143, 143, 143, 143, 142]
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
const EXPECTED_TEMPERATURE_ROW_COUNT := 720
const EXPECTED_TEMPERATURE_INTERPOLATION := "HALF_OPEN_ANNUAL_LINEAR_WRAP"
const EXPECTED_TIDE_ROW_COUNT := 8760
const EXPECTED_TEMPERATURE_COLUMNS := {
	"mount_shasta": "shasta_keswick_release_temp_c",
	"mccloud_pit": "mccloud_above_shasta_lake_temp_c",
	"mill_creek": "mill_creek_temp_c",
	"feather_river": "feather_below_thermalito_temp_c",
	"american_river": "american_fair_oaks_temp_c",
	"delta": "delta_freeport_temp_c",
}
const EXPECTED_REGIME_PROFILE_PATH := "res://regime_feature_profiles.txt"
const EXPECTED_REGIME_SLOT_CAPACITIES := {
	"drain": 5,
	"obstacle": 2,
}
const EXPECTED_REGIME_NAMES := [
	"Kinship",
	"Agriculture",
	"Gold Rush",
	"Water Projects",
	"Hydropower",
	"Tech",
	"Watershed",
]
const SCENES: Array[Dictionary] = [
	{
		"path": "res://scene_1.tscn",
		"id": &"mount_shasta",
		"title": "Lake Shasta",
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
		"title": "Delta",
	},
]

var _failures := PackedStringArray()
var _seen_ids: Dictionary = {}
var _expected_timeline_snapshot: Dictionary = {}
var _regime_geometry_signature_by_screen: Dictionary = {}
var _temperature_values_by_column: Dictionary = {}


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	_check_project_configuration()
	_check_temperature_data_fixture()
	_prepare_shared_timeline()
	_check_regime_profile_matrix()
	for scene_spec in SCENES:
		await _check_scene(scene_spec)
	_expect(
		_seen_ids.size() == SCENES.size(),
		"The seven scenes must expose seven unique screen/stage IDs."
	)
	var unique_regime_geometry_signatures: Dictionary = {}
	for geometry_signature: Variant in _regime_geometry_signature_by_screen.values():
		unique_regime_geometry_signatures[String(geometry_signature)] = true
	_expect(
		unique_regime_geometry_signatures.size() == SCENES.size(),
		"The seven stages must generate distinct regime feature placements."
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
	_expect(
		String(ProjectSettings.get_setting("autoload/ModelTimeline", ""))
			== "*res://flow/model_timeline.gd",
		"project.godot must install the persistent ModelTimeline autoload."
	)
	_expect(
		String(ProjectSettings.get_setting("autoload/ModelRegimes", ""))
			== "*res://flow/model_regimes.gd",
		"project.godot must install the in-memory ModelRegimes autoload."
	)


func _check_temperature_data_fixture() -> void:
	_expect(
		FileAccess.file_exists(EXPECTED_TEMPERATURE_DATA_PATH),
		"The shared 720-row water-temperature file must be packaged in res://."
	)
	if not FileAccess.file_exists(EXPECTED_TEMPERATURE_DATA_PATH):
		return
	var expected_column_names: Array = EXPECTED_TEMPERATURE_COLUMNS.values()
	var column_indices: Dictionary = {}
	for column_name: String in expected_column_names:
		_temperature_values_by_column[column_name] = PackedFloat64Array()
	var header_found := false
	for raw_line: String in FileAccess.get_file_as_string(
		EXPECTED_TEMPERATURE_DATA_PATH
	).split("\n", false):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var delimiter := "," if line.contains(",") else "\t"
		var columns := line.split(delimiter, false)
		if not header_found:
			header_found = true
			_expect(
				columns.size() >= 4
				and String(columns[0]) == "frame"
				and String(columns[1]) == "timestamp_pacific",
				"The temperature fixture must begin with frame and timestamp_pacific.",
			)
			for column_name: String in expected_column_names:
				var column_index := columns.find(column_name)
				_expect(
					column_index >= 0,
					"The temperature fixture is missing column %s." % column_name,
				)
				column_indices[column_name] = column_index
			continue
		var expected_frame := int(PackedFloat64Array(
			_temperature_values_by_column[expected_column_names[0]]
		).size())
		_expect(
			columns.size() >= 4
			and String(columns[0]).is_valid_int()
			and int(columns[0]) == expected_frame,
			"Temperature frame indices must be contiguous from 0 through 719.",
		)
		for column_name: String in expected_column_names:
			var column_index := int(column_indices.get(column_name, -1))
			var value_is_valid := (
				column_index >= 0
				and column_index < columns.size()
				and String(columns[column_index]).is_valid_float()
			)
			_expect(
				value_is_valid,
				"Temperature fixture has invalid %s data at frame %d."
					% [column_name, expected_frame],
			)
			if value_is_valid:
				var values := PackedFloat64Array(
					_temperature_values_by_column[column_name]
				)
				values.append(float(columns[column_index]))
				_temperature_values_by_column[column_name] = values
	_expect(header_found, "The temperature fixture header is missing.")
	for column_name: String in expected_column_names:
		_expect(
			PackedFloat64Array(
				_temperature_values_by_column[column_name]
			).size() == EXPECTED_TEMPERATURE_ROW_COUNT,
			"Temperature column %s must contain exactly 720 values."
				% column_name,
		)


func _prepare_shared_timeline() -> void:
	var regimes := get_node_or_null("/root/ModelRegimes")
	_expect(regimes != null, "ModelRegimes autoload must exist at runtime.")
	if regimes != null:
		regimes.call(&"clear_regimes")
		regimes.call(&"set_active_names", ["Agriculture", "Tech"])
	var timeline := get_node_or_null("/root/ModelTimeline")
	_expect(timeline != null, "ModelTimeline autoload must exist at runtime.")
	if timeline == null:
		return
	timeline.call(&"configure_if_needed", 720.0, 181, true, false)
	timeline.call(&"set_paused", true)
	# Integer MM/DD boundaries must survive the elapsed-seconds round trip. Test
	# both supported year origins before establishing the shared fixture date.
	for start_day: int in [0, 181]:
		_expect(
			bool(timeline.call(&"set_start_day_index", start_day, true)),
			"ModelTimeline must accept a valid model-year origin.",
		)
		for day_index in range(365):
			_expect(
				bool(timeline.call(&"set_date", day_index, 0, &"midnight_smoke")),
				"ModelTimeline must accept every non-leap model day.",
			)
			var midnight_snapshot: Dictionary = timeline.call(&"snapshot")
			if (
				int(midnight_snapshot.get("day_index", -1)) != day_index
				or int(midnight_snapshot.get("minute_of_day", -1)) != 0
			):
				_expect(
					false,
					"ModelTimeline midnight round trip failed at origin %d day %d."
						% [start_day, day_index],
				)
				break
	_expect(
		bool(timeline.call(&"set_start_day_index", 181, true)),
		"ModelTimeline must restore the production July 1 origin.",
	)
	_expect(
		bool(timeline.call(&"set_date", 244, 615, &"scene_switch_smoke")),
		"ModelTimeline must accept a deterministic scene-switch test date."
	)
	_expected_timeline_snapshot = timeline.call(&"snapshot")


func _check_regime_profile_matrix() -> void:
	var regimes := get_node_or_null("/root/ModelRegimes")
	if regimes == null:
		return
	var loaded_snapshot: Dictionary = regimes.call(&"snapshot")
	_expect(
		bool(loaded_snapshot.get("profiles_loaded", false))
		and int(loaded_snapshot.get("profile_count", 0)) == 7
		and Array(loaded_snapshot.get("profile_diagnostics", [])).is_empty(),
		"The seven regime profiles must load without diagnostics.",
	)
	_expect(
		not Dictionary(loaded_snapshot.get("effective_features", {})).has(
			"source_area_fraction"
		),
		"The removed supplemental-source feature is still present in regime state.",
	)
	for regime_spec: Dictionary in [
		{"name": "Kinship", "id": "kinship"},
		{"name": "Agriculture", "id": "ranch"},
		{"name": "Gold Rush", "id": "gold_rush"},
		{"name": "Water Projects", "id": "water_projects"},
		{"name": "Hydropower", "id": "hydropower"},
		{"name": "Tech", "id": "tech"},
		{"name": "Watershed", "id": "watershed"},
	]:
		var regime_name := String(regime_spec["name"])
		var regime_id := String(regime_spec["id"])
		regimes.call(&"set_active_names", [regime_name])
		var snapshot: Dictionary = regimes.call(&"snapshot")
		_expect(
			Array(snapshot.get("active_names", [])) == [regime_name],
			"Regime matrix could not activate %s alone." % regime_name,
		)
		var features_by_screen: Dictionary = snapshot.get(
			"effective_feature_state_by_screen",
			{},
		)
		var schedules_by_screen: Dictionary = snapshot.get(
			"active_schedules_by_screen",
			{},
		)
		for scene_spec: Dictionary in SCENES:
			var screen_id := String(scene_spec["id"])
			var screen_features: Dictionary = features_by_screen.get(screen_id, {})
			_expect(
				not screen_features.has("source_area_fraction"),
				"%s still exposes supplemental-source state for %s."
					% [regime_name, screen_id],
			)
			var expected_features := _regime_matrix_expected_features(
				regime_id,
				screen_id,
			)
			for feature_name: String in expected_features:
				var expected_value: Variant = expected_features[feature_name]
				var feature_state: Dictionary = screen_features.get(feature_name, {})
				var expected_defined := expected_value != null
				_expect(
					bool(feature_state.get("defined", false)) == expected_defined
					and is_equal_approx(
						float(feature_state.get("value", -1.0)),
						float(expected_value) if expected_defined else 0.0,
					)
					and int(feature_state.get("contributor_count", -1))
						== (1 if expected_defined else 0)
					and Array(feature_state.get("contributor_ids", []))
						== ([regime_id] if expected_defined else []),
					"%s has incorrect %s state for %s."
						% [regime_name, feature_name, screen_id],
				)
			var expected_schedule := _regime_matrix_expected_schedule(
				regime_id,
				screen_id,
			)
			var screen_schedules: Dictionary = schedules_by_screen.get(screen_id, {})
			var actual_schedule: Dictionary = screen_schedules.get(regime_id, {})
			_expect(
				actual_schedule.size() == expected_schedule.size(),
				"%s has an unexpected schedule shape for %s."
					% [regime_name, screen_id],
			)
			for schedule_name: String in expected_schedule:
				_expect(
					String(actual_schedule.get(schedule_name, ""))
						== String(expected_schedule[schedule_name]),
					"%s has incorrect %s for %s."
						% [regime_name, schedule_name, screen_id],
				)

	# The seven instantiated scenes below intentionally share this mixed fixture.
	regimes.call(&"set_active_names", ["Agriculture", "Tech"])
	_expect(
		Array(Dictionary(regimes.call(&"snapshot")).get("active_names", []))
			== ["Agriculture", "Tech"],
		"Regime matrix did not restore the Agriculture + Tech fixture.",
	)


func _regime_matrix_expected_features(
	regime_id: String,
	screen_id: String
) -> Dictionary:
	match regime_id:
		"kinship":
			return {
				"reservoir_area_fraction": 0.0,
				"reservoir_count": 0.0,
				"reservoir_gate_aperture_fraction": null,
				"drain_area_fraction": 0.0,
				"drain_power": 0.0,
				"obstacle_area_fraction": 0.0,
				"obstacle_power": 0.0,
				"shoreline_randomness": 1.0,
				"salmon_activity": 1.0,
				"leaf_activity": 1.0,
			}
		"ranch":
			var reservoir_counts := {
				"mount_shasta": 1.0,
				"mccloud_pit": 2.0,
				"cottonwood_creek": 0.0,
				"mill_creek": 1.0,
				"feather_river": 1.0,
				"american_river": 1.0,
				"delta": 2.0,
			}
			return {
				"reservoir_area_fraction": (
					0.0 if screen_id == "cottonwood_creek" else 0.20
				),
				"reservoir_count": reservoir_counts[screen_id],
				"drain_area_fraction": 0.75,
				"obstacle_area_fraction": 0.10,
				"shoreline_randomness": (
					0.30
					if screen_id in [
						"mount_shasta",
						"mccloud_pit",
						"cottonwood_creek",
					]
					else 0.0
				),
			}
		"gold_rush":
			var affected := screen_id in ["feather_river", "american_river", "delta"]
			return {
				"reservoir_area_fraction": 0.10 if affected else null,
				"reservoir_count": null,
				"drain_area_fraction": 0.30 if affected else null,
				"drain_power": 1.0 if affected else null,
				"obstacle_area_fraction": 0.30 if affected else null,
				"obstacle_power": 1.0 if affected else null,
				"shoreline_randomness": 1.0 if affected else null,
				"salmon_activity": 1.0 if affected else null,
				"leaf_activity": 1.0 if affected else null,
			}
		"water_projects":
			var selected := screen_id in [
				"mount_shasta",
				"mccloud_pit",
				"feather_river",
				"american_river",
				"delta",
			]
			return {
				"reservoir_area_fraction": 0.33 if selected else 0.0,
				"reservoir_count": 1.0 if selected else 0.0,
				"drain_area_fraction": 0.50 if selected else 0.0,
				"shoreline_randomness": 0.0,
				"leaf_activity": 0.0,
			}
		"hydropower":
			var has_reservoir := screen_id != "cottonwood_creek"
			return {
				"reservoir_area_fraction": 0.50 if has_reservoir else 0.0,
				"reservoir_count": 2.0 if has_reservoir else 0.0,
				"reservoir_gate_aperture_fraction": 0.33 if has_reservoir else null,
				"drain_area_fraction": 0.25,
				"shoreline_randomness": (
					0.20
					if screen_id in ["mccloud_pit", "cottonwood_creek"]
					else 0.0
				),
			}
		"tech":
			return {
				"reservoir_area_fraction": 0.75,
				"reservoir_count": 2.0,
				"drain_area_fraction": 0.75,
				"drain_power": 1.0,
				"obstacle_area_fraction": null,
				"shoreline_randomness": 0.0,
			}
		"watershed":
			var no_effects: Dictionary = {}
			for feature_name: String in [
				"reservoir_area_fraction",
				"reservoir_count",
				"reservoir_gate_aperture_fraction",
				"drain_area_fraction",
				"drain_power",
				"obstacle_area_fraction",
				"obstacle_power",
				"shoreline_randomness",
				"salmon_activity",
				"leaf_activity",
			]:
				no_effects[feature_name] = null
			return no_effects
	return {}


func _regime_matrix_expected_schedule(
	regime_id: String,
	screen_id: String
) -> Dictionary:
	if regime_id == "kinship":
		return {
			"salmon_start_mm_dd": "11/01",
			"salmon_end_mm_dd": "01/31",
			"salmon_interval_days": "1",
			"leaf_start_mm_dd": "10/01",
			"leaf_end_mm_dd": "10/31",
			"leaf_interval_days": "2",
		}
	if regime_id == "ranch" and screen_id != "cottonwood_creek":
		return {
			"reservoir_gate_open_start_mm_dd": "06/01",
			"reservoir_gate_open_end_mm_dd": "08/31",
		}
	if regime_id == "gold_rush" and screen_id in [
		"feather_river",
		"american_river",
		"delta",
	]:
		return {
			"salmon_start_mm_dd": "11/01",
			"salmon_end_mm_dd": "01/31",
			"salmon_interval_days": "1",
			"leaf_start_mm_dd": "10/01",
			"leaf_end_mm_dd": "10/31",
			"leaf_interval_days": "2",
		}
	if regime_id == "hydropower" and screen_id != "cottonwood_creek":
		return {
			"reservoir_gate_open_start_mm_dd": "01/01",
			"reservoir_gate_open_end_mm_dd": "12/31",
		}
	return {}


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
		first_stage.call(&"set_debug_visible", true)
		second_stage.call(&"set_debug_visible", true)
		var v_key := InputEventKey.new()
		v_key.pressed = true
		v_key.keycode = KEY_V
		first_stage.call(&"_unhandled_input", v_key)
		_expect(
			bool(first_stage.call(&"runtime_summary").get(
				"debug_visible", false
			))
			and bool(second_stage.call(&"runtime_summary").get(
				"debug_visible", false
			)),
			"V from stage A must not hide geometry on either active stage."
		)
		second_stage.call(&"_unhandled_input", v_key)
		_expect(
			bool(first_stage.call(&"runtime_summary").get(
				"debug_visible", false
			))
			and bool(second_stage.call(&"runtime_summary").get(
				"debug_visible", false
			)),
			"V from stage B must keep geometry visible on both active stages."
		)
		first_stage.call(&"queue_control_message", {
			"actions": ["toggle_debug"],
		})
		await get_tree().process_frame
		_expect(
			bool(first_stage.call(&"runtime_summary").get(
				"debug_visible", false
			))
			and bool(second_stage.call(&"runtime_summary").get(
				"debug_visible", false
			)),
			"A targeted debug action must not hide recipient geometry."
		)
		first_stage.call(&"set_debug_visible", true)
		var first_summary: Dictionary = first_stage.call(&"runtime_summary")
		var second_summary: Dictionary = second_stage.call(&"runtime_summary")
		_expect(
			_shoreline_geometry_signature(first_summary).is_empty()
			and _shoreline_geometry_signature(second_summary).is_empty(),
			"Simultaneous stages must not recreate legacy shoreline banks."
		)
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
		_check_water_temperature(stage, expected_id, scene_path)
		_check_regime_panel(stage, expected_id == &"delta", scene_path)
		_check_shoreline(stage, expected_id, scene_path)
		await _check_delta_tide_exclusivity(stage, expected_id, scene_path)
		_check_shared_timeline_state(stage, scene_path)
		_check_palette_layers(stage, scene_path)
		_check_ecology(stage, scene_path)
		_check_gate_roundtrip(stage, scene_path)
		await _check_control_route(stage, expected_id, scene_path)

	scene_root.queue_free()
	await get_tree().process_frame


func _check_delta_tide_exclusivity(
	stage: Node,
	expected_id: StringName,
	scene_path: String,
) -> void:
	stage.call(&"set_active_regime_names", ["Kinship"])
	await get_tree().process_frame
	await get_tree().process_frame
	var summary: Dictionary = stage.call(&"runtime_summary")
	var is_delta := expected_id == &"delta"
	_expect(
		bool(summary.get("delta_tide_visible", false)) == is_delta,
		"%s must %s the Delta tide."
			% [scene_path, "show" if is_delta else "never show"],
	)
	_expect(
			(
				String(summary.get("delta_tide_data_status", "")) == "READY"
				and int(summary.get("delta_tide_data_row_count", 0))
					== EXPECTED_TIDE_ROW_COUNT
		) if is_delta else (
			String(summary.get("delta_tide_data_status", "")) == "NOT_DELTA"
			and int(summary.get("delta_tide_data_row_count", -1)) == 0
		),
		"%s must %s Delta-only tide data."
			% [scene_path, "load" if is_delta else "not load"],
	)
	stage.call(&"set_active_regime_names", ["Agriculture", "Tech"])
	await get_tree().process_frame
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
	_expect(
		bool(summary.get("delta_tide_visible", false)) == is_delta,
		"%s must keep Delta tide visibility independent of regime."
			% scene_path,
	)


func _check_shared_timeline_state(stage: Node, scene_path: String) -> void:
	if _expected_timeline_snapshot.is_empty():
		return
	var summary: Dictionary = stage.call(&"runtime_summary")
	var expected_progress := float(_expected_timeline_snapshot.get(
		"year_progress", 0.0
	))
	var expected_row := floori(expected_progress * 720.0)
	_expect(
		int(summary.get("model_day_index", -1))
			== int(_expected_timeline_snapshot.get("day_index", -2))
		and int(summary.get("model_minute_of_day", -1))
			== int(_expected_timeline_snapshot.get("minute_of_day", -2))
		and is_equal_approx(
			float(summary.get("model_elapsed_seconds", -1.0)),
			float(_expected_timeline_snapshot.get("elapsed_seconds", -2.0))
		)
		and int(summary.get("watershed_data_row_index", -1)) == expected_row,
		"%s must inherit the shared date and watershed row without resetting."
			% scene_path
	)
	_expect(
		bool(stage.call(&"is_paused")),
		"%s must inherit the shared paused clock state." % scene_path
	)
	_expect(
		bool(summary.get("model_timeline_shared", false))
		and String(summary.get("model_timeline_scope", ""))
			== "GODOT_PROCESS"
		and int(summary.get("model_timeline_revision", 0)) > 0,
		"%s must report the process-persistent timeline authority." % scene_path
	)


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
		"%s must distribute 1,000 global heads as 143x6 + 142." % scene_path
	)
	_expect(
		String(summary.get("head_emission_timing", ""))
		== "EVENLY_PHASED_DIRECT_RECYCLE_CONTINUOUS"
		and String(summary.get("head_native_amount_ratio_strategy", ""))
		== "FULL_CYCLE_SHADER_GATED"
		and not bool(summary.get("head_reentry_waits_for_native_cycle", true)),
		"%s must use continuous, evenly phased direct head recycling." % scene_path
	)
	_expect(
		String(summary.get("water_coverage_model", ""))
		== "CENTER_BAND_SYMMETRIC_FLOW_PERCENT"
		and is_equal_approx(
			float(summary.get("water_inlet_band_center_y_pixels", 0.0)),
			540.0,
		),
		"%s water must widen symmetrically from screen center." % scene_path
	)
	for native_ratio: Variant in Array(summary.get("head_layer_amount_ratios", [])):
		_expect(
			is_equal_approx(float(native_ratio), 1.0),
			"%s native head emitters must keep complete cycles." % scene_path
		)
	_expect(
		int(summary.get("trail_segment_capacity", 0)) == 75000,
		"%s must retain the full 75,000-segment capacity." % scene_path
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
	var date_label := stage.get_node_or_null("StageTitleLayer/ModelDate") as Label
	_expect(title_layer != null, "%s must expose StageTitleLayer." % scene_path)
	_expect(title_label != null, "%s must expose StageTitleLayer/StageTitle." % scene_path)
	_expect(date_label != null, "%s must expose StageTitleLayer/ModelDate." % scene_path)
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
	var expected_display_title := String(summary.get(
		"stage_title_display_text",
		expected_title,
	))
	_expect(
		title_label.text == expected_display_title,
		"%s title must be '%s'; got '%s'."
			% [scene_path, expected_display_title, title_label.text]
	)
	_expect(
		(title_label.position + title_label.pivot_offset).is_equal_approx(
			EXPECTED_TITLE_POSITION
		),
		"%s title must be centered on the left-edge centerline." % scene_path
	)
	_expect(
		is_equal_approx(title_label.rotation_degrees, -90.0),
		"%s title must be rotated -90 degrees." % scene_path
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
	var title_font := title_label.get_theme_font(&"font") as FontVariation
	var tnum_tag := TextServerManager.get_primary_interface().name_to_tag(
		EXPECTED_DATE_OPENTYPE_FEATURE
	)
	_expect(
		title_font != null
		and title_font.base_font != null
		and title_font.base_font.resource_path == EXPECTED_TITLE_FONT_PATH
		and int(title_font.opentype_features.get(tnum_tag, 0)) == 1,
		"%s title must use Barlow with tabular numerals." % scene_path
	)
	if date_label != null:
		_expect(
			(date_label.position + date_label.pivot_offset).is_equal_approx(
				EXPECTED_DATE_POSITION
			),
			"%s date must be centered on the right-edge centerline." % scene_path
		)
		_expect(
			is_equal_approx(date_label.rotation_degrees, -90.0),
			"%s date must be rotated -90 degrees." % scene_path
		)
		_expect(
			date_label.get_theme_font_size(&"font_size") == EXPECTED_DATE_FONT_SIZE,
			"%s date must be 48 px." % scene_path
		)
		var date_font := date_label.get_theme_font(&"font") as FontVariation
		_expect(
			date_font != null
			and title_font != null
			and date_font.get_instance_id() == title_font.get_instance_id()
			and date_font.base_font != null
			and date_font.base_font.resource_path == EXPECTED_TITLE_FONT_PATH
			and int(date_font.opentype_features.get(tnum_tag, 0)) == 1,
			"%s title and date must share Barlow tabular numerals." % scene_path
		)
		_expect(
			bool(summary.get("stage_date_tabular_numerals", false))
			and String(summary.get("stage_date_opentype_feature", ""))
				== EXPECTED_DATE_OPENTYPE_FEATURE,
			"%s summary must report the date's tnum feature." % scene_path
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
		and String(summary.get("stage_title_display_text", ""))
			== expected_display_title
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
		and bool(summary.get("water_texture_excludes_stage_title", false)),
		"%s runtime summary must expose the complete title contract." % scene_path
	)
	var initial_debug_visible := bool(summary.get("debug_visible", true))
	stage.call(&"set_debug_visible", not initial_debug_visible)
	_expect(
		title_label.visible and title_label.text == expected_display_title,
		"%s debug visibility must not affect the stage title." % scene_path
	)
	stage.call(&"set_debug_visible", initial_debug_visible)


func _check_water_temperature(
	stage: Node,
	expected_id: StringName,
	scene_path: String
) -> void:
	var screen_id := String(expected_id)
	var expected_visible := EXPECTED_TEMPERATURE_COLUMNS.has(screen_id)
	var expected_column := String(EXPECTED_TEMPERATURE_COLUMNS.get(
		screen_id,
		"",
	))
	var summary: Dictionary = stage.call(&"runtime_summary")
	var water_viewport := stage.get_node_or_null(
		"WaterOnlyViewport"
	) as SubViewport
	var title_label := stage.get_node_or_null(
		"StageTitleLayer/StageTitle"
	) as Label
	var separate_temperature_label := stage.get_node_or_null(
		"StageTitleLayer/WaterTemperature"
	)
	_expect(
		separate_temperature_label == null,
		"%s must integrate temperature into StageTitle, without a separate Label."
			% scene_path,
	)
	_expect(
		bool(stage.get("stage_temperature_visible")) == expected_visible
		and bool(summary.get("water_temperature_visible", not expected_visible))
			== expected_visible,
		"%s temperature export and summary visibility disagree." % scene_path,
	)
	_expect(
		title_label != null
		and (
			water_viewport == null
			or not water_viewport.is_ancestor_of(title_label)
		),
		"%s temperature-bearing title must remain outside WaterOnlyViewport."
			% scene_path,
	)
	_expect(
		bool(summary.get("water_texture_excludes_stage_temperature", false)),
		"%s water texture must exclude temperature text." % scene_path,
	)
	_expect(
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
		and String(summary.get("water_temperature_fallback_text", "")) == "— °C",
		"%s summary must expose the integrated temperature typography contract."
			% scene_path,
	)
	if not expected_visible:
		_expect(
			title_label != null
			and title_label.text == String(stage.get("stage_title"))
			and String(summary.get("water_temperature_data_path", "")).is_empty()
			and String(summary.get("water_temperature_data_column", "")).is_empty()
			and String(summary.get("water_temperature_text", "")) == "— °C",
			"%s must remain title-only when no temperature series exists."
				% scene_path,
		)
		return

	_expect(
		bool(summary.get("water_temperature_value_valid", false))
		and bool(summary.get("water_temperature_data_loaded", false))
		and String(summary.get("water_temperature_data_error", "")).is_empty()
		and String(summary.get("water_temperature_data_path", ""))
			== EXPECTED_TEMPERATURE_DATA_PATH
		and String(summary.get("water_temperature_data_column", ""))
			== expected_column
		and int(summary.get("water_temperature_data_row_count", 0))
			== EXPECTED_TEMPERATURE_ROW_COUNT
		and String(summary.get("water_temperature_interpolation_mode", ""))
			== EXPECTED_TEMPERATURE_INTERPOLATION,
		"%s did not load the correct 720-row temperature column." % scene_path,
	)
	if _expected_timeline_snapshot.is_empty():
		return
	var row_position := (
		float(_expected_timeline_snapshot.get("year_progress", 0.0))
		* float(EXPECTED_TEMPERATURE_ROW_COUNT)
	)
	var expected_row := mini(
		floori(row_position),
		EXPECTED_TEMPERATURE_ROW_COUNT - 1,
	)
	var expected_fraction := row_position - floorf(row_position)
	var actual_row := int(summary.get("water_temperature_data_row_index", -1))
	var actual_fraction := float(summary.get(
		"water_temperature_data_row_fraction",
		-1.0,
	))
	_expect(
		actual_row == expected_row
		and is_equal_approx(actual_fraction, expected_fraction),
		"%s temperature row must stay synchronized with ModelTimeline."
			% scene_path,
	)
	var values := PackedFloat64Array(
		_temperature_values_by_column.get(
			expected_column,
			PackedFloat64Array(),
		)
	)
	if values.size() != EXPECTED_TEMPERATURE_ROW_COUNT:
		return
	var following_row := (expected_row + 1) % EXPECTED_TEMPERATURE_ROW_COUNT
	var expected_value := lerpf(
		float(values[expected_row]),
		float(values[following_row]),
		expected_fraction,
	)
	_expect(
		is_equal_approx(
			float(summary.get("water_temperature_value_c", NAN)),
			expected_value,
		),
		"%s temperature must interpolate the selected measured-data column."
			% scene_path,
	)
	var expected_temperature_text := "%.1f °C" % expected_value
	var expected_title_text := "%s (%s)" % [
		String(stage.get("stage_title")),
		expected_temperature_text,
	]
	_expect(
		title_label != null
		and title_label.text == expected_title_text
		and String(summary.get("stage_title_display_text", ""))
			== expected_title_text
		and String(summary.get("water_temperature_text", ""))
			== expected_temperature_text
		and bool(summary.get("stage_title_temperature_visible", false)),
		"%s title must display exactly '%s'."
			% [scene_path, expected_title_text],
	)


func _check_regime_panel(
	stage: Node,
	expected_visible: bool,
	scene_path: String
) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	var panel := stage.get_node_or_null(
		"StageTitleLayer/ActiveRegimes"
	) as Node2D
	var water_viewport := stage.get_node_or_null(
		"WaterOnlyViewport"
	) as SubViewport
	_expect(panel != null, "%s must expose the shared regime panel." % scene_path)
	if panel == null:
		return
	_expect(
		panel.visible == expected_visible,
		"%s regime panel visibility must be Delta-only." % scene_path
	)
	_expect(
		panel.position == Vector2(1324.0, 1050.0),
		"%s regime panel must match the reference position." % scene_path
	)
	_expect(
		is_equal_approx(panel.rotation_degrees, -90.0),
		"%s regime panel must be rotated -90 degrees." % scene_path
	)
	_expect(
		String(summary.get("regime_heading_text", "")) == "Regime"
		and int(summary.get("regime_heading_font_size", 0)) == 48
		and int(summary.get("regime_name_font_size", 0)) == 60,
		"%s regime typography does not match the rotated reference." % scene_path
	)
	var heading := stage.get_node_or_null(
		"StageTitleLayer/ActiveRegimes/Heading"
	) as Label
	_expect(heading != null, "%s regime heading node is missing." % scene_path)
	if heading != null:
		var expected_heading_visible := not expected_visible
		_expect(
			heading.visible == expected_heading_visible
			and bool(summary.get("regime_heading_visible", false))
				== expected_heading_visible,
			"%s must hide the Regime heading on Delta only." % scene_path
		)
	_expect(
		water_viewport == null or not water_viewport.is_ancestor_of(panel),
		"%s regime panel must remain outside water occupancy." % scene_path
	)
	_expect(
		bool(summary.get("regime_state_shared", false))
		and String(summary.get("regime_state_scope", "")) == "GODOT_PROCESS",
		"%s must consume the in-memory process regime state." % scene_path
	)
	_expect(
		Array(summary.get("regime_names", [])) == EXPECTED_REGIME_NAMES,
		"%s regime names must use the required historical order." % scene_path
	)
	_expect(
		Array(summary.get("active_regime_names", [])) == ["Agriculture", "Tech"],
		"%s must hydrate the shared active regime set." % scene_path
	)
	_expect(
		bool(summary.get("water_texture_excludes_regime_panel", false)),
		"%s water texture must exclude regime text." % scene_path
	)
	for index in range(EXPECTED_REGIME_NAMES.size()):
		var label := stage.get_node_or_null(
			"StageTitleLayer/ActiveRegimes/Regime%d" % (index + 1)
		) as Label
		_expect(label != null, "%s regime label %d is missing." % [
			scene_path,
			index + 1,
		])
		if label == null:
			continue
		var expected_label: String = EXPECTED_REGIME_NAMES[index]
		if expected_visible and index == 3:
			expected_label = "Water Project"
		elif expected_visible and index == EXPECTED_REGIME_NAMES.size() - 1:
			expected_label = "AI Watershed"
		_expect(
			label.text == expected_label,
			"%s regime label order is incorrect." % scene_path
		)
		var expected_alpha := 1.0 if index in [1, 5] else 0.25
		_expect(
			is_equal_approx(
				label.get_theme_color(&"font_color").a,
				expected_alpha,
			),
			"%s regime label alpha does not reflect active state." % scene_path
		)


func _check_ecology(stage: Node, scene_path: String) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	_expect(
		not stage.has_method(&"get_source_polygon")
		and not summary.has("source_polygon_count")
		and not summary.has("source_polygons")
		and not summary.has("source_count_uniforms")
		and not summary.has("source_data_texture_bound"),
		"%s still exposes the removed supplemental-source system." % scene_path,
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
			== "REACH_SCREEN_MIDLINE_THEN_FADE",
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
			540.0
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


func _check_shoreline(
	stage: Node,
	expected_id: StringName,
	scene_path: String
) -> void:
	var summary: Dictionary = stage.call(&"runtime_summary")
	_expect(
		String(summary.get("regime_profile_path", ""))
			== EXPECTED_REGIME_PROFILE_PATH
		and bool(summary.get("regime_profiles_loaded", false))
		and int(summary.get("regime_profile_count", 0)) == 7,
		"%s must load all seven profiles from the root text table." % scene_path
	)
	_expect(
		String(summary.get("regime_geometry_mode", ""))
			== "GENERATION_SALTED_BOUNDED_SLOT_BANKS"
		and int(summary.get("regime_layout_generation", -1)) >= 0,
		"%s must expose generation-salted fixed feature placement." % scene_path,
	)
	var natural_agriculture_shoreline := expected_id in [
		&"mount_shasta",
		&"mccloud_pit",
		&"cottonwood_creek",
	]
	var expected_shoreline_weight := (
		0.15 if natural_agriculture_shoreline else 0.0
	)
	var expected_reservoir_weight := (
		0.375 if expected_id == &"cottonwood_creek" else 0.475
	)
	var feature_state: Dictionary = summary.get(
		"regime_effective_feature_state",
		{},
	)
	var expected_feature_states := {
		"reservoir_area_fraction": {
			"defined": true,
			"value": expected_reservoir_weight,
			"contributors": ["ranch", "tech"],
		},
		"drain_area_fraction": {
			"defined": true,
			"value": 0.75,
			"contributors": ["ranch", "tech"],
		},
		"obstacle_area_fraction": {
			"defined": true,
			"value": 0.10,
			"contributors": ["ranch"],
		},
		"shoreline_randomness": {
			"defined": true,
			"value": expected_shoreline_weight,
			"contributors": ["ranch", "tech"],
		},
	}
	for feature_name: String in expected_feature_states:
		var expected_state: Dictionary = expected_feature_states[feature_name]
		var actual_state_variant: Variant = feature_state.get(feature_name, {})
		var actual_state: Dictionary = (
			actual_state_variant if actual_state_variant is Dictionary else {}
		)
		var expected_contributors: Array = expected_state["contributors"]
		_expect(
			bool(actual_state.get("defined", false))
				== bool(expected_state["defined"])
			and is_equal_approx(
				float(actual_state.get("value", -1.0)),
				float(expected_state["value"]),
			)
			and int(actual_state.get("contributor_count", -1))
				== expected_contributors.size()
			and Array(actual_state.get("contributor_ids", []))
				== expected_contributors,
			"%s has incorrect per-river Agriculture + Tech state for %s."
				% [scene_path, feature_name]
		)
	_expect(
		is_equal_approx(
			float(summary.get("shoreline_randomness", -1.0)),
			expected_shoreline_weight,
		),
		"%s did not apply its per-river Agriculture shoreline weight." % scene_path
	)
	_expect(
		bool(summary.get("regime_profile_physics_enabled", false)),
		"%s must opt into per-river regime physics." % scene_path
	)
	var applied_budgets: Dictionary = summary.get(
		"regime_applied_feature_budgets",
		{}
	)
	var expected_budget_values := [expected_reservoir_weight, 0.75, 0.10]
	var budget_names := [
		"reservoir_area_fraction",
		"drain_area_fraction",
		"obstacle_area_fraction",
	]
	for budget_index in range(budget_names.size()):
		_expect(
			is_equal_approx(
				float(applied_budgets.get(budget_names[budget_index], -1.0)),
				float(expected_budget_values[budget_index]),
			),
			"%s has an incorrect applied regime feature budget." % scene_path
		)
	var applied_overrides: Dictionary = summary.get(
		"regime_applied_feature_overrides",
		{},
	)
	_expect(
		bool(applied_overrides.get("reservoir", false))
		and bool(applied_overrides.get("drain_area", false))
		and bool(applied_overrides.get("obstacle_area", false)),
		"%s must apply the defined interaction budgets." % scene_path
	)
	_expect_feature_slots(
		summary,
		{"drain": 4, "obstacle": 1},
		scene_path,
	)
	_check_edge_turbulence(summary, expected_shoreline_weight, scene_path)
	_regime_geometry_signature_by_screen[String(expected_id)] = (
		_regime_geometry_signature(summary)
	)


func _expect_feature_slots(
	summary: Dictionary,
	expected: Dictionary,
	context: String,
) -> void:
	_expect(
		Dictionary(summary.get("regime_feature_slot_capacities", {}))
			== EXPECTED_REGIME_SLOT_CAPACITIES
		and Dictionary(summary.get("regime_feature_slot_counts_resident", {}))
			== EXPECTED_REGIME_SLOT_CAPACITIES,
		"%s must retain fixed 5-drain and 2-obstacle banks." % context,
	)
	_expect(
		Dictionary(summary.get("regime_feature_slot_counts_desired", {})) == expected
		and Dictionary(summary.get("regime_feature_slot_counts_rendered", {})) == expected,
		"%s has incorrect desired or rendered feature counts." % context,
	)
	_expect(
		Dictionary(summary.get("regime_feature_controller_spare_capacity", {})) == {
			"interaction": 1,
		},
		"%s did not preserve controller capacity outside the fixed banks." % context,
	)
	_expect(
		int(summary.get("interaction_polygon_count", 0)) == 7
		and int(summary.get("interaction_overlay_count", 0))
			== int(expected.get("drain", 0)) + int(expected.get("obstacle", 0)),
		"%s does not retain the complete resident feature resources." % context,
	)
	var expected_interaction_count := int(expected.get("drain", 0)) + int(
		expected.get("obstacle", 0)
	)
	for count_variant: Variant in Array(summary.get("interaction_count_uniforms", [])):
		_expect(
			int(count_variant) == expected_interaction_count,
			"%s interaction count did not reach every shader." % context,
		)


func _check_edge_turbulence(
	summary: Dictionary,
	expected_amount: float,
	context: String,
) -> void:
	_expect(
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
		),
		"%s has incorrect edge-turbulence settings." % context,
	)
	_expect(
		int(summary.get("shoreline_count", -1)) == 0
		and int(summary.get("shoreline_vertex_count", -1)) == 0
		and Array(summary.get("shoreline_ids", [])).is_empty()
		and Array(summary.get("shoreline_obstacles", [])).is_empty()
		and int(summary.get("shoreline_overlay_count", -1)) == 0
		and not bool(summary.get("shoreline_data_texture_bound", true))
		and Vector2(summary.get("shoreline_data_texture_size", Vector2.ONE))
			== Vector2.ZERO,
		"%s still allocates legacy shoreline geometry, texture, or overlays." % context,
	)
	_expect(
		Vector2(summary.get("shoreline_inlet_y_range_pixels", Vector2.ZERO))
			== Vector2(28.0, 1052.0),
		"%s edge turbulence must retain the full 28..1052 inlet." % context,
	)
	for uniform_spec: Array in [
		["edge_turbulence_amount_uniforms", expected_amount],
		["edge_turbulence_band_uniforms", 180.0],
		["edge_turbulence_wall_band_uniforms", 40.0],
	]:
		var values := Array(summary.get(String(uniform_spec[0]), []))
		_expect(
			values.size() == 7,
			"%s %s must reach all seven shader layers." % [context, uniform_spec[0]],
		)
		for value_variant: Variant in values:
			_expect(
				is_equal_approx(float(value_variant), float(uniform_spec[1])),
				"%s %s is inconsistent across shaders." % [context, uniform_spec[0]],
			)
	for count_variant: Variant in Array(summary.get("shoreline_count_uniforms", [])):
		_expect(
			int(count_variant) == 0,
			"%s still enables legacy shoreline shader records." % context,
		)
	for bound_variant: Variant in Array(
		summary.get("shoreline_texture_bound_uniforms", [])
	):
		_expect(
			not bool(bound_variant),
			"%s still binds a legacy shoreline texture to a shader." % context,
		)
	for inlet_variant: Variant in Array(
		summary.get("shoreline_inlet_y_range_uniforms", [])
	):
		_expect(
			Vector2(inlet_variant) == Vector2(28.0, 1052.0),
			"%s full inlet did not reach every shader." % context,
		)
	_expect(
		int(summary.get("edge_turbulence_parameter_upload_count", 0)) >= 1,
		"%s never uploaded its edge-turbulence parameters." % context,
	)


func _shoreline_geometry_signature(summary: Dictionary) -> String:
	var parts := PackedStringArray()
	for definition_variant: Variant in Array(
		summary.get("shoreline_obstacles", [])
	):
		if not definition_variant is Dictionary:
			continue
		var definition: Dictionary = definition_variant
		parts.append(String(definition.get("element_id", "")))
		var vertices_variant: Variant = definition.get(
			"vertices_world", PackedVector2Array()
		)
		if not vertices_variant is PackedVector2Array:
			continue
		for point: Vector2 in PackedVector2Array(vertices_variant):
			parts.append("%.6f,%.6f" % [point.x, point.y])
	return "|".join(parts)


func _regime_geometry_signature(summary: Dictionary) -> String:
	var parts := PackedStringArray()
	var center := Vector2(summary.get("reservoir_center_pixels", Vector2.ZERO))
	parts.append("reservoir=%.6f,%.6f" % [center.x, center.y])
	for definition_variant: Variant in Array(summary.get("interaction_polygons", [])):
		if not definition_variant is Dictionary:
			continue
		var definition: Dictionary = definition_variant
		parts.append(String(definition.get("element_id", "")))
		var vertices_variant: Variant = definition.get(
			"vertices",
			PackedVector2Array(),
		)
		if not vertices_variant is Array:
			continue
		for point_variant: Variant in Array(vertices_variant):
			if point_variant is Array and Array(point_variant).size() >= 2:
				parts.append("%.6f,%.6f" % [
					float(Array(point_variant)[0]),
					float(Array(point_variant)[1]),
				])
	return "|".join(parts)


func _check_gate_roundtrip(stage: Node, scene_path: String) -> void:
	# Direct gate helpers operate on the authored aperture. Isolate that API from
	# the shared Agriculture winter schedule, which intentionally multiplies the
	# effective aperture down to zero at this fixture date.
	var regimes := get_node_or_null("/root/ModelRegimes")
	var active_regime_names: Array = []
	if regimes != null:
		active_regime_names = Array(
			Dictionary(regimes.call(&"snapshot")).get("active_names", [])
		).duplicate()
		regimes.call(&"clear_regimes")
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
	if regimes != null:
		regimes.call(&"set_active_names", active_regime_names)


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
	var expected_remaining := 0.60 * (
		1.0 - float(summary.get("total_extraction_fraction", 0.0))
	)
	_expect(
		is_equal_approx(float(summary.get("basin_input_rate", 0.0)), 0.60)
		and is_equal_approx(
			float(summary.get("basin_remaining_rate", 0.0)),
			expected_remaining
		),
		"%s routed input must pass through the active extraction budget."
			% scene_path
	)
	stage.call(&"set_flow_rate", 0.50)

	var salmon_before: Dictionary = summary.get("salmon_summary", {})
	var leaves_before: Dictionary = summary.get("leaf_summary", {})
	recipients = int(bus.call(&"route_control_message", {
		"target": String(expected_id),
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
		"%s routed ecology packet must reach exactly one stage." % scene_path
	)
	await get_tree().process_frame
	summary = stage.call(&"runtime_summary")
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
		int(summary.get("interaction_polygon_count", 0)) == 8,
		"%s routed polygon upsert must add outside the resident interaction bank."
			% scene_path
	)
	for count_variant: Variant in Array(summary.get("interaction_count_uniforms", [])):
		_expect(
			int(count_variant) == 6,
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
		int(summary.get("interaction_polygon_count", 0)) == 7,
		"%s routed polygon removal must restore the resident interaction bank."
			% scene_path
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
			+ "six temperature-bearing titles, "
				+ "shared in-memory timeline/regimes + gate + routed "
			+ "polygons/salmon/leaves)"
		)
		get_tree().quit(0)
		return
	for failure in _failures:
		push_error("GPU_STAGE_SCENES_SMOKE: %s" % failure)
	print("GPU_STAGE_SCENES_SMOKE: FAIL (%d failures)" % _failures.size())
	get_tree().quit(1)
