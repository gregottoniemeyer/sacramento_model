shader_type canvas_item;
render_mode unshaded;

// The resident particle transform supplies the leaf's stable per-generation
// diameter. This shader turns its white square texel into a soft antialiased
// disk without a sprite atlas or CPU-side geometry.


void fragment() {
	float radial_distance = length(UV - vec2(0.5));
	float antialias_width = max(fwidth(radial_distance), 0.001);
	float disk_alpha = 1.0 - smoothstep(
		0.5 - antialias_width,
		0.5,
		radial_distance
	);
	COLOR = texture(TEXTURE, UV) * COLOR;
	COLOR.a *= disk_alpha;
}
