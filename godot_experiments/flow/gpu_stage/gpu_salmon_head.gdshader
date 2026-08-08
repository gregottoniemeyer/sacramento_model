shader_type particles;
render_mode keep_data, disable_force, disable_velocity;

// Isolated salmon head simulation. Every one of the 300 resident GPU slots
// polls one texel in the CPU-written generation texture. A changed generation
// starts a new fish without CPU particle-state readback.
uniform sampler2D salmon_control_texture : filter_nearest, repeat_disable;
uniform sampler2D water_occupancy_texture : filter_linear, repeat_disable;
uniform vec2 stage_size = vec2(1920.0, 1080.0);
uniform float slot_capacity = 300.0;
uniform bool occupancy_flip_y = false;

uniform float upstream_speed_pixels = 100.0;
uniform float speed_variation = 0.10;
uniform float velocity_response = 12.0;
uniform float noise_strength = 18.0;
uniform float noise_scale = 0.010;
uniform float noise_speed = 0.72;
uniform float stage_phase = 0.0;

// The contact test is the user-requested centered 240 x 24 pixel rectangle by
// default. `water_lookahead_pixels` is its configurable X half-extent.
uniform float water_alpha_threshold = 0.001;
uniform float water_lookahead_pixels = 120.0;
uniform float water_contact_half_height_pixels = 12.0;
uniform float water_steering_strength = 5.0;
uniform float spawn_search_width_pixels = 120.0;
uniform float spawn_search_half_height_pixels = 2048.0;

uniform float streak_length_pixels = 100.0;
uniform float streak_width_pixels = 3.0;
uniform float fade_seconds = 0.50;
uniform float salmon_alpha = 1.0;
uniform float segment_max_length_pixels = 32.0;

const float STATE_INACTIVE = 0.0;
const float STATE_SWIMMING = 1.0;
const float STATE_FADING = 2.0;
const float STATE_PENDING = 3.0;
const float TAU_VALUE = 6.28318530718;
const int CONTACT_X_SAMPLES = 9;
const int CONTACT_Y_SAMPLES = 13;
const int SPAWN_X_SAMPLES = 9;
const int SPAWN_Y_SAMPLES = 541;


float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453123);
}


float occupancy_alpha(vec2 point) {
	if (
		point.x < 0.0
		|| point.x > stage_size.x
		|| point.y < 0.0
		|| point.y > stage_size.y
	) {
		return 0.0;
	}
	vec2 safe_size = max(stage_size, vec2(0.001));
	vec2 occupancy_uv = point / safe_size;
	if (occupancy_flip_y) {
		occupancy_uv.y = 1.0 - occupancy_uv.y;
	}
	return textureLod(water_occupancy_texture, occupancy_uv, 0.0).a;
}


vec2 safe_swim_direction(vec2 direction) {
	float direction_length = length(direction);
	return (
		direction_length > 0.000001
			? direction / direction_length
			: vec2(-1.0, 0.0)
	);
}


// Returns (maximum alpha, direction.x, direction.y, found). The same fixed
// 9 x 13 grid preserves the approved centered 240 x 24 contact/fade footprint,
// but steering now evaluates the complete occupied 2D offset. Strong heading
// continuity and a smaller upstream bias keep a fish on one nearby water path.
vec4 contact_and_steering(vec2 point, vec2 current_direction) {
	vec2 prior = safe_swim_direction(current_direction);
	float maximum_alpha = 0.0;
	vec2 best_direction = prior;
	float best_score = -1.0e20;
	float found = 0.0;
	float maximum_distance = max(
		length(vec2(water_lookahead_pixels, water_contact_half_height_pixels)),
		0.001
	);
	for (int x_index = 0; x_index < CONTACT_X_SAMPLES; x_index++) {
		float x_fraction = float(x_index) / float(CONTACT_X_SAMPLES - 1);
		float x_offset = mix(
			-water_lookahead_pixels,
			water_lookahead_pixels,
			x_fraction
		);
		for (int y_index = 0; y_index < CONTACT_Y_SAMPLES; y_index++) {
			float y_fraction = float(y_index) / float(CONTACT_Y_SAMPLES - 1);
			float y_offset = mix(
				-water_contact_half_height_pixels,
				water_contact_half_height_pixels,
				y_fraction
			);
			vec2 offset = vec2(x_offset, y_offset);
			float sample_alpha = occupancy_alpha(point + offset);
			maximum_alpha = max(maximum_alpha, sample_alpha);
			float offset_length = length(offset);
			if (
				sample_alpha >= water_alpha_threshold
				&& x_offset < -0.001
				&& offset_length > 0.001
			) {
				vec2 candidate_direction = offset / offset_length;
				float continuity = dot(candidate_direction, prior);
				float upstream_alignment = -candidate_direction.x;
				float distance_fraction = offset_length / maximum_distance;
				float score = (
					continuity * 4.0
					+ upstream_alignment * 1.25
					+ sample_alpha * 0.50
					+ distance_fraction * 0.15
				);
				if (score > best_score) {
					best_score = score;
					best_direction = candidate_direction;
					found = 1.0;
				}
			}
		}
	}
	return vec4(maximum_alpha, best_direction, found);
}


// Returns (x, y, found). Release selectors are evenly distributed by the CPU;
// each one searches a narrow Y neighborhood and the rightmost X band. This is
// GPU-only occupancy sampling, not CPU texture inspection.
vec3 find_spawn_point(float lane_selector) {
	float target_y = mix(
		water_contact_half_height_pixels,
		stage_size.y - water_contact_half_height_pixels,
		clamp(lane_selector, 0.0, 1.0)
	);
	float target_x = max(stage_size.x - 1.0, 0.0);
	vec2 best_point = vec2(target_x, target_y);
	float best_score = 1.0e20;
	float found = 0.0;
	float search_min_y = max(
		target_y - spawn_search_half_height_pixels,
		water_contact_half_height_pixels
	);
	float search_max_y = min(
		target_y + spawn_search_half_height_pixels,
		stage_size.y - water_contact_half_height_pixels
	);
	for (int x_index = 0; x_index < SPAWN_X_SAMPLES; x_index++) {
		float x_fraction = float(x_index) / float(SPAWN_X_SAMPLES - 1);
		float sample_x = stage_size.x - spawn_search_width_pixels * x_fraction;
		for (int y_index = 0; y_index < SPAWN_Y_SAMPLES; y_index++) {
			float y_fraction = float(y_index) / float(SPAWN_Y_SAMPLES - 1);
			float sample_y = mix(search_min_y, search_max_y, y_fraction);
			vec2 candidate = vec2(sample_x, clamp(sample_y, 0.0, stage_size.y));
			float candidate_alpha = occupancy_alpha(candidate);
			if (candidate_alpha >= water_alpha_threshold) {
				float score = (
					abs(candidate.y - target_y)
					+ abs(candidate.x - target_x) * 0.20
				);
				if (score < best_score) {
					best_score = score;
					best_point = candidate;
					found = 1.0;
				}
			}
		}
	}
	return vec3(best_point, found);
}


float flow_noise(vec2 point, float seed) {
	float first = sin(
		point.x * noise_scale
		+ point.y * noise_scale * 0.73
		+ TIME * noise_speed
		+ seed * TAU_VALUE
		+ stage_phase
	);
	float second = sin(
		point.x * noise_scale * 0.31
		- point.y * noise_scale * 1.27
		- TIME * noise_speed * 0.63
		+ seed * 11.0
	);
	return first * 0.68 + second * 0.32;
}


vec2 approach_velocity(vec2 current, vec2 target, float delta_seconds) {
	if (velocity_response <= 0.0) {
		return target;
	}
	float response_alpha = 1.0 - exp(-velocity_response * delta_seconds);
	return mix(current, target, response_alpha);
}


vec4 salmon_color(float palette_index) {
	if (palette_index < 0.5) {
		return vec4(1.0, 0.360784, 0.541176, salmon_alpha); // #FF5C8A
	}
	if (palette_index < 1.5) {
		return vec4(1.0, 0.478431, 0.447059, salmon_alpha); // #FF7A72
	}
	if (palette_index < 2.5) {
		return vec4(1.0, 0.549020, 0.258824, salmon_alpha); // #FF8C42
	}
	if (palette_index < 3.5) {
		return vec4(1.0, 0.678431, 0.200000, salmon_alpha); // #FFAD33
	}
	return vec4(1.0, 0.823529, 0.247059, salmon_alpha); // #FFD23F
}


void start() {
	// keep_data preserves logical state across the resident emitter's normal
	// lifetime rollover. Generation polling in process() owns actual restarts.
	VELOCITY = vec3(0.0);
}


void process() {
	float control_x = (float(INDEX) + 0.5) / max(slot_capacity, 1.0);
	vec4 control = textureLod(
		salmon_control_texture,
		vec2(control_x, 0.5),
		0.0
	);
	bool control_enabled = control.a >= 0.5 && control.r > 0.5;
	bool generation_changed = abs(control.r - CUSTOM.x) > 0.25;

	if (!control_enabled) {
		CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
		VELOCITY = vec3(0.0);
		COLOR = vec4(0.0);
		TRANSFORM[3].xy = vec2(-10000.0);
	} else {
		if (generation_changed) {
			vec3 spawn_result = find_spawn_point(control.g);
			CUSTOM = vec4(
				control.r,
				spawn_result.z >= 0.5 ? STATE_SWIMMING : STATE_PENDING,
				0.0,
				control.g
			);
			TRANSFORM[3].xy = (
				spawn_result.z >= 0.5 ? spawn_result.xy : vec2(-10000.0)
			);
			float varied_speed = upstream_speed_pixels * mix(
				1.0 - speed_variation,
				1.0 + speed_variation,
				hash11(float(INDEX) * 2.371 + control.r * 0.017)
			);
			VELOCITY = (
				spawn_result.z >= 0.5
					? vec3(-varied_speed, 0.0, 0.0)
					: vec3(0.0)
			);
		}

		COLOR = salmon_color(control.b);
		if (abs(CUSTOM.y - STATE_PENDING) < 0.25) {
			// A release is not discarded merely because the source viewport had no
			// right-edge water on one frame. Keep it invisible and retry at 4 Hz.
			CUSTOM.z += DELTA;
			VELOCITY = vec3(0.0);
			COLOR.a = 0.0;
			TRANSFORM[3].xy = vec2(-10000.0);
			if (CUSTOM.z >= 0.25) {
				CUSTOM.z = 0.0;
				vec3 spawn_result = find_spawn_point(CUSTOM.w);
				if (spawn_result.z >= 0.5) {
					CUSTOM.y = STATE_SWIMMING;
					TRANSFORM[3].xy = spawn_result.xy;
					float varied_speed = upstream_speed_pixels * mix(
						1.0 - speed_variation,
						1.0 + speed_variation,
						hash11(float(INDEX) * 2.371 + control.r * 0.017)
					);
					VELOCITY = vec3(-varied_speed, 0.0, 0.0);
					COLOR = salmon_color(control.b);
				}
			}
		} else if (abs(CUSTOM.y - STATE_FADING) < 0.25) {
			// Water loss is latched and linearly fades for exactly the
			// configured interval. Occupancy returning cannot revive this generation.
			// The invisible control head keeps a damped version of its last direction
			// and emits progressively fainter immutable samples; otherwise only the
			// transparent head would receive this 0.5-second fade.
			CUSTOM.z += DELTA;
			float fade_progress = clamp(
				CUSTOM.z / max(fade_seconds, 0.001),
				0.0,
				1.0
			);
			// Recompute from the configured base alpha every frame. Multiplying the
			// previous frame's alpha would compound the fade and make it disappear
			// much sooner than the requested half second.
			COLOR.a = salmon_alpha * (1.0 - fade_progress);
			if (fade_progress < 1.0) {
				vec2 point = TRANSFORM[3].xy;
				vec2 fade_velocity = VELOCITY.xy * exp(-4.0 * DELTA);
				vec2 next_point = point + fade_velocity * DELTA;
				vec2 completed_step = next_point - point;
				float completed_length = length(completed_step);
				if (
					completed_length > 0.0001
					&& completed_length <= max(segment_max_length_pixels, 0.001)
				) {
					vec2 direction = completed_step / completed_length;
					vec2 normal = vec2(-direction.y, direction.x);
					mat4 segment_transform = mat4(1.0);
					segment_transform[0].xy = direction * completed_length;
					segment_transform[1].xy = normal;
					segment_transform[3].xy = (point + next_point) * 0.5;
					emit_subparticle(
						segment_transform,
						vec3(0.0),
						COLOR,
						vec4(streak_width_pixels, 0.0, 0.0, 0.0),
						FLAG_EMIT_POSITION
							| FLAG_EMIT_ROT_SCALE
							| FLAG_EMIT_VELOCITY
							| FLAG_EMIT_COLOR
							| FLAG_EMIT_CUSTOM
					);
				}
				VELOCITY = vec3(fade_velocity, 0.0);
				TRANSFORM[3].xy = next_point;
			} else {
				CUSTOM.y = STATE_INACTIVE;
				VELOCITY = vec3(0.0);
				COLOR.a = 0.0;
				TRANSFORM[3].xy = vec2(-10000.0);
			}
		} else if (abs(CUSTOM.y - STATE_SWIMMING) < 0.25) {
			vec2 point = TRANSFORM[3].xy;
			vec4 contact = contact_and_steering(point, VELOCITY.xy);
			if (contact.x < water_alpha_threshold) {
				CUSTOM.y = STATE_FADING;
				CUSTOM.z = 0.0;
			} else {
				float varied_speed = upstream_speed_pixels * mix(
					1.0 - speed_variation,
					1.0 + speed_variation,
					hash11(float(INDEX) * 2.371 + control.r * 0.017)
				);
				float seed = hash11(float(INDEX) + control.r * 0.131 + stage_phase);
				vec2 prior_direction = safe_swim_direction(VELOCITY.xy);
				vec2 prior_normal = vec2(-prior_direction.y, prior_direction.x);
				vec2 upstream_noise_direction = safe_swim_direction(
					prior_direction * varied_speed
					+ prior_normal * flow_noise(point, seed) * noise_strength
				);
				vec2 target_direction = upstream_noise_direction;
				if (contact.w >= 0.5) {
					target_direction = safe_swim_direction(
						upstream_noise_direction
						+ contact.yz * max(water_steering_strength, 0.0)
					);
				}
				vec2 target_velocity = target_direction * varied_speed;
				vec2 resolved_velocity = approach_velocity(
					VELOCITY.xy,
					target_velocity,
					DELTA
				);
				resolved_velocity = (
					safe_swim_direction(resolved_velocity) * varied_speed
				);
				vec2 next_point = point + resolved_velocity * DELTA;
				vec2 completed_step = next_point - point;
				float completed_length = length(completed_step);
				if (
					completed_length > 0.0001
					&& completed_length <= max(segment_max_length_pixels, 0.001)
				) {
					vec2 direction = completed_step / completed_length;
					vec2 normal = vec2(-direction.y, direction.x);
					mat4 segment_transform = mat4(1.0);
					segment_transform[0].xy = direction * completed_length;
					segment_transform[1].xy = normal;
					segment_transform[3].xy = (point + next_point) * 0.5;
					emit_subparticle(
						segment_transform,
						vec3(0.0),
						COLOR,
						vec4(streak_width_pixels, 0.0, 0.0, 0.0),
						FLAG_EMIT_POSITION
							| FLAG_EMIT_ROT_SCALE
							| FLAG_EMIT_VELOCITY
							| FLAG_EMIT_COLOR
							| FLAG_EMIT_CUSTOM
					);
				}
				VELOCITY = vec3(resolved_velocity, 0.0);
				TRANSFORM[3].xy = next_point;
				if (next_point.x < -max(streak_length_pixels, 1.0)) {
					CUSTOM.y = STATE_INACTIVE;
					COLOR.a = 0.0;
					TRANSFORM[3].xy = vec2(-10000.0);
				}
			}
		} else {
			COLOR.a = 0.0;
			VELOCITY = vec3(0.0);
		}
	}
}
