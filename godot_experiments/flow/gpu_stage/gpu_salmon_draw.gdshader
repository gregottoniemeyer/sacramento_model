shader_type canvas_item;
render_mode unshaded;

const float RIBBON_ENVELOPE_WIDTH_PIXELS = 8.0;

uniform float trail_lifetime_seconds = 0.50;
uniform float segment_sample_seconds = 0.0333333333;

varying float line_width_pixels;
varying float segment_age_seconds;


void vertex() {
	line_width_pixels = clamp(INSTANCE_CUSTOM.x, 1.0, 5.0);
	segment_age_seconds = max(INSTANCE_CUSTOM.y, 0.0);
}


void fragment() {
	float lateral_distance = (
		abs(UV.y - 0.5) * RIBBON_ENVELOPE_WIDTH_PIXELS
	);
	float signed_edge_distance = lateral_distance - line_width_pixels * 0.5;
	float antialias_width = max(fwidth(lateral_distance), 0.55);
	float edge_alpha = 1.0 - smoothstep(
		-antialias_width,
		antialias_width,
		signed_edge_distance
	);
	// UV.x runs from the older start to the newer end. Interpolating one sample
	// interval across every immutable quad makes adjacent segment endpoints share
	// one fade value instead of exposing a staircase of constant-alpha bands.
	float interpolated_age = (
		segment_age_seconds
		+ (1.0 - UV.x) * max(segment_sample_seconds, 0.0)
	);
	float linear_fade = 1.0 - clamp(
		interpolated_age / max(trail_lifetime_seconds, 0.001),
		0.0,
		1.0
	);
	COLOR = texture(TEXTURE, UV) * COLOR;
	COLOR.a *= edge_alpha * linear_fade;
}
