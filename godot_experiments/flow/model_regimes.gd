extends Node
## Process-persistent authority for the seven historical water regimes.
##
## The active set survives current-scene replacement and is intentionally
## independent of river identity. Several historical regimes may be active at
## once; Watershed is the exclusive optimize-or-bust state and clears the rest.

signal regimes_changed(state: Dictionary)

const BasinBudgetModel := preload("res://flow/basin_budget.gd")
const PROFILE_TEXT_PATH := "res://regime_feature_profiles.txt"
const PROFILE_SCHEMA_VERSION := "2"
const RIVER_PROFILE_SCHEMA_VERSION := "2"
const RIVER_PROFILE_DIRECTORY := "res://flow/data/regimes/"
const MONTH_DAY_COUNTS: Array[int] = [
	31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
]
const CANONICAL_SCREEN_IDS: Array[StringName] = [
	&"mount_shasta",
	&"mccloud_pit",
	&"cottonwood_creek",
	&"mill_creek",
	&"feather_river",
	&"american_river",
	&"delta",
]
const FEATURE_FIELDS: Array[String] = [
	"reservoir_area_fraction",
	"drain_area_fraction",
	"obstacle_area_fraction",
	"shoreline_randomness",
	"salmon_activity",
	"leaf_activity",
]
const EFFECTIVE_FEATURE_FIELDS: Array[String] = [
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
]
const RIVER_FRACTION_FIELDS: Array[String] = [
	"reservoir_area_fraction",
	"reservoir_gate_aperture_fraction",
	"drain_area_fraction",
	"drain_power",
	"obstacle_area_fraction",
	"obstacle_power",
	"shoreline_randomness",
	"salmon_activity",
	"leaf_activity",
]
const SCHEDULE_FIELDS: Array[String] = [
	"salmon_start_mm_dd",
	"salmon_end_mm_dd",
	"salmon_interval_days",
	"leaf_start_mm_dd",
	"leaf_end_mm_dd",
	"leaf_interval_days",
]
const RIVER_SCHEDULE_FIELDS: Array[String] = [
	"reservoir_gate_open_start_mm_dd",
	"reservoir_gate_open_end_mm_dd",
	"salmon_start_mm_dd",
	"salmon_end_mm_dd",
	"salmon_interval_days",
	"leaf_start_mm_dd",
	"leaf_end_mm_dd",
	"leaf_interval_days",
]
const RIVER_PROFILE_COLUMNS: Array[String] = [
	"schema_version",
	"screen_id",
	"reservoir_area_fraction",
	"reservoir_count",
	"reservoir_gate_aperture_fraction",
	"reservoir_gate_open_start_mm_dd",
	"reservoir_gate_open_end_mm_dd",
	"drain_area_fraction",
	"drain_power",
	"obstacle_area_fraction",
	"obstacle_power",
	"shoreline_randomness",
	"salmon_activity",
	"salmon_start_mm_dd",
	"salmon_end_mm_dd",
	"salmon_interval_days",
	"leaf_activity",
	"leaf_start_mm_dd",
	"leaf_end_mm_dd",
	"leaf_interval_days",
	"notes",
]
const REGIME_NAMES: Array[String] = [
	"Kinship",
	"Agriculture",
	"Gold Rush",
	"Water Projects",
	"Hydropower",
	"Tech",
	"Watershed",
]
const REGIME_IDS: Array[StringName] = [
	&"kinship",
	&"ranch",
	&"gold_rush",
	&"water_projects",
	&"hydropower",
	&"tech",
	&"watershed",
]
const WATERSHED_REGIME_INDEX := 6

# Open in the non-extractive Kinship state. A valid chair packet replaces this
# with an absolute seven-regime state as soon as the hardware reports.
var _active := PackedByteArray([1, 0, 0, 0, 0, 0, 0])
var _revision: int = 0
var _profiles_by_id: Dictionary = {}
var _profile_diagnostics: Array[String] = []
var _profiles_loaded: bool = false
var _profile_reload_revision: int = 0
var _effective_features: Dictionary = {
	"reservoir_area_fraction": 0.0,
	"drain_area_fraction": 0.0,
	"obstacle_area_fraction": 0.0,
	"shoreline_randomness": 0.0,
	"salmon_activity": 0.0,
	"leaf_activity": 0.0,
}
var _effective_feature_state_by_screen: Dictionary = {}
var _active_schedules_by_screen: Dictionary = {}


func _ready() -> void:
	reload_profiles(false)


func regime_count() -> int:
	return REGIME_NAMES.size()


func reload_profiles(publish_snapshot: bool = true) -> bool:
	## Reload the comma-delimited text table without treating draft cells as zero.
	var loaded := _load_profiles_from_text()
	_recompute_effective_features()
	if publish_snapshot:
		_publish_change()
	return loaded


func toggle_regime(index: int) -> bool:
	if not _valid_index(index):
		return false
	var activating := _active[index] == 0
	if activating and index == WATERSHED_REGIME_INDEX:
		_active.fill(0)
	elif activating and _active[WATERSHED_REGIME_INDEX] != 0:
		_active[WATERSHED_REGIME_INDEX] = 0
	_active[index] = 1 if activating else 0
	_publish_change()
	return true


func set_regime_active(index: int, active: bool) -> bool:
	if not _valid_index(index):
		return false
	var next_value := 1 if active else 0
	var before := _active.duplicate()
	if active and index == WATERSHED_REGIME_INDEX:
		_active.fill(0)
	elif active and _active[WATERSHED_REGIME_INDEX] != 0:
		_active[WATERSHED_REGIME_INDEX] = 0
	_active[index] = next_value
	if _active == before:
		return true
	_publish_change()
	return true


func set_regime_active_by_id(regime_id: StringName, active: bool) -> bool:
	return set_regime_active(REGIME_IDS.find(regime_id), active)


func set_active_names(names: Array) -> bool:
	var next_active := PackedByteArray()
	next_active.resize(REGIME_NAMES.size())
	for name_variant: Variant in names:
		var index := _index_for_name(String(name_variant))
		if index < 0:
			return false
		next_active[index] = 1
	if next_active[WATERSHED_REGIME_INDEX] != 0:
		next_active.fill(0)
		next_active[WATERSHED_REGIME_INDEX] = 1
	if next_active == _active:
		return true
	_active = next_active
	_publish_change()
	return true


func set_active_indices(indices: Array) -> bool:
	var next_active := PackedByteArray()
	next_active.resize(REGIME_NAMES.size())
	for index_variant: Variant in indices:
		if not _is_integral_number(index_variant):
			return false
		var index := int(index_variant)
		if not _valid_index(index):
			return false
		next_active[index] = 1
	if next_active[WATERSHED_REGIME_INDEX] != 0:
		next_active.fill(0)
		next_active[WATERSHED_REGIME_INDEX] = 1
	if next_active == _active:
		return true
	_active = next_active
	_publish_change()
	return true


func clear_regimes() -> void:
	var already_clear := true
	for value in _active:
		if value != 0:
			already_clear = false
			break
	if already_clear:
		return
	_active.fill(0)
	_publish_change()


func snapshot() -> Dictionary:
	var active_states: Array[bool] = []
	var active_indices: Array[int] = []
	var active_names: Array[String] = []
	var active_ids: Array[StringName] = []
	var active_schedules: Dictionary = {}
	var active_profiles: Dictionary = {}
	for index in range(REGIME_NAMES.size()):
		var active := _active[index] != 0
		active_states.append(active)
		if active:
			active_indices.append(index)
			active_names.append(REGIME_NAMES[index])
			active_ids.append(REGIME_IDS[index])
			var regime_id := REGIME_IDS[index]
			if _profiles_by_id.has(regime_id):
				var profile: Dictionary = _profiles_by_id[regime_id]
				active_schedules[String(regime_id)] = Dictionary(
					profile.get("schedule", {})
				).duplicate(true)
				active_profiles[String(regime_id)] = _profile_snapshot(profile)
	var extraction_breakdown := BasinBudgetModel.extraction_breakdown(active_states)
	var total_extraction_fraction := BasinBudgetModel.total_extraction_fraction(
		active_states
	)
	return {
		"regime_names": REGIME_NAMES.duplicate(),
		"regime_ids": REGIME_IDS.duplicate(),
		"active_states": active_states,
		"active_indices": active_indices,
		"active_names": active_names,
		"active_ids": active_ids,
		"active_count": active_indices.size(),
		"extraction_breakdown": extraction_breakdown,
		"total_extraction_fraction": total_extraction_fraction,
		"total_extraction_percent": total_extraction_fraction * 100.0,
		"revision": _revision,
		"scope": "GODOT_PROCESS",
		"profile_path": PROFILE_TEXT_PATH,
		"profiles_loaded": _profiles_loaded,
		"profile_count": _profiles_by_id.size(),
		"profile_reload_revision": _profile_reload_revision,
		"profile_diagnostics": _profile_diagnostics.duplicate(),
		"effective_features": _effective_features.duplicate(true),
		"active_schedules": active_schedules,
		"effective_feature_state_by_screen": (
			_effective_feature_state_by_screen.duplicate(true)
		),
		"active_schedules_by_screen": _active_schedules_by_screen.duplicate(true),
		"active_profiles": active_profiles,
	}


func _publish_change() -> void:
	_recompute_effective_features()
	_revision += 1
	regimes_changed.emit(snapshot())


func _load_profiles_from_text() -> bool:
	var next_profiles: Dictionary = {}
	var next_diagnostics: Array[String] = []
	var file := FileAccess.open(PROFILE_TEXT_PATH, FileAccess.READ)
	if file == null:
		next_diagnostics.append(
			"Could not open %s: %s" % [
				PROFILE_TEXT_PATH,
				error_string(FileAccess.get_open_error()),
			]
		)
		_commit_loaded_profiles(next_profiles, next_diagnostics, false)
		return false

	var header_row := file.get_csv_line()
	var header_indices := _csv_header_indices(header_row, next_diagnostics)
	var master_profiles_valid := next_diagnostics.is_empty()
	if not header_indices.has("schema_version"):
		next_diagnostics.append(
			"Profile header is missing required column: schema_version"
		)
		master_profiles_valid = false
	if not header_indices.has("regime_id"):
		next_diagnostics.append("Profile header is missing required column: regime_id")
		_commit_loaded_profiles(next_profiles, next_diagnostics, false)
		return false
	if not header_indices.has("river_profile_path"):
		next_diagnostics.append(
			"Profile header is missing required column: river_profile_path"
		)
		master_profiles_valid = false
	for feature_name: String in FEATURE_FIELDS:
		if not header_indices.has(feature_name):
			next_diagnostics.append(
				"Profile header is missing feature column: %s" % feature_name
			)
			master_profiles_valid = false
	for schedule_name: String in SCHEDULE_FIELDS:
		if not header_indices.has(schedule_name):
			next_diagnostics.append(
				"Profile header is missing schedule column: %s" % schedule_name
			)
			master_profiles_valid = false

	var linked_profiles_valid := true
	var row_number := 1
	while not file.eof_reached():
		var row := file.get_csv_line()
		row_number += 1
		if _csv_row_is_empty(row):
			continue
		var raw_regime_id := _csv_cell(row, header_indices, "regime_id")
		var normalized_id := _normalize_regime_id(raw_regime_id)
		var regime_id := StringName(normalized_id)
		if regime_id == &"":
			next_diagnostics.append("Row %d has no regime_id; row ignored." % row_number)
			master_profiles_valid = false
			continue
		if REGIME_IDS.find(regime_id) < 0:
			next_diagnostics.append(
				"Row %d has unknown regime_id '%s'; row ignored." % [
					row_number,
					raw_regime_id,
				]
			)
			master_profiles_valid = false
			continue
		if next_profiles.has(regime_id):
			next_diagnostics.append(
				"Row %d repeats regime_id '%s'; row ignored." % [
					row_number,
					normalized_id,
				]
			)
			master_profiles_valid = false
			continue

		var schema_version := _csv_cell(
			row,
			header_indices,
			"schema_version"
		)
		if schema_version != PROFILE_SCHEMA_VERSION:
			next_diagnostics.append(
				"Row %d uses unsupported schema_version '%s'." % [
					row_number,
					schema_version,
				]
			)
			master_profiles_valid = false

		var feature_values: Dictionary = {}
		for feature_name: String in FEATURE_FIELDS:
			var raw_value := _csv_cell(row, header_indices, feature_name)
			if raw_value == "":
				continue
			var parsed_value: Variant = _parse_fraction(raw_value)
			if parsed_value == null:
				next_diagnostics.append(
					"Row %d %s is not a 0-1 number: '%s'; value ignored." % [
						row_number,
						feature_name,
						raw_value,
					]
				)
				master_profiles_valid = false
				continue
			feature_values[feature_name] = float(parsed_value)

		var diagnostics_before_schedule := next_diagnostics.size()
		var schedule_values := _validated_schedule_values(
			row,
			header_indices,
			row_number,
			next_diagnostics,
		)
		if next_diagnostics.size() != diagnostics_before_schedule:
			master_profiles_valid = false

		var river_profile_path := _csv_cell(
			row,
			header_indices,
			"river_profile_path"
		)
		var river_result := _load_river_profile(
			river_profile_path,
			normalized_id,
			schedule_values,
			next_diagnostics,
		)
		if not bool(river_result.get("valid", false)):
			linked_profiles_valid = false

		next_profiles[regime_id] = {
			"regime_id": normalized_id,
			"regime_name": _csv_cell(row, header_indices, "regime_name"),
			# Status remains available for diagnostics and authoring, but never gates
			# valid values. Several intentionally evolving rows are `not_defined`.
			"profile_status": _csv_cell(row, header_indices, "profile_status"),
			"features": feature_values,
			"schedule": schedule_values,
			"river_profile_path": river_profile_path,
			"river_overrides": Dictionary(
				river_result.get("overrides", {})
			).duplicate(true),
		}

	for expected_regime_id: StringName in REGIME_IDS:
		if not next_profiles.has(expected_regime_id):
			next_diagnostics.append(
				"Profile table is missing regime_id '%s'." % String(expected_regime_id)
			)
			master_profiles_valid = false
	var loaded := (
		not next_profiles.is_empty()
		and master_profiles_valid
		and linked_profiles_valid
	)
	if next_profiles.is_empty():
		next_diagnostics.append("Profile table contains no usable regime profiles.")
	_commit_loaded_profiles(next_profiles, next_diagnostics, loaded)
	return loaded


func _commit_loaded_profiles(
	next_profiles: Dictionary,
	next_diagnostics: Array[String],
	loaded: bool
) -> void:
	# A malformed live edit must never erase the last known-good installation
	# state. The reload call still returns false and publishes diagnostics, while
	# a cold start with no valid profile remains unloaded.
	if loaded:
		_profiles_by_id = next_profiles
	_profile_diagnostics = next_diagnostics
	_profiles_loaded = not _profiles_by_id.is_empty()
	_profile_reload_revision += 1


func _csv_header_indices(
	header_row: PackedStringArray,
	diagnostics: Array[String]
) -> Dictionary:
	var result: Dictionary = {}
	for column_index in range(header_row.size()):
		var header_name := _normalize_header(header_row[column_index])
		if header_name == "":
			continue
		if result.has(header_name):
			diagnostics.append(
				"Profile header repeats column '%s'; first column retained." % header_name
			)
			continue
		result[header_name] = column_index
	return result


func _csv_cell(
	row: PackedStringArray,
	header_indices: Dictionary,
	header_name: String
) -> String:
	var normalized_header := _normalize_header(header_name)
	if not header_indices.has(normalized_header):
		return ""
	var column_index := int(header_indices[normalized_header])
	if column_index < 0 or column_index >= row.size():
		return ""
	return row[column_index].strip_edges()


func _csv_row_is_empty(row: PackedStringArray) -> bool:
	for cell: String in row:
		if not cell.strip_edges().is_empty():
			return false
	return true


func _normalize_header(value: String) -> String:
	return value.strip_edges().trim_prefix("\ufeff").to_lower()


func _normalize_regime_id(value: String) -> String:
	return value.strip_edges().to_lower().replace("-", "_").replace(" ", "_")


func _parse_fraction(raw_value: String) -> Variant:
	var text := raw_value.strip_edges()
	if text == "" or not text.is_valid_float():
		return null
	var value := text.to_float()
	if not is_finite(value) or value < 0.0 or value > 1.0:
		return null
	return value


func _validated_schedule_values(
	row: PackedStringArray,
	header_indices: Dictionary,
	row_number: int,
	diagnostics: Array[String]
) -> Dictionary:
	var result: Dictionary = {}
	for ecology_name: String in ["salmon", "leaf"]:
		var start_name := "%s_start_mm_dd" % ecology_name
		var end_name := "%s_end_mm_dd" % ecology_name
		var interval_name := "%s_interval_days" % ecology_name
		var start_value := _csv_cell(row, header_indices, start_name)
		var end_value := _csv_cell(row, header_indices, end_name)
		var interval_value := _csv_cell(row, header_indices, interval_name)
		if start_value.is_empty() and end_value.is_empty() and interval_value.is_empty():
			continue
		if (
			not _valid_canonical_mm_dd(start_value)
			or not _valid_canonical_mm_dd(end_value)
			or not interval_value.is_valid_int()
			or int(interval_value) <= 0
		):
			diagnostics.append(
				(
					"Row %d has an invalid %s schedule; expected MM/DD start/end "
					+ "and a positive integer interval. Schedule ignored."
				) % [row_number, ecology_name]
			)
			continue
		result[start_name] = start_value
		result[end_name] = end_value
		result[interval_name] = interval_value
	return result


func _valid_canonical_mm_dd(value: String) -> bool:
	if value.length() != 5 or value.substr(2, 1) != "/":
		return false
	var month_text := value.substr(0, 2)
	var day_text := value.substr(3, 2)
	if not month_text.is_valid_int() or not day_text.is_valid_int():
		return false
	var month := int(month_text)
	var day := int(day_text)
	return (
		month >= 1
		and month <= MONTH_DAY_COUNTS.size()
		and day >= 1
		and day <= MONTH_DAY_COUNTS[month - 1]
	)


func _load_river_profile(
	path: String,
	regime_id: String,
	default_schedule: Dictionary,
	diagnostics: Array[String]
) -> Dictionary:
	if path.is_empty():
		return {"valid": true, "overrides": {}}
	if not _valid_river_profile_path(path, regime_id):
		diagnostics.append(
			"Regime '%s' has invalid river_profile_path '%s'." % [regime_id, path]
		)
		return {"valid": false, "overrides": {}}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		diagnostics.append(
			"Could not open river profile %s for '%s': %s" % [
				path,
				regime_id,
				error_string(FileAccess.get_open_error()),
			]
		)
		return {"valid": false, "overrides": {}}

	var header_row := file.get_csv_line()
	var normalized_columns: Array[String] = []
	for header_value: String in header_row:
		normalized_columns.append(_normalize_header(header_value))
	if normalized_columns != RIVER_PROFILE_COLUMNS:
		diagnostics.append(
			"River profile %s must use the exact canonical column list." % path
		)
		return {"valid": false, "overrides": {}}
	var header_indices := _csv_header_indices(header_row, diagnostics)
	var overrides: Dictionary = {}
	var seen_screen_ids: Dictionary = {}
	var valid := true
	var row_number := 1
	while not file.eof_reached():
		var row := file.get_csv_line()
		row_number += 1
		if _csv_row_is_empty(row):
			continue
		var screen_id := _normalize_screen_id(
			_csv_cell(row, header_indices, "screen_id")
		)
		if CANONICAL_SCREEN_IDS.find(StringName(screen_id)) < 0:
			diagnostics.append(
				"%s row %d has unknown screen_id '%s'." % [
					path,
					row_number,
					screen_id,
				]
			)
			valid = false
			continue
		if seen_screen_ids.has(screen_id):
			diagnostics.append(
				"%s row %d repeats screen_id '%s'." % [
					path,
					row_number,
					screen_id,
				]
			)
			valid = false
			continue
		seen_screen_ids[screen_id] = true
		var schema_version := _csv_cell(row, header_indices, "schema_version")
		if schema_version != RIVER_PROFILE_SCHEMA_VERSION:
			diagnostics.append(
				"%s row %d uses unsupported schema_version '%s'." % [
					path,
					row_number,
					schema_version,
				]
			)
			valid = false

		var parsed := _parse_river_override(
			row,
			header_indices,
			default_schedule,
			path,
			row_number,
			diagnostics,
		)
		if not bool(parsed.get("valid", false)):
			valid = false
		overrides[screen_id] = Dictionary(parsed.get("override", {}))

	for canonical_id: StringName in CANONICAL_SCREEN_IDS:
		if not seen_screen_ids.has(String(canonical_id)):
			diagnostics.append(
				"River profile %s is missing screen_id '%s'." % [
					path,
					String(canonical_id),
				]
			)
			valid = false
	if not valid:
		return {"valid": false, "overrides": {}}
	return {"valid": true, "overrides": overrides}


func _parse_river_override(
	row: PackedStringArray,
	header_indices: Dictionary,
	default_schedule: Dictionary,
	path: String,
	row_number: int,
	diagnostics: Array[String]
) -> Dictionary:
	var valid := true
	var features: Dictionary = {}
	for feature_name: String in RIVER_FRACTION_FIELDS:
		var raw_value := _csv_cell(row, header_indices, feature_name)
		if raw_value.is_empty():
			continue
		var parsed_value: Variant = _parse_fraction(raw_value)
		if parsed_value == null:
			diagnostics.append(
				"%s row %d %s is not a 0-1 number: '%s'." % [
					path,
					row_number,
					feature_name,
					raw_value,
				]
			)
			valid = false
			continue
		features[feature_name] = float(parsed_value)

	var raw_count := _csv_cell(row, header_indices, "reservoir_count")
	if not raw_count.is_empty():
		if not raw_count.is_valid_int():
			diagnostics.append(
				"%s row %d reservoir_count is not an integer: '%s'." % [
					path,
					row_number,
					raw_count,
				]
			)
			valid = false
		else:
			var reservoir_count := int(raw_count)
			if reservoir_count < 0 or reservoir_count > 2:
				diagnostics.append(
					"%s row %d reservoir_count must be in 0..2: '%s'." % [
						path,
						row_number,
						raw_count,
					]
				)
				valid = false
			else:
				features["reservoir_count"] = reservoir_count

	var schedule: Dictionary = {}
	for schedule_name: String in RIVER_SCHEDULE_FIELDS:
		var raw_value := _csv_cell(row, header_indices, schedule_name)
		if raw_value.is_empty():
			continue
		if schedule_name.ends_with("_mm_dd"):
			if not _valid_canonical_mm_dd(raw_value):
				diagnostics.append(
					"%s row %d %s is not a canonical MM/DD date: '%s'." % [
						path,
						row_number,
						schedule_name,
						raw_value,
					]
				)
				valid = false
				continue
		elif schedule_name.ends_with("_interval_days"):
			if not raw_value.is_valid_int() or int(raw_value) <= 0:
				diagnostics.append(
					"%s row %d %s must be a positive integer: '%s'." % [
						path,
						row_number,
						schedule_name,
						raw_value,
					]
				)
				valid = false
				continue
		schedule[schedule_name] = raw_value

	var merged_schedule := default_schedule.duplicate(true)
	for schedule_name: Variant in schedule:
		merged_schedule[schedule_name] = schedule[schedule_name]
	for schedule_group: Array in [
		[
			"reservoir gate",
			"reservoir_gate_open_start_mm_dd",
			"reservoir_gate_open_end_mm_dd",
		],
		["salmon", "salmon_start_mm_dd", "salmon_end_mm_dd", "salmon_interval_days"],
		["leaf", "leaf_start_mm_dd", "leaf_end_mm_dd", "leaf_interval_days"],
	]:
		if not _schedule_group_is_complete(merged_schedule, schedule_group.slice(1)):
			diagnostics.append(
				"%s row %d has an incomplete %s schedule after default merge." % [
					path,
					row_number,
					String(schedule_group[0]),
				]
			)
			valid = false

	var override: Dictionary = {
		"features": features,
		"schedule": schedule,
	}
	var notes := _csv_cell(row, header_indices, "notes")
	if not notes.is_empty():
		override["notes"] = notes
	return {"valid": valid, "override": override}


func _schedule_group_is_complete(schedule: Dictionary, fields: Array) -> bool:
	var present_count := 0
	for field_variant: Variant in fields:
		if not String(schedule.get(String(field_variant), "")).is_empty():
			present_count += 1
	return present_count == 0 or present_count == fields.size()


func _valid_river_profile_path(path: String, regime_id: String) -> bool:
	return (
		path.begins_with(RIVER_PROFILE_DIRECTORY)
		and path.ends_with(".txt")
		and not path.contains("..")
		and not path.contains("\\")
		and path.get_file().get_basename() == regime_id
	)


func _normalize_screen_id(value: String) -> String:
	return value.strip_edges().to_lower().replace("-", "_").replace(" ", "_")


func _profile_snapshot(profile: Dictionary) -> Dictionary:
	return {
		"regime_id": String(profile.get("regime_id", "")),
		"regime_name": String(profile.get("regime_name", "")),
		"profile_status": String(profile.get("profile_status", "")),
		"river_profile_path": String(profile.get("river_profile_path", "")),
		"defaults": {
			"features": Dictionary(profile.get("features", {})).duplicate(true),
			"schedule": Dictionary(profile.get("schedule", {})).duplicate(true),
		},
		"river_overrides": Dictionary(
			profile.get("river_overrides", {})
		).duplicate(true),
	}


func _merged_profile_for_screen(profile: Dictionary, screen_id: String) -> Dictionary:
	var features := Dictionary(profile.get("features", {})).duplicate(true)
	var schedule := Dictionary(profile.get("schedule", {})).duplicate(true)
	var river_overrides: Dictionary = profile.get("river_overrides", {})
	var override_variant: Variant = river_overrides.get(screen_id, {})
	if override_variant is Dictionary:
		var override: Dictionary = override_variant
		var feature_overrides: Dictionary = override.get("features", {})
		for feature_name: Variant in feature_overrides:
			features[feature_name] = feature_overrides[feature_name]
		var schedule_overrides: Dictionary = override.get("schedule", {})
		for schedule_name: Variant in schedule_overrides:
			schedule[schedule_name] = schedule_overrides[schedule_name]
	return {"features": features, "schedule": schedule}


func _recompute_effective_features() -> void:
	var next_effective: Dictionary = {}
	for feature_name: String in FEATURE_FIELDS:
		var total := 0.0
		var contributor_count := 0
		for regime_index in range(REGIME_IDS.size()):
			if _active[regime_index] == 0:
				continue
			var regime_id := REGIME_IDS[regime_index]
			if not _profiles_by_id.has(regime_id):
				continue
			var profile: Dictionary = _profiles_by_id[regime_id]
			var features_variant: Variant = profile.get("features", {})
			if not features_variant is Dictionary:
				continue
			var features: Dictionary = features_variant
			if not features.has(feature_name):
				continue
			total += float(features[feature_name])
			contributor_count += 1
		next_effective[feature_name] = (
			total / float(contributor_count) if contributor_count > 0 else 0.0
		)
	_effective_features = next_effective

	var next_feature_state_by_screen: Dictionary = {}
	var next_schedules_by_screen: Dictionary = {}
	for screen_id_name: StringName in CANONICAL_SCREEN_IDS:
		var screen_id := String(screen_id_name)
		var totals: Dictionary = {}
		var contributor_ids_by_feature: Dictionary = {}
		for feature_name: String in EFFECTIVE_FEATURE_FIELDS:
			totals[feature_name] = 0.0
			contributor_ids_by_feature[feature_name] = []

		var schedules_for_screen: Dictionary = {}
		for regime_index in range(REGIME_IDS.size()):
			if _active[regime_index] == 0:
				continue
			var regime_id := REGIME_IDS[regime_index]
			if not _profiles_by_id.has(regime_id):
				continue
			var profile: Dictionary = _profiles_by_id[regime_id]
			var merged := _merged_profile_for_screen(profile, screen_id)
			var merged_features: Dictionary = merged.get("features", {})
			for feature_name: String in EFFECTIVE_FEATURE_FIELDS:
				if not merged_features.has(feature_name):
					continue
				totals[feature_name] = (
					float(totals[feature_name]) + float(merged_features[feature_name])
				)
				var contributor_ids: Array = contributor_ids_by_feature[feature_name]
				contributor_ids.append(String(regime_id))
			var merged_schedule: Dictionary = merged.get("schedule", {})
			if not merged_schedule.is_empty():
				schedules_for_screen[String(regime_id)] = merged_schedule.duplicate(true)

		var feature_state: Dictionary = {}
		for feature_name: String in EFFECTIVE_FEATURE_FIELDS:
			var contributor_ids: Array = contributor_ids_by_feature[feature_name]
			var contributor_count := contributor_ids.size()
			feature_state[feature_name] = {
				"defined": contributor_count > 0,
				"value": (
					float(totals[feature_name]) / float(contributor_count)
					if contributor_count > 0
					else 0.0
				),
				"contributor_count": contributor_count,
				"contributor_ids": contributor_ids.duplicate(),
			}
		next_feature_state_by_screen[screen_id] = feature_state
		next_schedules_by_screen[screen_id] = schedules_for_screen

	_effective_feature_state_by_screen = next_feature_state_by_screen
	_active_schedules_by_screen = next_schedules_by_screen


func _index_for_name(value: String) -> int:
	var normalized := value.strip_edges().to_lower().replace("-", "_")
	normalized = normalized.replace(" ", "_")
	for index in range(REGIME_NAMES.size()):
		var normalized_name := REGIME_NAMES[index].to_lower().replace("-", "_")
		normalized_name = normalized_name.replace(" ", "_")
		if (
			normalized == String(REGIME_IDS[index])
			or normalized == normalized_name
		):
			return index
	return -1


func _valid_index(index: int) -> bool:
	return index >= 0 and index < REGIME_NAMES.size()


func _is_integral_number(value: Variant) -> bool:
	if value is int:
		return true
	if value is float:
		var number := float(value)
		return is_finite(number) and is_equal_approx(number, roundf(number))
	return false
