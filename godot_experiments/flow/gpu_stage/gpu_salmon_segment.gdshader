shader_type particles;
render_mode keep_data, disable_force, disable_velocity;

// Immutable salmon trail samples. No flow or occupancy physics runs here.
uniform float trail_lifetime_seconds = 0.50;


void start() {
	VELOCITY = vec3(0.0);
	CUSTOM.y = 0.0;
	ACTIVE = true;
}


void process() {
	CUSTOM.y += DELTA;
	VELOCITY = vec3(0.0);
	if (CUSTOM.y >= max(trail_lifetime_seconds, 0.001)) {
		ACTIVE = false;
	}
}
