shader_type particles;
render_mode keep_data, disable_force;

// Deliberately small, fixed-cost approximation of the CPU flow solver.
// Positions are native 1920 x 1080 stage pixels, with Godot's Y-down axis.
uniform vec2 stage_size = vec2(1920.0, 1080.0);
uniform float particle_slot_count = 300.0;
// A production stage can split the global head population across several
// independent draw layers. Defaults preserve the prototype's one-pool INDEX.
uniform float particle_index_stride = 1.0;
uniform float particle_index_offset = 0.0;
uniform bool force_palette_color = false;
uniform vec4 forced_palette_color = vec4(1.0);
uniform float base_speed = 300.0;
uniform float speed_variation = 0.14;
uniform float velocity_response = 12.0;
uniform float noise_strength = 52.0;
uniform float noise_scale = 0.010;
uniform float noise_speed = 0.72;
uniform float stage_phase = 0.0;
uniform float line_width_min = 1.0;
uniform float line_width_max = 5.0;
uniform float particle_alpha = 0.94;
uniform float trail_lifetime_seconds = 2.0;

// Per-river regime controls. When disabled, authored resource values retain
// their exact legacy meaning. When enabled, these 0..1 values become stable
// encounter/admission budgets without rebuilding any geometry.
uniform bool regime_profile_physics_enabled = false;
uniform bool regime_reservoir_override_enabled = false;
uniform bool regime_reservoir_present = true;
uniform bool regime_drain_override_enabled = false;
uniform bool regime_drain_power_override_enabled = false;
uniform bool regime_obstacle_override_enabled = false;
uniform bool regime_obstacle_power_override_enabled = false;
uniform float regime_reservoir_weight = 1.0;
uniform float regime_drain_weight = 1.0;
uniform float regime_drain_power = 1.0;
uniform float regime_obstacle_weight = 1.0;
uniform float regime_obstacle_power = 1.0;

uniform vec2 reservoir_center = vec2(1388.57, 771.43);
uniform float reservoir_geometry_revision = 0.0;
uniform float reservoir_radius = 223.71;
uniform float reservoir_influence = 86.0;
uniform float reservoir_swirl_speed = 145.0;
uniform float reservoir_orbit_radius_min_ratio = 0.05;
uniform float reservoir_orbit_radius_max_ratio = 0.78;
uniform float reservoir_orbit_full_speed_ratio = 0.46;
uniform float reservoir_orbit_max_angular_speed = 1.50;
uniform float reservoir_capture_y_ratio = 1.0;
uniform float reservoir_capture_edge_softness = 24.0;
uniform float reservoir_entry_min_incidence = 0.50;
uniform float reservoir_entry_pull_strength = 3.50;
uniform float reservoir_entry_min_inward_speed_ratio = 0.30;
uniform float reservoir_gate_staging_radius_ratio = 0.86;
// Production prewarm populates the river with this disabled. Heads that pass
// the reservoir during that phase are latched as bypasses, so capture begins
// empty instead of retroactively admitting prewarmed water.
uniform bool reservoir_admission_enabled = true;
uniform float gate_half_width = 15.0;
uniform bool gate_open = true;
uniform float trail_segment_overlap_pixels = 0.0;
uniform float trail_segment_max_length_pixels = 96.0;
uniform bool trail_recording_enabled = true;
// Runtime polygon geometry is packed once on the CPU into a shared 128 x 1
// floating-point data texture. Draw shaders never sample it; only this head
// simulation shader owns interaction physics and position updates.
uniform sampler2D interaction_data_texture : filter_nearest, repeat_disable;
uniform int interaction_count = 0;
uniform bool interaction_admission_enabled = true;
uniform int shoreline_count = 0;
uniform vec2 shoreline_inlet_y_range = vec2(28.0, 1052.0);
// The legacy shoreline_randomness profile value now drives a cheap vector field
// near the physical top/bottom edges. It bends flow without narrowing the river.
uniform float edge_turbulence_amount = 0.0;
uniform float edge_turbulence_band_pixels = 180.0;
uniform float edge_turbulence_wall_band_pixels = 40.0;
uniform float edge_turbulence_crossflow_ratio = 0.65;
uniform float edge_turbulence_streamwise_ratio = 0.08;
uniform float edge_turbulence_inward_ratio = 0.75;
// A bank-connected ABSORB polygon is a lateral field intake. Eligible heads
// bend toward its river-facing mouth, then continue through the field and leave
// the viewport vertically instead of teleporting or stopping in the channel.
uniform float bank_field_suction_reach_pixels = 300.0;
uniform float bank_field_suction_crossflow_ratio = 1.60;
uniform float bank_field_suction_streamwise_ratio = 0.0;
uniform float bank_field_min_withdrawal_speed_pixels = 540.0;
uniform float bank_field_capture_depth_pixels = 18.0;

const float STATE_FLOWING = 0.0;
const float STATE_ENTERING = 1.0;
const float STATE_RETAINED = 2.0;
const float STATE_EXITING = 3.0;
const float STATE_RELEASED = 4.0;
const float STATE_BYPASSING = 5.0;
const float STATE_GATE_STAGING = 6.0;
const float STATE_GATE_FLUSHING = 7.0;
const float STATE_ABSORBED = 8.0;
const float STATE_FIELD_DRAINING = 9.0;
const float RECYCLE_EPSILON = 0.0001;
const float RECYCLE_SAFETY_SECONDS = 0.067;
const int MAX_INTERACTION_POLYGONS = 8;
const int MAX_INTERACTION_VERTICES = 12;
const int INTERACTION_TEXELS_PER_POLYGON = 16;
const int INTERACTION_TEXTURE_WIDTH = 128;

float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453123);
}

vec4 interaction_record(int polygon_index, int record_offset) {
	float texture_x = (
		float(polygon_index * INTERACTION_TEXELS_PER_POLYGON + record_offset)
		+ 0.5
	) / float(INTERACTION_TEXTURE_WIDTH);
	return textureLod(interaction_data_texture, vec2(texture_x, 0.5), 0.0);
}

vec2 interaction_vertex(int polygon_index, int vertex_index) {
	return interaction_record(polygon_index, 4 + vertex_index).xy;
}

float cross_2d(vec2 first, vec2 second) {
	return first.x * second.y - first.y * second.x;
}

float segment_intersection_fraction(
	vec2 segment_start,
	vec2 segment_end,
	vec2 edge_start,
	vec2 edge_end
) {
	vec2 segment = segment_end - segment_start;
	vec2 edge = edge_end - edge_start;
	float denominator = cross_2d(segment, edge);
	if (abs(denominator) <= 0.000001) {
		return -1.0;
	}
	vec2 offset = edge_start - segment_start;
	float segment_fraction = cross_2d(offset, edge) / denominator;
	float edge_fraction = cross_2d(offset, segment) / denominator;
	if (
		segment_fraction >= 0.0
		&& segment_fraction <= 1.0
		&& edge_fraction >= 0.0
		&& edge_fraction <= 1.0
	) {
		return segment_fraction;
	}
	return -1.0;
}

bool point_in_interaction_polygon(
	int polygon_index,
	int vertex_count,
	vec2 point
) {
	bool inside = false;
	for (int vertex_index = 0; vertex_index < MAX_INTERACTION_VERTICES; vertex_index++) {
		if (vertex_index >= vertex_count) {
			break;
		}
		int following_index = vertex_index + 1;
		if (following_index >= vertex_count) {
			following_index = 0;
		}
		vec2 current = interaction_vertex(polygon_index, vertex_index);
		vec2 following = interaction_vertex(polygon_index, following_index);
		bool crosses_y = (current.y > point.y) != (following.y > point.y);
		float safe_y_delta = following.y - current.y;
		if (abs(safe_y_delta) < 0.000001) {
			safe_y_delta = safe_y_delta < 0.0 ? -0.000001 : 0.000001;
		}
		float crossing_x = (
			(following.x - current.x)
			* (point.y - current.y)
			/ safe_y_delta
			+ current.x
		);
		if (crosses_y && point.x < crossing_x) {
			inside = !inside;
		}
	}
	return inside;
}

vec2 approach_velocity(vec2 current, vec2 target, float delta_seconds) {
	if (velocity_response <= 0.0) {
		return target;
	}
	float response_alpha = 1.0 - exp(-velocity_response * delta_seconds);
	return mix(current, target, response_alpha);
}

float first_circle_intersection(
	vec2 segment_start,
	vec2 segment_end,
	float circle_radius
) {
	vec2 segment = segment_end - segment_start;
	float quadratic_a = dot(segment, segment);
	if (quadratic_a <= 0.000001) {
		return -1.0;
	}
	float quadratic_b = 2.0 * dot(segment_start, segment);
	float quadratic_c = dot(segment_start, segment_start) - circle_radius * circle_radius;
	float discriminant = quadratic_b * quadratic_b - 4.0 * quadratic_a * quadratic_c;
	if (discriminant < 0.0) {
		return -1.0;
	}
	float root = sqrt(discriminant);
	float inverse_denominator = 0.5 / quadratic_a;
	float first_fraction = (-quadratic_b - root) * inverse_denominator;
	float second_fraction = (-quadratic_b + root) * inverse_denominator;
	if (first_fraction >= 0.0 && first_fraction <= 1.0) {
		return first_fraction;
	}
	if (second_fraction >= 0.0 && second_fraction <= 1.0) {
		return second_fraction;
	}
	return -1.0;
}

float flow_noise(vec2 point, float seed) {
	float first = sin(
		point.x * noise_scale
		+ point.y * noise_scale * 0.73
		+ TIME * noise_speed
		+ seed * 6.2831853
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

vec4 line_color(float selector) {
	if (force_palette_color) {
		return vec4(
			forced_palette_color.rgb,
			forced_palette_color.a * particle_alpha
		);
	}
	if (selector < 0.142857) {
		return vec4(1.0, 1.0, 1.0, particle_alpha);
	}
	if (selector < 0.285714) {
		return vec4(0.918, 0.969, 0.933, particle_alpha);
	}
	if (selector < 0.428571) {
		return vec4(0.827, 0.937, 0.863, particle_alpha);
	}
	if (selector < 0.571428) {
		return vec4(0.675, 0.882, 0.686, particle_alpha);
	}
	if (selector < 0.714285) {
		return vec4(0.482, 0.812, 0.769, particle_alpha);
	}
	if (selector < 0.857142) {
		return vec4(0.290, 0.690, 0.882, particle_alpha);
	}
	return vec4(0.118, 0.565, 1.0, particle_alpha);
}

void start() {
	float particle_index = (
		float(INDEX) * particle_index_stride + particle_index_offset
	);
	float lane_seed = hash11(particle_index + stage_phase * 19.0);
	float style_seed = hash11(particle_index * 1.913 + stage_phase * 31.0);
	float enabled_slot_count = ceil(
		max(particle_slot_count, 1.0) * clamp(AMOUNT_RATIO, 0.0, 1.0)
	);

	// Custom particle shaders must apply GPUParticles2D.amount_ratio themselves.
	// Clear rejected slots so a later runtime increase starts them cleanly at the
	// inlet instead of reconnecting an old head position.
	bool slot_enabled = (
		AMOUNT_RATIO > 0.0 && particle_index < enabled_slot_count
	);
	if (!slot_enabled) {
		CUSTOM = vec4(0.0);
		VELOCITY = vec3(0.0);
		ACTIVE = false;
	}

	// keep_data lets a head survive the emitter's normal lifetime boundary.
	// CUSTOM.x is positive after first initialization, so later lifetime
	// restarts retain its simulation state; visible segments live independently.
	if (slot_enabled && CUSTOM.x <= 0.0) {
		// TRANSFORM[2].w is invisible in the 2D renderer and survives logical
		// recycling. It varies the inlet lane per lifecycle without CPU readback.
		float lifecycle_generation = max(TRANSFORM[2].w, 0.0);
		// Ordinary left-edge inlets vary their Y lane after each completed
		// lifecycle too. A reservoir-held head still owns its slot until release,
		// but once any other head recycles it can refill a formerly starved band
		// instead of returning forever to one fixed horizontal channel.
		lane_seed = hash11(
			particle_index
			+ stage_phase * 19.0
			+ lifecycle_generation * 53.137
		);
		TRANSFORM = mat4(1.0);
		// This invisible basis component owns the reservoir layout generation.
		// It survives normal 2D transform updates and is refreshed on admission.
		TRANSFORM[1].z = reservoir_geometry_revision;
		vec2 initial_direction = vec2(1.0, 0.0);
		float inlet_min_y = clamp(
			min(shoreline_inlet_y_range.x, shoreline_inlet_y_range.y),
			0.0,
			stage_size.y
		);
		float inlet_max_y = clamp(
			max(shoreline_inlet_y_range.x, shoreline_inlet_y_range.y),
			inlet_min_y,
			stage_size.y
		);
		TRANSFORM[3].xy = vec2(
			-18.0,
			mix(inlet_min_y, inlet_max_y, lane_seed)
		);
		// TRANSFORM[2].xy is unused by 2D drawing. Keep the previous completed
		// head position there so a segment also covers Godot's pre-process
		// velocity integration on the next fixed tick.
		TRANSFORM[2].xy = TRANSFORM[3].xy;
		// Reserved for the native-Y direction of a bank field after capture.
		TRANSFORM[2].z = 0.0;
		TRANSFORM[2].w = lifecycle_generation;
		float speed = base_speed * mix(
			1.0 - speed_variation,
			1.0 + speed_variation,
			hash11(particle_index * 2.371)
		);
		VELOCITY = vec3(initial_direction * speed, 0.0);
		COLOR = line_color(style_seed);
		// x: width, y: state timer, z: stable seed, w: lifecycle state.
		CUSTOM = vec4(
			mix(line_width_min, line_width_max, style_seed),
			0.0,
			lane_seed,
			STATE_FLOWING
		);
	}
}

void process() {
	float particle_index = (
		float(INDEX) * particle_index_stride + particle_index_offset
	);
	CUSTOM.y += DELTA;
	float style_seed = hash11(particle_index * 1.913 + stage_phase * 31.0);
	// Orbit placement must be independent of the inlet-lane seed in CUSTOM.z.
	// Reservoir admission necessarily selects a narrow Y band; reusing that
	// value here would silently exclude the configured near-center orbit range.
	float orbit_seed = hash11(
		particle_index * 5.713 + stage_phase * 43.0 + 0.317
	);
	CUSTOM.x = mix(
		line_width_min,
		line_width_max,
		style_seed
	);
	// keep_data preserves COLOR too, so refresh it for immediate runtime alpha.
	COLOR = line_color(style_seed);

	// A negative state is an elapsed recycle timer. Keep this head slot beyond
	// the edge until its already-emitted segments have faded, then reuse it for a
	// clean inlet emission without overlapping two logical lines in one slot.
	bool process_regular_flow = true;
	if (CUSTOM.w < 0.0) {
		process_regular_flow = false;
		CUSTOM.w -= DELTA;
		float trail_duration = max(trail_lifetime_seconds, 0.01);
		float recycle_age = -CUSTOM.w;
		if (recycle_age >= trail_duration + RECYCLE_SAFETY_SECONDS) {
			// This slot's previous segment set has now faded. Clearing CUSTOM.x
			// makes start() initialize it despite keep_data on its next emission.
			float next_lifecycle_generation = TRANSFORM[2].w + 1.0;
			CUSTOM = vec4(0.0);
			TRANSFORM[2].w = next_lifecycle_generation;
			VELOCITY = vec3(0.0);
			ACTIVE = false;
		} else {
			vec2 exit_point = TRANSFORM[3].xy;
			float exit_speed = base_speed * mix(
				1.0 - speed_variation,
				1.0 + speed_variation,
				hash11(particle_index * 2.371)
			);
			float exit_noise = flow_noise(exit_point, CUSTOM.z) * noise_strength;
			vec2 exit_velocity = vec2(
				exit_speed,
				exit_noise
			);
			// Fail-safe geometry can recycle from any edge. Force motion outward
			// immediately so the head cannot curve back onscreen while its native
			// history spends one trail lifetime fading beyond the boundary.
			if (exit_point.x < -96.0) {
				exit_velocity = vec2(-exit_speed, exit_noise);
			} else if (exit_point.y < -96.0) {
				exit_velocity = vec2(exit_noise, -exit_speed);
			} else if (exit_point.y > stage_size.y + 96.0) {
				exit_velocity = vec2(exit_noise, exit_speed);
			}
			VELOCITY = vec3(exit_velocity, 0.0);
			vec2 exit_direction = normalize(exit_velocity + vec2(0.0001, 0.0));
			vec2 exit_normal = vec2(-exit_direction.y, exit_direction.x);
			TRANSFORM[0].xy = exit_direction;
			// Width is applied as draw-shader coverage inside a fixed ribbon.
			TRANSFORM[1].xy = exit_normal;
			TRANSFORM[3].xy += exit_velocity * DELTA;
		}
	}
	// Absorption is a latched terminal state for this logical head. Its last
	// motion step emitted one immutable segment ending just inside the polygon;
	// now the head stays fixed until that complete tail has faded, then the slot
	// restarts cleanly at the inlet.
	if (CUSTOM.w > 7.5 && CUSTOM.w < 8.5) {
		process_regular_flow = false;
		VELOCITY = vec3(0.0);
		TRANSFORM[2].xy = TRANSFORM[3].xy;
		if (
			CUSTOM.y
			>= max(trail_lifetime_seconds, 0.01) + RECYCLE_SAFETY_SECONDS
		) {
			float next_lifecycle_generation = TRANSFORM[2].w + 1.0;
			CUSTOM = vec4(0.0);
			TRANSFORM[2].w = next_lifecycle_generation;
			ACTIVE = false;
		}
	}

	if (process_regular_flow) {
	vec2 point = TRANSFORM[3].xy;
	float speed = base_speed * mix(
		1.0 - speed_variation,
		1.0 + speed_variation,
		hash11(particle_index * 2.371)
	);
	vec2 target_velocity = vec2(
		speed,
		flow_noise(point, CUSTOM.z) * noise_strength
	);
	bool head_flowing = CUSTOM.w < 0.5;
	bool head_entering = CUSTOM.w > 0.5 && CUSTOM.w < 1.5;
	bool head_retained = CUSTOM.w > 1.5 && CUSTOM.w < 2.5;
	bool head_exiting = CUSTOM.w > 2.5 && CUSTOM.w < 3.5;
	bool head_released = CUSTOM.w > 3.5 && CUSTOM.w < 4.5;
	bool head_bypassing = CUSTOM.w > 4.5 && CUSTOM.w < 5.5;
	bool head_gate_staging = CUSTOM.w > 5.5 && CUSTOM.w < 6.5;
	bool head_gate_flushing = CUSTOM.w > 6.5 && CUSTOM.w < 7.5;
	bool head_field_draining = CUSTOM.w > 8.5 && CUSTOM.w < 9.5;
	if (head_field_draining) {
		float field_direction_y = clamp(TRANSFORM[2].z, -1.0, 1.0);
		float field_withdrawal_speed = max(
			speed * max(bank_field_suction_crossflow_ratio, 0.0),
			max(bank_field_min_withdrawal_speed_pixels, 0.0)
		);
		target_velocity = vec2(
			speed * max(bank_field_suction_streamwise_ratio, 0.0),
			field_direction_y * field_withdrawal_speed
		);
	}
	bool reservoir_geometry_changed = (
		abs(TRANSFORM[1].z - reservoir_geometry_revision) > 0.25
	);
	// Regime changes invalidate every live reservoir owner before the new center
	// is evaluated. Release in place: no transform or trail anchor is teleported,
	// and immutable orbit history fades while the head resumes downstream flow.
	if (
		reservoir_geometry_changed
		&& (
			head_entering
			|| head_retained
			|| head_exiting
			|| head_gate_staging
			|| head_gate_flushing
		)
	) {
		CUSTOM.y = 0.0;
		CUSTOM.w = STATE_RELEASED;
		TRANSFORM[1].z = reservoir_geometry_revision;
		head_entering = false;
		head_retained = false;
		head_exiting = false;
		head_gate_staging = false;
		head_gate_flushing = false;
		head_released = true;
	}
	if (reservoir_geometry_changed && head_bypassing) {
		CUSTOM.w = STATE_FLOWING;
		TRANSFORM[1].z = reservoir_geometry_revision;
		head_bypassing = false;
		head_flowing = true;
	}
	if (reservoir_geometry_changed && head_released) {
		TRANSFORM[1].z = reservoir_geometry_revision;
	}
	// A regime may explicitly remove both generic polygon categories while their
	// authored geometry remains packed for later regimes. Skip both polygon passes
	// in that state. Requiring both presence overrides preserves authored fallback
	// and still evaluates the shared records whenever either category is active.
	bool regime_removes_all_interactions = (
		regime_profile_physics_enabled
		&& regime_drain_override_enabled
		&& regime_obstacle_override_enabled
		&& clamp(regime_drain_weight, 0.0, 1.0) <= 0.0
		&& clamp(regime_obstacle_weight, 0.0, 1.0) <= 0.0
	);
	bool generic_interaction_pass_enabled = (
		interaction_admission_enabled
		&& interaction_count > 0
		&& !regime_removes_all_interactions
	);
	bool reservoir_live_admission = (
		reservoir_admission_enabled && regime_reservoir_present
	);
	// A zero regime budget removes the reservoir at runtime, including water
	// already owned by its state machine. Release those heads into downstream
	// flow; their immutable orbit trails then disappear over the normal trail
	// lifetime instead of leaving a permanently visible basin behind.
	if (
		!regime_reservoir_present
		&& (
			head_entering
			|| head_retained
			|| head_exiting
			|| head_gate_staging
			|| head_gate_flushing
		)
	) {
		CUSTOM.y = 0.0;
		CUSTOM.w = STATE_RELEASED;
		head_entering = false;
		head_retained = false;
		head_exiting = false;
		head_gate_staging = false;
		head_gate_flushing = false;
		head_released = true;
	}
	// BYPASSING only latches the one-time decision for a live reservoir. Once the
	// reservoir is removed there is no admission region left to clear, so resume
	// ordinary flow immediately without changing the head position or trail anchor.
	if (!regime_reservoir_present && head_bypassing) {
		CUSTOM.w = STATE_FLOWING;
		head_bypassing = false;
		head_flowing = true;
	}

	// Bank-connected fields and repellers share the same bounded interaction
	// records. Fields select the strongest eligible lateral intake instead of
	// summing several pulls; repellers retain their authored additive steering.
	// Immutable tails never re-simulate either influence.
	bool bank_field_suction_active = false;
	float bank_field_suction_strength = 0.0;
	vec2 bank_field_suction_velocity = vec2(0.0);
	if (generic_interaction_pass_enabled && head_flowing) {
		for (
			int polygon_index = 0;
			polygon_index < MAX_INTERACTION_POLYGONS;
			polygon_index++
		) {
			if (polygon_index >= interaction_count) {
				break;
			}
			vec4 interaction_parameters = interaction_record(polygon_index, 0);
			vec4 interaction_metadata = interaction_record(polygon_index, 1);
			vec4 interaction_bounds = interaction_record(polygon_index, 2);
			vec4 interaction_center_enabled = interaction_record(polygon_index, 3);
			bool absorb_mode = interaction_parameters.x < 0.5;
			bool repel_mode = !absorb_mode;
			if (interaction_center_enabled.w < 0.5) {
				continue;
			}
			int vertex_count = int(interaction_metadata.x + 0.5);
			if (absorb_mode) {
				float bank_direction_y = interaction_center_enabled.z;
				if (abs(bank_direction_y) < 0.5) {
					// Interior/controller absorbers keep their legacy swept-only path.
					continue;
				}
				if (regime_profile_physics_enabled && regime_drain_override_enabled) {
					float drain_selector = hash11(
						particle_index * 29.731
						+ TRANSFORM[2].w * 53.117
						+ stage_phase * 17.0
					);
					if (drain_selector >= clamp(regime_drain_weight, 0.0, 1.0)) {
						continue;
					}
				}
				float absorption_probability = clamp(
					interaction_parameters.y,
					0.0,
					1.0
				);
				if (
					regime_profile_physics_enabled
					&& regime_drain_power_override_enabled
				) {
					absorption_probability = clamp(
						regime_drain_power,
						0.0,
						1.0
					);
				}
				float absorption_selector = hash11(
					particle_index * 19.731
					+ interaction_metadata.z * 811.0
					+ stage_phase * 7.0
				);
				if (absorption_selector >= absorption_probability) {
					continue;
				}
				float suction_reach = max(
					interaction_metadata.y,
					max(bank_field_suction_reach_pixels, 0.0)
				);
				if (
					point.x < interaction_bounds.x - suction_reach
					|| point.x > interaction_bounds.z + suction_reach
					|| point.y < interaction_bounds.y - suction_reach
					|| point.y > interaction_bounds.w + suction_reach
				) {
					continue;
				}
				if (point_in_interaction_polygon(polygon_index, vertex_count, point)) {
					// A regime may appear around an existing head; do not consume it
					// retroactively without a real water-to-field mouth crossing.
					continue;
				}
				vec2 river_facing_outward = vec2(0.0, -bank_direction_y);
				float mouth_distance_squared = 1.0e20;
				vec2 mouth_point = point;
				bool mouth_found = false;
				for (
					int vertex_index = 0;
					vertex_index < MAX_INTERACTION_VERTICES;
					vertex_index++
				) {
					if (vertex_index >= vertex_count) {
						break;
					}
					int following_index = vertex_index + 1;
					if (following_index >= vertex_count) {
						following_index = 0;
					}
					vec2 edge_start = interaction_vertex(polygon_index, vertex_index);
					vec2 edge_end = interaction_vertex(polygon_index, following_index);
					vec2 edge = edge_end - edge_start;
					vec2 right_normal = normalize(
						vec2(edge.y, -edge.x) + vec2(0.000001, 0.0)
					);
					vec2 outward = (
						interaction_metadata.w >= 0.0 ? right_normal : -right_normal
					);
					if (dot(outward, river_facing_outward) < 0.35) {
						continue;
					}
					float edge_length_squared = max(dot(edge, edge), 0.000001);
					float edge_fraction = clamp(
						dot(point - edge_start, edge) / edge_length_squared,
						0.0,
						1.0
					);
					vec2 candidate_mouth_point = edge_start + edge * edge_fraction;
					float candidate_distance_squared = dot(
						point - candidate_mouth_point,
						point - candidate_mouth_point
					);
					if (candidate_distance_squared < mouth_distance_squared) {
						mouth_distance_squared = candidate_distance_squared;
						mouth_point = candidate_mouth_point;
						mouth_found = true;
					}
				}
				if (!mouth_found) {
					continue;
				}
				float mouth_distance = sqrt(max(mouth_distance_squared, 0.0));
				if (
					mouth_distance > suction_reach
					|| point.x > mouth_point.x + 24.0
				) {
					continue;
				}
				float proximity = 1.0 - smoothstep(
					0.0,
					max(suction_reach, 0.001),
					mouth_distance
				);
				float active_strength = clamp(
					proximity,
					0.0,
					1.0
				);
				if (active_strength <= bank_field_suction_strength) {
					continue;
				}
				// Aim beyond the mouth, not merely at its edge. This guarantees that
				// accepted water crosses into the trapezoid before the latched field
				// state resolves a crisp vertical quarter-turn toward the bank.
				vec2 through_mouth_point = mouth_point + vec2(
					0.0,
					bank_direction_y * max(bank_field_capture_depth_pixels * 2.0, 36.0)
				);
				vec2 suction_direction = normalize(
					through_mouth_point - point + vec2(0.0001, 0.0)
				);
				float withdrawal_speed = max(
					speed * max(bank_field_suction_crossflow_ratio, 0.0),
					max(bank_field_min_withdrawal_speed_pixels, 0.0)
				);
				float suction_x = max(
					speed * max(bank_field_suction_streamwise_ratio, 0.0),
					max(suction_direction.x, 0.0) * withdrawal_speed
				);
				bank_field_suction_velocity = vec2(
					suction_x,
					suction_direction.y * withdrawal_speed
				);
				bank_field_suction_strength = active_strength;
				bank_field_suction_active = true;
				continue;
			}

			float repellent_strength = clamp(interaction_parameters.z, 0.0, 1.0);
			if (regime_profile_physics_enabled && regime_obstacle_override_enabled) {
				float obstacle_selector = hash11(
					particle_index * 43.731
					+ TRANSFORM[2].w * 71.117
					+ stage_phase * 11.0
				);
				if (obstacle_selector >= clamp(regime_obstacle_weight, 0.0, 1.0)) {
					continue;
				}
			}
			if (
				regime_profile_physics_enabled
				&& regime_obstacle_power_override_enabled
			) {
				repellent_strength = clamp(regime_obstacle_power, 0.0, 1.0);
			}
			if (
				!repel_mode
				|| repellent_strength <= 0.0
			) {
				continue;
			}
			float influence = max(interaction_metadata.y, 0.0);
			if (
				point.x < interaction_bounds.x - influence
				|| point.x > interaction_bounds.z + influence
				|| point.y < interaction_bounds.y - influence
				|| point.y > interaction_bounds.w + influence
			) {
				continue;
			}
			bool point_inside = point_in_interaction_polygon(
				polygon_index,
				vertex_count,
				point
			);
			float closest_distance_squared = 1.0e20;
			vec2 closest_outward = vec2(-1.0, 0.0);
			for (
				int vertex_index = 0;
				vertex_index < MAX_INTERACTION_VERTICES;
				vertex_index++
			) {
				if (vertex_index >= vertex_count) {
					break;
				}
				int following_index = vertex_index + 1;
				if (following_index >= vertex_count) {
					following_index = 0;
				}
				vec2 edge_start = interaction_vertex(polygon_index, vertex_index);
				vec2 edge_end = interaction_vertex(polygon_index, following_index);
				vec2 edge = edge_end - edge_start;
				float edge_length_squared = max(dot(edge, edge), 0.000001);
				float edge_fraction = clamp(
					dot(point - edge_start, edge) / edge_length_squared,
					0.0,
					1.0
				);
				vec2 closest_point = edge_start + edge * edge_fraction;
				float distance_squared = dot(
					point - closest_point,
					point - closest_point
				);
				if (distance_squared < closest_distance_squared) {
					closest_distance_squared = distance_squared;
					vec2 right_normal = normalize(
						vec2(edge.y, -edge.x) + vec2(0.000001, 0.0)
					);
					closest_outward = (
						interaction_metadata.w >= 0.0
						? right_normal
						: -right_normal
					);
				}
			}
			float closest_distance = sqrt(max(closest_distance_squared, 0.0));
			if (!point_inside && closest_distance > influence) {
				continue;
			}
			float proximity = (
				point_inside
				? 1.0
				: 1.0 - smoothstep(0.0, max(influence, 0.001), closest_distance)
			);
			float vertical_side = (
				point.y < interaction_center_enabled.y ? -1.0 : 1.0
			);
			if (abs(point.y - interaction_center_enabled.y) < 1.0) {
				vertical_side = (
					hash11(particle_index * 3.173 + interaction_metadata.z * 97.0)
					< 0.5
					? -1.0
					: 1.0
				);
			}
			float active_strength = repellent_strength * proximity;
			target_velocity += (
				closest_outward * speed * 1.10
				+ vec2(0.0, vertical_side * speed * 0.85)
			) * active_strength;
			// Even a maximum repeller redirects flow instead of reversing the river.
			target_velocity.x = max(target_velocity.x, speed * 0.08);
		}
	}

	// Edge turbulence occupies the full-width river rather than displacing its
	// banks inward. The broad band is zero-mean; only the last thin wall band has
	// a gentle inward bias, preventing escape without herding flow to the center.
	float edge_amount = clamp(edge_turbulence_amount, 0.0, 1.0);
	float edge_inward_sign = point.y < stage_size.y * 0.5 ? 1.0 : -1.0;
	float edge_resolved_inward_floor = 0.0;
	if (head_flowing && edge_amount > 0.000001) {
		float edge_distance = max(
			min(point.y, stage_size.y - point.y),
			0.0
		);
		float edge_envelope = 1.0 - smoothstep(
			0.0,
			max(edge_turbulence_band_pixels, 0.001),
			edge_distance
		);
		float wall_envelope = 1.0 - smoothstep(
			0.0,
			max(edge_turbulence_wall_band_pixels, 0.001),
			edge_distance
		);
		float inlet_envelope = smoothstep(0.0, 32.0, point.x);
		float temporal_phase = CUSTOM.y * noise_speed * 1.65;
		float wave_a = sin(
			point.x * 0.021
			+ point.y * 0.006
			+ temporal_phase
			+ CUSTOM.z * 6.2831853
			+ stage_phase
		);
		float wave_b = sin(
			point.x * 0.013
			- point.y * 0.009
			- temporal_phase * 0.73
			+ CUSTOM.z * 11.173
			+ stage_phase * 1.37
		);
		vec2 eddy = vec2(
			(wave_a - wave_b) * 0.5,
			wave_a * 0.65 + wave_b * 0.35
		);
		target_velocity += inlet_envelope * edge_amount * speed * vec2(
			edge_envelope * edge_turbulence_streamwise_ratio * eddy.x,
			edge_envelope * edge_turbulence_crossflow_ratio * eddy.y
				+ wall_envelope * edge_turbulence_inward_ratio * edge_inward_sign
		);
		// Fixed noise can exceed low-flow speed. In the last wall band, enforce
		// a small inward component so active edge turbulence never ejects a head.
		edge_resolved_inward_floor = edge_amount * wall_envelope * max(
			speed * 0.10,
			max(noise_strength, 0.0) * 0.25
		);
		if (edge_inward_sign > 0.0) {
			target_velocity.y = max(target_velocity.y, edge_resolved_inward_floor);
		} else {
			target_velocity.y = min(target_velocity.y, -edge_resolved_inward_floor);
		}
		target_velocity.x = max(target_velocity.x, speed * 0.08);
	}
	// Field capture takes local precedence over the thin edge-containment floor.
	// This lets an eligible trail visibly turn through a bank mouth while the
	// ordinary shoreline field continues to protect every other edge location.
	if (head_flowing && bank_field_suction_active) {
		target_velocity = mix(
			target_velocity,
			bank_field_suction_velocity,
			clamp(bank_field_suction_strength * 1.15, 0.0, 1.0)
		);
		target_velocity.x = max(
			target_velocity.x,
			speed * max(bank_field_suction_streamwise_ratio, 0.0)
		);
		edge_resolved_inward_floor = 0.0;
	}

	vec2 from_reservoir = point - reservoir_center;
	// A released head is no longer eligible for reservoir capture. Keep it in
	// this bypass state for a full trail lifetime so every stored orbit sample
	// is replaced by downstream history before ordinary flow can resume. This
	// lightweight release path also runs while the reservoir itself is absent.
	if (head_released) {
		float release_clear_x = reservoir_radius + reservoir_influence;
		float outlet_weight = 1.0 - smoothstep(
			reservoir_radius * 0.75,
			release_clear_x,
			from_reservoir.x
		);
		vec2 released_velocity = vec2(speed * 1.45, -from_reservoir.y * 4.0);
		target_velocity = mix(target_velocity, released_velocity, outlet_weight);
		if (
			CUSTOM.y >= max(trail_lifetime_seconds, 0.01)
			&& from_reservoir.x > release_clear_x
		) {
			CUSTOM.w = STATE_FLOWING;
		}
	}
	vec2 resolved_velocity = approach_velocity(VELOCITY.xy, target_velocity, DELTA);
	if (head_field_draining) {
		// The swept mouth crossing is the corner: remove the last streamwise
		// velocity immediately so the recorded trail makes a readable 90° turn.
		resolved_velocity = target_velocity;
	}
	if (head_flowing && edge_resolved_inward_floor > 0.0) {
		if (edge_inward_sign > 0.0) {
			resolved_velocity.y = max(
				resolved_velocity.y,
				edge_resolved_inward_floor
			);
		} else {
			resolved_velocity.y = min(
				resolved_velocity.y,
				-edge_resolved_inward_floor
			);
		}
	}
	vec2 next_point = point + resolved_velocity * DELTA;
	// Regime removal keeps authored reservoir resources available for later use,
	// but ordinary and released heads need none of the orbit/admission state math.
	// The uniform branch is coherent across the complete particle dispatch.
	if (regime_reservoir_present) {
	float raw_distance_to_center = length(from_reservoir);
	float distance_to_center = max(raw_distance_to_center, 0.001);
	float center_fallback_angle = orbit_seed * 6.2831853;
	vec2 radial = (
		raw_distance_to_center > 0.001
		? from_reservoir / raw_distance_to_center
		: vec2(cos(center_fallback_angle), sin(center_fallback_angle))
	);
	vec2 tangent = vec2(-radial.y, radial.x);
	float orbit_radius_min_ratio = clamp(
		min(reservoir_orbit_radius_min_ratio, reservoir_orbit_radius_max_ratio),
		0.02,
		1.0
	);
	float orbit_radius_max_ratio = clamp(
		max(reservoir_orbit_radius_min_ratio, reservoir_orbit_radius_max_ratio),
		orbit_radius_min_ratio,
		1.0
	);
	float orbit_radius_ratio = mix(
		orbit_radius_min_ratio,
		orbit_radius_max_ratio,
		orbit_seed
	);
	float orbit_radius = reservoir_radius * orbit_radius_ratio;
	// Preserve the existing outer-ring speed while reducing linear speed in
	// direct proportion to small inner radii. The angular-speed cap protects
	// tiny runtime reservoirs and prevents tight 30 Hz turns from jittering.
	float orbit_tangent_scale = min(
		orbit_radius_ratio / max(reservoir_orbit_full_speed_ratio, 0.02),
		1.0
	);
	float orbit_tangent_speed = min(
		reservoir_swirl_speed * orbit_tangent_scale,
		max(reservoir_orbit_max_angular_speed, 0.01) * orbit_radius
	);
	float radial_error = distance_to_center - orbit_radius;
	vec2 orbit_velocity = (
		tangent * orbit_tangent_speed
		- radial * radial_error * 2.35
	);
	float gate_staging_ratio = clamp(
		max(reservoir_gate_staging_radius_ratio, orbit_radius_ratio),
		0.50,
		0.95
	);
	float gate_staging_radius = reservoir_radius * gate_staging_ratio;
	float gate_staging_tangent_speed = min(
		reservoir_swirl_speed,
		max(reservoir_orbit_max_angular_speed, 0.01)
			* max(distance_to_center, 0.01)
	);
	vec2 settled_gate_staging_velocity = (
		tangent * gate_staging_tangent_speed
		- radial * (distance_to_center - gate_staging_radius) * 2.35
	);
	float capture_half_height = max(
		reservoir_radius * clamp(reservoir_capture_y_ratio, 0.05, 1.0),
		0.01
	);
	float capture_edge_softness = clamp(
		reservoir_capture_edge_softness,
		0.01,
		capture_half_height
	);
	float aperture_fraction = clamp(
		gate_half_width / max(reservoir_radius, 0.01),
		0.0,
		1.0
	);
	float release_probability = aperture_fraction;
	bool aperture_fully_open = (
		gate_open && aperture_fraction >= 0.999
	);
	// Outlet geometry uses the same physical width as the probability. Clamping
	// at the radius makes a diameter-wide aperture the single meaningful maximum.
	float live_gate_half_width = clamp(
		gate_half_width,
		0.0,
		max(reservoir_radius, 0.01)
	);
	// A fully open gate is a hard-drain condition. Keep a positive transport
	// floor even if a controller has reduced swirl or entry pull to zero.
	float full_drain_tangent_speed = max(
		gate_staging_tangent_speed,
		max(speed * 0.35, 40.0)
	);
	vec2 full_drain_settled_velocity = (
		tangent * full_drain_tangent_speed
		- radial * (distance_to_center - gate_staging_radius) * 2.35
	);
	float active_entry_pull_strength = max(
		max(reservoir_entry_pull_strength, 0.0),
		aperture_fully_open ? 1.0 : 0.0
	);
	float active_entry_min_inward_ratio = max(
		clamp(reservoir_entry_min_inward_speed_ratio, 0.0, 1.0),
		aperture_fully_open ? 0.30 : 0.0
	);
	// At full aperture, an admitted ENTERING head must cross the physical rim in
	// finite time. An exposed orbit radius of 1.0 would otherwise let its inward
	// correction asymptotically vanish exactly at the rim and never become RETAINED.
	float active_entry_target_radius = (
		aperture_fully_open
		? min(orbit_radius, reservoir_radius * 0.90)
		: orbit_radius
	);
	float active_entry_radial_error = (
		distance_to_center - active_entry_target_radius
	);

	// Every +X approach receives exactly one geometry-only admission decision
	// before reservoir force begins. Reconstruct the exact crossing of an
	// upstream plane so fixed-step overshoot and changing flow noise cannot turn
	// an initial rejection into a later admission.
	float minimum_incidence = clamp(reservoir_entry_min_incidence, 0.0, 1.0);
	float incidence_capture_limit = (
		capture_half_height
		* sqrt(max(1.0 - minimum_incidence * minimum_incidence, 0.0))
	);
	float soft_edge_capture_limit = max(
		capture_half_height - capture_edge_softness * 0.5,
		0.01
	);
	float entry_capture_limit_y = min(
		incidence_capture_limit,
		soft_edge_capture_limit
	);
	float entry_decision_lead = max(32.0, speed * DELTA * 2.0);
	float entry_decision_x = -(
		reservoir_radius + reservoir_influence + entry_decision_lead
	);
	float entry_clear_x = (
		reservoir_radius + reservoir_influence + entry_decision_lead
	);
	// Prewarmed heads must not become newly eligible when admission turns on.
	// Give any head already traversing the reservoir region its one permanent
	// reject decision while admission is disabled.
	if (
		!reservoir_live_admission
		&& head_flowing
		&& from_reservoir.x >= entry_decision_x
		&& from_reservoir.x <= entry_clear_x
	) {
		CUSTOM.y = 0.0;
		CUSTOM.w = STATE_BYPASSING;
		TRANSFORM[1].z = reservoir_geometry_revision;
		head_flowing = false;
		head_bypassing = true;
	}
	vec2 previous_from_reservoir = from_reservoir - VELOCITY.xy * DELTA;
	bool reached_entry_decision = (
		reservoir_live_admission
		&& head_flowing
		&& from_reservoir.x >= entry_decision_x
		&& from_reservoir.x < 0.0
	);
	float decision_y = from_reservoir.y;
	float decision_segment_x = from_reservoir.x - previous_from_reservoir.x;
	if (
		previous_from_reservoir.x < entry_decision_x
		&& abs(decision_segment_x) > 0.0001
	) {
		float decision_fraction = clamp(
			(entry_decision_x - previous_from_reservoir.x) / decision_segment_x,
			0.0,
			1.0
		);
		decision_y = mix(
			previous_from_reservoir.y,
			from_reservoir.y,
			decision_fraction
		);
	}
	bool head_on_upstream_entry = (
		reached_entry_decision
		&& abs(decision_y) <= entry_capture_limit_y
	);
	if (
		head_on_upstream_entry
		&& regime_profile_physics_enabled
		&& regime_reservoir_override_enabled
	) {
		float reservoir_selector = hash11(
			particle_index * 73.171
			+ TRANSFORM[2].w * 37.717
			+ stage_phase * 19.0
			+ 0.271
		);
		head_on_upstream_entry = (
			reservoir_selector < clamp(regime_reservoir_weight, 0.0, 1.0)
		);
	}
	if (reached_entry_decision) {
		CUSTOM.y = 0.0;
		TRANSFORM[1].z = reservoir_geometry_revision;
		head_flowing = false;
		if (head_on_upstream_entry) {
			CUSTOM.w = STATE_ENTERING;
			head_entering = true;
		} else {
			// Rejection is as permanent as admission. This prevents a marginal
			// trajectory from failing at the entrance and becoming eligible later
			// after noise changes its angle closer to the reservoir center.
			CUSTOM.w = STATE_BYPASSING;
			head_bypassing = true;
		}
	}
	if (
		head_bypassing
		&& from_reservoir.x > entry_clear_x
	) {
		CUSTOM.w = STATE_FLOWING;
		head_bypassing = false;
		head_flowing = true;
	}

	// Geometry decides admission only once. From then on the state owns the
	// head, so leaving the soft influence band can never restore ordinary flow.
	if (head_entering || head_retained) {
		if (
			head_entering
			&& distance_to_center <= reservoir_radius
		) {
			CUSTOM.w = STATE_RETAINED;
			head_entering = false;
			head_retained = true;
		}
		float gate_sector_sine = clamp(
			live_gate_half_width / max(reservoir_radius, 0.01),
			0.0,
			1.0
		);
		bool orbit_settled = abs(radial_error) <= max(4.0, orbit_radius * 0.10);
		bool at_outlet_approach = (
			from_reservoir.x > 0.0
			&& abs(from_reservoir.y) / distance_to_center < gate_sector_sine
			&& orbit_settled
		);
		float release_tick = floor(CUSTOM.y * 30.0);
		// Gate width is the release control. A zero-width aperture releases none;
		// an aperture as wide as the reservoir diameter drains every retained head.
		float release_selector = hash11(
			particle_index * 17.137 + release_tick * 0.731
		);
		bool release_at_gate = (
			gate_open
			&& gate_half_width > 0.0
			&& head_retained
			&& (
				aperture_fully_open
				|| (
					at_outlet_approach
					&& release_selector < release_probability
				)
			)
		);
		if (release_at_gate) {
			// Selection first begins a trail-aware outward spiral. A near-center
			// orbit must never be connected directly to the outlet by a radial spoke.
			CUSTOM.w = STATE_GATE_STAGING;
			CUSTOM.y = 0.0;
			head_retained = false;
			head_gate_staging = true;
		}
		if (head_entering) {
			float entry_force = 1.0 - smoothstep(
				reservoir_radius,
				reservoir_radius + max(reservoir_influence, 0.01),
				distance_to_center
			);
			vec2 entry_velocity = (
				tangent
				* orbit_tangent_speed
				* 0.20
				- radial
					* max(active_entry_radial_error, 0.0)
					* active_entry_pull_strength
			);
			target_velocity = mix(target_velocity, entry_velocity, entry_force);
		} else {
			target_velocity = orbit_velocity;
		}
	}

	if (head_gate_staging) {
		// Selection commits the head immediately. It travels continuously outward
		// toward the staging ring; position is never teleported and no timer delays
		// its departure.
		float active_staging_radius = gate_staging_radius;
		float staging_tangent_speed = (
			aperture_fully_open
			? full_drain_tangent_speed
			: gate_staging_tangent_speed
		);
		vec2 staging_velocity = (
			tangent * staging_tangent_speed
			- radial
				* (distance_to_center - active_staging_radius)
				* 2.35
		);
		target_velocity = staging_velocity;
		float staging_tolerance = max(4.0, reservoir_radius * 0.025);
		if (
			abs(distance_to_center - gate_staging_radius) <= staging_tolerance
			// Fully open is also a hard drain command. This fallback prevents
			// numerical settling at the tolerance boundary from owning a head forever;
			// the flushing velocity continues the same outward correction.
			|| (aperture_fully_open && CUSTOM.y >= 2.0)
		) {
			CUSTOM.w = STATE_GATE_FLUSHING;
			CUSTOM.y = 0.0;
			head_gate_staging = false;
			head_gate_flushing = true;
		}
	}

	if (head_gate_flushing) {
		// The selected head is already committed. Continue around the outer ring
		// only as long as physically necessary to reach the live aperture.
		target_velocity = (
			aperture_fully_open
			? full_drain_settled_velocity
			: settled_gate_staging_velocity
		);
		float full_drain_orbit_seconds = max(
			6.2831853 * gate_staging_radius / max(full_drain_tangent_speed, 0.01),
			2.0
		);
		if (aperture_fully_open && CUSTOM.y >= full_drain_orbit_seconds + 0.5) {
			// Numerical aliasing or extreme runtime geometry must not own a flushing
			// head forever. After one complete circulation, seek the downstream half
			// continuously; containment still prevents an illegal rim crossing.
			target_velocity = vec2(
				max(speed * 1.25, 40.0),
				-from_reservoir.y * 3.0
			);
		}
		float live_corridor_half_width = live_gate_half_width;
		bool staged_at_outlet = (
			from_reservoir.x > 0.0
			&& abs(from_reservoir.y) < live_corridor_half_width
		);
		if (
			gate_open
			&& live_corridor_half_width > 0.0
			&& staged_at_outlet
		) {
			CUSTOM.w = STATE_EXITING;
			CUSTOM.y = 0.0;
			head_gate_flushing = false;
			head_exiting = true;
		}
	}

	if (head_exiting) {
		float live_corridor_half_width = live_gate_half_width;
		if (
			!gate_open
			|| live_corridor_half_width <= 0.0
			|| abs(from_reservoir.y) > live_corridor_half_width
		) {
			// Return a blocked final crossing to the outer flush ring. Restart the
			// dwell timer so aborted corridor history expires before another attempt.
			CUSTOM.w = STATE_GATE_FLUSHING;
			CUSTOM.y = 0.0;
			head_exiting = false;
			head_gate_flushing = true;
			target_velocity = settled_gate_staging_velocity;
		} else {
			// Center the head inside the live aperture before it reaches the rim.
			target_velocity = vec2(speed * 1.55, -from_reservoir.y * 5.0);
		}
	}

	resolved_velocity = approach_velocity(VELOCITY.xy, target_velocity, DELTA);
	bool entering_after_update = CUSTOM.w > 0.5 && CUSTOM.w < 1.5;
	bool retained_after_update = CUSTOM.w > 1.5 && CUSTOM.w < 2.5;
	bool exiting_after_update = CUSTOM.w > 2.5 && CUSTOM.w < 3.5;
	bool gate_staging_after_update = CUSTOM.w > 5.5 && CUSTOM.w < 6.5;
	bool gate_flushing_after_update = CUSTOM.w > 6.5 && CUSTOM.w < 7.5;
	if (entering_after_update) {
		// Admission is already latched, so the wave may bend the approach but may
		// never reverse its radial progress. The remaining-pull limit lets this
		// floor fade naturally at the assigned orbit radius and preserves a zero
		// entry-pull setting as an explicit runtime override.
		float requested_inward_speed = (
			speed * active_entry_min_inward_ratio
		);
		float remaining_inward_pull = (
			max(active_entry_radial_error, 0.0)
			* active_entry_pull_strength
		);
		float minimum_inward_speed = min(
			requested_inward_speed,
			remaining_inward_pull
		);
		float current_inward_speed = dot(resolved_velocity, -radial);
		if (current_inward_speed < minimum_inward_speed) {
			resolved_velocity += (
				-radial * (minimum_inward_speed - current_inward_speed)
			);
		}
	}
	next_point = point + resolved_velocity * DELTA;
	bool entering_inside_envelope = (
		entering_after_update
		&& distance_to_center <= reservoir_radius + reservoir_influence
	);
	if (entering_after_update && distance_to_center > reservoir_radius) {
		vec2 sweep_start = point - reservoir_center;
		vec2 sweep_end = next_point - reservoir_center;
		float rim_crossing = first_circle_intersection(
			sweep_start,
			sweep_end,
			reservoir_radius
		);
		if (rim_crossing >= 0.0) {
			// Promote at the exact upstream rim crossing, even when one high-speed
			// fixed step would otherwise tunnel completely through a small pool.
			vec2 rim_point = mix(sweep_start, sweep_end, rim_crossing);
			vec2 rim_normal = normalize(rim_point + vec2(0.0001, 0.0));
			next_point = reservoir_center + rim_normal * reservoir_radius * 0.995;
			CUSTOM.w = STATE_RETAINED;
			entering_after_update = false;
			entering_inside_envelope = false;
			retained_after_update = true;
			head_entering = false;
			head_retained = true;
		} else if (
			distance_to_center > reservoir_radius + reservoir_influence
			&& length(sweep_end) > reservoir_radius + reservoir_influence
		) {
			float envelope_radius = reservoir_radius + reservoir_influence;
			float envelope_crossing = first_circle_intersection(
				sweep_start,
				sweep_end,
				envelope_radius
			);
			if (envelope_crossing >= 0.0) {
				// A tangent/high-speed accepted segment may enter and leave the soft
				// envelope between samples. Hold it at the first crossing so its
				// already-latched admission cannot silently turn into a bypass.
				vec2 envelope_point = mix(
					sweep_start,
					sweep_end,
					envelope_crossing
				);
				vec2 envelope_normal = normalize(
					envelope_point + vec2(0.0001, 0.0)
				);
				next_point = (
					reservoir_center
					+ envelope_normal * max(envelope_radius - 0.01, 0.0)
				);
			}
		}
	}
	if (exiting_after_update) {
		// The EXITING state is still reservoir-owned. Keep its next sample inside
		// the aperture corridor and promote it only after a real rim crossing.
		float corridor_half_width = live_gate_half_width;
		vec2 gate_point = next_point - reservoir_center;
		gate_point.y = clamp(
			gate_point.y,
			-corridor_half_width,
			corridor_half_width
		);
		next_point = reservoir_center + gate_point;
		float gate_rim_x = sqrt(max(
			reservoir_radius * reservoir_radius - gate_point.y * gate_point.y,
			0.0
		));
		if (gate_point.x >= gate_rim_x) {
			CUSTOM.w = STATE_RELEASED;
			CUSTOM.y = 0.0;
			exiting_after_update = false;
			head_exiting = false;
			head_released = true;
		}
	}
	if (
		entering_inside_envelope
		|| retained_after_update
		|| gate_staging_after_update
		|| gate_flushing_after_update
	) {
		// ENTERING heads may not leave the capture envelope. Once a head has
		// crossed the physical rim, retained/staging/flush states use the rim
		// itself as a one-way boundary. Projection is at most one fixed-step
		// correction and prevents smoothing from carrying a head back out.
		float containment_radius = reservoir_radius * 0.995;
		if (entering_inside_envelope) {
			containment_radius = reservoir_radius + reservoir_influence;
		}
		vec2 next_from_reservoir = next_point - reservoir_center;
		float next_distance = length(next_from_reservoir);
		if (next_distance > containment_radius) {
			vec2 containment_normal = next_from_reservoir / max(next_distance, 0.001);
			float outward_speed = dot(resolved_velocity, containment_normal);
			if (outward_speed > 0.0) {
				resolved_velocity -= containment_normal * outward_speed;
			}
			next_point = point + resolved_velocity * DELTA;
			next_from_reservoir = next_point - reservoir_center;
			next_distance = length(next_from_reservoir);
			if (next_distance > containment_radius) {
				next_point = (
					reservoir_center
					+ next_from_reservoir / max(next_distance, 0.001)
					* containment_radius
				);
			}
		}
	}
	}

	// Swept polygon entry is resolved only for ordinary flowing heads. This both
	// prevents high-speed tunneling and keeps reservoir ownership decisive when
	// geometries overlap. Absorption is a single deterministic decision based on
	// stable particle/object identity; rejected heads get one small wave impulse.
	bool absorbed_after_update = false;
	if (generic_interaction_pass_enabled && CUSTOM.w < 0.5) {
		for (
			int polygon_index = 0;
			polygon_index < MAX_INTERACTION_POLYGONS;
			polygon_index++
		) {
			if (polygon_index >= interaction_count) {
				break;
			}
			vec4 interaction_parameters = interaction_record(polygon_index, 0);
			vec4 interaction_metadata = interaction_record(polygon_index, 1);
			vec4 interaction_bounds = interaction_record(polygon_index, 2);
			vec4 interaction_center_enabled = interaction_record(polygon_index, 3);
			if (interaction_center_enabled.w < 0.5) {
				continue;
			}
			float segment_min_x = min(point.x, next_point.x);
			float segment_max_x = max(point.x, next_point.x);
			float segment_min_y = min(point.y, next_point.y);
			float segment_max_y = max(point.y, next_point.y);
			if (
				segment_max_x < interaction_bounds.x
				|| segment_min_x > interaction_bounds.z
				|| segment_max_y < interaction_bounds.y
				|| segment_min_y > interaction_bounds.w
			) {
				continue;
			}
			int vertex_count = int(interaction_metadata.x + 0.5);
			if (point_in_interaction_polygon(polygon_index, vertex_count, point)) {
				// A runtime edit may place a polygon around an existing head. It should
				// influence future motion, but absorption still requires a real left-face
				// entry and never retroactively consumes an already-inside trail.
				continue;
			}
			bool absorb_mode = interaction_parameters.x < 0.5;
			float bank_direction_y = (
				absorb_mode ? interaction_center_enabled.z : 0.0
			);
			if (absorb_mode && regime_profile_physics_enabled && regime_drain_override_enabled) {
				float drain_selector = hash11(
					particle_index * 29.731
					+ TRANSFORM[2].w * 53.117
					+ stage_phase * 17.0
				);
				if (drain_selector >= clamp(regime_drain_weight, 0.0, 1.0)) {
					continue;
				}
			}
			if (!absorb_mode && regime_profile_physics_enabled && regime_obstacle_override_enabled) {
				float obstacle_selector = hash11(
					particle_index * 43.731
					+ TRANSFORM[2].w * 71.117
					+ stage_phase * 11.0
				);
				if (obstacle_selector >= clamp(regime_obstacle_weight, 0.0, 1.0)) {
					continue;
				}
			}
			float earliest_crossing = 2.0;
			vec2 crossing_outward = vec2(-1.0, 0.0);
			for (
				int vertex_index = 0;
				vertex_index < MAX_INTERACTION_VERTICES;
				vertex_index++
			) {
				if (vertex_index >= vertex_count) {
					break;
				}
				int following_index = vertex_index + 1;
				if (following_index >= vertex_count) {
					following_index = 0;
				}
				vec2 edge_start = interaction_vertex(polygon_index, vertex_index);
				vec2 edge_end = interaction_vertex(polygon_index, following_index);
				vec2 edge = edge_end - edge_start;
				vec2 right_normal = normalize(
					vec2(edge.y, -edge.x) + vec2(0.000001, 0.0)
				);
				vec2 outward = (
					interaction_metadata.w >= 0.0 ? right_normal : -right_normal
				);
				if (absorb_mode) {
					if (abs(bank_direction_y) > 0.5) {
						// A top/bottom field accepts water only through its horizontal,
						// river-facing mouth. Root and side edges are not intakes.
						vec2 river_facing_outward = vec2(0.0, -bank_direction_y);
						if (dot(outward, river_facing_outward) < 0.35) {
							continue;
						}
					} else if (outward.x >= -0.15) {
						// Freeform/controller absorbers preserve legacy upstream entry.
						continue;
					}
				}
				if (dot(next_point - point, outward) >= 0.0) {
					continue;
				}
				float crossing = segment_intersection_fraction(
					point,
					next_point,
					edge_start,
					edge_end
				);
				if (crossing >= 0.0 && crossing < earliest_crossing) {
					earliest_crossing = crossing;
					crossing_outward = outward;
				}
			}
			if (earliest_crossing > 1.0) {
				continue;
			}
			vec2 crossing_point = mix(point, next_point, earliest_crossing);
			if (absorb_mode) {
				float absorption_probability = clamp(
					interaction_parameters.y,
					0.0,
					1.0
				);
				if (
					regime_profile_physics_enabled
					&& regime_drain_power_override_enabled
				) {
					absorption_probability = clamp(
						regime_drain_power,
						0.0,
						1.0
					);
				}
				float absorption_selector = hash11(
					particle_index * 19.731
					+ interaction_metadata.z * 811.0
					+ stage_phase * 7.0
				);
				if (absorption_selector < absorption_probability) {
					// Enter through the actual crossed mouth, never by teleporting to
					// an object center. Bank fields keep recording vertically through
					// the trapezoid; freeform absorbers retain the terminal fade state.
					float capture_depth = (
						abs(bank_direction_y) > 0.5
						? max(bank_field_capture_depth_pixels, 1.5)
						: 1.5
					);
					next_point = crossing_point - crossing_outward * capture_depth;
					if (abs(bank_direction_y) > 0.5) {
						CUSTOM.w = STATE_FIELD_DRAINING;
						TRANSFORM[2].z = bank_direction_y;
					} else {
						CUSTOM.w = STATE_ABSORBED;
					}
					CUSTOM.y = 0.0;
					absorbed_after_update = true;
					break;
				}
				float wave_direction = (
					hash11(
						particle_index * 5.271
						+ interaction_metadata.z * 173.0
					)
					< 0.5
					? -1.0
					: 1.0
				);
				resolved_velocity = (
					(next_point - point) / max(DELTA, 0.0001)
				);
				resolved_velocity.y += (
					wave_direction
					* speed
					* clamp(interaction_parameters.w, 0.0, 1.0)
					* 0.35
				);
				resolved_velocity.x = max(resolved_velocity.x, speed * 0.08);
				next_point = point + resolved_velocity * DELTA;
			} else {
				float repellent_strength = clamp(
					interaction_parameters.z,
					0.0,
					1.0
				);
				if (
					regime_profile_physics_enabled
					&& regime_obstacle_power_override_enabled
				) {
					repellent_strength = clamp(
						regime_obstacle_power,
						0.0,
						1.0
					);
				}
				if (repellent_strength <= 0.0) {
					continue;
				}
				float vertical_side = (
					crossing_point.y < interaction_center_enabled.y ? -1.0 : 1.0
				);
				if (abs(crossing_point.y - interaction_center_enabled.y) < 1.0) {
					vertical_side = (
						hash11(
							particle_index * 3.173
							+ interaction_metadata.z * 97.0
						)
						< 0.5
						? -1.0
						: 1.0
					);
				}
				float remaining_step = length(next_point - crossing_point);
				vec2 redirected_direction = normalize(vec2(
					max(0.12, 0.38 + crossing_outward.x * 0.22),
					vertical_side * (0.85 + abs(crossing_outward.y) * 0.25)
				));
				vec2 redirected_endpoint = (
					crossing_point
					+ crossing_outward * 1.5
					+ redirected_direction * remaining_step
				);
				next_point = mix(
					next_point,
					redirected_endpoint,
					repellent_strength
				);
			}
		}
	}
	// Any swept rim/corridor/containment correction must become the stored
	// velocity and basis. Otherwise the next step starts from a velocity that
	// never produced the corrected position.
	resolved_velocity = (next_point - point) / max(DELTA, 0.0001);
	VELOCITY = vec3(resolved_velocity, 0.0);
	vec2 direction = normalize(resolved_velocity + vec2(0.0001, 0.0));
	vec2 normal = vec2(-direction.y, direction.x);
	TRANSFORM[0].xy = direction;
	TRANSFORM[1].xy = normal;

	// Godot's native GPUParticles2D trail re-simulates delayed copies of this
	// stateful shader and can therefore pull a tail section into the reservoir.
	// Emit one independent, stationary quad instead. Its transform is a literal
	// record of two consecutive completed head positions and can never be bent
	// later by reservoir physics or a runtime geometry change.
	vec2 recorded_start = TRANSFORM[2].xy;
	vec2 recorded_step = next_point - recorded_start;
	float recorded_length = length(recorded_step);
	float maximum_recorded_length = max(trail_segment_max_length_pixels, 0.01);
	bool advance_recording_anchor = true;
	// Do not suppress RESTART here. keep_data preserves a continuous head at
	// each normal eight-second lifetime rollover, so skipping that tick creates
	// one stationary, fixed-size hole. Cold/recycled starts synchronize both
	// recorded positions, while explicit resets disable recording during prewarm.
	if (
		trail_recording_enabled
		&& recorded_length > 0.0001
		&& recorded_length <= maximum_recorded_length
	) {
		vec2 recorded_direction = recorded_step / recorded_length;
		vec2 recorded_normal = vec2(-recorded_direction.y, recorded_direction.x);
		// A small longitudinal overlap closes subpixel raster seams without
		// making every 30 Hz junction visibly brighter through alpha overdraw.
		float overlap = max(trail_segment_overlap_pixels, 0.0);
		mat4 segment_transform = mat4(1.0);
		// The emitted texture is one pixel wide and eight pixels tall.
		segment_transform[0].xy = (
			recorded_direction * (recorded_length + overlap * 2.0)
		);
		segment_transform[1].xy = recorded_normal;
		segment_transform[3].xy = (recorded_start + next_point) * 0.5;
		bool segment_emitted = emit_subparticle(
			segment_transform,
			vec3(0.0),
			COLOR,
			vec4(CUSTOM.x, 0.0, 0.0, 0.0),
			FLAG_EMIT_POSITION
				| FLAG_EMIT_ROT_SCALE
				| FLAG_EMIT_VELOCITY
				| FLAG_EMIT_COLOR
				| FLAG_EMIT_CUSTOM
		);
		// A sub-emitter can reject a batch while reusable slots change generation.
		// Retain the old anchor on failure; the next successful quad spans the
		// skipped sample instead of leaving a permanent one-segment hole.
		advance_recording_anchor = segment_emitted;
	}
	// A discontinuity longer than the safety bound intentionally creates a gap,
	// never a bridge. Disabled recording also follows the head during prewarm.
	if (advance_recording_anchor || absorbed_after_update) {
		TRANSFORM[2].xy = next_point;
	}
	TRANSFORM[3].xy = next_point;

	// Begin head recycling when it first crosses any stage exit. Already emitted
	// segments are independent particles and continue fading if this head stops.
	bool released_before_recycle = CUSTOM.w > 3.5 && CUSTOM.w < 4.5;
	if (
		(
			TRANSFORM[3].x < -96.0
			|| TRANSFORM[3].x > stage_size.x
			|| TRANSFORM[3].y < -96.0
			|| TRANSFORM[3].y > stage_size.y + 96.0
		)
		&& (
			// Ordinary and reservoir-owned states recycle immediately as an
			// offstage fail-safe. RELEASED preserves its historical flush delay.
			!released_before_recycle
			|| CUSTOM.y >= max(trail_lifetime_seconds, 0.01)
		)
	) {
		CUSTOM.w = -RECYCLE_EPSILON;
	}
	}
}
