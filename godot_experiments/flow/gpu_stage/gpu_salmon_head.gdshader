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

// Routed Delta cohorts reconstruct the exact forward water cubic from their
// edge anchor plus command-encoded merge X, then traverse it in reverse.
uniform float delta_route_turn_pixels = 240.0;
uniform float delta_route_trunk_center_y_pixels = 540.0;
uniform float delta_route_approach_pixels = 240.0;
uniform float delta_route_lookahead_pixels = 120.0;
uniform float delta_route_spawn_stagger_seconds = 2.50;

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
const int COHORT_ROUTE_CLOSEST_SAMPLES = 16;
const int COHORT_ROUTE_NEWTON_STEPS = 3;


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


vec2 cohort_route_inward_direction(vec2 destination) {
	if (destination.x <= 0.5) {
		return vec2(1.0, 0.0);
	}
	if (destination.y <= 0.5) {
		return vec2(0.0, 1.0);
	}
	return vec2(0.0, -1.0);
}


vec2 cohort_route_control_1(vec2 destination, float merge_x) {
	vec2 inward = cohort_route_inward_direction(destination);
	vec2 merge_point = vec2(merge_x, delta_route_trunk_center_y_pixels);
	float turn_handle = max(delta_route_turn_pixels, 60.0);
	float horizontal_handle = min(
		turn_handle,
		max(180.0, abs(merge_point.y - destination.y) * 0.5)
	);
	float inlet_handle = (
		abs(inward.x) > 0.5
			? horizontal_handle
			: min(
				turn_handle,
				max(abs(merge_point.y - destination.y) * 0.45, 60.0)
			)
	);
	return destination + inward * inlet_handle;
}


vec2 cohort_route_control_2(vec2 destination, float merge_x) {
	vec2 inward = cohort_route_inward_direction(destination);
	float turn_handle = max(delta_route_turn_pixels, 60.0);
	float horizontal_handle = min(
		turn_handle,
		max(
			180.0,
			abs(delta_route_trunk_center_y_pixels - destination.y) * 0.5
		)
	);
	float outlet_handle = (
		abs(inward.x) > 0.5
			? horizontal_handle
			: min(turn_handle, 180.0)
	);
	return vec2(
		merge_x - outlet_handle,
		delta_route_trunk_center_y_pixels
	);
}


vec2 cohort_route_point(vec2 destination, float merge_x, float t) {
	vec2 point_1 = cohort_route_control_1(destination, merge_x);
	vec2 point_2 = cohort_route_control_2(destination, merge_x);
	vec2 point_3 = vec2(merge_x, delta_route_trunk_center_y_pixels);
	float u = 1.0 - t;
	return (
		u * u * u * destination
		+ 3.0 * u * u * t * point_1
		+ 3.0 * u * t * t * point_2
		+ t * t * t * point_3
	);
}


vec2 cohort_route_tangent(vec2 destination, float merge_x, float t) {
	vec2 point_1 = cohort_route_control_1(destination, merge_x);
	vec2 point_2 = cohort_route_control_2(destination, merge_x);
	vec2 point_3 = vec2(merge_x, delta_route_trunk_center_y_pixels);
	float u = 1.0 - t;
	return (
		3.0 * u * u * (point_1 - destination)
		+ 6.0 * u * t * (point_2 - point_1)
		+ 3.0 * t * t * (point_3 - point_2)
	);
}


vec2 cohort_route_second_derivative(
	vec2 destination,
	float merge_x,
	float t
) {
	vec2 point_1 = cohort_route_control_1(destination, merge_x);
	vec2 point_2 = cohort_route_control_2(destination, merge_x);
	vec2 point_3 = vec2(merge_x, delta_route_trunk_center_y_pixels);
	return (
		6.0 * (1.0 - t) * (point_2 - 2.0 * point_1 + destination)
		+ 6.0 * t * (point_3 - 2.0 * point_2 + point_1)
	);
}


float cohort_route_closest_t(
	vec2 point,
	vec2 destination,
	float merge_x,
	float previous_route_t
) {
	float maximum_t = clamp(previous_route_t, 0.0, 1.0);
	// Fish still on the trunk retain t=1. The lookahead below already activates
	// before merge and breaks the shared Shasta/McCloud P3 tie without allowing
	// numerical closest-point noise to advance either branch prematurely.
	if (point.x >= merge_x && maximum_t >= 0.999) {
		return 1.0;
	}
	float best_t = maximum_t;
	float best_distance_squared = 1.0e30;
	for (
		int sample_index = 0;
		sample_index <= COHORT_ROUTE_CLOSEST_SAMPLES;
		sample_index++
	) {
		float sample_t = maximum_t * (
			float(sample_index) / float(COHORT_ROUTE_CLOSEST_SAMPLES)
		);
		vec2 offset = cohort_route_point(destination, merge_x, sample_t) - point;
		float distance_squared = dot(offset, offset);
		if (distance_squared < best_distance_squared) {
			best_distance_squared = distance_squared;
			best_t = sample_t;
		}
	}
	for (int iteration = 0; iteration < COHORT_ROUTE_NEWTON_STEPS; iteration++) {
		vec2 curve_point = cohort_route_point(destination, merge_x, best_t);
		vec2 derivative = cohort_route_tangent(destination, merge_x, best_t);
		vec2 second_derivative = cohort_route_second_derivative(
			destination,
			merge_x,
			best_t
		);
		vec2 curve_error = curve_point - point;
		float denominator = (
			dot(derivative, derivative)
			+ dot(curve_error, second_derivative)
		);
		if (abs(denominator) > 0.000001) {
			best_t = clamp(
				best_t - dot(curve_error, derivative) / denominator,
				0.0,
				maximum_t
			);
		}
	}
	return min(maximum_t, best_t);
}


// Returns (direction.x, direction.y, monotonically nonincreasing t, weight).
// The preview point lies 120px (by default) farther along the reverse cubic.
// At the shared left merge it is already on the distinct Shasta/McCloud rail,
// while closest-point normal correction pulls every fish back to its centerline.
vec4 cohort_bezier_rail(
	vec2 point,
	vec2 destination,
	float merge_x,
	float previous_route_t
) {
	float route_t = cohort_route_closest_t(
		point,
		destination,
		merge_x,
		previous_route_t
	);
	vec2 curve_point = cohort_route_point(destination, merge_x, route_t);
	vec2 forward_derivative = cohort_route_tangent(
		destination,
		merge_x,
		route_t
	);
	float derivative_length = max(length(forward_derivative), 0.001);
	vec2 reverse_tangent = -forward_derivative / derivative_length;
	float preview_delta_t = clamp(
		delta_route_lookahead_pixels / derivative_length,
		0.02,
		0.25
	);
	float preview_t = max(route_t - preview_delta_t, 0.0);
	vec2 preview_point = cohort_route_point(destination, merge_x, preview_t);
	vec2 preview_delta = preview_point - point;
	vec2 pursuit_direction = (
		length(preview_delta) > 0.000001
			? normalize(preview_delta)
			: reverse_tangent
	);
	vec2 route_normal = vec2(-reverse_tangent.y, reverse_tangent.x);
	float cross_track_error = dot(curve_point - point, route_normal);
	float normal_correction = clamp(
		cross_track_error / max(delta_route_lookahead_pixels, 1.0),
		-1.0,
		1.0
	) * 2.25;
	vec2 rail_direction = safe_swim_direction(
		reverse_tangent * 1.25
		+ pursuit_direction * 1.75
		+ route_normal * normal_correction
	);
	float approach = max(delta_route_approach_pixels, 1.0);
	float raw_weight = 1.0 - clamp(max(point.x - merge_x, 0.0) / approach, 0.0, 1.0);
	float rail_weight = smoothstep(0.0, 1.0, raw_weight);
	if (previous_route_t < 0.999) {
		rail_weight = 1.0;
	}
	return vec4(rail_direction, route_t, rail_weight);
}


float cohort_route_progress(
	vec2 point,
	vec2 destination,
	float merge_x,
	float route_t
) {
	float release_x = max(stage_size.x - 1.0, merge_x + 1.0);
	float trunk_distance = max(release_x - merge_x, 1.0);
	float branch_distance = max(
		distance(destination, vec2(merge_x, delta_route_trunk_center_y_pixels)),
		1.0
	);
	float merge_fraction = trunk_distance / (trunk_distance + branch_distance);
	if (point.x > merge_x && route_t >= 0.999) {
		float trunk_progress = clamp(
			(release_x - point.x) / trunk_distance,
			0.0,
			1.0
		);
		return trunk_progress * merge_fraction;
	}
	return mix(merge_fraction, 1.0, 1.0 - clamp(route_t, 0.0, 1.0));
}


float cohort_arrival_radius(float varied_speed, float delta_seconds) {
	return min(
		max(
			segment_max_length_pixels,
			varied_speed * delta_seconds * 1.5
		),
		128.0
	);
}


bool cohort_reaches_anchor(
	vec2 point,
	vec2 next_point,
	vec2 destination,
	float route_t,
	float arrival_radius
) {
	if (route_t > 0.10) {
		return false;
	}
	vec2 step = next_point - point;
	float step_squared = dot(step, step);
	float projection = (
		step_squared > 0.000001
			? clamp(dot(destination - point, step) / step_squared, 0.0, 1.0)
			: 0.0
	);
	vec2 nearest_step_point = point + step * projection;
	return (
		distance(point, destination) <= arrival_radius
		|| distance(next_point, destination) <= arrival_radius
		|| distance(nearest_step_point, destination) <= arrival_radius
	);
}


float cohort_route_control_polygon_length(vec2 destination, float merge_x) {
	vec2 point_1 = cohort_route_control_1(destination, merge_x);
	vec2 point_2 = cohort_route_control_2(destination, merge_x);
	vec2 point_3 = vec2(merge_x, delta_route_trunk_center_y_pixels);
	return (
		distance(destination, point_1)
		+ distance(point_1, point_2)
		+ distance(point_2, point_3)
	);
}


vec2 cohort_immediate_spawn_point(float generation, float slot_index) {
	// Routed Delta fish do not wait for a water texel. The confluence trunk is a
	// fixed geometry contract, so cold/no-right-edge-water releases start now and
	// the CPU handoff clock cannot run while their heads remain pending.
	float lane_seed = hash11(slot_index * 5.173 + generation * 0.071);
	float half_height = min(
		max(water_contact_half_height_pixels, 1.0),
		48.0
	);
	return vec2(
		max(stage_size.x - 1.0, 0.0),
		clamp(
			delta_route_trunk_center_y_pixels
				+ mix(-half_height, half_height, lane_seed),
			0.0,
			stage_size.y
		)
	);
}


float cohort_spawn_delay_seconds(
	float generation,
	float slot_index,
	vec2 destination
) {
	// Stable command identity produces an irregular but replayable cadence. No
	// CPU queue, allocation, or logical cohort split is introduced.
	float delay_seed = hash11(
		slot_index * 7.913
		+ generation * 0.113
		+ destination.x * 0.0031
		+ destination.y * 0.0053
	);
	return delay_seed * max(delta_route_spawn_stagger_seconds, 0.0);
}


// Returns (next point X/Y, forward cubic t, normalized total progress). Routed
// movement is an explicit finite schedule: constant-time trunk travel followed
// by a time-parametric traversal of the exact reverse cubic. The cubic control
// polygon bounds its arc, so every varied-speed survivor reaches P0 no later
// than (trunk + polygon) / its captured speed, with no occupancy dependency.
vec4 cohort_scheduled_motion(
	vec2 destination,
	float merge_x,
	float spawn_y,
	float varied_speed,
	float elapsed_seconds
) {
	float release_x = max(stage_size.x - 1.0, merge_x);
	float trunk_distance = max(release_x - merge_x, 0.0);
	float safe_speed = max(varied_speed, 1.0);
	float trunk_seconds = trunk_distance / safe_speed;
	float polygon_length = max(
		cohort_route_control_polygon_length(destination, merge_x),
		1.0
	);
	float branch_seconds = polygon_length / safe_speed;
	float total_seconds = max(trunk_seconds + branch_seconds, 0.000001);
	float elapsed = clamp(elapsed_seconds, 0.0, total_seconds);
	if (elapsed < trunk_seconds && trunk_seconds > 0.000001) {
		float trunk_progress = clamp(elapsed / trunk_seconds, 0.0, 1.0);
		float point_x = mix(release_x, merge_x, trunk_progress);
		float centered_y = mix(
			spawn_y,
			delta_route_trunk_center_y_pixels,
			smoothstep(0.0, 0.75, trunk_progress)
		);
		// A small deterministic lead identifies the branch before the shared merge,
		// then returns to P3 with a continuous exact-cubic handoff.
		float approach = max(delta_route_approach_pixels, 1.0);
		float approach_progress = clamp(
			1.0 - max(point_x - merge_x, 0.0) / approach,
			0.0,
			1.0
		);
		vec2 preview = cohort_route_point(destination, merge_x, 0.78);
		float preview_delta_y = preview.y - delta_route_trunk_center_y_pixels;
		float lead_amplitude = clamp(preview_delta_y * 0.18, -24.0, 24.0);
		float lead_y = lead_amplitude * sin(approach_progress * TAU_VALUE * 0.5);
		return vec4(
			point_x,
			centered_y + lead_y,
			1.0,
			elapsed / total_seconds
		);
	}
	float branch_progress = clamp(
		(elapsed - trunk_seconds) / max(branch_seconds, 0.000001),
		0.0,
		1.0
	);
	float route_t = 1.0 - branch_progress;
	vec2 route_point = cohort_route_point(destination, merge_x, route_t);
	return vec4(route_point, route_t, elapsed / total_seconds);
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
		vec2(control_x, 0.25),
		0.0
	);
	// Row one is zero for ordinary releases. Routed Delta generations carry an
	// exact edge anchor, its branch merge X, and one authoritative survival bit.
	vec4 cohort_control = textureLod(
		salmon_control_texture,
		vec2(control_x, 0.75),
		0.0
	);
	bool control_enabled = control.a >= 0.5 && control.r > 0.5;
	bool generation_changed = abs(control.r - CUSTOM.x) > 0.25;
	float cohort_merge_x = cohort_control.b;
	bool cohort_routed = cohort_merge_x >= 0.5;
	bool cohort_survives = cohort_control.a >= 0.5;
	vec2 cohort_destination = cohort_control.rg;
	// Ordinary enabled commands carry exactly 1.0. Routed row-zero A encodes
	// 1.0 plus the exact destination-group delay chosen by the CPU.
	float cohort_group_offset = (
		cohort_routed ? max(control.a - 1.0, 0.0) : 0.0
	);

	if (!control_enabled) {
		CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
		VELOCITY = vec3(0.0);
		COLOR = vec4(0.0);
		TRANSFORM[0].z = 0.0;
		TRANSFORM[3].xy = vec2(-10000.0);
	} else {
		if (generation_changed) {
			vec3 spawn_result = (
				cohort_routed
					? vec3(cohort_immediate_spawn_point(control.r, float(INDEX)), 1.0)
					: find_spawn_point(control.g)
			);
			CUSTOM = vec4(
				control.r,
				spawn_result.z >= 0.5 ? STATE_SWIMMING : STATE_PENDING,
				0.0,
				control.g
			);
			TRANSFORM[3].xy = (
				spawn_result.z >= 0.5 ? spawn_result.xy : vec2(-10000.0)
			);
			TRANSFORM[0].z = cohort_routed ? 1.0 : 0.0;
			float captured_base_speed = (
				cohort_routed ? max(control.g, 1.0) : upstream_speed_pixels
			);
			float varied_speed = (
				cohort_routed
					? captured_base_speed
					: captured_base_speed * mix(
						1.0 - speed_variation,
						1.0 + speed_variation,
						hash11(float(INDEX) * 2.371 + control.r * 0.017)
					)
			);
			VELOCITY = (
				spawn_result.z >= 0.5
					? vec3(-varied_speed, 0.0, 0.0)
					: vec3(0.0)
			);
		}

		COLOR = salmon_color(control.b);
		if (abs(CUSTOM.y - STATE_PENDING) < 0.25) {
			if (cohort_routed) {
				// Recover an already-resident pending routed generation after a live
				// shader deployment; new routed generations take this spawn immediately.
				CUSTOM.y = STATE_SWIMMING;
				CUSTOM.z = 0.0;
				TRANSFORM[3].xy = cohort_immediate_spawn_point(
					control.r,
					float(INDEX)
				);
				TRANSFORM[0].z = 1.0;
				float varied_speed = max(control.g, 1.0);
				VELOCITY = vec3(-varied_speed, 0.0, 0.0);
				COLOR = salmon_color(control.b);
			} else {
				// Ordinary tributary salmon retain occupancy-gated retry semantics.
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
						TRANSFORM[0].z = 0.0;
						float varied_speed = upstream_speed_pixels * mix(
							1.0 - speed_variation,
							1.0 + speed_variation,
							hash11(float(INDEX) * 2.371 + control.r * 0.017)
						);
						VELOCITY = vec3(-varied_speed, 0.0, 0.0);
						COLOR = salmon_color(control.b);
					}
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
			float captured_base_speed = (
				cohort_routed ? max(control.g, 1.0) : upstream_speed_pixels
			);
			float varied_speed = (
				cohort_routed
					? captured_base_speed
					: captured_base_speed * mix(
						1.0 - speed_variation,
						1.0 + speed_variation,
						hash11(float(INDEX) * 2.371 + control.r * 0.017)
					)
			);
			vec4 scheduled_now = vec4(point, TRANSFORM[0].z, 0.0);
			if (cohort_routed) {
				float spawn_y = cohort_immediate_spawn_point(
					control.r,
					float(INDEX)
				).y;
				float spawn_delay = cohort_spawn_delay_seconds(
					control.r,
					float(INDEX),
					cohort_destination
				) + cohort_group_offset;
				scheduled_now = cohort_scheduled_motion(
					cohort_destination,
					cohort_merge_x,
					spawn_y,
					varied_speed,
					max(CUSTOM.z - spawn_delay, 0.0)
				);
			}
			float route_progress = cohort_routed ? scheduled_now.w : 0.0;
			float death_progress = mix(
				0.32,
				0.72,
				hash11(
					float(INDEX) * 29.371
					+ control.r * 0.173
					+ cohort_destination.x * 0.0017
					+ cohort_destination.y * 0.0023
				)
			);
			bool commanded_death = (
				cohort_routed
				&& !cohort_survives
				&& route_progress >= death_progress
			);
			vec4 contact = (
				cohort_routed
					? vec4(1.0, -1.0, 0.0, 1.0)
					: contact_and_steering(point, VELOCITY.xy)
			);
			// Ordinary tributary-stage fish retain the exact contact-loss fade.
			// Routed Delta outcomes are CPU-authoritative: commanded deaths fade at
			// their deterministic progress, while survivors can cross short mask gaps
			// and are retired exactly at their assigned Delta edge anchor.
			if (
				commanded_death
				|| (!cohort_routed && contact.x < water_alpha_threshold)
			) {
				CUSTOM.y = STATE_FADING;
				CUSTOM.z = 0.0;
			} else {
				vec2 resolved_velocity = VELOCITY.xy;
				vec2 next_point = point;
				bool cohort_arrived = false;
				if (cohort_routed) {
					float next_elapsed = CUSTOM.z + DELTA;
					float spawn_delay = cohort_spawn_delay_seconds(
						control.r,
						float(INDEX),
						cohort_destination
					) + cohort_group_offset;
					vec4 scheduled_next = cohort_scheduled_motion(
						cohort_destination,
						cohort_merge_x,
						cohort_immediate_spawn_point(
							control.r,
							float(INDEX)
						).y,
						varied_speed,
						max(next_elapsed - spawn_delay, 0.0)
					);
					next_point = scheduled_next.xy;
					resolved_velocity = (
						(next_point - point) / max(DELTA, 0.000001)
					);
					CUSTOM.z = next_elapsed;
					TRANSFORM[0].z = scheduled_next.z;
					cohort_arrived = scheduled_next.w >= 0.999999;
				} else {
					float seed = hash11(
						float(INDEX) + control.r * 0.131 + stage_phase
					);
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
					resolved_velocity = approach_velocity(
						VELOCITY.xy,
						target_velocity,
						DELTA
					);
					resolved_velocity = (
						safe_swim_direction(resolved_velocity) * varied_speed
					);
					next_point = point + resolved_velocity * DELTA;
				}
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
				bool route_complete = (
					cohort_routed
						? (cohort_survives && cohort_arrived)
						: next_point.x < -max(streak_length_pixels, 1.0)
				);
				if (route_complete) {
					CUSTOM.y = STATE_INACTIVE;
					VELOCITY = vec3(0.0);
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
