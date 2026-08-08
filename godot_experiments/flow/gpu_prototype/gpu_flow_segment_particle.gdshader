shader_type particles;
// keep_data is required on Godot 4.7 Mobile: without it, the reusable
// subparticle slot clears the transform supplied by emit_subparticle().
render_mode keep_data, disable_force, disable_velocity;

// Trail segments are immutable samples of the head's completed motion. They
// never run flow, reservoir, gate, obstacle, or shoreline physics.
uniform float segment_lifetime_seconds = 2.0;

void start() {
	VELOCITY = vec3(0.0);
	CUSTOM.y = 0.0;
	ACTIVE = true;
}

void process() {
	CUSTOM.y += DELTA;
	VELOCITY = vec3(0.0);
	if (CUSTOM.y >= max(segment_lifetime_seconds, 0.01)) {
		ACTIVE = false;
	}
}
