shader_type particles;
render_mode keep_data, disable_force, disable_velocity;

// Resident GPU leaf heads. The CPU writes only release generations, X-lane
// selectors, palette indices, originating banks, and launch delays. Motion,
// water contact, irreversible attachment, and disk sizing stay on the GPU.
uniform sampler2D leaf_control_texture : filter_nearest, repeat_disable;
uniform sampler2D water_occupancy_texture : filter_linear, repeat_disable;
uniform vec2 stage_size = vec2(1920.0, 1080.0);
uniform float slot_capacity = 300.0;
uniform bool occupancy_flip_y = false;

uniform float free_speed_pixels = 120.0;
uniform float flow_speed_pixels = 300.0;
uniform float speed_variation = 0.0;
uniform float velocity_response = 8.0;
uniform float free_sway_amplitude_min_pixels = 2.0;
uniform float free_sway_amplitude_max_pixels = 6.0;
uniform float free_sway_period_min_seconds = 1.2;
uniform float free_sway_period_max_seconds = 2.8;
uniform float free_water_search_radius_pixels = 120.0;
uniform float free_water_steering_strength = 0.35;
uniform float free_search_max_distance_pixels = 540.0;
uniform float stopped_fade_seconds = 0.5;

uniform float water_alpha_threshold = 0.001;
uniform float contact_radius_pixels = 12.0;
uniform float follow_probe_min_pixels = 8.0;
uniform float follow_probe_max_pixels = 56.0;
uniform float follow_turn_radians = 0.6108652382; // 35 degrees.
uniform float follow_resample_interval_seconds = 0.12;

uniform float streak_width_pixels = 10.0;
uniform float line_width_variation = 1.0;
uniform float leaf_alpha = 1.0;

const float STATE_INACTIVE = 0.0;
const float STATE_FREE = 1.0;
const float STATE_WATER_LATCHED = 2.0;
const float STATE_SCHEDULED = 3.0;
const float STATE_STOPPED_FADING = 4.0;
const float TAU_VALUE = 6.28318530718;
// Nine samples per axis keep a thin antialiased water line from slipping
// between contact probes while remaining inexpensive for the 300-slot pool.
const int CONTACT_AXIS_SAMPLES = 9;
// Seventeen samples span the default 240px diameter at 15px spacing, dense
// enough to see narrow water lines without a CPU-side search or readback.
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


// A leaf changes classification only when its center-radius contact disk
// overlaps nontransparent water. Once true, the state is never evaluated back
// to FREE for the same release generation.
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


// Returns (direction.x, direction.y, found). FREE leaves search a true 2D
// vicinity instead of probing only along their vertical fall line. Distance is
// the dominant score, with a small inward preference for stable bank-to-center
// travel when two water samples are equally close.
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
				// A missed stream may attract laterally, but never back toward the
				// originating bank.
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


// Returns (direction.x, direction.y, found). The fan is anchored to the cached
// local water heading and is evaluated only at the configured resample cadence.
// Multi-radius center-and-flank support bends the cached heading before it
// reaches a reservoir edge. Continuity and a smaller +X bias keep the result
// calm and downstream without forcing a straight chord across every curve.
vec3 find_follow_direction(vec2 point, vec2 previous_direction) {
	vec2 prior = safe_direction(previous_direction);
	float maximum_turn = clamp(
		abs(follow_turn_radians),
		0.0,
		1.396263402
	);

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
	return vec3(normalize(best_direction), found);
}


vec2 approach_velocity(vec2 current, vec2 target, float delta_seconds) {
	if (velocity_response <= 0.0) {
		return target;
	}
	float response_alpha = 1.0 - exp(-velocity_response * delta_seconds);
	return mix(current, target, response_alpha);
}


vec4 leaf_color(float palette_index) {
	if (palette_index < 0.5) {
		return vec4(0.549020, 0.247059, 0.039216, leaf_alpha); // #8C3F0A
	}
	if (palette_index < 1.5) {
		return vec4(0.662745, 0.329412, 0.070588, leaf_alpha); // #A95412
	}
	if (palette_index < 2.5) {
		return vec4(0.768627, 0.478431, 0.070588, leaf_alpha); // #C47A12
	}
	if (palette_index < 3.5) {
		return vec4(0.760784, 0.603922, 0.094118, leaf_alpha); // #C29A18
	}
	if (palette_index < 4.5) {
		return vec4(0.541176, 0.560784, 0.164706, leaf_alpha); // #8A8F2A
	}
	if (palette_index < 5.5) {
		return vec4(0.309804, 0.466667, 0.176471, leaf_alpha); // #4F772D
	}
	return vec4(0.211765, 0.372549, 0.196078, leaf_alpha); // #365F32
}


void start() {
	VELOCITY = vec3(0.0);
}


void process() {
	float control_x = (float(INDEX) + 0.5) / max(slot_capacity, 1.0);
	vec4 control = textureLod(
		leaf_control_texture,
		vec2(control_x, 0.25),
		0.0
	);
	vec4 command = textureLod(
		leaf_control_texture,
		vec2(control_x, 0.75),
		0.0
	);
	bool control_enabled = control.a >= 0.5 && control.r > 0.5;
	bool generation_changed = abs(control.r - CUSTOM.x) > 0.25;
	bool explicit_source = control.a >= 2.5;
	vec2 source_position = vec2(control.g, command.r);
	vec2 source_inward_direction = safe_direction(vec2(command.g, command.b));

	if (!control_enabled) {
		CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
		VELOCITY = vec3(0.0);
		COLOR = vec4(0.0);
		TRANSFORM[3].xy = vec2(-10000.0);
	} else {
	float bank_direction = control.a < 1.5 ? 1.0 : -1.0;
	float speed_factor = max(
		mix(
			1.0 - speed_variation,
			1.0 + speed_variation,
			hash11(float(INDEX) * 2.371 + control.r * 0.017)
		),
		MIN_SPEED_FACTOR
	);
	float leaf_diameter_pixels = streak_width_pixels * mix(
		1.0,
		1.0 + clamp(line_width_variation, 0.0, 1.0),
		hash11(float(INDEX) * 17.213 + control.r * 0.311)
	);
	float leaf_radius_pixels = leaf_diameter_pixels * 0.5;
	// The texture is one white pixel. Scaling both basis axes by the stable
	// per-generation diameter lets the canvas shader render the visible disk.
	TRANSFORM[0].xy = vec2(leaf_diameter_pixels, 0.0);
	TRANSFORM[1].xy = vec2(0.0, leaf_diameter_pixels);
	if (generation_changed) {
		if (explicit_source) {
			// Exact confluence entries remain parked at their supplied point. The
			// first generation tick is hidden so circular slot reuse cannot draw an
			// interpolation bridge from the retired command.
			CUSTOM = vec4(
				control.r,
				STATE_SCHEDULED,
				max(command.a, 0.0),
				0.0
			);
			TRANSFORM[3].xy = source_position;
			VELOCITY = vec3(0.0);
		} else {
		float safe_margin = min(
			max(
				max(contact_radius_pixels, leaf_radius_pixels),
				free_sway_amplitude_max_pixels
			),
			stage_size.x * 0.49
		);
		float spawn_x = mix(
			safe_margin,
			stage_size.x - safe_margin,
			clamp(control.g, 0.0, 1.0)
		);
		float scheduled_y = (
			bank_direction > 0.0
				? -leaf_radius_pixels
				: stage_size.y + leaf_radius_pixels
		);
		// Park invisibly at the final bank entry point, not at a distant sentinel.
		// The extra hidden generation tick prevents interpolation from sweeping a
		// newly reused disk across the canvas, even for a zero-delay command.
		CUSTOM = vec4(control.r, STATE_SCHEDULED, max(command.r, 0.0), spawn_x);
		TRANSFORM[3].xy = vec2(spawn_x, scheduled_y);
		VELOCITY = vec3(0.0);
		}
	}

	COLOR = leaf_color(control.b);
	if (abs(CUSTOM.y - STATE_SCHEDULED) < 0.25) {
		if (generation_changed) {
			COLOR = vec4(0.0);
		} else {
			CUSTOM.z -= DELTA;
			if (CUSTOM.z <= 0.0) {
			if (explicit_source) {
				CUSTOM.y = STATE_FREE;
				CUSTOM.z = 0.0;
				CUSTOM.w = atan(
					source_inward_direction.y,
					source_inward_direction.x
				);
				TRANSFORM[3].xy = source_position;
				VELOCITY = vec3(
					source_inward_direction * free_speed_pixels * speed_factor,
					0.0
				);
			} else {
			float spawn_y = (
				bank_direction > 0.0
					? -leaf_radius_pixels
					: stage_size.y + leaf_radius_pixels
			);
			CUSTOM.y = STATE_FREE;
			CUSTOM.z = 0.0;
			TRANSFORM[3].xy = vec2(CUSTOM.w, spawn_y);
			VELOCITY = vec3(
				0.0,
				bank_direction * free_speed_pixels * speed_factor,
				0.0
			);
			}
			} else {
				COLOR = vec4(0.0);
			}
		}
	}
		if (abs(CUSTOM.y - STATE_FREE) < 0.25) {
			vec2 point = TRANSFORM[3].xy;
			if (explicit_source) {
				if (touches_water(point)) {
					// Preserve the supplied/steered confluence heading at the decisive
					// latch. The normal follower can then bend it along the local water.
					vec2 latch_direction = source_inward_direction;
					if (length(VELOCITY.xy) > 0.000001) {
						latch_direction = safe_direction(VELOCITY.xy);
					}
					CUSTOM.y = STATE_WATER_LATCHED;
					CUSTOM.z = hash11(
						float(INDEX) * 19.731 + control.r * 0.419
					) * max(follow_resample_interval_seconds, DELTA);
					CUSTOM.w = atan(latch_direction.y, latch_direction.x);
					VELOCITY = vec3(
						latch_direction * flow_speed_pixels * speed_factor,
						0.0
					);
				} else {
					float inward_distance = max(
						dot(
							point - source_position,
							source_inward_direction
						),
						0.0
					);
					// A left source receives a half-width search span while top and
					// bottom retain the legacy half-height minimum. Diagonal commands
					// use the projected half-stage span along their supplied direction.
					float source_center_span = dot(
						abs(source_inward_direction),
						stage_size * 0.5
					);
					float search_distance_limit = max(
						max(free_search_max_distance_pixels, source_center_span),
						1.0
					);
					if (inward_distance >= search_distance_limit) {
						CUSTOM.y = STATE_STOPPED_FADING;
						CUSTOM.z = 0.0;
						CUSTOM.w = 0.0;
						VELOCITY = vec3(0.0);
					} else {
						CUSTOM.z += DELTA;
						vec3 nearby_water = find_nearby_water_direction(
							point,
							source_inward_direction
						);
						vec2 free_direction = source_inward_direction;
						if (nearby_water.z >= 0.5) {
							free_direction = safe_direction(mix(
								source_inward_direction,
								nearby_water.xy,
								clamp(
									free_water_steering_strength,
									0.0,
									1.0
								)
							));
							float inward_alignment = dot(
								free_direction,
								source_inward_direction
							);
							if (inward_alignment < 0.20) {
								free_direction = safe_direction(
									free_direction
									+ source_inward_direction
										* (0.20 - inward_alignment)
								);
							}
						}
						vec2 steering_velocity = (
							free_direction * free_speed_pixels * speed_factor
						);
						float inward_step = max(
							dot(
								steering_velocity,
								source_inward_direction
							) * DELTA,
							0.0
						);
						float remaining_inward_distance = max(
							search_distance_limit - inward_distance,
							0.0
						);
						float movement_scale = (
							inward_step > 0.000001
								? min(
									remaining_inward_distance / inward_step,
									1.0
								)
								: 1.0
						);
						float movement_delta = DELTA * movement_scale;
						vec2 next_point = (
							point + steering_velocity * movement_delta
						);
						VELOCITY = vec3(steering_velocity, 0.0);
						TRANSFORM[3].xy = next_point;
					}
				}
			} else {
			if (touches_water(point)) {
			// The state transition is decisive and position-preserving. All attached
			// leaves adopt the known downstream (+X) orientation, regardless of bank.
			CUSTOM.y = STATE_WATER_LATCHED;
			CUSTOM.z = hash11(
				float(INDEX) * 19.731 + control.r * 0.419
			) * max(follow_resample_interval_seconds, DELTA);
				CUSTOM.w = 0.0;
				VELOCITY = vec3(flow_speed_pixels * speed_factor, 0.0, 0.0);
			} else {
				float inward_distance = (
					bank_direction > 0.0
						? max(point.y, 0.0)
						: max(stage_size.y - point.y, 0.0)
				);
					// Missing leaves must cross from their bank to the screen's true
					// horizontal midline before they can stop and fade. A larger configured
					// search distance is still honored for deliberate future variants.
					float search_distance_limit = max(
						max(free_search_max_distance_pixels, stage_size.y * 0.5),
						1.0
					);
				if (inward_distance >= search_distance_limit) {
					// A miss freezes at its bounded bank-to-center search point. The
					// visible disk then fades in place without any motion-history trail.
					CUSTOM.y = STATE_STOPPED_FADING;
					CUSTOM.z = 0.0;
					CUSTOM.w = 0.0;
					VELOCITY = vec3(0.0);
				} else {
				CUSTOM.z += DELTA;
				float sway_amplitude = mix(
				free_sway_amplitude_min_pixels,
				free_sway_amplitude_max_pixels,
				hash11(float(INDEX) * 5.173 + control.r * 0.071)
			);
			float sway_period = mix(
				free_sway_period_min_seconds,
				free_sway_period_max_seconds,
				hash11(float(INDEX) * 7.917 + control.r * 0.113)
			);
			float sway_phase = hash11(
				float(INDEX) * 11.371 + control.r * 0.193
			) * TAU_VALUE;
			// The short envelope makes the first sample position-preserving while
			// keeping every later displacement within the configured amplitude.
			float sway_envelope = smoothstep(
				0.0,
				0.25,
				CUSTOM.z
			);
				vec2 inward_direction = vec2(0.0, bank_direction);
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
					// Even a strength of one cannot send a searching leaf back out of
					// its originating bank; the configured inward-distance bound remains
					// guaranteed to complete.
					float inward_alignment = dot(free_direction, inward_direction);
					if (inward_alignment < 0.20) {
						free_direction = safe_direction(
							free_direction
							+ inward_direction * (0.20 - inward_alignment)
						);
					}
				}
				vec2 steering_velocity = (
					free_direction * free_speed_pixels * speed_factor
				);
				float inward_step = max(
					dot(steering_velocity, inward_direction) * DELTA,
					0.0
				);
				float remaining_inward_distance = max(
					search_distance_limit - inward_distance,
					0.0
				);
				float movement_scale = (
					inward_step > 0.000001
						? min(remaining_inward_distance / inward_step, 1.0)
						: 1.0
				);
				float movement_delta = DELTA * movement_scale;
				CUSTOM.w += steering_velocity.x * movement_delta;
				float sway_x = (
					CUSTOM.w
					+ sway_amplitude
					* sin(
						sway_phase
						+ CUSTOM.z * TAU_VALUE / max(sway_period, 0.001)
					)
					* sway_envelope
			);
				vec2 next_point = vec2(
					sway_x,
					point.y + steering_velocity.y * movement_delta
				);
				vec2 free_velocity = (
					(next_point - point) / max(movement_delta, 0.000001)
				);
				VELOCITY = vec3(free_velocity, 0.0);
				TRANSFORM[3].xy = next_point;
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
		// Smooth toward the cached heading, then restore configured speed. The
		// resample score retains a +X bias without forcing a leaf straight across
		// curved reservoir water.
		resolved_velocity = safe_direction(resolved_velocity) * attached_speed;
		vec2 next_point = point + resolved_velocity * DELTA;
		VELOCITY = vec3(resolved_velocity, 0.0);
		TRANSFORM[3].xy = next_point;

		// Attachment remains latched even through a temporary alpha gap. A latched
		// leaf cannot disappear through a bank or reconsider free motion; only the
		// downstream edge retires it after the complete disk has cleared.
			if (next_point.x > stage_size.x + leaf_radius_pixels) {
			CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
			VELOCITY = vec3(0.0);
			COLOR = vec4(0.0);
				TRANSFORM[3].xy = vec2(-10000.0);
			}
		} else if (abs(CUSTOM.y - STATE_STOPPED_FADING) < 0.25) {
			CUSTOM.z += DELTA;
			VELOCITY = vec3(0.0);
			float fade_seconds = max(stopped_fade_seconds, DELTA);
			COLOR.a *= 1.0 - smoothstep(0.0, fade_seconds, CUSTOM.z);
			if (CUSTOM.z >= fade_seconds) {
				CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
				VELOCITY = vec3(0.0);
				COLOR = vec4(0.0);
				TRANSFORM[3].xy = vec2(-10000.0);
			}
		} else if (abs(CUSTOM.y - STATE_SCHEDULED) >= 0.25) {
		CUSTOM = vec4(control.r, STATE_INACTIVE, 0.0, control.g);
		VELOCITY = vec3(0.0);
		COLOR = vec4(0.0);
		TRANSFORM[3].xy = vec2(-10000.0);
	}
	}
}
