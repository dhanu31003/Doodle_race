class_name VehicleState
extends RefCounted
## Authoritative state for one car. Presentation may interpolate copies of it.

const QuantizationType := preload("res://game/core/quantization.gd")

const MAX_VERTICAL_OFFSET_METERS: float = 12.0
const MAX_VERTICAL_SPEED_MPS: float = 30.0

var vehicle_id: StringName = &""
var position: Vector2 = Vector2.ZERO
var velocity: Vector2 = Vector2.ZERO
var heading: float = 0.0
var track_distance: float = 0.0
var lateral_offset: float = 0.0
var track_collision_layer: int = 1
var track_collision_mask: int = 1
var track_elevation: float = 0.0
var bridge_id: String = ""
# The route authority remains two-dimensional, while these three fixed-step
# values describe the car's short physical separation from that route surface.
# Offsets and velocity are SI presentation/physics units so gravity does not
# depend on track-canvas scale. A grounded car always carries exact zeroes.
var vertical_offset_meters: float = 0.0
var vertical_velocity_mps: float = 0.0
var is_grounded: bool = true
# Formula drivetrain/handling authority. Gear -1 is reverse, 0 is neutral
# during exceptional recovery/import states, and 1–8 are forward gears.
var gear: int = 1
var engine_rpm: float = 4500.0
var shift_ticks_remaining: int = 0
var shift_serial: int = 0
var steering_input: float = 0.0
var slip_angle: float = 0.0
var wheel_slip: float = 0.0
var lateral_acceleration: float = 0.0
var nitro_energy: float = 3.0
var nitro_cooldown_remaining: float = 0.0
var nitro_active: bool = false
var is_offtrack: bool = false
var wall_contacts: int = 0
# Monotonic car-to-car contact telemetry. Presentation compares the serial on
# interpolated previous/current states, then maps the authority-space position
# and normal into its own world. One car records at most one (strongest) impact
# per fixed tick even when the iterative solver needs several separation passes.
var vehicle_contact_serial: int = 0
var vehicle_contact_tick: int = -1
var vehicle_contact_speed: float = 0.0
var vehicle_contact_position: Vector2 = Vector2.ZERO
var vehicle_contact_normal: Vector2 = Vector2.RIGHT
var vehicle_contact_other_id: StringName = &""
var recovery_hard_snap_serial: int = 0
var last_recovery_tick: int = -1
var last_recovery_reason: StringName = &""
var simulation_tick: int = 0


func forward() -> Vector2:
	return Vector2(cos(heading), sin(heading))


func speed() -> float:
	return velocity.length()


func forward_speed() -> float:
	return velocity.dot(forward())


func duplicate_state() -> VehicleState:
	var copy := VehicleState.new()
	copy.vehicle_id = vehicle_id
	copy.position = position
	copy.velocity = velocity
	copy.heading = heading
	copy.track_distance = track_distance
	copy.lateral_offset = lateral_offset
	copy.track_collision_layer = track_collision_layer
	copy.track_collision_mask = track_collision_mask
	copy.track_elevation = track_elevation
	copy.bridge_id = bridge_id
	copy.vertical_offset_meters = vertical_offset_meters
	copy.vertical_velocity_mps = vertical_velocity_mps
	copy.is_grounded = is_grounded
	copy.gear = gear
	copy.engine_rpm = engine_rpm
	copy.shift_ticks_remaining = shift_ticks_remaining
	copy.shift_serial = shift_serial
	copy.steering_input = steering_input
	copy.slip_angle = slip_angle
	copy.wheel_slip = wheel_slip
	copy.lateral_acceleration = lateral_acceleration
	copy.nitro_energy = nitro_energy
	copy.nitro_cooldown_remaining = nitro_cooldown_remaining
	copy.nitro_active = nitro_active
	copy.is_offtrack = is_offtrack
	copy.wall_contacts = wall_contacts
	copy.vehicle_contact_serial = vehicle_contact_serial
	copy.vehicle_contact_tick = vehicle_contact_tick
	copy.vehicle_contact_speed = vehicle_contact_speed
	copy.vehicle_contact_position = vehicle_contact_position
	copy.vehicle_contact_normal = vehicle_contact_normal
	copy.vehicle_contact_other_id = vehicle_contact_other_id
	copy.recovery_hard_snap_serial = recovery_hard_snap_serial
	copy.last_recovery_tick = last_recovery_tick
	copy.last_recovery_reason = last_recovery_reason
	copy.simulation_tick = simulation_tick
	return copy


func quantize_authority() -> void:
	position = QuantizationType.vector2(position, 0.0001)
	velocity = QuantizationType.vector2(velocity, 0.0001)
	heading = QuantizationType.scalar(wrapf(heading, -PI, PI), 0.000001)
	track_distance = QuantizationType.scalar(track_distance, 0.001)
	lateral_offset = QuantizationType.scalar(lateral_offset, 0.001)
	track_elevation = QuantizationType.scalar(clampf(track_elevation, 0.0, 1.0), 0.0001)
	vertical_offset_meters = QuantizationType.scalar(
		clampf(vertical_offset_meters, 0.0, MAX_VERTICAL_OFFSET_METERS), 0.0001
	)
	vertical_velocity_mps = QuantizationType.scalar(
		clampf(vertical_velocity_mps, -MAX_VERTICAL_SPEED_MPS, MAX_VERTICAL_SPEED_MPS),
		0.0001
	)
	if is_grounded or (
		vertical_offset_meters <= 0.0 and vertical_velocity_mps <= 0.0
	):
		is_grounded = true
		vertical_offset_meters = 0.0
		vertical_velocity_mps = 0.0
	gear = clampi(gear, -1, 8)
	engine_rpm = QuantizationType.scalar(clampf(engine_rpm, 0.0, 20_000.0), 0.1)
	shift_ticks_remaining = clampi(shift_ticks_remaining, 0, 120)
	shift_serial = maxi(0, shift_serial)
	steering_input = QuantizationType.scalar(clampf(steering_input, -1.0, 1.0), 0.0001)
	slip_angle = QuantizationType.scalar(clampf(slip_angle, -PI * 0.5, PI * 0.5), 0.0001)
	wheel_slip = QuantizationType.scalar(clampf(wheel_slip, 0.0, 4.0), 0.0001)
	lateral_acceleration = QuantizationType.scalar(
		clampf(lateral_acceleration, -2000.0, 2000.0), 0.001
	)
	nitro_energy = QuantizationType.scalar(nitro_energy, 0.0001)
	nitro_cooldown_remaining = QuantizationType.scalar(nitro_cooldown_remaining, 0.0001)
	vehicle_contact_serial = maxi(0, vehicle_contact_serial)
	vehicle_contact_tick = maxi(-1, vehicle_contact_tick)
	vehicle_contact_speed = QuantizationType.scalar(
		clampf(vehicle_contact_speed, 0.0, 2000.0), 0.001
	)
	vehicle_contact_position = QuantizationType.vector2(vehicle_contact_position, 0.0001)
	if not QuantizationType.is_finite_vector2(vehicle_contact_normal) \
			or vehicle_contact_normal.length_squared() <= 0.00000001:
		vehicle_contact_normal = Vector2.RIGHT
	else:
		vehicle_contact_normal = QuantizationType.vector2(
			vehicle_contact_normal.normalized(), 0.0001
		).normalized()


func is_finite() -> bool:
	return QuantizationType.is_finite_vector2(position) \
		and QuantizationType.is_finite_vector2(velocity) \
		and QuantizationType.is_finite_scalar(heading) \
		and QuantizationType.is_finite_scalar(track_distance) \
		and QuantizationType.is_finite_scalar(lateral_offset) \
		and QuantizationType.is_finite_scalar(track_elevation) \
		and QuantizationType.is_finite_scalar(vertical_offset_meters) \
		and vertical_offset_meters >= 0.0 \
		and vertical_offset_meters <= MAX_VERTICAL_OFFSET_METERS \
		and QuantizationType.is_finite_scalar(vertical_velocity_mps) \
		and absf(vertical_velocity_mps) <= MAX_VERTICAL_SPEED_MPS \
		and ((is_grounded and vertical_offset_meters == 0.0 \
			and vertical_velocity_mps == 0.0) \
			or (not is_grounded and (vertical_offset_meters > 0.0 \
				or vertical_velocity_mps > 0.0))) \
		and (track_collision_layer == 1 or track_collision_layer == 2) \
		and track_collision_mask >= 1 and track_collision_mask <= 3 \
		and gear >= -1 and gear <= 8 \
		and QuantizationType.is_finite_scalar(engine_rpm) \
		and engine_rpm >= 0.0 and engine_rpm <= 20_000.0 \
		and shift_ticks_remaining >= 0 and shift_ticks_remaining <= 120 \
		and shift_serial >= 0 \
		and QuantizationType.is_finite_scalar(steering_input) \
		and absf(steering_input) <= 1.0 \
		and QuantizationType.is_finite_scalar(slip_angle) \
		and QuantizationType.is_finite_scalar(wheel_slip) \
		and QuantizationType.is_finite_scalar(lateral_acceleration) \
		and QuantizationType.is_finite_scalar(nitro_energy) \
		and QuantizationType.is_finite_scalar(nitro_cooldown_remaining) \
		and vehicle_contact_serial >= 0 \
		and vehicle_contact_tick >= -1 \
		and QuantizationType.is_finite_scalar(vehicle_contact_speed) \
		and vehicle_contact_speed >= 0.0 and vehicle_contact_speed <= 2000.0 \
		and QuantizationType.is_finite_vector2(vehicle_contact_position) \
		and QuantizationType.is_finite_vector2(vehicle_contact_normal) \
		and vehicle_contact_normal.length_squared() > 0.999 \
		and vehicle_contact_normal.length_squared() < 1.001


func authority_snapshot() -> Dictionary:
	return {
		"vehicle_id": str(vehicle_id),
		"position_q": [
			QuantizationType.to_fixed(position.x, 10_000),
			QuantizationType.to_fixed(position.y, 10_000),
		],
		"velocity_q": [
			QuantizationType.to_fixed(velocity.x, 10_000),
			QuantizationType.to_fixed(velocity.y, 10_000),
		],
		"heading_q": QuantizationType.to_fixed(heading, 1_000_000),
		"track_distance_q": QuantizationType.to_fixed(track_distance),
		"lateral_offset_q": QuantizationType.to_fixed(lateral_offset),
		"track_collision_layer": track_collision_layer,
		"track_collision_mask": track_collision_mask,
		"track_elevation_q": QuantizationType.to_fixed(track_elevation, 10_000),
		"bridge_id": bridge_id,
		"vertical_offset_q": QuantizationType.to_fixed(vertical_offset_meters, 10_000),
		"vertical_velocity_q": QuantizationType.to_fixed(vertical_velocity_mps, 10_000),
		"grounded": is_grounded,
		"gear": gear,
		"engine_rpm_q": QuantizationType.to_fixed(engine_rpm, 10),
		"shift_ticks_remaining": shift_ticks_remaining,
		"shift_serial": shift_serial,
		"steering_input_q": QuantizationType.to_fixed(steering_input, 10_000),
		"slip_angle_q": QuantizationType.to_fixed(slip_angle, 10_000),
		"wheel_slip_q": QuantizationType.to_fixed(wheel_slip, 10_000),
		"lateral_acceleration_q": QuantizationType.to_fixed(lateral_acceleration, 1000),
		"nitro_energy_q": QuantizationType.to_fixed(nitro_energy, 10_000),
		"nitro_cooldown_q": QuantizationType.to_fixed(nitro_cooldown_remaining, 10_000),
		"nitro_active": nitro_active,
		"is_offtrack": is_offtrack,
		"wall_contacts": wall_contacts,
		"vehicle_contact_serial": vehicle_contact_serial,
		"vehicle_contact_tick": vehicle_contact_tick,
		"vehicle_contact_speed_q": QuantizationType.to_fixed(vehicle_contact_speed, 1000),
		"vehicle_contact_position_q": [
			QuantizationType.to_fixed(vehicle_contact_position.x, 10_000),
			QuantizationType.to_fixed(vehicle_contact_position.y, 10_000),
		],
		"vehicle_contact_normal_q": [
			QuantizationType.to_fixed(vehicle_contact_normal.x, 10_000),
			QuantizationType.to_fixed(vehicle_contact_normal.y, 10_000),
		],
		"vehicle_contact_other_id": str(vehicle_contact_other_id),
		# Network/presentation consumers hard-snap when this serial increments.
		"recovery_hard_snap_serial": recovery_hard_snap_serial,
		"last_recovery_tick": last_recovery_tick,
		"last_recovery_reason": str(last_recovery_reason),
		"simulation_tick": simulation_tick,
	}
