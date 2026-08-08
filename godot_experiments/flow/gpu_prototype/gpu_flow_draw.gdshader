shader_type canvas_item;
render_mode unshaded;

const float RIBBON_ENVELOPE_WIDTH_PX = 8.0;
const float SEGMENT_SAMPLE_SECONDS = 1.0 / 30.0;

uniform float trail_lifetime_seconds = 2.0;

varying float line_core_width;
varying float segment_age_seconds;

// Every particle is one immutable head-to-head segment. Width remains coverage
// inside a fixed eight-pixel envelope, while CUSTOM.y is that segment's age.
void vertex() {
	line_core_width = clamp(INSTANCE_CUSTOM.x, 1.0, 5.0);
	segment_age_seconds = max(INSTANCE_CUSTOM.y, 0.0);
}

void fragment() {
	float distance_from_center_px = abs(UV.y - 0.5) * RIBBON_ENVELOPE_WIDTH_PX;
	float signed_edge_distance_px = distance_from_center_px - line_core_width * 0.5;
	float edge_alpha = 1.0 - smoothstep(-0.5, 0.5, signed_edge_distance_px);
	// UV.x runs from the older recorded start to the newer recorded end. Add
	// one sample interval across the quad so adjacent segments share exactly
	// the same fade value at their common endpoint instead of forming bands.
	float interpolated_age = (
		segment_age_seconds + (1.0 - UV.x) * SEGMENT_SAMPLE_SECONDS
	);
	float age_ratio = clamp(
		interpolated_age / max(trail_lifetime_seconds, 0.01),
		0.0,
		1.0
	);
	// Preserve the existing soft fade only at the oldest end of the tail.
	float tail_alpha = 1.0 - smoothstep(0.62, 1.0, age_ratio);
	COLOR = texture(TEXTURE, UV) * COLOR;
	COLOR.a *= edge_alpha * tail_alpha;
}
