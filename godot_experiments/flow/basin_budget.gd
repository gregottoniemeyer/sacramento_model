class_name BasinBudget
extends RefCounted

## Pure, shared accounting for the installation's one-input/one-output model.
##
## Input is normalized atmospheric water arrival. Output is the fraction
## removed by active historical regimes. Remaining river water is
## input * (1 - output). Fractions are conceptual installation parameters,
## deliberately visible and testable rather than hidden in particle behavior.

const REGIME_EXTRACTION_FRACTIONS: Array[float] = [
	0.00, # Kinship: floodplain circulation, no modeled extraction.
	0.45, # Ranch: irrigated agriculture and field evapotranspiration.
	0.30, # Gold Rush: mining diversion, washing, and contamination loss.
	0.40, # Water Projects: storage and southward aqueduct export.
	0.15, # Hydropower: reservoir evaporation and cooling/operational loss.
	0.25, # Tech: explicit data-center cooling extraction.
	0.00, # Watershed: restorative monitoring, no additional extraction.
]

const REGIME_EXTRACTION_LABELS: Array[String] = [
	"Floodplain circulation",
	"Agriculture",
	"Gold mining",
	"DIVERT",
	"Reservoir + hydropower loss",
	"Data-center cooling",
	"Watershed restoration",
]

# Every field and data center is a true axis-aligned Rect2 in the model's
# 16 x 9 Y-up world. GPU interaction code receives the four derived corners;
# public budget geometry and drawing retain the simpler rectangle definition.
const EXTRACTOR_DEFINITIONS: Array[Dictionary] = [
	{
		"element_id": "agriculture_field_west",
		"label": "FIELD",
		"kind": "field",
		"regime_index": 1,
		# Bottom-bank field: the rectangle ends exactly at the screen edge.
		"rect_world": Rect2(3.5, 0.0, 2.25, 1.55),
		"absorption_fraction": 0.23,
	},
	{
		"element_id": "agriculture_field_east",
		"label": "FIELD",
		"kind": "field",
		"regime_index": 1,
		# Top-bank field: Y-up world coordinates end exactly at y=9.
		"rect_world": Rect2(6.75, 7.45, 2.55, 1.55),
		"absorption_fraction": 0.23,
	},
	{
		"element_id": "gold_mine",
		"label": "MINE",
		"kind": "mine",
		"regime_index": 2,
		"rect_world": Rect2(5.8, 7.50, 1.75, 1.50),
		"absorption_fraction": 0.30,
	},
	{
		"element_id": "water_project_export",
		"label": "DIVERT",
		"kind": "water_project",
		"regime_index": 3,
		"rect_world": Rect2(10.2, 0.0, 1.75, 1.40),
		"absorption_fraction": 0.40,
	},
	{
		"element_id": "data_center_north",
		"label": "DATA CENTER",
		"kind": "data_center",
		"regime_index": 5,
		"rect_world": Rect2(9.45, 7.60, 1.90, 1.40),
		"absorption_fraction": 0.13,
	},
	{
		"element_id": "data_center_east",
		"label": "DATA CENTER",
		"kind": "data_center",
		"regime_index": 5,
		"rect_world": Rect2(12.45, 0.0, 1.90, 1.45),
		"absorption_fraction": 0.13,
	},
]


static func extraction_breakdown(active_states: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(REGIME_EXTRACTION_FRACTIONS.size()):
		var active := index < active_states.size() and bool(active_states[index])
		var fraction := REGIME_EXTRACTION_FRACTIONS[index] if active else 0.0
		result.append({
			"regime_index": index,
			"label": REGIME_EXTRACTION_LABELS[index],
			"active": active,
			"fraction": fraction,
			"percent": fraction * 100.0,
		})
	return result


static func total_extraction_fraction(active_states: Array) -> float:
	var total := 0.0
	for item: Dictionary in extraction_breakdown(active_states):
		total += float(item["fraction"])
	return clampf(total, 0.0, 1.0)


static func remaining_water(input_rate: float, active_states: Array) -> float:
	return clampf(input_rate, 0.0, 1.0) * (
		1.0 - total_extraction_fraction(active_states)
	)


static func extractor_definitions() -> Array[Dictionary]:
	return EXTRACTOR_DEFINITIONS.duplicate(true)


static func rect_vertices(rectangle: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		rectangle.position,
		Vector2(rectangle.end.x, rectangle.position.y),
		rectangle.end,
		Vector2(rectangle.position.x, rectangle.end.y),
	])
