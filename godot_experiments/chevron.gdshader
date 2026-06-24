shader_type canvas_item;

uniform vec2 rect_size_px = vec2(1080.0, 960.0);
uniform float chevron_height_px = 240.0;
uniform float stroke_width_px = 60.0;
uniform float speed_px = 6.0;
uniform vec2 pattern_offset_px = vec2(0.0, 0.0);
uniform float custom_time = 0.0;
uniform sampler2D mask_texture;

void fragment() {
	// Preserve the original UV coordinates for textures.
	vec2 original_uv = UV;

	// Generate the moving chevrons in local pixels so the pattern does not
	// stretch when the node width changes.
	vec2 px = original_uv * rect_size_px;
	px.x -= rect_size_px.x * 0.5;
	px += pattern_offset_px;
	px.y += custom_time * speed_px;

	float height_px = max(chevron_height_px, 1.0);
	float period_x_px = height_px * 2.0;
	float x = abs(mod(px.x, period_x_px) - height_px);
	float y = mod(px.y, height_px);
	float distance_to_row = abs(x - y);
	distance_to_row = min(distance_to_row, abs(x - (y - height_px)));
	distance_to_row = min(distance_to_row, abs(x - (y + height_px)));
	float distance_to_line = distance_to_row * 0.70710678;
	float chevron = step(distance_to_line, stroke_width_px * 0.5);

	// Read the sprite's original alpha and the mask.
	vec4 sprite_color = texture(TEXTURE, original_uv);
	float mask_value = texture(mask_texture, vec2(UV.y, 0.5)).r;

	// Chevron RGB with masked sprite alpha.
	float final_alpha = sprite_color.a * mask_value;
	COLOR = vec4(vec3(chevron), final_alpha);
}
