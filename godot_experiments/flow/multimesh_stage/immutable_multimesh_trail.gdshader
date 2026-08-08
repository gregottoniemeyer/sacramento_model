shader_type canvas_item;
render_mode unshaded;

// Every instance is one immutable quad spanning two consecutive completed
// head positions. Geometry never changes after append; only this shared clock
// advances its alpha. Neighboring instances meet with flat anti-aliased ends
// and a subpixel overhang. Full round caps would overlap at every recorded
// point and create a brighter bead through ordinary alpha compositing.
const float LONGITUDINAL_MARGIN_PIXELS = 1.0;
const float JOIN_OVERHANG_PIXELS = 0.25;

uniform float simulation_time_seconds = 0.0;
uniform float trail_lifetime_seconds = 2.0;
uniform float fade_start_ratio = 0.62;

varying float instance_line_width;
varying float instance_birth_time;
varying float instance_segment_length;
varying float instance_active;


void vertex() {
	instance_line_width = clamp(INSTANCE_CUSTOM.x, 1.0, 5.0);
	instance_birth_time = INSTANCE_CUSTOM.y;
	instance_segment_length = max(INSTANCE_CUSTOM.z, 0.0);
	instance_active = INSTANCE_CUSTOM.w;
}


void fragment() {
	float lifetime = max(trail_lifetime_seconds, 0.001);
	float age = simulation_time_seconds - instance_birth_time;
	if (
		instance_active < 0.5
		|| instance_segment_length <= 0.0001
		|| age < 0.0
		|| age >= lifetime
	) {
		discard;
	}

	float quad_length = (
		instance_segment_length + LONGITUDINAL_MARGIN_PIXELS * 2.0
	);
	float longitudinal = (UV.x - 0.5) * quad_length;
	float lateral = abs(UV.y - 0.5) * 8.0;
	float radius = instance_line_width * 0.5;
	float lateral_aa = max(fwidth(lateral), 0.55);
	float lateral_coverage = 1.0 - smoothstep(
		radius - lateral_aa,
		radius + lateral_aa,
		lateral
	);
	float half_length = (
		instance_segment_length * 0.5 + JOIN_OVERHANG_PIXELS
	);
	float longitudinal_distance = abs(longitudinal);
	float longitudinal_aa = max(fwidth(longitudinal_distance), 0.55);
	float longitudinal_coverage = 1.0 - smoothstep(
		half_length - longitudinal_aa,
		half_length + longitudinal_aa,
		longitudinal_distance
	);
	float coverage = min(lateral_coverage, longitudinal_coverage);

	float fade_start = clamp(fade_start_ratio, 0.0, 0.999) * lifetime;
	float age_alpha = 1.0 - smoothstep(fade_start, lifetime, age);
	COLOR.a *= coverage * age_alpha;
}
