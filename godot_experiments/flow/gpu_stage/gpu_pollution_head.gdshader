shader_type particles;
render_mode keep_data, disable_force, disable_velocity;

// Resident GPU pollution disks. The CPU writes only release generations,
// exact source positions, inward directions, source-class tags, deterministic
// source seeds, and launch delays. Free water seeking, irreversible attachment, local water
// following, and bounded centerline parking stay GPU-owned without readback.
uniform sampler2D pollution_control_texture : filter_nearest, repeat_disable;
uniform sampler2D water_occupancy_texture : filter_linear, repeat_disable;
uniform vec2 stage_size = vec2(1920.0, 1080.0);
uniform float slot_capacity = 96.0;
uniform bool occupancy_flip_y = false;

uniform float free_speed_pixels = 120.0;
uniform float flow_speed_pixels = 300.0;
uniform float speed_variation = 0.15;
uniform float velocity_response = 8.0;
uniform float free_water_search_radius_pixels = 120.0;
uniform float free_water_steering_strength = 0.35;
uniform float water_alpha_threshold = 0.001;
uniform float contact_radius_pixels = 12.0;
uniform float follow_probe_min_pixels = 8.0;
uniform float follow_probe_max_pixels = 56.0;
uniform float follow_turn_radians = 0.6108652382; // 35 degrees.
uniform float follow_resample_interval_seconds = 0.12;
uniform float center_recheck_interval_seconds = 0.50;
uniform float center_hold_seconds = 8.0;
uniform float center_fade_seconds = 2.0;

uniform float disk_diameter_pixels = 10.0;
uniform float radius_variation = 0.40;
uniform vec4 pollution_color : source_color = vec4(0.38, 0.38, 0.38, 1.0);
uniform vec4 heat_pollution_color : source_color = vec4(1.0, 0.0, 0.0, 1.0);

const float STATE_INACTIVE = 0.0;
const float STATE_SCHEDULED = 1.0;
const float STATE_FREE = 2.0;
const float STATE_WATER_LATCHED = 3.0;
const float STATE_CENTER_STOPPED = 4.0;
const int CONTACT_AXIS_SAMPLES = 9;
const int FREE_SEARCH_AXIS_SAMPLES = 17;
const int FOLLOW_ANGLE_SAMPLES = 9;
const int FOLLOW_RADIUS_SAMPLES = 3;
const float MIN_SPEED_FACTOR = 0.05;


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


// A pollution disk attaches only when its center-radius contact disk overlaps
// nontransparent water. Once attached, it never returns to FREE.
bool touches_water(vec2 point) {
	for (int x_index = 0; x_index < CONTACT_AXIS_SAMPLES; x_index++) {
		float x_fraction = float(x_index) / float(CONTACT_AXIS_SAMPLES - 1);
		float x_offset = mix(
			-contact_radius_pixels,
			contact_radius_pixels,
			x_fraction
		);
		for (int y_index = 0; y_index < CONTACT_AXIS_SAMPLES; y_index++) {
			float y_fraction = float(y_index) / float(CONTACT_AXIS_SAMPLES - 1);
			float y_offset = mix(
				-contact_radius_pixels,
				contact_radius_pixels,
				y_fraction
			);
			vec2 offset = vec2(x_offset, y_offset);
			if (
				length(offset) <= contact_radius_pixels + 0.001
				&& occupancy_alpha(point + offset) >= water_alpha_threshold
			) {
				return true;
			}
		}
	}
	return false;
}


// Returns (direction.x, direction.y, found). The 17 x 17 disk search may
// attract laterally toward nearby water, but samples behind the supplied
// inward direction are rejected.
vec3 find_nearby_water_direction(vec2 point, vec2 inward_direction) {
	float search_radius = max(free_water_search_radius_pixels, 1.0);
	float inward_magnitude = length(inward_direction);
	vec2 inward = (
		inward_magnitude > 0.000001
			? inward_direction / inward_magnitude
			: vec2(0.0, 1.0)
	);
	vec2 best_direction = inward;
	float best_score = -1.0e20;
	float found = 0.0;
	for (int x_index = 0; x_index < FREE_SEARCH_AXIS_SAMPLES; x_index++) {
		float x_fraction = float(x_index) / float(FREE_SEARCH_AXIS_SAMPLES - 1);
		float x_offset = mix(-search_radius, search_radius, x_fraction);
		for (int y_index = 0; y_index < FREE_SEARCH_AXIS_SAMPLES; y_index++) {
			float y_fraction = float(y_index) / float(FREE_SEARCH_AXIS_SAMPLES - 1);
			float y_offset = mix(-search_radius, search_radius, y_fraction);
			vec2 offset = vec2(x_offset, y_offset);
			float offset_length = length(offset);
			if (offset_length <= 0.001 || offset_length > search_radius + 0.001) {
				continue;
			}
			float sample_alpha = occupancy_alpha(point + offset);
			if (sample_alpha >= water_alpha_threshold) {
				vec2 candidate_direction = offset / offset_length;
				float inward_alignment = dot(candidate_direction, inward);
				if (inward_alignment < 0.0) {
					continue;
				}
				float distance_score = 1.0 - offset_length / search_radius;
				float score = (
					distance_score * 4.0
					+ inward_alignment * 1.50
					+ sample_alpha * 0.01
				);
				if (score > best_score) {
					best_score = score;
					best_direction = candidate_direction;
					found = 1.0;
				}
			}
		}
	}
	float best_magnitude = length(best_direction);
	vec2 resolved_direction = (
		best_magnitude > 0.000001 ? best_direction / best_magnitude : inward
	);
	return vec3(resolved_direction, found);
}


vec2 rotate_direction(vec2 direction, float angle) {
	float cosine = cos(angle);
	float sine = sin(angle);
	return vec2(
		direction.x * cosine - direction.y * sine,
		direction.x * sine + direction.y * cosine
	);
}


vec2 safe_direction(vec2 direction) {
	float magnitude = length(direction);
	return magnitude > 0.000001 ? direction / magnitude : vec2(1.0, 0.0);
}


// This is the same local, periodically resampled water-following strategy used
// by the leaf heads: a center-and-flank fan follows curving water while local
// continuity and a smaller +X score preserve a stable downstream tendency.
vec3 find_follow_direction(vec2 point, vec2 previous_direction) {
	vec2 prior = safe_direction(previous_direction);
	float maximum_turn = clamp(abs(follow_turn_radians), 0.0, 1.396263402);

	vec2 best_direction = prior;
	float best_score = -1.0e20;
	float found = 0.0;
	for (int angle_index = 0; angle_index < FOLLOW_ANGLE_SAMPLES; angle_index++) {
		float angle_fraction = float(angle_index) / float(FOLLOW_ANGLE_SAMPLES - 1);
		float angle = mix(-maximum_turn, maximum_turn, angle_fraction);
		vec2 candidate_direction = rotate_direction(prior, angle);
		vec2 candidate_normal = vec2(-candidate_direction.y, candidate_direction.x);
		float water_support = 0.0;
		float maximum_support = 0.0;
		float center_hits = 0.0;
		for (int radius_index = 0; radius_index < FOLLOW_RADIUS_SAMPLES; radius_index++) {
			float radius_fraction = (
				float(radius_index) / float(FOLLOW_RADIUS_SAMPLES - 1)
			);
			float probe_radius = mix(
				follow_probe_min_pixels,
				follow_probe_max_pixels,
				radius_fraction
			);
			float radius_weight = mix(0.65, 1.0, radius_fraction);
			vec2 probe_point = point + candidate_direction * probe_radius;
			float flank_distance = min(
				max(contact_radius_pixels * 0.5, 2.0),
				probe_radius * 0.35
			);
			float center_alpha = occupancy_alpha(probe_point);
			float left_alpha = occupancy_alpha(
				probe_point + candidate_normal * flank_distance
			);
			float right_alpha = occupancy_alpha(
				probe_point - candidate_normal * flank_distance
			);
			if (center_alpha >= water_alpha_threshold) {
				center_hits += 1.0;
			}
			water_support += radius_weight * (
				center_alpha * 2.0 + left_alpha * 0.5 + right_alpha * 0.5
			);
			maximum_support += radius_weight * 3.0;
		}
		if (center_hits >= 0.5) {
			float normalized_support = water_support / max(maximum_support, 0.001);
			float continuity = dot(candidate_direction, prior);
			float downstream_alignment = candidate_direction.x;
			float turn_continuity = 1.0 - abs(angle) / max(
				maximum_turn,
				0.000001
			);
			float score = (
				normalized_support * 3.0
				+ continuity * 3.5
				+ downstream_alignment * 0.90
				+ turn_continuity * 0.25
			);
			if (score > best_score) {
				best_score = score;
				best_direction = candidate_direction;
				found = 1.0;
			}
		}
	}
	return vec3(safe_direction(best_direction), found);
}


vec2 approach_velocity(vec2 current, vec2 target, float delta_seconds) {
	if (velocity_response <= 0.0) {
		return target;
	}
	float response_alpha = 1.0 - exp(-velocity_response * delta_seconds);
	return mix(current, target, response_alpha);
}


void start() {
	VELOCITY = vec3(0.0);
}


void process() {
	float control_x = (float(INDEX) + 0.5) / max(slot_capacity, 1.0);
	vec4 control = textureLod(
		pollution_control_texture,
		vec2(control_x, 0.25),
		0.0
	);
	vec4 command = textureLod(
		pollution_control_texture,
		vec2(control_x, 0.75),
		0.0
	);
	bool control_enabled = control.a >= 0.5 && control.r > 0.5;
	bool generation_changed = abs(control.r - CUSTOM.x) > 0.25;

	if (!control_enabled) {
		CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, 0.0);
		VELOCITY = vec3(0.0);
		COLOR = vec4(0.0);
		TRANSFORM[3].xy = vec2(-10000.0);
	} else {
		// Tags 1/2 are legacy material/heat commands; 3/4 are their
		// confluence equivalents that begin irreversibly water-latched.
		bool heat_pollution = (
			abs(control.a - 2.0) < 0.25
			|| abs(control.a - 4.0) < 0.25
		);
		bool start_latched = control.a >= 2.5;
		float source_seed = command.g;
		vec2 inward_direction = safe_direction(command.ba);
		float speed_factor = max(
			mix(
				1.0 - speed_variation,
				1.0 + speed_variation,
				hash11(float(INDEX) * 2.371 + control.r * 0.017 + source_seed * 7.31)
			),
			MIN_SPEED_FACTOR
		);
		float resolved_diameter_pixels = disk_diameter_pixels * mix(
			1.0,
			1.0 + clamp(radius_variation, 0.0, 1.0),
			hash11(float(INDEX) * 17.213 + control.r * 0.311 + source_seed * 5.19)
		);
		float disk_radius_pixels = resolved_diameter_pixels * 0.5;
		TRANSFORM[0].xy = vec2(resolved_diameter_pixels, 0.0);
		TRANSFORM[1].xy = vec2(0.0, resolved_diameter_pixels);

		float grey_variation = mix(
			0.82,
			1.12,
			hash11(float(INDEX) * 13.173 + control.r * 0.227 + source_seed * 11.91)
		);
		vec3 resolved_color = (
			heat_pollution
				? heat_pollution_color.rgb
				: clamp(
					pollution_color.rgb * grey_variation,
					vec3(0.0),
					vec3(1.0)
				)
		);
		// Every release starts opaque. Only a bounded center miss may later fade;
		// water-latched travel remains opaque apart from the disk's antialiased edge.
		COLOR = vec4(resolved_color, 1.0);

		if (generation_changed) {
			// Hide the replacement generation for one simulation tick so renderer
			// interpolation cannot draw a bridge from the slot's former position.
			CUSTOM = vec4(
				control.r,
				STATE_SCHEDULED,
				max(command.r, 0.0),
				0.0
			);
			TRANSFORM[3].xy = control.gb;
			VELOCITY = vec3(0.0);
			COLOR = vec4(0.0);
			} else if (abs(CUSTOM.y - STATE_SCHEDULED) < 0.25) {
				CUSTOM.z -= DELTA;
				if (CUSTOM.z <= 0.0) {
					CUSTOM.z = 0.0;
					TRANSFORM[3].xy = control.gb;
					if (start_latched) {
						CUSTOM.y = STATE_WATER_LATCHED;
						CUSTOM.w = atan(inward_direction.y, inward_direction.x);
						VELOCITY = vec3(
							inward_direction * flow_speed_pixels * speed_factor,
							0.0
						);
					} else {
						CUSTOM.y = STATE_FREE;
						CUSTOM.w = 0.0;
						// Legacy pollution begins at the exact supplied source and
						// seeks inward until it reaches water or the centerline.
						VELOCITY = vec3(
							inward_direction * free_speed_pixels * speed_factor,
							0.0
						);
					}
				} else {
					COLOR = vec4(0.0);
				}
			} else if (abs(CUSTOM.y - STATE_FREE) < 0.25) {
				vec2 point = TRANSFORM[3].xy;
				if (touches_water(point)) {
					CUSTOM.y = STATE_WATER_LATCHED;
					CUSTOM.z = hash11(
						float(INDEX) * 19.731 + control.r * 0.419 + source_seed * 3.73
					) * max(follow_resample_interval_seconds, DELTA);
					CUSTOM.w = 0.0;
					VELOCITY = vec3(flow_speed_pixels * speed_factor, 0.0, 0.0);
				} else {
					float centerline_y = stage_size.y * 0.5;
					bool moves_down = inward_direction.y >= 0.0;
					bool reached_centerline = (
						moves_down ? point.y >= centerline_y : point.y <= centerline_y
					);
					if (reached_centerline) {
						CUSTOM.y = STATE_CENTER_STOPPED;
						CUSTOM.z = 0.0;
						CUSTOM.w = hash11(
							float(INDEX) * 23.117
							+ control.r * 0.713
							+ source_seed * 5.31
						) * max(center_recheck_interval_seconds, DELTA);
						TRANSFORM[3].y = centerline_y;
						VELOCITY = vec3(0.0);
					} else {
						vec3 nearby_water = find_nearby_water_direction(
							point,
							inward_direction
						);
						vec2 free_direction = inward_direction;
						if (nearby_water.z >= 0.5) {
							free_direction = safe_direction(mix(
								inward_direction,
								nearby_water.xy,
								clamp(free_water_steering_strength, 0.0, 1.0)
							));
							// Retain enough inward progress that lateral attraction cannot
							// turn an unlatched disk back toward its source bank.
							float inward_alignment = dot(
								free_direction,
								inward_direction
							);
							if (inward_alignment < 0.20) {
								free_direction = safe_direction(
									free_direction
									+ inward_direction * (0.20 - inward_alignment)
								);
							}
						}

						vec2 free_velocity = (
							free_direction * free_speed_pixels * speed_factor
						);
						float distance_to_centerline = abs(centerline_y - point.y);
						float vertical_speed = max(abs(free_velocity.y), 0.000001);
						float movement_delta = min(
							DELTA,
							distance_to_centerline / vertical_speed
						);
						vec2 next_point = point + free_velocity * movement_delta;
						bool crossed_centerline = (
							moves_down
								? next_point.y >= centerline_y
								: next_point.y <= centerline_y
						);
						if (crossed_centerline || movement_delta < DELTA) {
							next_point.y = centerline_y;
							reached_centerline = true;
						}
						TRANSFORM[3].xy = next_point;
						VELOCITY = vec3(free_velocity, 0.0);

						// Check the bounded movement endpoint as well as the previous
						// point so a thin water line cannot be stepped over at 30 Hz.
						if (touches_water(next_point)) {
							CUSTOM.y = STATE_WATER_LATCHED;
							CUSTOM.z = hash11(
								float(INDEX) * 19.731
								+ control.r * 0.419
								+ source_seed * 3.73
							) * max(follow_resample_interval_seconds, DELTA);
							CUSTOM.w = 0.0;
							VELOCITY = vec3(
								flow_speed_pixels * speed_factor,
								0.0,
								0.0
							);
						} else if (reached_centerline) {
							// Park at center for later water reacquisition, then retire by the
							// bounded hold-and-fade policy if no trail arrives.
							CUSTOM.y = STATE_CENTER_STOPPED;
							CUSTOM.z = 0.0;
							CUSTOM.w = hash11(
								float(INDEX) * 23.117
								+ control.r * 0.713
								+ source_seed * 5.31
							) * max(center_recheck_interval_seconds, DELTA);
							VELOCITY = vec3(0.0);
						}
					}
				}
			} else if (abs(CUSTOM.y - STATE_WATER_LATCHED) < 0.25) {
			vec2 point = TRANSFORM[3].xy;
			vec2 desired_direction = vec2(cos(CUSTOM.w), sin(CUSTOM.w));
			float resample_interval = max(follow_resample_interval_seconds, DELTA);
			CUSTOM.z += DELTA;
			if (CUSTOM.z >= resample_interval) {
				CUSTOM.z = mod(CUSTOM.z, resample_interval);
				vec3 follow_result = find_follow_direction(point, desired_direction);
				// A temporary water-alpha gap never changes classification or opacity.
				// With no supported turn, the last cached heading simply continues.
				if (follow_result.z >= 0.5) {
					desired_direction = safe_direction(follow_result.xy);
					CUSTOM.w = atan(desired_direction.y, desired_direction.x);
				}
			}
			float attached_speed = flow_speed_pixels * speed_factor;
			vec2 target_velocity = desired_direction * attached_speed;
			vec2 resolved_velocity = approach_velocity(
				VELOCITY.xy,
				target_velocity,
				DELTA
			);
			resolved_velocity = safe_direction(resolved_velocity) * attached_speed;
			vec2 next_point = point + resolved_velocity * DELTA;
			VELOCITY = vec3(resolved_velocity, 0.0);
			TRANSFORM[3].xy = next_point;

			// The complete antialiased disk must clear the downstream/right edge.
			// There is no age, water-gap, or opacity-based retirement path.
			if (next_point.x > stage_size.x + disk_radius_pixels) {
				CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, 0.0);
				VELOCITY = vec3(0.0);
				COLOR = vec4(0.0);
				TRANSFORM[3].xy = vec2(-10000.0);
			}
			} else if (abs(CUSTOM.y - STATE_CENTER_STOPPED) < 0.25) {
				// A center miss remains eligible for later water contact. Recheck only
				// at a phased, bounded cadence so parked slots stay cheap on Intel GPUs.
				TRANSFORM[3].y = stage_size.y * 0.5;
				VELOCITY = vec3(0.0);
				CUSTOM.z += DELTA;
				float recheck_interval = max(center_recheck_interval_seconds, DELTA);
				if (CUSTOM.z >= CUSTOM.w) {
					// Discard missed probe history after a render stall; one contact test
					// now is sufficient and avoids a catch-up spike on the older Intel GPU.
					CUSTOM.w = CUSTOM.z + recheck_interval;
					if (touches_water(TRANSFORM[3].xy)) {
						CUSTOM.y = STATE_WATER_LATCHED;
						CUSTOM.z = hash11(
							float(INDEX) * 19.731
							+ control.r * 0.419
							+ source_seed * 3.73
						) * max(follow_resample_interval_seconds, DELTA);
						CUSTOM.w = 0.0;
						COLOR.a = 1.0;
						VELOCITY = vec3(
							flow_speed_pixels * speed_factor,
							0.0,
							0.0
						);
					}
				}
				if (abs(CUSTOM.y - STATE_CENTER_STOPPED) < 0.25) {
					float hold_seconds = max(center_hold_seconds, 0.0);
					float fade_seconds = max(center_fade_seconds, DELTA);
					float fade_progress = clamp(
						(CUSTOM.z - hold_seconds) / fade_seconds,
						0.0,
						1.0
					);
					COLOR.a *= 1.0 - smoothstep(0.0, 1.0, fade_progress);
					if (CUSTOM.z >= hold_seconds + fade_seconds) {
						CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, 0.0);
						VELOCITY = vec3(0.0);
						COLOR = vec4(0.0);
						TRANSFORM[3].xy = vec2(-10000.0);
					}
				}
			} else {
			CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, 0.0);
			VELOCITY = vec3(0.0);
			COLOR = vec4(0.0);
			TRANSFORM[3].xy = vec2(-10000.0);
		}
	}
}
