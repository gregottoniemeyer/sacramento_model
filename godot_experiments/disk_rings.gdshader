shader_type canvas_item;

uniform vec2 rect_size_px = vec2(720.0, 720.0);
uniform float ring_width_px = 48.0;
uniform vec4 black_ring_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 white_ring_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float animation_speed_px = 80.0;
uniform bool animate_inner_to_outer = true;
uniform float animation_offset_px = 0.0;
uniform float antialias_px = 1.25;

void fragment() {
	vec2 size_px = max(rect_size_px, vec2(1.0, 1.0));
	vec2 center_px = size_px * 0.5;
	vec2 local_px = UV * size_px;
	float disk_radius_px = min(size_px.x, size_px.y) * 0.5;
	float radius_px = distance(local_px, center_px);
	float edge_aa_px = max(fwidth(radius_px) * antialias_px, 0.001);
	float disk_alpha = 1.0 - smoothstep(disk_radius_px - edge_aa_px, disk_radius_px + edge_aa_px, radius_px);

	float width_px = max(ring_width_px, 1.0);
	float travel_px = animation_offset_px;
	float distance_behind_front_px = animate_inner_to_outer ? radius_px - travel_px : radius_px + travel_px;

	float ring_phase = mod(distance_behind_front_px, width_px * 2.0);
	float ring_aa_px = max(fwidth(distance_behind_front_px) * antialias_px, 0.001);
	float first_edge = smoothstep(width_px - ring_aa_px, width_px + ring_aa_px, ring_phase);
	float second_edge = smoothstep((width_px * 2.0) - ring_aa_px, width_px * 2.0, ring_phase);
	float ring_selector = first_edge * (1.0 - second_edge);
	vec4 ring_color = mix(black_ring_color, white_ring_color, ring_selector);

	COLOR = vec4(ring_color.rgb, ring_color.a * disk_alpha);
}
