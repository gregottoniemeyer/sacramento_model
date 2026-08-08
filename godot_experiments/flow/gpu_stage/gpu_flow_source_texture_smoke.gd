extends Node

const SOURCE_SCRIPT := preload(
	"res://flow/gpu_stage/gpu_flow_source_polygon.gd"
)
const PACKER_SCRIPT := preload(
	"res://flow/gpu_stage/gpu_flow_source_texture_packer.gd"
)
const PARTICLE_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_particle.gdshader"
)
const EPSILON := 0.0001
const PIXELS_PER_WORLD_UNIT := 120.0


func _ready() -> void:
	var errors := PackedStringArray()
	_test_resource_contract(errors)
	_test_exact_texture_layout(errors)
	_test_weighted_shader_reference(errors)
	_test_horizontal_shader_contract(errors)
	_test_stable_ids_and_capacity(errors)
	if errors.is_empty():
		print("GPU_FLOW_SOURCE_TEXTURE_SMOKE: PASS")
		get_tree().quit(0)
		return
	for error: String in errors:
		push_error("GPU_FLOW_SOURCE_TEXTURE_SMOKE: %s" % error)
	get_tree().quit(1)


func _test_resource_contract(errors: PackedStringArray) -> void:
	var source: GPUFlowSourcePolygon = SOURCE_SCRIPT.new()
	_expect(source.flow_direction == Vector2.RIGHT, "default flow is not +X", errors)
	_expect(source.apply_dictionary({
		"id": "resource_contract",
		"vertices": [[0, 0], [2, 0], [2, 2], [0, 2]],
		"emission_fraction": 0.375,
		"flow_direction": {"x": 1, "y": 0},
		"seed": 42,
	}), "valid resource patch failed", errors)
	var canonical := source.to_dictionary()
	_expect(String(canonical.get("element_id", "")) == "resource_contract", "stable ID missing", errors)
	_expect(int(canonical.get("seed", -1)) == 42, "seed missing", errors)
	var baseline := canonical.duplicate(true)
	_expect(not source.apply_dictionary({"flow_direction": [0, 0]}), "zero direction accepted", errors)
	_expect(source.to_dictionary() == baseline, "invalid patch was not atomic", errors)
	var edges := GPUFlowSourcePolygon.selected_downstream_edges(
		source.vertices,
		source.flow_direction,
	)
	_expect(edges.size() == 1, "rectangle did not expose one downstream edge", errors)
	if edges.size() == 1:
		_expect_near(float(edges[0]["weight"]), 2.0, "world edge weight", errors)


func _test_exact_texture_layout(errors: PackedStringArray) -> void:
	var source := _make_source(
		"seeded_rectangle",
		[[1, 2], [3, 2], [3, 5], [1, 5]],
		0.25,
		Vector2.RIGHT,
		42,
		errors,
	)
	if source == null:
		return
	var packer: GPUFlowSourceTexturePacker = PACKER_SCRIPT.new()
	var count := packer.pack_sources([source])
	_expect(count == 1, "one source did not pack", errors)
	var texture := packer.get_texture()
	_expect(texture != null, "texture was not created", errors)
	if texture != null:
		_expect(texture.get_size() == Vector2(128, 1), "texture is not 128x1", errors)
	var image := packer.get_image()
	var metadata0 := image.get_pixel(0, 0)
	var metadata1 := image.get_pixel(1, 0)
	var bounds := image.get_pixel(2, 0)
	var identity := image.get_pixel(3, 0)
	_expect_near(metadata0.r, 4.0, "vertex_count texel", errors)
	_expect_near(metadata0.g, 0.25, "emission_fraction texel", errors)
	_expect_near(metadata0.b, 1.0, "enabled texel", errors)
	_expect_near(
		metadata0.a,
		GPUFlowSourcePolygon.seed_phase(42),
		"seed phase texel",
		errors,
	)
	_expect_vector(Vector2(metadata1.r, metadata1.g), Vector2.RIGHT, "native direction", errors)
	_expect_near(metadata1.b, -1.0, "native orientation", errors)
	_expect_near(metadata1.a, 360.0, "total projected edge weight", errors)
	_expect_color(
		bounds,
		Color(120.0, 480.0, 360.0, 840.0),
		"native bounds",
		errors,
	)
	_expect_vector(Vector2(identity.r, identity.g), Vector2(240, 660), "centroid", errors)
	_expect(identity.b >= 0.0 and identity.b < 1.0, "stable ID hash is not unit range", errors)
	_expect_near(identity.a, 1.0, "explicit seed flag", errors)

	var vertex0 := image.get_pixel(4, 0)
	var vertex1 := image.get_pixel(5, 0)
	_expect_color(vertex0, Color(120, 840, 0, 0), "vertex 0 record", errors)
	_expect_color(vertex1, Color(360, 840, 360, 360), "vertex 1 edge record", errors)
	_expect_color(image.get_pixel(15, 0), Color(0, 0, 0, 0), "unused vertex texel", errors)
	_expect_color(image.get_pixel(16, 0), Color(0, 0, 0, 0), "unused source record", errors)

	var edge_sample01 := 0.314159
	var horizontal_sample01 := 0.271828
	var world_sample := source.sample_emission_point(edge_sample01, 0.1)
	var phased_horizontal_sample := fposmod(
		horizontal_sample01 + GPUFlowSourcePolygon.seed_phase(42),
		1.0,
	)
	var expected_native := Vector2(
		lerpf(bounds.r, bounds.b, phased_horizontal_sample),
		1080.0 - world_sample.y * PIXELS_PER_WORLD_UNIT,
	)
	var packed_sample := packer.sample_packed_emission_point(
		0,
		edge_sample01,
		12.0,
		horizontal_sample01,
	)
	_expect_vector(
		packed_sample,
		expected_native,
		"packed seeded edge-Y/bounds-X sample",
		errors,
	)
	_expect(
		packed_sample.x >= bounds.r and packed_sample.x <= bounds.b,
		"seeded horizontal sample escaped packed X bounds",
		errors,
	)


func _test_weighted_shader_reference(errors: PackedStringArray) -> void:
	var irregular := _make_source(
		"irregular",
		[[0, 0], [3, 0], [4, 1], [3, 3], [0, 3]],
		1.0,
		Vector2.RIGHT,
		GPUFlowSourcePolygon.NO_SEED,
		errors,
	)
	if irregular == null:
		return
	var packer: GPUFlowSourceTexturePacker = PACKER_SCRIPT.new()
	_expect(packer.pack_sources([irregular]) == 1, "irregular source did not pack", errors)
	var image := packer.get_image()
	var edge1 := image.get_pixel(5, 0)
	var edge2 := image.get_pixel(6, 0)
	_expect_near(edge1.b, 120.0, "first projected edge weight", errors)
	_expect_near(edge1.a, 120.0, "first cumulative edge weight", errors)
	_expect_near(edge2.b, 240.0, "second projected edge weight", errors)
	_expect_near(edge2.a, 360.0, "second cumulative edge weight", errors)
	var edge_samples := [0.20, 0.50, 0.95]
	var horizontal_samples := [0.05, 0.50, 0.95]
	for sample_index in range(edge_samples.size()):
		var edge_sample01: float = edge_samples[sample_index]
		var horizontal_sample01: float = horizontal_samples[sample_index]
		var world_sample := irregular.sample_emission_point(edge_sample01)
		var expected_native := Vector2(
			lerpf(0.0, 4.0 * PIXELS_PER_WORLD_UNIT, horizontal_sample01),
			1080.0 - world_sample.y * PIXELS_PER_WORLD_UNIT,
		)
		_expect_vector(
			packer.sample_packed_emission_point(
				0,
				edge_sample01,
				0.0,
				horizontal_sample01,
			),
				expected_native,
				"weighted edge-Y/bounds-X shader-reference sample %.2f"
					% edge_sample01,
				errors,
			)
	var fixed_edge_left := packer.sample_packed_emission_point(0, 0.50, 0.0, 0.10)
	var fixed_edge_right := packer.sample_packed_emission_point(0, 0.50, 0.0, 0.90)
	_expect_near(
		fixed_edge_left.y,
		fixed_edge_right.y,
		"independent horizontal sample changed edge-derived Y",
		errors,
	)
	_expect_near(
		fixed_edge_left.x,
		48.0,
		"horizontal 0.10 sample did not use packed minimum/maximum X",
		errors,
	)
	_expect_near(
		fixed_edge_right.x,
		432.0,
		"horizontal 0.90 sample did not use packed minimum/maximum X",
		errors,
	)


func _test_horizontal_shader_contract(errors: PackedStringArray) -> void:
	var shader_code := PARTICLE_SHADER.code
	_expect(
		shader_code.contains("vec4 source_bounds = source_record(selected_source, 2)")
		and shader_code.contains("float horizontal_sample = hash11")
		and shader_code.contains("spawn_point.x = mix"),
		"water shader does not distribute source X across packed bounds",
		errors,
	)
	_expect(
		GPUFlowSourceTexturePacker.texture_layout().size() == 5,
		"source X distribution changed the fixed 16-texel packing contract",
		errors,
	)


func _test_stable_ids_and_capacity(errors: PackedStringArray) -> void:
	var first := _make_source(
		"stable_first", [[0, 0], [1, 0], [1, 1], [0, 1]],
		0.25, Vector2.RIGHT, GPUFlowSourcePolygon.NO_SEED, errors,
	)
	var duplicate := _make_source(
		"stable_first", [[2, 0], [3, 0], [3, 1], [2, 1]],
		0.25, Vector2.RIGHT, GPUFlowSourcePolygon.NO_SEED, errors,
	)
	var second := _make_source(
		"stable_second", [[4, 0], [5, 0], [5, 1], [4, 1]],
		0.50, Vector2.RIGHT, GPUFlowSourcePolygon.NO_SEED, errors,
	)
	if first == null or duplicate == null or second == null:
		return
	var packer: GPUFlowSourceTexturePacker = PACKER_SCRIPT.new()
	_expect(packer.pack_sources([first, duplicate, second]) == 2, "ID dedupe count", errors)
	_expect(packer.get_record_index(&"stable_first") == 0, "first stable index", errors)
	_expect(packer.get_record_index(&"stable_second") == 1, "second stable index", errors)
	var texture_rid := packer.get_texture().get_rid()
	first.enabled = false
	_expect(packer.pack_sources([first, duplicate, second]) == 2, "repack count", errors)
	_expect(packer.get_texture().get_rid() == texture_rid, "repack replaced texture RID", errors)
	_expect(packer.get_record_index(&"stable_second") == 1, "toggle shifted stable index", errors)
	_expect_near(packer.get_image().get_pixel(0, 0).b, 0.0, "disabled policy texel", errors)
	_expect(not packer.get_warnings().is_empty(), "duplicate ID produced no warning", errors)

	var capacity_sources: Array = []
	for index in range(9):
		var x := float(index) * 1.25
		var source := _make_source(
			"capacity_%d" % index,
			[[x, 0], [x + 1, 0], [x + 1, 1], [x, 1]],
			1.0,
			Vector2.RIGHT,
			GPUFlowSourcePolygon.NO_SEED,
			errors,
		)
		if source != null:
			capacity_sources.append(source)
	_expect(packer.pack_sources(capacity_sources) == 8, "capacity did not clamp to eight", errors)
	var summary := packer.runtime_summary()
	_expect(int(summary.get("ignored_capacity_count", 0)) == 1, "capacity overflow not reported", errors)
	_expect(int(summary.get("max_vertices", 0)) == 12, "max vertex contract", errors)
	_expect(int(summary.get("texels_per_source", 0)) == 16, "texel stride contract", errors)


func _make_source(
	element_id: String,
	vertices: Array,
	emission_fraction: float,
	flow_direction: Vector2,
	seed: int,
	errors: PackedStringArray,
) -> GPUFlowSourcePolygon:
	var source: GPUFlowSourcePolygon = SOURCE_SCRIPT.new()
	var applied := source.apply_dictionary({
		"element_id": element_id,
		"vertices": vertices,
		"emission_fraction": emission_fraction,
		"flow_direction": flow_direction,
		"seed": seed,
	})
	if not applied:
		errors.append("Failed to build source fixture %s." % element_id)
		return null
	return source


func _expect(condition: bool, message: String, errors: PackedStringArray) -> void:
	if not condition:
		errors.append(message)


func _expect_near(
	actual: float,
	expected: float,
	message: String,
	errors: PackedStringArray,
) -> void:
	if absf(actual - expected) > EPSILON:
		errors.append("%s (actual=%s expected=%s)" % [message, actual, expected])


func _expect_vector(
	actual: Vector2,
	expected: Vector2,
	message: String,
	errors: PackedStringArray,
) -> void:
	if actual.distance_to(expected) > EPSILON:
		errors.append("%s (actual=%s expected=%s)" % [message, actual, expected])


func _expect_color(
	actual: Color,
	expected: Color,
	message: String,
	errors: PackedStringArray,
) -> void:
	if (
		absf(actual.r - expected.r) > EPSILON
		or absf(actual.g - expected.g) > EPSILON
		or absf(actual.b - expected.b) > EPSILON
		or absf(actual.a - expected.a) > EPSILON
	):
		errors.append("%s (actual=%s expected=%s)" % [message, actual, expected])
