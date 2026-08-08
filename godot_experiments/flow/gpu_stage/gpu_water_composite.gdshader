shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

// Transparent SubViewport pixels are resolved with premultiplied RGB. Composite
// them once with premultiplied blending so faint water edges and tail alpha are
// not multiplied a second time on the stage background.
void fragment() {
	COLOR = texture(TEXTURE, UV) * COLOR;
}
