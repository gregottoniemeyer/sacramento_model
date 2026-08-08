shader_type canvas_item;
render_mode unshaded;

const float LONGITUDINAL_MARGIN_PIXELS = 4.0;
const float QUAD_ENVELOPE_HEIGHT_PIXELS = 8.0;

varying float instance_line_width;
varying float instance_streak_length;
varying float instance_active;


void vertex() {
	instance_line_width = clamp(INSTANCE_CUSTOM.x, 1.0, 5.0);
	instance_streak_length = max(INSTANCE_CUSTOM.y, 0.0);
	instance_active = INSTANCE_CUSTOM.w;
}


void fragment() {
	if (instance_active < 0.5 || instance_streak_length <= 0.0001) {
		discard;
	}

	float quad_length = (
		instance_streak_length + LONGITUDINAL_MARGIN_PIXELS * 2.0
	);
	float longitudinal = (UV.x - 0.5) * quad_length;
	float lateral = abs(UV.y - 0.5) * QUAD_ENVELOPE_HEIGHT_PIXELS;
	float beyond_endpoint = max(
		abs(longitudinal) - instance_streak_length * 0.5,
		0.0
	);
	float capsule_distance = length(vec2(beyond_endpoint, lateral));
	float radius = instance_line_width * 0.5;
	float antialias_width = max(fwidth(capsule_distance), 0.55);
	float coverage = 1.0 - smoothstep(
		radius - antialias_width,
		radius + antialias_width,
		capsule_distance
	);
	COLOR.a *= coverage;
}
