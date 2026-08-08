extends Node2D
class_name ImmutableMultiMeshTrailRenderer

## Seven-layer immutable trail renderer backed by fixed circular MultiMeshes.
##
## The caller owns all simulation and collision state. Call append_segment()
## once for each completed head step. Existing segment transforms are never
## modified; the shared simulation clock drives their alpha in the canvas
## shader. Pausing freezes that clock, so visible tails do not expire while the
## model is paused.

const TRAIL_SHADER := preload(
	"res://flow/multimesh_stage/immutable_multimesh_trail.gdshader"
)

const PALETTE_LAYER_COUNT := 7
const QUAD_ENVELOPE_HEIGHT_PIXELS := 8.0
const QUAD_LONGITUDINAL_MARGIN_PIXELS := 1.0
const MIN_SEGMENT_LENGTH_PIXELS := 0.0001

const WATER_PALETTE: Array[Color] = [
	Color("ffffff"),
	Color("eaf7ee"),
	Color("d3efdc"),
	Color("ace1af"),
	Color("7bcfc4"),
	Color("4ab0e1"),
	Color("1e90ff"),
]

@export_group("Capacity")
## Exact aggregate allocation across the seven fixed palette layers. Each
## layer owns an independent circular share; the first remainder layers receive
## one extra slot so their sum is exactly this value.
@export_range(7, 200000, 1) var total_segment_capacity: int = 22500:
	set(value):
		total_segment_capacity = maxi(value, PALETTE_LAYER_COUNT)
		if is_node_ready():
			_rebuild_layers()

@export_group("Appearance")
@export_range(0.05, 8.0, 0.05) var trail_lifetime_seconds: float = 2.0:
	set(value):
		trail_lifetime_seconds = clampf(value, 0.05, 8.0)
		_apply_material_parameters()
@export_range(0.0, 0.99, 0.01) var fade_start_ratio: float = 0.62:
	set(value):
		fade_start_ratio = clampf(value, 0.0, 0.99)
		_apply_material_parameters()
@export var renderer_modulate: Color = Color.WHITE:
	set(value):
		renderer_modulate = value
		_apply_renderer_modulate()
## Absolute Z of palette layer zero. Later layers draw at base_z_index + index.
## A second renderer can therefore reuse this class for salmon or leaves above
## every water layer without creating per-segment nodes.
@export_range(-4096, 4090, 1) var base_z_index: int = 0:
	set(value):
		base_z_index = clampi(value, -4096, 4090)
		_apply_z_indices()

@export_group("Clock")
## Disable this when an external fixed-step model calls advance_simulation().
@export var auto_advance_time: bool = true
@export var start_paused: bool = false

@export_group("Culling")
## A fixed AABB avoids rebuilding aggregate bounds as circular slots change.
## The default contains one 1920 x 1080 stage plus a generous exit margin.
@export var fixed_visibility_rect := Rect2(
	Vector2(-256.0, -256.0),
	Vector2(2432.0, 1592.0)
):
	set(value):
		fixed_visibility_rect = value
		_apply_fixed_visibility_bounds()

var _layers: Array[MultiMeshInstance2D] = []
var _layer_capacities := PackedInt32Array()
var _layer_write_indices := PackedInt32Array()
var _layer_counts := PackedInt32Array()
var _material: ShaderMaterial
var _white_texture: ImageTexture
var _simulation_time_seconds: float = 0.0
var _paused: bool = false
var _append_serial: int = 0


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = TRAIL_SHADER
	_white_texture = _make_white_texture()
	_paused = start_paused
	_rebuild_layers()
	_apply_material_parameters()
	_apply_renderer_modulate()


func _process(delta: float) -> void:
	if auto_advance_time:
		advance_simulation(delta)


func configure(capacity_per_layer: int, lifetime: float) -> void:
	## Configure seven equal fixed circular buffers. Reconfiguration intentionally
	## clears existing geometry because MultiMesh instance counts are immutable
	## once their buffers are allocated.
	total_segment_capacity = (
		maxi(capacity_per_layer, 1) * PALETTE_LAYER_COUNT
	)
	trail_lifetime_seconds = clampf(lifetime, 0.05, 8.0)


func append_segment(
	old_position: Vector2,
	new_position: Vector2,
	width_pixels: float,
	palette_index: int,
	alpha: float = 1.0
) -> int:
	## Append one segment using a stable water palette layer and the current
	## simulation time. This is the normal model-facing API.
	if palette_index < 0 or palette_index >= PALETTE_LAYER_COUNT:
		return -1
	var color := WATER_PALETTE[palette_index]
	color.a = clampf(alpha, 0.0, 1.0)
	return append_colored_segment(
		old_position,
		new_position,
		width_pixels,
		color,
		palette_index,
		_simulation_time_seconds
	)


func append_colored_segment(
	old_position: Vector2,
	new_position: Vector2,
	width_pixels: float,
	color: Color,
	layer_index: int,
	birth_time_seconds: float = -1.0
) -> int:
	## Lower-level append for custom color and explicit birth time. Returns its
	## layer-local circular slot.
	## Returns -1 for an invalid layer, an unbuilt renderer, or a zero-length step.
	if layer_index < 0 or layer_index >= PALETTE_LAYER_COUNT:
		return -1
	if _layers.size() != PALETTE_LAYER_COUNT:
		return -1
	var segment_delta := new_position - old_position
	var segment_length := segment_delta.length()
	if segment_length <= MIN_SEGMENT_LENGTH_PIXELS:
		return -1

	var capacity: int = _layer_capacities[layer_index]
	if capacity <= 0:
		return -1
	var slot: int = _layer_write_indices[layer_index]
	var direction := segment_delta / segment_length
	var normal := Vector2(-direction.y, direction.x)
	var quad_length := (
		segment_length + QUAD_LONGITUDINAL_MARGIN_PIXELS * 2.0
	)
	var segment_transform := Transform2D(
		direction * quad_length,
		normal * QUAD_ENVELOPE_HEIGHT_PIXELS,
		(old_position + new_position) * 0.5
	)
	var birth_time := (
		_simulation_time_seconds
		if birth_time_seconds < 0.0
		else birth_time_seconds
	)
	var multimesh: MultiMesh = _layers[layer_index].multimesh
	multimesh.set_instance_transform_2d(slot, segment_transform)
	multimesh.set_instance_color(slot, color)
	multimesh.set_instance_custom_data(
		slot,
		Color(
			clampf(width_pixels, 1.0, 5.0),
			birth_time,
			segment_length,
			1.0
		)
	)

	_layer_write_indices[layer_index] = (slot + 1) % capacity
	_layer_counts[layer_index] = mini(
		_layer_counts[layer_index] + 1,
		capacity
	)
	_append_serial += 1
	return slot


func append_palette_segment(
	old_position: Vector2,
	new_position: Vector2,
	width_pixels: float,
	layer_index: int,
	birth_time_seconds: float = -1.0,
	alpha: float = 1.0
) -> int:
	## Compatibility wrapper for callers that need an explicit birth time.
	if birth_time_seconds < 0.0:
		return append_segment(
			old_position,
			new_position,
			width_pixels,
			layer_index,
			alpha
		)
	if layer_index < 0 or layer_index >= PALETTE_LAYER_COUNT:
		return -1
	var color := WATER_PALETTE[layer_index]
	color.a = clampf(alpha, 0.0, 1.0)
	return append_colored_segment(
		old_position,
		new_position,
		width_pixels,
		color,
		layer_index,
		birth_time_seconds
	)


func advance_simulation(delta_seconds: float) -> void:
	## Advance the renderer clock only while running. Use the same delta as the
	## authoritative head model so pauses and fixed-step catch-up remain coherent.
	if _paused or delta_seconds <= 0.0:
		return
	set_simulation_time(_simulation_time_seconds + delta_seconds)


func advance_time(delta_seconds: float) -> void:
	## Public integration alias requested by the model-facing API.
	advance_simulation(delta_seconds)


func set_simulation_time(value: float) -> void:
	_simulation_time_seconds = maxf(value, 0.0)
	if _material != null:
		_material.set_shader_parameter(
			&"simulation_time_seconds",
			_simulation_time_seconds
		)


func get_simulation_time() -> float:
	return _simulation_time_seconds


func set_paused(value: bool) -> void:
	_paused = value


func is_paused() -> bool:
	return _paused


func clear() -> void:
	## Hide every written slot without reallocating any MultiMesh buffer.
	for layer_index in range(_layers.size()):
		var multimesh: MultiMesh = _layers[layer_index].multimesh
		var written_count: int = _layer_counts[layer_index]
		for slot in range(written_count):
			multimesh.set_instance_custom_data(slot, Color(0.0, 0.0, 0.0, 0.0))
		_layer_write_indices[layer_index] = 0
		_layer_counts[layer_index] = 0
	_append_serial = 0


func reset() -> void:
	## Clear all rings and restart the pause-safe simulation clock.
	clear()
	set_simulation_time(0.0)


func get_layer_capacity(layer_index: int) -> int:
	if layer_index < 0 or layer_index >= _layer_capacities.size():
		return 0
	return _layer_capacities[layer_index]


func get_layer_count(layer_index: int) -> int:
	if layer_index < 0 or layer_index >= _layer_counts.size():
		return 0
	return _layer_counts[layer_index]


func runtime_summary() -> Dictionary:
	var layer_z_indices: Array[int] = []
	for layer: MultiMeshInstance2D in _layers:
		layer_z_indices.append(layer.z_index)
	return {
		"backend": "immutable_multimesh_segments",
		"layer_count": _layers.size(),
		"layer_capacities": Array(_layer_capacities),
		"layer_counts": Array(_layer_counts),
		"layer_write_indices": Array(_layer_write_indices),
		"total_segment_capacity": total_segment_capacity,
		"capacity_per_layer": (
			_layer_capacities[0] if not _layer_capacities.is_empty() else 0
		),
		"append_serial": _append_serial,
		"trail_lifetime_seconds": trail_lifetime_seconds,
		"fade_start_ratio": fade_start_ratio,
		"base_z_index": base_z_index,
		"layer_z_indices": layer_z_indices,
		"simulation_time_seconds": _simulation_time_seconds,
		"paused": _paused,
		"auto_advance_time": auto_advance_time,
		"per_segment_nodes": 0,
		"buffer_readback": false,
	}


func _rebuild_layers() -> void:
	for layer: MultiMeshInstance2D in _layers:
		if is_instance_valid(layer):
			remove_child(layer)
			layer.queue_free()
	_layers.clear()
	_layer_capacities.resize(PALETTE_LAYER_COUNT)
	_layer_write_indices.resize(PALETTE_LAYER_COUNT)
	_layer_counts.resize(PALETTE_LAYER_COUNT)
	_layer_write_indices.fill(0)
	_layer_counts.fill(0)

	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = TRAIL_SHADER
	if _white_texture == null:
		_white_texture = _make_white_texture()

	var base_capacity := total_segment_capacity / PALETTE_LAYER_COUNT
	var remainder := total_segment_capacity % PALETTE_LAYER_COUNT
	for layer_index in range(PALETTE_LAYER_COUNT):
		var layer_capacity := base_capacity + (1 if layer_index < remainder else 0)
		_layer_capacities[layer_index] = layer_capacity
		var layer := MultiMeshInstance2D.new()
		layer.name = "WaterTrailLayer%d" % (layer_index + 1)
		layer.z_index = base_z_index + layer_index
		layer.z_as_relative = false
		layer.material = _material
		layer.texture = _white_texture

		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_2D
		multimesh.use_colors = true
		multimesh.use_custom_data = true
		multimesh.mesh = quad
		multimesh.instance_count = layer_capacity
		multimesh.visible_instance_count = -1
		layer.multimesh = multimesh
		add_child(layer)
		_layers.append(layer)

	_apply_fixed_visibility_bounds()
	_apply_material_parameters()
	_apply_renderer_modulate()
	_apply_z_indices()


func _apply_material_parameters() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(
		&"simulation_time_seconds",
		_simulation_time_seconds
	)
	_material.set_shader_parameter(
		&"trail_lifetime_seconds",
		trail_lifetime_seconds
	)
	_material.set_shader_parameter(&"fade_start_ratio", fade_start_ratio)


func _apply_renderer_modulate() -> void:
	for layer: MultiMeshInstance2D in _layers:
		layer.modulate = renderer_modulate


func _apply_z_indices() -> void:
	for layer_index in range(_layers.size()):
		var layer: MultiMeshInstance2D = _layers[layer_index]
		layer.z_index = base_z_index + layer_index
		layer.z_as_relative = false


func _apply_fixed_visibility_bounds() -> void:
	var bounds := AABB(
		Vector3(
			fixed_visibility_rect.position.x,
			fixed_visibility_rect.position.y,
			-1.0
		),
		Vector3(
			fixed_visibility_rect.size.x,
			fixed_visibility_rect.size.y,
			2.0
		)
	)
	for layer: MultiMeshInstance2D in _layers:
		if layer.multimesh != null:
			layer.multimesh.custom_aabb = bounds


func _make_white_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)
