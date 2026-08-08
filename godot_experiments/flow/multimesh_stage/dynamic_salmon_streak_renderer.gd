extends Node2D
class_name DynamicSalmonStreakRenderer

## One dynamic MultiMesh instance per possible salmon, never one Node per fish.

const STREAK_SHADER := preload(
	"res://flow/multimesh_stage/dynamic_salmon_streak.gdshader"
)

const CAPACITY := 300
const QUAD_ENVELOPE_HEIGHT_PIXELS := 8.0
const QUAD_LONGITUDINAL_MARGIN_PIXELS := 4.0
const MIN_DIRECTION_LENGTH := 0.0001

@export_range(-4096, 4096, 1) var z_index_absolute: int = 20:
	set(value):
		z_index_absolute = clampi(value, -4096, 4096)
		_apply_z_index()
@export var renderer_modulate: Color = Color.WHITE:
	set(value):
		renderer_modulate = value
		_apply_modulate()
@export var fixed_visibility_rect := Rect2(
	Vector2(-256.0, -256.0),
	Vector2(2432.0, 1592.0)
):
	set(value):
		fixed_visibility_rect = value
		_apply_fixed_visibility_bounds()

var _instance: MultiMeshInstance2D
var _multimesh: MultiMesh
var _material: ShaderMaterial
var _white_texture: ImageTexture
var _visible_slots := PackedByteArray()
var _update_serial: int = 0


func _ready() -> void:
	_build_renderer()


func set_streak(
	slot: int,
	head_position: Vector2,
	travel_direction: Vector2,
	length_pixels: float,
	width_pixels: float,
	color: Color,
	alpha: float
) -> bool:
	if slot < 0 or slot >= CAPACITY or _multimesh == null:
		return false
	var normalized_direction := travel_direction.normalized()
	if travel_direction.length_squared() <= MIN_DIRECTION_LENGTH * MIN_DIRECTION_LENGTH:
		normalized_direction = Vector2.LEFT
	var streak_length := maxf(length_pixels, 0.001)
	var tail_position := head_position - normalized_direction * streak_length
	var center := (tail_position + head_position) * 0.5
	var normal := Vector2(-normalized_direction.y, normalized_direction.x)
	var quad_length := streak_length + QUAD_LONGITUDINAL_MARGIN_PIXELS * 2.0
	var segment_transform := Transform2D(
		normalized_direction * quad_length,
		normal * QUAD_ENVELOPE_HEIGHT_PIXELS,
		center
	)
	var display_color := color
	display_color.a *= clampf(alpha, 0.0, 1.0)
	_multimesh.set_instance_transform_2d(slot, segment_transform)
	_multimesh.set_instance_color(slot, display_color)
	_multimesh.set_instance_custom_data(
		slot,
		Color(clampf(width_pixels, 1.0, 5.0), streak_length, 0.0, 1.0)
	)
	_visible_slots[slot] = 1
	_update_serial += 1
	return true


func hide_streak(slot: int) -> void:
	if slot < 0 or slot >= CAPACITY or _multimesh == null:
		return
	if _visible_slots[slot] == 0:
		return
	_multimesh.set_instance_custom_data(slot, Color(0.0, 0.0, 0.0, 0.0))
	_visible_slots[slot] = 0
	_update_serial += 1


func reset() -> void:
	if _multimesh == null:
		return
	for slot in range(CAPACITY):
		if _visible_slots[slot] != 0:
			_multimesh.set_instance_custom_data(
				slot,
				Color(0.0, 0.0, 0.0, 0.0)
			)
	_visible_slots.fill(0)
	_update_serial = 0


func runtime_summary() -> Dictionary:
	var visible_count: int = 0
	for value: int in _visible_slots:
		visible_count += int(value != 0)
	return {
		"backend": "dynamic_salmon_multimesh",
		"capacity": CAPACITY,
		"instance_count": _multimesh.instance_count if _multimesh != null else 0,
		"visible_streak_count": visible_count,
		"update_serial": _update_serial,
		"z_index": _instance.z_index if _instance != null else z_index_absolute,
		"per_fish_nodes": 0,
		"buffer_readback": false,
	}


func _build_renderer() -> void:
	_visible_slots.resize(CAPACITY)
	_visible_slots.fill(0)
	_material = ShaderMaterial.new()
	_material.shader = STREAK_SHADER
	_white_texture = _make_white_texture()

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = quad
	_multimesh.instance_count = CAPACITY
	_multimesh.visible_instance_count = -1

	_instance = MultiMeshInstance2D.new()
	_instance.name = "SalmonStreaks"
	_instance.multimesh = _multimesh
	_instance.texture = _white_texture
	_instance.material = _material
	add_child(_instance)
	_apply_z_index()
	_apply_modulate()
	_apply_fixed_visibility_bounds()


func _apply_z_index() -> void:
	if _instance == null:
		return
	_instance.z_index = z_index_absolute
	_instance.z_as_relative = false


func _apply_modulate() -> void:
	if _instance != null:
		_instance.modulate = renderer_modulate


func _apply_fixed_visibility_bounds() -> void:
	if _multimesh == null:
		return
	_multimesh.custom_aabb = AABB(
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


func _make_white_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)
