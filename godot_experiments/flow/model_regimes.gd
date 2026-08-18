extends Node
## Process-persistent authority for the seven historical water regimes.
##
## The active set survives current-scene replacement and is intentionally
## independent of river identity. Keyboard testing and future controller code
## both mutate this one shared state so several regimes may be active at once.

signal regimes_changed(state: Dictionary)

const PROFILE_TEXT_PATH := "res://regime_feature_profiles.txt"
const PROFILE_SCHEMA_VERSION := "1"
const FEATURE_FIELDS: Array[String] = [
	"reservoir_area_fraction",
	"drain_area_fraction",
	"obstacle_area_fraction",
	"source_area_fraction",
	"shoreline_randomness",
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

var _active := PackedByteArray([0, 0, 0, 0, 0, 0, 0])
var _revision: int = 0
var _profiles_by_id: Dictionary = {}
var _profile_diagnostics: Array[String] = []
var _profiles_loaded: bool = false
var _profile_reload_revision: int = 0
var _effective_features: Dictionary = {
	"reservoir_area_fraction": 0.0,
	"drain_area_fraction": 0.0,
	"obstacle_area_fraction": 0.0,
	"source_area_fraction": 0.0,
	"shoreline_randomness": 0.0,
}


func _ready() -> void:
	reload_profiles(false)


func regime_count() -> int:
	return REGIME_NAMES.size()


func reload_profiles(publish_snapshot: bool = true) -> bool:
	## Reload the author-edited CSV without treating incomplete draft cells as zero.
	var loaded := _load_profiles_from_text()
	_recompute_effective_features()
	if publish_snapshot:
		_publish_change()
	return loaded


func toggle_regime(index: int) -> bool:
	if not _valid_index(index):
		return false
	_active[index] = 0 if _active[index] != 0 else 1
	_publish_change()
	return true


func set_regime_active(index: int, active: bool) -> bool:
	if not _valid_index(index):
		return false
	var next_value := 1 if active else 0
	if _active[index] == next_value:
		return true
	_active[index] = next_value
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
	for index in range(REGIME_NAMES.size()):
		var active := _active[index] != 0
		active_states.append(active)
		if active:
			active_indices.append(index)
			active_names.append(REGIME_NAMES[index])
			active_ids.append(REGIME_IDS[index])
	return {
		"regime_names": REGIME_NAMES.duplicate(),
		"regime_ids": REGIME_IDS.duplicate(),
		"active_states": active_states,
		"active_indices": active_indices,
		"active_names": active_names,
		"active_ids": active_ids,
		"active_count": active_indices.size(),
		"revision": _revision,
		"scope": "GODOT_PROCESS",
		"profile_path": PROFILE_TEXT_PATH,
		"profiles_loaded": _profiles_loaded,
		"profile_count": _profiles_by_id.size(),
		"profile_reload_revision": _profile_reload_revision,
		"profile_diagnostics": _profile_diagnostics.duplicate(),
		"effective_features": _effective_features.duplicate(true),
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
	if not header_indices.has("regime_id"):
		next_diagnostics.append("Profile header is missing required column: regime_id")
		_commit_loaded_profiles(next_profiles, next_diagnostics, false)
		return false
	for feature_name: String in FEATURE_FIELDS:
		if not header_indices.has(feature_name):
			next_diagnostics.append(
				"Profile header is missing feature column: %s" % feature_name
			)

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
			continue
		if REGIME_IDS.find(regime_id) < 0:
			next_diagnostics.append(
				"Row %d has unknown regime_id '%s'; row ignored." % [
					row_number,
					raw_regime_id,
				]
			)
			continue
		if next_profiles.has(regime_id):
			next_diagnostics.append(
				"Row %d repeats regime_id '%s'; row ignored." % [
					row_number,
					normalized_id,
				]
			)
			continue

		var schema_version := _csv_cell(
			row,
			header_indices,
			"schema_version"
		)
		if schema_version != "" and schema_version != PROFILE_SCHEMA_VERSION:
			next_diagnostics.append(
				"Row %d uses unsupported schema_version '%s'." % [
					row_number,
					schema_version,
				]
			)

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
				continue
			feature_values[feature_name] = float(parsed_value)

		next_profiles[regime_id] = {
			"regime_id": normalized_id,
			"regime_name": _csv_cell(row, header_indices, "regime_name"),
			# Status remains available for diagnostics and authoring, but never gates
			# valid values. Several intentionally evolving rows are `not_defined`.
			"profile_status": _csv_cell(row, header_indices, "profile_status"),
			"features": feature_values,
		}

	var loaded := not next_profiles.is_empty()
	if not loaded:
		next_diagnostics.append("Profile table contains no usable regime profiles.")
	_commit_loaded_profiles(next_profiles, next_diagnostics, loaded)
	return loaded


func _commit_loaded_profiles(
	next_profiles: Dictionary,
	next_diagnostics: Array[String],
	loaded: bool
) -> void:
	_profiles_by_id = next_profiles
	_profile_diagnostics = next_diagnostics
	_profiles_loaded = loaded
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
