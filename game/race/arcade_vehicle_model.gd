class_name ArcadeVehicleModel
extends RefCounted
## Deterministic fixed-step arcade vehicle authority.
## Perspective cameras consume this state without changing its 2D route physics.

const RaceInputType := preload("res://game/race/race_input.gd")
const VehicleConfigType := preload("res://game/race/vehicle_config.gd")
const VehicleStateType := preload("res://game/race/vehicle_state.gd")

const FIXED_HZ: int = 60
const FIXED_DT: float = 1.0 / float(FIXED_HZ)
const MAX_STEP_DT: float = 1.0 / 15.0
const CONTACT_RESTITUTION: float = 0.18
const CONTACT_FRICTION: float = 0.24
const CONTACT_SEPARATION_BIAS: float = 0.002
const CONTACT_PAIR_POSITION_ITERATIONS: int = 4
const MAX_CONTACT_DELTA_SPEED: float = 380.0
const REVERSE_ENGAGE_SPEED: float = 1.0
const FORWARD_GEAR_COUNT: int = VehicleConfigType.FORWARD_GEAR_COUNT
const WORLD_UNIT_TO_METERS: float = 0.30
const STANDARD_GRAVITY: float = 9.80665
const BRIDGE_HEIGHT_METERS: float = 6.0
# Crest airtime is deliberately a short release of the suspension/downforce
# constraint, not a jump-boost mechanic. The speed gate is 115.2 km/h and the
# launch is capped so the ballistic arc normally lands on the same flat deck.
const MIN_CREST_LAUNCH_SPEED_MPS: float = 32.0
const MIN_CREST_LAUNCH_VERTICAL_SPEED_MPS: float = 0.75
const MAX_CREST_LAUNCH_VERTICAL_SPEED_MPS: float = 3.2
const CREST_DECK_RUNWAY_FRACTION: float = 0.82
const CREST_ELEVATION_EPSILON: float = 0.0002
const LANDING_EPSILON_METERS: float = 0.001

var config: VehicleConfig
# Opt-in shadow check used only by focused equivalence tests. Disabled authority
# pays no legacy projection cost.
var projection_equivalence_probe_enabled: bool = false
var last_projection_equivalence_match: bool = true
# Diagnostic only: RaceDirector passes each model's already-sanitized immutable
# config, so steady-state pack collisions must not allocate replacement configs.
var contact_config_sanitization_count: int = 0


func _init(source_config: VehicleConfig = null) -> void:
	config = (source_config if source_config != null else VehicleConfigType.new()).sanitized()


func create_state(
		vehicle_id: StringName,
		track: RaceTrackQuery,
		distance_along: float = 0.0,
		lateral_offset: float = 0.0
	) -> VehicleState:
	var state := VehicleStateType.new()
	state.vehicle_id = vehicle_id
	state.gear = 1
	state.engine_rpm = config.idle_rpm
	state.nitro_energy = config.nitro_capacity
	if track == null or not track.is_valid():
		return state
	var sample := track.sample_at_distance(distance_along)
	var safe_lateral := clampf(
		lateral_offset,
		-maxf(0.0, track.track_width * 0.5 - config.vehicle_radius),
		maxf(0.0, track.track_width * 0.5 - config.vehicle_radius)
	)
	state.position = sample["position"] + sample["normal"] * safe_lateral
	state.heading = Vector2.RIGHT.angle_to(sample["tangent"])
	state.track_distance = float(sample["distance_along"])
	state.lateral_offset = safe_lateral
	_apply_surface_context(state, sample)
	state.quantize_authority()
	return state


func step_fixed(state: VehicleState, command: RaceInput, track: RaceTrackQuery) -> bool:
	return step(state, command, track, FIXED_DT)


func step(
		state: VehicleState,
		command: RaceInput,
		track: RaceTrackQuery,
		delta: float
	) -> bool:
	if state == null or track == null or not track.is_valid():
		return false
	if is_nan(delta) or is_inf(delta) or delta <= 0.0 or delta > MAX_STEP_DT:
		return false
	if not state.is_finite():
		return false
	var safe_command := command.duplicate_input() if command != null else RaceInputType.new()
	safe_command.sanitize()
	var projection_window := _projection_window(state, track, delta)
	var before := track.nearest_continuous(
		state.position,
		state.track_distance,
		state.track_collision_layer,
		projection_window
	)
	if before.is_empty():
		return false
	var road_limit := maxf(0.1, track.track_width * 0.5 - config.vehicle_radius)
	state.is_offtrack = absf(float(before["signed_lateral"])) > road_limit
	_update_nitro(state, safe_command, delta)

	var forward := state.forward()
	var right := Vector2(-forward.y, forward.x)
	var longitudinal_speed := state.velocity.dot(forward)
	var lateral_speed := state.velocity.dot(right)
	_update_steering_input(state, safe_command.steer, delta)
	_update_drivetrain(state, safe_command, longitudinal_speed)
	var engine_factor := config.offtrack_engine_factor if state.is_offtrack else 1.0
	var longitudinal_acceleration := 0.0
	state.wheel_slip = 0.0
	if safe_command.brake > 0.0:
		if longitudinal_speed > REVERSE_ENGAGE_SPEED:
			# Carbon-brake strength rises with aerodynamic load. The bounded move
			# toward zero is the ABS/accessibility layer: a fixed tick cannot lock
			# the wheels and numerically overshoot straight into reverse.
			var brake_capacity := config.brake_deceleration \
				+ config.brake_downforce_coefficient * longitudinal_speed * longitudinal_speed
			longitudinal_speed = move_toward(
				longitudinal_speed, 0.0,
				safe_command.brake * brake_capacity * delta
			)
		else:
			# The conventional brake pedal engages reverse only after forward
			# motion has settled. Reverse is deliberately single-speed and tame.
			longitudinal_acceleration -= safe_command.brake * config.reverse_acceleration
	elif safe_command.throttle > 0.0:
		var requested_drive := _requested_drive_acceleration(
			state, safe_command.throttle
		) * engine_factor
		var traction_capacity := config.launch_traction_acceleration \
			+ config.downforce_traction_coefficient * longitudinal_speed * longitudinal_speed
		if state.is_offtrack:
			traction_capacity *= config.offtrack_traction_factor
		state.wheel_slip = maxf(
			0.0,
			(requested_drive - traction_capacity) / maxf(traction_capacity, 1.0)
		)
		longitudinal_acceleration += minf(requested_drive, traction_capacity)
	else:
		var rolling_and_engine_brake := config.coast_deceleration
		if state.gear > 0 and longitudinal_speed > 0.0:
			rolling_and_engine_brake += config.engine_brake_deceleration * _engine_brake_factor(state)
		longitudinal_speed = move_toward(
			longitudinal_speed, 0.0, rolling_and_engine_brake * delta
		)
	if state.nitro_active:
		longitudinal_acceleration += config.nitro_acceleration * engine_factor
	# Quadratic drag always opposes travel, including reverse.
	longitudinal_acceleration -= (
		config.aerodynamic_drag * longitudinal_speed * absf(longitudinal_speed)
	)
	longitudinal_speed += longitudinal_acceleration * delta
	if state.is_offtrack:
		# Sand/gravel should punish a fast excursion without becoming an invisible
		# handbrake. Resistance grows smoothly with speed, while the low-speed term
		# stays below available first-gear/reverse force so the driver can steer and
		# manually crawl back to asphalt.
		longitudinal_speed = move_toward(
			longitudinal_speed,
			0.0,
			_offtrack_resistance(absf(longitudinal_speed)) * delta
		)
	var maximum_speed := config.maximum_forward_speed
	if state.nitro_active:
		maximum_speed += config.nitro_max_speed_bonus
	longitudinal_speed = clampf(longitudinal_speed, -config.maximum_reverse_speed, maximum_speed)

	# Apply drive/brake along the pre-steer chassis direction, then rotate the
	# chassis independently. Re-projecting the unchanged world velocity after the
	# yaw step creates real, bounded tyre slip instead of rotating velocity for free.
	state.velocity = forward * longitudinal_speed + right * lateral_speed
	var absolute_speed := absf(longitudinal_speed)
	var maximum_steer_angle := config.maximum_steering_angle_for_speed(absolute_speed)
	var front_wheel_angle := state.steering_input * maximum_steer_angle
	var requested_yaw_rate := longitudinal_speed / config.wheelbase * tan(front_wheel_angle)
	var lateral_capacity := lateral_acceleration_capacity(absolute_speed, state.is_offtrack)
	var maximum_yaw_rate := lateral_capacity / maxf(absolute_speed, 12.0)
	var yaw_rate := clampf(requested_yaw_rate, -maximum_yaw_rate, maximum_yaw_rate)
	state.heading = wrapf(state.heading + yaw_rate * delta, -PI, PI)
	forward = state.forward()
	right = Vector2(-forward.y, forward.x)
	longitudinal_speed = state.velocity.dot(forward)
	lateral_speed = state.velocity.dot(right)
	state.slip_angle = atan2(lateral_speed, maxf(absf(longitudinal_speed), 1.0))
	var grip := config.lateral_grip
	if absolute_speed >= config.drift_start_speed and absf(safe_command.steer) >= 0.45:
		grip = config.drift_grip
	if state.is_offtrack:
		grip *= 0.55
	var excess_slip := maxf(0.0, absf(state.slip_angle) / config.peak_slip_angle - 1.0)
	var slide_grip_factor := lerpf(
		1.0, config.minimum_slide_grip, clampf(excess_slip * 0.55, 0.0, 1.0)
	)
	var desired_lateral_acceleration := -lateral_speed * grip
	state.lateral_acceleration = clampf(
		desired_lateral_acceleration,
		-lateral_capacity * slide_grip_factor,
		lateral_capacity * slide_grip_factor
	)
	lateral_speed += state.lateral_acceleration * delta
	state.velocity = forward * longitudinal_speed + right * lateral_speed
	state.position += state.velocity * delta
	# Wall resolution already performs the authoritative contextual projection.
	# Reusing it avoids a second identical route-window scan on every fixed tick.
	var after := _resolve_wall(state, track, projection_window)
	if after.is_empty():
		after = track.nearest_continuous(
			state.position,
			state.track_distance,
			state.track_collision_layer,
			projection_window
		)
	if after.is_empty():
		return false
	if projection_equivalence_probe_enabled:
		var legacy_after := track.nearest_continuous(
			state.position,
			state.track_distance,
			state.track_collision_layer,
			projection_window
		)
		last_projection_equivalence_match = not legacy_after.is_empty() \
			and _projection_authority_signature(after) \
			== _projection_authority_signature(legacy_after)
	state.track_distance = float(after["distance_along"])
	state.lateral_offset = float(after["signed_lateral"])
	_update_vertical_motion(
		state,
		before,
		after,
		track,
		delta,
		absf(state.lateral_offset) <= road_limit
	)
	_apply_surface_context(state, after)
	state.is_offtrack = absf(state.lateral_offset) > road_limit
	_refresh_engine_rpm(state, safe_command.throttle, state.forward_speed())
	state.simulation_tick += 1
	state.quantize_authority()
	return state.is_finite()


func _update_steering_input(state: VehicleState, requested: float, delta: float) -> void:
	var target := clampf(requested, -1.0, 1.0)
	var response := config.steering_return_rate if absf(target) <= 0.0001 \
		else config.steering_input_rate
	state.steering_input = move_toward(state.steering_input, target, response * delta)


func _update_drivetrain(
		state: VehicleState,
		command: RaceInput,
		longitudinal_speed: float
	) -> void:
	var speed := absf(longitudinal_speed)
	if state.shift_ticks_remaining > 0:
		state.shift_ticks_remaining -= 1
		_refresh_engine_rpm(state, command.throttle, longitudinal_speed)
		return

	if longitudinal_speed < -REVERSE_ENGAGE_SPEED:
		if command.throttle > 0.02 and command.brake <= 0.02:
			# The accelerator requests forward travel. Select first and let its
			# positive tractive force settle reverse motion through neutral before
			# accelerating forward; there is no dead gear state.
			_set_direct_gear(state, 1)
		else:
			_set_direct_gear(state, -1)
			_refresh_engine_rpm(state, command.brake, longitudinal_speed)
			return
	if longitudinal_speed <= REVERSE_ENGAGE_SPEED \
			and command.brake > 0.0 and command.throttle <= 0.02:
		_set_direct_gear(state, -1)
		_refresh_engine_rpm(state, command.brake, longitudinal_speed)
		return
	if state.gear <= 0:
		_set_direct_gear(state, 1)

	state.gear = clampi(state.gear, 1, FORWARD_GEAR_COUNT)
	_refresh_engine_rpm(state, command.throttle, longitudinal_speed)
	if state.gear < FORWARD_GEAR_COUNT and state.engine_rpm >= config.upshift_rpm:
		_begin_shift(state, state.gear + 1)
		_refresh_engine_rpm(state, command.throttle, longitudinal_speed)
		return
	if state.gear > 1 and speed < config.gear_downshift_speeds[state.gear - 1]:
		_begin_shift(state, state.gear - 1)
		_refresh_engine_rpm(state, command.throttle, longitudinal_speed)


func _set_direct_gear(state: VehicleState, next_gear: int) -> void:
	var bounded := clampi(next_gear, -1, FORWARD_GEAR_COUNT)
	if state.gear != bounded:
		state.gear = bounded
		state.shift_serial += 1
	state.shift_ticks_remaining = 0


func _begin_shift(state: VehicleState, next_gear: int) -> void:
	var bounded := clampi(next_gear, 1, FORWARD_GEAR_COUNT)
	if state.gear == bounded:
		return
	state.gear = bounded
	state.shift_ticks_remaining = maxi(1, roundi(config.shift_duration * float(FIXED_HZ)))
	state.shift_serial += 1


func _refresh_engine_rpm(
		state: VehicleState,
		pedal: float,
		longitudinal_speed: float
	) -> void:
	var speed := absf(longitudinal_speed)
	if state.gear < 0:
		var reverse_ratio := clampf(speed / maxf(config.maximum_reverse_speed, 1.0), 0.0, 1.0)
		state.engine_rpm = lerpf(
			config.idle_rpm, config.upshift_rpm * 0.72, reverse_ratio
		)
		return
	if state.gear == 0:
		state.engine_rpm = lerpf(
			config.idle_rpm, config.launch_rpm, clampf(pedal, 0.0, 1.0)
		)
		return
	var speed_limit := config.gear_speed_limits[clampi(
		state.gear - 1, 0, FORWARD_GEAR_COUNT - 1
	)]
	var coupled_rpm := config.redline_rpm * speed / maxf(speed_limit, 1.0)
	var launch_rpm := lerpf(
		config.idle_rpm, config.launch_rpm, clampf(pedal, 0.0, 1.0)
	) if state.gear == 1 and speed < config.gear_speed_limits[0] * 0.30 else config.idle_rpm
	state.engine_rpm = clampf(
		maxf(coupled_rpm, launch_rpm), config.idle_rpm, config.redline_rpm
	)


func _requested_drive_acceleration(state: VehicleState, throttle: float) -> float:
	if state.gear <= 0:
		return 0.0
	var rpm_range := maxf(config.redline_rpm - config.idle_rpm, 1.0)
	var normalized_rpm := clampf((state.engine_rpm - config.idle_rpm) / rpm_range, 0.0, 1.0)
	var power_band := lerpf(0.72, 1.0, normalized_rpm / 0.55) \
		if normalized_rpm <= 0.55 \
		else lerpf(1.0, 0.80, (normalized_rpm - 0.55) / 0.45)
	var gear_factor := config.gear_acceleration_factors[clampi(
		state.gear - 1, 0, FORWARD_GEAR_COUNT - 1
	)]
	var shift_factor := config.shift_torque_factor \
		if state.shift_ticks_remaining > 0 else 1.0
	return clampf(throttle, 0.0, 1.0) * config.engine_acceleration \
		* gear_factor * power_band * shift_factor


func _engine_brake_factor(state: VehicleState) -> float:
	var rpm_range := maxf(config.redline_rpm - config.idle_rpm, 1.0)
	var normalized_rpm := clampf((state.engine_rpm - config.idle_rpm) / rpm_range, 0.0, 1.0)
	return lerpf(0.35, 1.0, normalized_rpm)


func lateral_acceleration_capacity(speed: float, offtrack: bool = false) -> float:
	var bounded_speed := clampf(absf(speed), 0.0, config.maximum_forward_speed)
	var capacity := config.mechanical_lateral_acceleration \
		+ config.downforce_lateral_coefficient * bounded_speed * bounded_speed
	return capacity * 0.46 if offtrack else capacity


func _offtrack_resistance(speed: float) -> float:
	var ratio := clampf(
		absf(speed) / maxf(config.offtrack_drag_reference_speed, 1.0), 0.0, 1.0
	)
	var smooth_ratio := ratio * ratio * (3.0 - 2.0 * ratio)
	return lerpf(
		config.offtrack_rolling_resistance,
		config.offtrack_drag,
		smooth_ratio
	)


static func world_lateral_acceleration_to_g(world_acceleration: float) -> float:
	if is_nan(world_acceleration) or is_inf(world_acceleration):
		return 0.0
	return absf(world_acceleration) * WORLD_UNIT_TO_METERS / STANDARD_GRAVITY


func resolve_vehicle_contact(
		first: VehicleState,
		second: VehicleState,
		second_config: VehicleConfig = null,
		second_config_is_sanitized: bool = false
	) -> bool:
	if first == null or second == null or first == second:
		return false
	if not first.is_finite() or not second.is_finite():
		return false
	if (first.track_collision_mask & second.track_collision_layer) == 0 \
			or (second.track_collision_mask & first.track_collision_layer) == 0:
		return false
	var other_config := config
	if second_config != null:
		if second_config_is_sanitized:
			other_config = second_config
		else:
			other_config = second_config.sanitized()
			contact_config_sanitization_count += 1
	var contact := _vehicle_contact_geometry(first, second, config, other_config)
	if contact.is_empty() or float(contact["penetration"]) <= 0.0:
		return false
	var normal: Vector2 = contact["normal"]
	var first_inverse_mass := 1.0 / config.mass
	var second_inverse_mass := 1.0 / other_config.mass
	var inverse_mass_sum := first_inverse_mass + second_inverse_mass
	var relative_normal_speed := (second.velocity - first.velocity).dot(normal)
	var impact_speed := maxf(0.0, -relative_normal_speed)
	_record_vehicle_contact(first, second, contact, impact_speed, normal)
	_record_vehicle_contact(second, first, contact, impact_speed, -normal)
	if relative_normal_speed < 0.0:
		var impulse := -(1.0 + CONTACT_RESTITUTION) * relative_normal_speed \
			/ inverse_mass_sum
		var maximum_impulse := MAX_CONTACT_DELTA_SPEED / maxf(
			first_inverse_mass, second_inverse_mass
		)
		impulse = minf(impulse, maximum_impulse)
		first.velocity -= normal * impulse * first_inverse_mass
		second.velocity += normal * impulse * second_inverse_mass
		var tangent := Vector2(-normal.y, normal.x)
		var relative_tangent_speed := (second.velocity - first.velocity).dot(tangent)
		var friction_impulse := clampf(
			-relative_tangent_speed / inverse_mass_sum,
			-impulse * CONTACT_FRICTION,
			impulse * CONTACT_FRICTION
		)
		first.velocity -= tangent * friction_impulse * first_inverse_mass
		second.velocity += tangent * friction_impulse * second_inverse_mass
	# Deep nose-to-tail overlaps can change closest capsule features while they
	# separate. Recompute a bounded number of times so one pairwise API call also
	# establishes a strict hull boundary; RaceDirector repeats this over the field
	# to converge stacked multi-car contacts deterministically.
	for _iteration in CONTACT_PAIR_POSITION_ITERATIONS:
		contact = _vehicle_contact_geometry(first, second, config, other_config)
		if contact.is_empty() or float(contact["penetration"]) <= 0.0:
			break
		normal = contact["normal"]
		var correction := float(contact["penetration"]) + CONTACT_SEPARATION_BIAS
		first.position -= normal * correction * first_inverse_mass / inverse_mass_sum
		second.position += normal * correction * second_inverse_mass / inverse_mass_sum
	first.quantize_authority()
	second.quantize_authority()
	return true


func vehicle_contact_penetration(
		first: VehicleState,
		second: VehicleState,
		second_config: VehicleConfig = null
	) -> float:
	if first == null or second == null or first == second \
			or not first.is_finite() or not second.is_finite():
		return 0.0
	if (first.track_collision_mask & second.track_collision_layer) == 0 \
			or (second.track_collision_mask & first.track_collision_layer) == 0:
		return 0.0
	var other_config := second_config.sanitized() if second_config != null else config
	var contact := _vehicle_contact_geometry(first, second, config, other_config)
	return maxf(0.0, float(contact.get("penetration", 0.0)))


func vehicle_contact_gap(
		first: VehicleState,
		second: VehicleState,
		second_config: VehicleConfig = null
	) -> float:
	if first == null or second == null or first == second \
			or not first.is_finite() or not second.is_finite():
		return INF
	if (first.track_collision_mask & second.track_collision_layer) == 0 \
			or (second.track_collision_mask & first.track_collision_layer) == 0:
		return INF
	var other_config := second_config.sanitized() if second_config != null else config
	var contact := _vehicle_contact_geometry(first, second, config, other_config)
	return maxf(0.0, -float(contact.get("penetration", -INF)))


func refresh_track_context_after_contact(state: VehicleState, track: RaceTrackQuery) -> bool:
	if state == null or track == null or not track.is_valid() or not state.is_finite():
		return false
	var projection_window := maxf(track.track_width * 2.5, 24.0)
	var projection := _resolve_wall(state, track, projection_window)
	if projection.is_empty():
		projection = track.nearest_continuous(
			state.position,
			state.track_distance,
			state.track_collision_layer,
			projection_window
		)
	if projection.is_empty():
		return false
	state.track_distance = float(projection["distance_along"])
	state.lateral_offset = float(projection["signed_lateral"])
	_apply_surface_context(state, projection)
	var road_limit := maxf(0.1, track.track_width * 0.5 - config.vehicle_radius)
	state.is_offtrack = absf(state.lateral_offset) > road_limit
	state.quantize_authority()
	return state.is_finite()


func _vehicle_contact_geometry(
		first: VehicleState,
		second: VehicleState,
		first_config: VehicleConfig,
		second_config: VehicleConfig
	) -> Dictionary:
	var first_segment_half := maxf(
		0.0,
		first_config.vehicle_collision_half_length \
			- first_config.vehicle_collision_half_width
	)
	var second_segment_half := maxf(
		0.0,
		second_config.vehicle_collision_half_length \
			- second_config.vehicle_collision_half_width
	)
	var broadphase_radius := first_config.vehicle_collision_half_length \
		+ second_config.vehicle_collision_half_length
	if first.position.distance_squared_to(second.position) \
			> broadphase_radius * broadphase_radius:
		return {}
	var first_axis := first.forward()
	var second_axis := second.forward()
	var closest := _closest_points_on_segments(
		first.position - first_axis * first_segment_half,
		first.position + first_axis * first_segment_half,
		second.position - second_axis * second_segment_half,
		second.position + second_axis * second_segment_half
	)
	var first_point: Vector2 = closest["first"]
	var second_point: Vector2 = closest["second"]
	var delta := second_point - first_point
	var distance := delta.length()
	var normal := delta / distance if distance > 0.000001 else _fallback_contact_normal(
		first, second, first_axis, second_axis
	)
	var radius_sum := first_config.vehicle_collision_half_width \
		+ second_config.vehicle_collision_half_width
	return {
		"normal": normal,
		"penetration": radius_sum - distance,
		"position": (
			first_point + normal * first_config.vehicle_collision_half_width \
			+ second_point - normal * second_config.vehicle_collision_half_width
		) * 0.5,
	}


func _closest_points_on_segments(
		first_start: Vector2,
		first_end: Vector2,
		second_start: Vector2,
		second_end: Vector2
	) -> Dictionary:
	var first_delta := first_end - first_start
	var second_delta := second_end - second_start
	var between_starts := first_start - second_start
	var first_length_squared := first_delta.length_squared()
	var second_length_squared := second_delta.length_squared()
	var first_amount := 0.0
	var second_amount := 0.0
	if first_length_squared <= 0.00000001 and second_length_squared <= 0.00000001:
		return {"first": first_start, "second": second_start}
	if first_length_squared <= 0.00000001:
		second_amount = clampf(
			second_delta.dot(between_starts) / second_length_squared, 0.0, 1.0
		)
	elif second_length_squared <= 0.00000001:
		first_amount = clampf(
			-first_delta.dot(between_starts) / first_length_squared, 0.0, 1.0
		)
	else:
		var first_second_dot := first_delta.dot(second_delta)
		var first_start_dot := first_delta.dot(between_starts)
		var second_start_dot := second_delta.dot(between_starts)
		var denominator := first_length_squared * second_length_squared \
			- first_second_dot * first_second_dot
		if absf(denominator) > 0.00000001:
			first_amount = clampf(
				(first_second_dot * second_start_dot \
					- first_start_dot * second_length_squared) / denominator,
				0.0,
				1.0
			)
		second_amount = (
			first_second_dot * first_amount + second_start_dot
		) / second_length_squared
		if second_amount < 0.0:
			second_amount = 0.0
			first_amount = clampf(
				-first_start_dot / first_length_squared, 0.0, 1.0
			)
		elif second_amount > 1.0:
			second_amount = 1.0
			first_amount = clampf(
				(first_second_dot - first_start_dot) / first_length_squared, 0.0, 1.0
			)
	return {
		"first": first_start + first_delta * first_amount,
		"second": second_start + second_delta * second_amount,
	}


func _fallback_contact_normal(
		first: VehicleState,
		second: VehicleState,
		first_axis: Vector2,
		second_axis: Vector2
	) -> Vector2:
	var center_delta := second.position - first.position
	if center_delta.length_squared() > 0.00000001:
		return center_delta.normalized()
	var average_axis := first_axis + second_axis
	if average_axis.length_squared() <= 0.00000001:
		average_axis = first_axis
	var normal := Vector2(-average_axis.y, average_axis.x).normalized()
	if str(first.vehicle_id) > str(second.vehicle_id):
		normal = -normal
	return normal


func _record_vehicle_contact(
		state: VehicleState,
		other: VehicleState,
		contact: Dictionary,
		impact_speed: float,
		normal: Vector2
	) -> void:
	var contact_tick := maxi(state.simulation_tick, other.simulation_tick)
	var first_contact_this_tick := state.vehicle_contact_tick != contact_tick
	if first_contact_this_tick:
		state.vehicle_contact_serial += 1
		state.vehicle_contact_tick = contact_tick
		state.vehicle_contact_speed = 0.0
	if first_contact_this_tick or impact_speed >= state.vehicle_contact_speed:
		state.vehicle_contact_speed = clampf(impact_speed, 0.0, 2000.0)
		state.vehicle_contact_position = contact.get("position", state.position)
		state.vehicle_contact_normal = normal
		state.vehicle_contact_other_id = other.vehicle_id


func recover_to_track(
	state: VehicleState,
	track: RaceTrackQuery,
	preserve_forward_speed: bool = false
	) -> bool:
	if state == null or track == null or not track.is_valid() or not state.is_finite():
		return false
	var projection := track.recovery_projection(
		state.position,
		state.track_distance,
		state.track_collision_layer,
		config.vehicle_radius
	)
	if projection.is_empty():
		return false
	var road_limit := maxf(0.1, float(projection["road_limit"]) * 0.85)
	var recovered_lateral := clampf(float(projection["signed_lateral"]), -road_limit, road_limit)
	var retained_speed := clampf(state.velocity.dot(projection["tangent"]), 0.0, config.maximum_forward_speed)
	state.position = projection["center"] + projection["normal"] * recovered_lateral
	state.heading = Vector2.RIGHT.angle_to(projection["tangent"])
	var recovered_speed := retained_speed if preserve_forward_speed else 0.0
	state.velocity = projection["tangent"] * recovered_speed
	state.track_distance = float(projection["distance_along"])
	state.lateral_offset = recovered_lateral
	state.is_offtrack = false
	state.gear = _gear_for_speed(recovered_speed) if preserve_forward_speed else 1
	state.shift_ticks_remaining = 0
	state.steering_input = 0.0
	state.slip_angle = 0.0
	state.wheel_slip = 0.0
	state.lateral_acceleration = 0.0
	state.vertical_offset_meters = 0.0
	state.vertical_velocity_mps = 0.0
	state.is_grounded = true
	_refresh_engine_rpm(state, 0.0, recovered_speed)
	_apply_surface_context(state, projection)
	state.quantize_authority()
	return state.is_finite()


func _gear_for_speed(speed: float) -> int:
	var bounded_speed := maxf(0.0, speed)
	for index in FORWARD_GEAR_COUNT:
		if bounded_speed <= config.gear_speed_limits[index]:
			return index + 1
	return FORWARD_GEAR_COUNT


func _update_nitro(state: VehicleState, command: RaceInput, delta: float) -> void:
	state.nitro_energy = clampf(state.nitro_energy, 0.0, config.nitro_capacity)
	state.nitro_cooldown_remaining = maxf(0.0, state.nitro_cooldown_remaining - delta)
	var requested := command.nitro and command.throttle > 0.2
	var can_activate := state.nitro_energy > 0.0 and state.nitro_cooldown_remaining <= 0.0
	var was_active := state.nitro_active
	state.nitro_active = requested and can_activate
	if state.nitro_active:
		state.nitro_energy = maxf(0.0, state.nitro_energy - delta)
		if state.nitro_energy <= 0.0:
			state.nitro_active = false
			state.nitro_cooldown_remaining = config.nitro_cooldown
	elif was_active:
		state.nitro_cooldown_remaining = config.nitro_cooldown
	elif state.nitro_cooldown_remaining <= 0.0:
		state.nitro_energy = minf(
			config.nitro_capacity, state.nitro_energy + config.nitro_recharge_rate * delta
		)


func _resolve_wall(
	state: VehicleState,
	track: RaceTrackQuery,
	projection_window: float
	) -> Dictionary:
	var wall := track.clamp_to_wall(
		state.position,
		config.vehicle_radius,
		state.track_distance,
		state.track_collision_layer,
		projection_window
	)
	if wall.is_empty():
		return {}
	if float(wall["wall_penetration"]) <= 0.0:
		return wall
	var lateral := float(wall["signed_lateral"])
	var outward: Vector2 = wall["normal"] * (-1.0 if lateral < 0.0 else 1.0)
	var tangent: Vector2 = wall["tangent"]
	var outward_speed := state.velocity.dot(outward)
	var tangent_speed := state.velocity.dot(tangent)
	state.position = wall["clamped_position"]
	state.velocity = tangent * tangent_speed * config.wall_tangent_retention
	if outward_speed > 0.0:
		state.velocity -= outward * outward_speed * config.wall_restitution
	else:
		state.velocity += outward * outward_speed
	state.wall_contacts += 1
	# The returned projection remains complete after clamping. Only its lateral
	# coordinate changes; route distance and bridge surface context are identical.
	wall["signed_lateral"] = clampf(lateral, -float(wall["drive_limit"]), float(wall["drive_limit"]))
	wall["distance_squared"] = state.position.distance_squared_to(wall["center"])
	wall["wall_penetration"] = 0.0
	return wall


func _projection_window(state: VehicleState, track: RaceTrackQuery, delta: float) -> float:
	return maxf(track.track_width * 2.5, state.speed() * delta * 4.0 + 12.0)


func _update_vertical_motion(
	state: VehicleState,
	before: Dictionary,
	after: Dictionary,
	track: RaceTrackQuery,
	delta: float,
	on_road: bool
	) -> void:
	var before_ground_m := clampf(
		float(before.get("elevation_level", state.track_elevation)), 0.0, 1.0
	) * BRIDGE_HEIGHT_METERS
	var after_ground_m := clampf(
		float(after.get("elevation_level", state.track_elevation)), 0.0, 1.0
	) * BRIDGE_HEIGHT_METERS
	if not state.is_grounded:
		# Semi-implicit position with the analytic half-gravity term keeps the arc
		# deterministic at 60 Hz and lands against the moving road surface rather
		# than assuming every deck is globally flat.
		var next_vertical_velocity := state.vertical_velocity_mps \
				- STANDARD_GRAVITY * delta
		var next_absolute_height := before_ground_m \
				+ state.vertical_offset_meters \
				+ state.vertical_velocity_mps * delta \
				- 0.5 * STANDARD_GRAVITY * delta * delta
		if next_absolute_height <= after_ground_m + LANDING_EPSILON_METERS:
			state.vertical_offset_meters = 0.0
			state.vertical_velocity_mps = 0.0
			state.is_grounded = true
		else:
			state.vertical_offset_meters = next_absolute_height - after_ground_m
			state.vertical_velocity_mps = next_vertical_velocity
		return

	state.vertical_offset_meters = 0.0
	state.vertical_velocity_mps = 0.0
	if not on_road:
		return
	var launch_velocity := _crest_launch_velocity_mps(state, before, after, track)
	if launch_velocity < MIN_CREST_LAUNCH_VERTICAL_SPEED_MPS:
		return
	state.is_grounded = false
	state.vertical_velocity_mps = launch_velocity


func _crest_launch_velocity_mps(
	state: VehicleState,
	before: Dictionary,
	after: Dictionary,
	track: RaceTrackQuery
	) -> float:
	var speed_mps := state.speed() * WORLD_UNIT_TO_METERS
	if speed_mps < MIN_CREST_LAUNCH_SPEED_MPS:
		return 0.0
	var before_elevation := float(before.get("elevation_level", 0.0))
	var after_elevation := float(after.get("elevation_level", 0.0))
	# Only a rising overpass ramp entering its flat deck is a launch crest. This
	# excludes ordinary flat road, the downhill-ramp bottom, and low-speed ramps.
	if before_elevation <= CREST_ELEVATION_EPSILON \
			or before_elevation >= 1.0 - CREST_ELEVATION_EPSILON \
			or after_elevation < 1.0 - CREST_ELEVATION_EPSILON \
			or str(before.get("bridge_branch", "")) != "overpass" \
			or str(after.get("bridge_branch", "")) != "overpass":
		return 0.0
	var bridge_id := str(after.get("bridge_id", ""))
	if bridge_id.is_empty() or bridge_id != str(before.get("bridge_id", "")):
		return 0.0
	var zone: Dictionary = {}
	for zone_value in track.bridge_zones:
		if str(zone_value.get("crossing_id", "")) == bridge_id:
			zone = zone_value
			break
	if zone.is_empty():
		return 0.0
	var deck_half_units := float(zone.get("deck_half_length", 0.0))
	var ramp_half_units := float(zone.get("ramp_half_length", 0.0))
	var ramp_run_m := (ramp_half_units - deck_half_units) * WORLD_UNIT_TO_METERS
	var flat_deck_run_m := deck_half_units * 2.0 * WORLD_UNIT_TO_METERS
	if ramp_run_m <= 0.0 or flat_deck_run_m <= 0.0:
		return 0.0
	var ramp_grade := BRIDGE_HEIGHT_METERS / ramp_run_m
	var physical_vertical_velocity := speed_mps * ramp_grade
	# The runway cap makes the complete ballistic time fit inside most of the
	# flat deck. Faster cars therefore float for less time instead of vaulting
	# unrealistically beyond the bridge and above the underpass branch.
	var deck_travel_seconds := flat_deck_run_m / maxf(speed_mps, 0.001)
	var runway_vertical_cap := 0.5 * STANDARD_GRAVITY \
			* deck_travel_seconds * CREST_DECK_RUNWAY_FRACTION
	return minf(
		physical_vertical_velocity,
		minf(MAX_CREST_LAUNCH_VERTICAL_SPEED_MPS, runway_vertical_cap)
	)


func _apply_surface_context(state: VehicleState, projection: Dictionary) -> void:
	state.track_collision_layer = int(projection.get(
		"collision_layer", RaceTrackQuery.COLLISION_LAYER_GROUND
	))
	state.track_collision_mask = int(projection.get(
		"collision_mask", state.track_collision_layer
	))
	state.track_elevation = float(projection.get("elevation_level", 0.0))
	state.bridge_id = str(projection.get("bridge_id", ""))


func _projection_authority_signature(projection: Dictionary) -> Dictionary:
	return {
		"track_distance": snappedf(float(projection.get("distance_along", 0.0)), 0.001),
		"lateral_offset": snappedf(float(projection.get("signed_lateral", 0.0)), 0.001),
		"collision_layer": int(projection.get("collision_layer", 1)),
		"collision_mask": int(projection.get("collision_mask", 1)),
		"elevation": snappedf(float(projection.get("elevation_level", 0.0)), 0.0001),
		"bridge_id": str(projection.get("bridge_id", "")),
	}
