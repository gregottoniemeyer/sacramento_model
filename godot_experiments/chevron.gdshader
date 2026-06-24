shader_type canvas_item;

uniform vec2 rect_size_px = vec2(1080.0, 960.0);
uniform float stroke_width_px = 60.0;
uniform float peak_to_peak_px = 480.0;
uniform float chevron_amplitude_px = 240.0;
uniform float speed_px = 6.0;
uniform vec2 pattern_offset_px = vec2(0.0, 0.0);
uniform float animation_offset_px = 0.0;
uniform int mask_mode = 0;
uniform bool invert_mask = false;
uniform sampler2D mask_texture;

void fragment() {
	// Preserve the original UV coordinates for textures.
	vec2 original_uv = UV;

	// Generate the moving chevrons in local pixels so the pattern does not
	// stretch when the node width changes.
	vec2 px = original_uv * rect_size_px;
	px.x -= rect_size_px.x * 0.5;
	px += pattern_offset_px;
	px.y += animation_offset_px;

	float peak_distance_px = max(peak_to_peak_px, 1.0);
	float half_peak_distance_px = peak_distance_px * 0.5;
	float amplitude_px = max(chevron_amplitude_px, 0.0);
	float chevron_profile_px = abs(mod(px.x, peak_distance_px) - half_peak_distance_px) / half_peak_distance_px * amplitude_px;
	float chevron_phase_px = px.y - chevron_profile_px;
	float chevron_slope = amplitude_px / half_peak_distance_px;
	float distance_to_chevron_px = chevron_phase_px / sqrt(1.0 + chevron_slope * chevron_slope);
	float stripe_index = floor(distance_to_chevron_px / max(stroke_width_px, 1.0));
	float chevron = 1.0 - mod(stripe_index, 2.0);

	// Read the sprite's original alpha and the mask.
	vec4 sprite_color = texture(TEXTURE, original_uv);
	vec2 mask_uv = vec2(UV.y, 0.5);
	if (mask_mode == 1) {
		mask_uv = original_uv;
	} else if (mask_mode == 2) {
		mask_uv = vec2(1.0 - original_uv.y, original_uv.x);
	}
	vec4 mask_color = texture(mask_texture, mask_uv);
	float mask_value = mask_color.a * dot(mask_color.rgb, vec3(0.299, 0.587, 0.114));
	if (invert_mask) {
		mask_value = 1.0 - mask_value;
	}

	// Alternating black/white chevrons with masked sprite alpha.
	float final_alpha = sprite_color.a * mask_value;
	COLOR = vec4(vec3(chevron), final_alpha);
}
