shader_type canvas_item;
render_mode unshaded;

// Heads still run the complete particle simulation and emit immutable trail
// segments, but only the segments are visible.
void fragment() {
	COLOR = vec4(0.0);
}
