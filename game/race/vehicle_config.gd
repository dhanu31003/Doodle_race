class_name VehicleConfig
extends RefCounted
## Bounded Formula-style handling parameters expressed in world units and seconds.
##
## The authority deliberately remains an accessible deterministic model rather
## than a tyre-temperature simulator. The values below describe the same car for
## human, AI, replay, and network prediction consumers.

const FORWARD_GEAR_COUNT: int = 8
const DEFAULT_GEAR_SPEED_LIMITS := [
	72.0, 108.0, 146.0, 184.0, 221.0, 255.0, 285.0, 310.0,
]
const DEFAULT_GEAR_DOWNSHIFT_SPEEDS := [
	0.0, 55.0, 88.0, 121.0, 154.0, 187.0, 219.0, 250.0,
]
const DEFAULT_GEAR_ACCELERATION_FACTORS := [
	1.00, 0.96, 0.89, 0.82, 0.75, 0.69, 0.63, 0.58,
]

var mass: float = 1.0
var engine_acceleration: float = 58.0
var reverse_acceleration: float = 30.0
var brake_deceleration: float = 76.0
var coast_deceleration: float = 3.8
var engine_brake_deceleration: float = 10.5
var aerodynamic_drag: float = 0.00024
var maximum_forward_speed: float = 310.0
var maximum_reverse_speed: float = 58.0
var gear_speed_limits: PackedFloat64Array = PackedFloat64Array(DEFAULT_GEAR_SPEED_LIMITS)
var gear_downshift_speeds: PackedFloat64Array = PackedFloat64Array(DEFAULT_GEAR_DOWNSHIFT_SPEEDS)
var gear_acceleration_factors: PackedFloat64Array = PackedFloat64Array(DEFAULT_GEAR_ACCELERATION_FACTORS)
var shift_duration: float = 0.0833333333
var shift_torque_factor: float = 0.08
var idle_rpm: float = 4500.0
var launch_rpm: float = 6500.0
var upshift_rpm: float = 11800.0
var redline_rpm: float = 12500.0
var low_speed_steer_angle: float = 0.47
var high_speed_steer_angle: float = 0.153
var steering_angle_fade_speed: float = 235.0
var steering_input_rate: float = 5.4
var steering_return_rate: float = 7.2
var wheelbase: float = 18.0
var mechanical_lateral_acceleration: float = 65.0
var downforce_lateral_coefficient: float = 0.00168
var lateral_grip: float = 8.8
var drift_grip: float = 4.2
var drift_start_speed: float = 168.0
var peak_slip_angle: float = 0.19
var minimum_slide_grip: float = 0.56
var launch_traction_acceleration: float = 43.0
var downforce_traction_coefficient: float = 0.00020
var brake_downforce_coefficient: float = 0.0010
var offtrack_engine_factor: float = 0.42
var offtrack_drag: float = 125.0
var offtrack_rolling_resistance: float = 6.0
var offtrack_drag_reference_speed: float = 80.0
var offtrack_traction_factor: float = 0.48
var wall_restitution: float = 0.22
var wall_tangent_retention: float = 0.72
var vehicle_radius: float = 4.5
var vehicle_collision_half_length: float = 8.0
var vehicle_collision_half_width: float = 3.25
var nitro_capacity: float = 3.0
var nitro_acceleration: float = 105.0
var nitro_max_speed_bonus: float = 62.0
var nitro_recharge_rate: float = 0.18
var nitro_cooldown: float = 1.0


func corner_speed_limit_for_radius(radius: float, safety_factor: float = 1.0) -> float:
	# Solve v^2 / r <= mechanical + downforce_coefficient * v^2 for v.
	# This lets every controller consume the same tyre envelope as authority
	# instead of maintaining an unrelated hand-tuned corner-speed coefficient.
	if is_nan(radius) or radius <= 0.0:
		return 0.0
	var safe_factor := clampf(safety_factor, 0.5, 1.0)
	if is_inf(radius):
		return maximum_forward_speed * safe_factor
	var denominator := 1.0 - downforce_lateral_coefficient * radius
	var physical_limit := maximum_forward_speed
	if denominator > 0.000001:
		physical_limit = sqrt(maxf(0.0, mechanical_lateral_acceleration * radius / denominator))
	return clampf(physical_limit * safe_factor, 0.0, maximum_forward_speed)


func braking_approach_speed_limit(
		corner_speed: float,
		distance_to_corner: float,
		braking_safety: float = 1.0
	) -> float:
	if is_nan(corner_speed) or is_inf(corner_speed) \
			or is_nan(distance_to_corner) or distance_to_corner < 0.0:
		return 0.0
	if is_inf(distance_to_corner):
		return maximum_forward_speed
	var safe_corner_speed := clampf(corner_speed, 0.0, maximum_forward_speed)
	var safe_distance := clampf(distance_to_corner, 0.0, 100_000.0)
	var safe_braking := clampf(braking_safety, 0.5, 1.0)
	# Integrate v dv/dx = -safety * (base + aero * v^2). This uses the
	# authority's exact speed-dependent brake curve instead of pretending the
	# lower corner-speed capacity applies across the whole braking zone.
	var base := brake_deceleration
	var aero := brake_downforce_coefficient
	if aero <= 0.000000001:
		return minf(
			maximum_forward_speed,
			sqrt(safe_corner_speed * safe_corner_speed \
				+ 2.0 * base * safe_braking * safe_distance)
		)
	var corner_term := base + aero * safe_corner_speed * safe_corner_speed
	var maximum_term := base + aero * maximum_forward_speed * maximum_forward_speed
	var exponent := 2.0 * aero * safe_braking * safe_distance
	var maximum_exponent := log(maximum_term / maxf(corner_term, 0.000001))
	if exponent >= maximum_exponent:
		return maximum_forward_speed
	var allowed_squared := (
		corner_term * exp(exponent) - base
	) / aero
	return clampf(sqrt(maxf(allowed_squared, 0.0)), 0.0, maximum_forward_speed)


func maximum_steering_angle_for_speed(speed: float) -> float:
	var bounded_speed := clampf(absf(speed), 0.0, maximum_forward_speed)
	var fade := clampf(bounded_speed / steering_angle_fade_speed, 0.0, 1.0)
	fade = fade * fade * (3.0 - 2.0 * fade)
	return lerpf(low_speed_steer_angle, high_speed_steer_angle, fade)


func sanitized() -> VehicleConfig:
	var output := VehicleConfig.new()
	output.mass = _bound(mass, 0.25, 10.0, 1.0)
	output.engine_acceleration = _bound(engine_acceleration, 1.0, 2000.0, 58.0)
	output.reverse_acceleration = _bound(reverse_acceleration, 0.0, 1000.0, 30.0)
	output.brake_deceleration = _bound(brake_deceleration, 1.0, 3000.0, 76.0)
	output.coast_deceleration = _bound(coast_deceleration, 0.0, 1000.0, 3.8)
	output.engine_brake_deceleration = _bound(engine_brake_deceleration, 0.0, 1000.0, 10.5)
	output.aerodynamic_drag = _bound(aerodynamic_drag, 0.0, 0.1, 0.00024)
	output.maximum_forward_speed = _bound(maximum_forward_speed, 10.0, 2000.0, 310.0)
	output.maximum_reverse_speed = _bound(maximum_reverse_speed, 0.0, output.maximum_forward_speed, 58.0)
	output.gear_speed_limits = _bounded_curve(
		gear_speed_limits, DEFAULT_GEAR_SPEED_LIMITS, 10.0, output.maximum_forward_speed, true
	)
	output.gear_speed_limits[FORWARD_GEAR_COUNT - 1] = output.maximum_forward_speed
	output.gear_downshift_speeds = _bounded_curve(
		gear_downshift_speeds, DEFAULT_GEAR_DOWNSHIFT_SPEEDS, 0.0,
		output.maximum_forward_speed, true
	)
	for index in FORWARD_GEAR_COUNT:
		output.gear_downshift_speeds[index] = minf(
			output.gear_downshift_speeds[index],
			maxf(0.0, output.gear_speed_limits[index] - 4.0)
		)
	output.gear_acceleration_factors = _bounded_curve(
		gear_acceleration_factors, DEFAULT_GEAR_ACCELERATION_FACTORS, 0.05, 2.0, false
	)
	output.shift_duration = _bound(shift_duration, 1.0 / 120.0, 0.5, 0.0833333333)
	output.shift_torque_factor = _bound(shift_torque_factor, 0.0, 1.0, 0.08)
	output.idle_rpm = _bound(idle_rpm, 500.0, 10000.0, 4500.0)
	output.launch_rpm = _bound(launch_rpm, output.idle_rpm, 14000.0, 6500.0)
	output.upshift_rpm = _bound(upshift_rpm, output.launch_rpm, 18000.0, 11800.0)
	output.redline_rpm = _bound(redline_rpm, output.upshift_rpm, 20000.0, 12500.0)
	output.low_speed_steer_angle = _bound(low_speed_steer_angle, 0.02, 0.8, 0.47)
	output.high_speed_steer_angle = _bound(
		high_speed_steer_angle, 0.01, output.low_speed_steer_angle, 0.153
	)
	output.steering_angle_fade_speed = _bound(
		steering_angle_fade_speed, 10.0, output.maximum_forward_speed, 235.0
	)
	output.steering_input_rate = _bound(steering_input_rate, 0.1, 30.0, 5.4)
	output.steering_return_rate = _bound(steering_return_rate, 0.1, 30.0, 7.2)
	output.wheelbase = _bound(wheelbase, 5.0, 100.0, 18.0)
	output.mechanical_lateral_acceleration = _bound(
		mechanical_lateral_acceleration, 1.0, 1000.0, 65.0
	)
	output.downforce_lateral_coefficient = _bound(
		downforce_lateral_coefficient, 0.0, 0.05, 0.00168
	)
	output.lateral_grip = _bound(lateral_grip, 0.0, 50.0, 8.8)
	output.drift_grip = _bound(drift_grip, 0.0, output.lateral_grip, 4.2)
	output.drift_start_speed = _bound(drift_start_speed, 0.0, output.maximum_forward_speed, 168.0)
	output.peak_slip_angle = _bound(peak_slip_angle, 0.03, 0.8, 0.19)
	output.minimum_slide_grip = _bound(minimum_slide_grip, 0.1, 1.0, 0.56)
	output.launch_traction_acceleration = _bound(
		launch_traction_acceleration, 1.0, 1000.0, 43.0
	)
	output.downforce_traction_coefficient = _bound(
		downforce_traction_coefficient, 0.0, 0.05, 0.00020
	)
	output.brake_downforce_coefficient = _bound(
		brake_downforce_coefficient, 0.0, 0.05, 0.0010
	)
	output.offtrack_engine_factor = _bound(offtrack_engine_factor, 0.0, 1.0, 0.42)
	output.offtrack_drag = _bound(offtrack_drag, 0.0, 2000.0, 125.0)
	output.offtrack_rolling_resistance = _bound(
		offtrack_rolling_resistance, 0.0, output.offtrack_drag, 6.0
	)
	output.offtrack_drag_reference_speed = _bound(
		offtrack_drag_reference_speed, 1.0, output.maximum_forward_speed, 80.0
	)
	output.offtrack_traction_factor = _bound(offtrack_traction_factor, 0.05, 1.0, 0.48)
	output.wall_restitution = _bound(wall_restitution, 0.0, 1.0, 0.22)
	output.wall_tangent_retention = _bound(wall_tangent_retention, 0.0, 1.0, 0.72)
	output.vehicle_radius = _bound(vehicle_radius, 0.5, 50.0, 4.5)
	output.vehicle_collision_half_width = _bound(
		vehicle_collision_half_width, 0.5, 25.0, 3.25
	)
	output.vehicle_collision_half_length = _bound(
		vehicle_collision_half_length,
		output.vehicle_collision_half_width,
		50.0,
		maxf(8.0, output.vehicle_collision_half_width)
	)
	output.nitro_capacity = _bound(nitro_capacity, 0.0, 30.0, 3.0)
	output.nitro_acceleration = _bound(nitro_acceleration, 0.0, 2000.0, 105.0)
	output.nitro_max_speed_bonus = _bound(nitro_max_speed_bonus, 0.0, 1000.0, 62.0)
	output.nitro_recharge_rate = _bound(nitro_recharge_rate, 0.0, 10.0, 0.18)
	output.nitro_cooldown = _bound(nitro_cooldown, 0.0, 30.0, 1.0)
	return output


static func _bound(value: float, minimum: float, maximum: float, fallback: float) -> float:
	if is_nan(value) or is_inf(value):
		return fallback
	return clampf(value, minimum, maximum)


static func _bounded_curve(
		source: PackedFloat64Array,
		fallback: Array,
		minimum: float,
		maximum: float,
		require_increasing: bool
	) -> PackedFloat64Array:
	var output := PackedFloat64Array()
	output.resize(FORWARD_GEAR_COUNT)
	var previous := minimum
	for index in FORWARD_GEAR_COUNT:
		var fallback_value := float(fallback[index])
		var value := float(source[index]) if index < source.size() else fallback_value
		value = _bound(value, minimum, maximum, fallback_value)
		if require_increasing and index > 0:
			value = maxf(value, previous + 0.1)
		value = minf(value, maximum)
		output[index] = value
		previous = value
	return output
