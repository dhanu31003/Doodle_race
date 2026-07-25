class_name NetworkRaceCodec
extends RefCounted
## Bounded conversion between deterministic race state and protocol-v2 wire
## payloads. Multiplayer intentionally exposes steering, throttle and
## brake/reverse only; the legacy boost field is always serialized false.

const Limits := preload("res://game/network/network_limits.gd")
const Result := preload("res://game/network/network_result.gd")
const RaceInputType := preload("res://game/race/race_input.gd")

const POSITION_SCALE := 10_000.0
const VELOCITY_SCALE := 10_000.0
const ROTATION_SCALE := 1_000_000.0
const CONTACT_SPEED_SCALE := 1000.0
const CONTACT_NORMAL_SCALE := 10_000.0
const VERTICAL_SCALE := 10_000.0
const FLAG_OFFTRACK := 1
const FLAG_FINISHED := 2
const FLAG_DNF := 4
const FLAG_RECOVERY_PARITY := 8
const DYNAMICS_FIELDS := [
	"gear", "engine_rpm_q", "shift_ticks", "steering_q", "slip_angle_q",
	"wheel_slip_q", "lateral_accel_q",
]
const AIRBORNE_FIELDS := [
	"vertical_offset_q", "vertical_velocity_q", "grounded",
]
const CONTACT_FIELDS := [
	"contact_serial", "contact_tick", "contact_speed_q", "contact_x_q", "contact_y_q",
	"contact_normal_x_q", "contact_normal_y_q",
]


static func input_payload(command: RaceInput, ack_host_tick: int) -> Dictionary:
	var safe := command.duplicate_input() if command != null else RaceInputType.new()
	safe.sanitize()
	return {
		"steering": clampi(roundi(safe.steer * 1000.0), Limits.STEERING_MIN, Limits.STEERING_MAX),
		"throttle": clampi(roundi(safe.throttle * 1000.0), Limits.PEDAL_MIN, Limits.PEDAL_MAX),
		"brake": clampi(roundi(safe.brake * 1000.0), Limits.PEDAL_MIN, Limits.PEDAL_MAX),
		"boost": false,
		"ack_host_tick": maxi(0, ack_host_tick),
	}


static func command_from_payload(payload: Dictionary) -> Dictionary:
	for key in ["steering", "throttle", "brake", "boost", "ack_host_tick"]:
		if not payload.has(key):
			return Result.failure(&"input_malformed", "Network input is missing a required field.", {"field": key})
	if typeof(payload["steering"]) != TYPE_INT \
			or int(payload["steering"]) < Limits.STEERING_MIN \
			or int(payload["steering"]) > Limits.STEERING_MAX:
		return Result.failure(&"input_steering_invalid", "Network steering is outside the fixed range.")
	for pedal in ["throttle", "brake"]:
		if typeof(payload[pedal]) != TYPE_INT \
				or int(payload[pedal]) < Limits.PEDAL_MIN \
				or int(payload[pedal]) > Limits.PEDAL_MAX:
			return Result.failure(&"input_pedal_invalid", "Network pedal is outside the fixed range.", {"field": pedal})
	if typeof(payload["boost"]) != TYPE_BOOL or bool(payload["boost"]):
		return Result.failure(&"input_boost_disabled", "Boost is disabled in multiplayer races.")
	if typeof(payload["ack_host_tick"]) != TYPE_INT or int(payload["ack_host_tick"]) < 0:
		return Result.failure(&"input_ack_invalid", "Acknowledged host tick must be non-negative.")
	return {"ok": true, "value": RaceInputType.new(
		float(payload["steering"]) / 1000.0,
		float(payload["throttle"]) / 1000.0,
		float(payload["brake"]) / 1000.0,
		false
	)}


static func car_from_entry(entry: RaceEntry, slot: int) -> Dictionary:
	if entry == null or entry.state == null:
		return {}
	var flags := FLAG_OFFTRACK if entry.state.is_offtrack else 0
	if str(entry.status) == "finished":
		flags |= FLAG_FINISHED
	elif str(entry.status) == "dnf":
		flags |= FLAG_DNF
	if (entry.state.recovery_hard_snap_serial & 1) != 0:
		flags |= FLAG_RECOVERY_PARITY
	var output := {
		"slot": slot,
		"x_q": clampi(roundi(entry.state.position.x * POSITION_SCALE), -Limits.WORLD_COORDINATE_Q_LIMIT, Limits.WORLD_COORDINATE_Q_LIMIT),
		"y_q": clampi(roundi(entry.state.position.y * POSITION_SCALE), -Limits.WORLD_COORDINATE_Q_LIMIT, Limits.WORLD_COORDINATE_Q_LIMIT),
		"rotation_q": clampi(roundi(entry.state.heading * ROTATION_SCALE), -Limits.ROTATION_Q_LIMIT, Limits.ROTATION_Q_LIMIT),
		"velocity_x_q": clampi(roundi(entry.state.velocity.x * VELOCITY_SCALE), -Limits.VELOCITY_Q_LIMIT, Limits.VELOCITY_Q_LIMIT),
		"velocity_y_q": clampi(roundi(entry.state.velocity.y * VELOCITY_SCALE), -Limits.VELOCITY_Q_LIMIT, Limits.VELOCITY_Q_LIMIT),
		"lap": maxi(0, entry.lap_tracker.laps_completed if entry.lap_tracker != null else 0),
		"checkpoint": maxi(0, entry.lap_tracker.next_checkpoint if entry.lap_tracker != null else 0),
		"collision_layer": clampi(entry.state.track_collision_layer, 1, 2),
		"collision_mask": clampi(entry.state.track_collision_mask, 1, 3),
		"flags": flags,
		"gear": clampi(entry.state.gear, -1, 8),
		"engine_rpm_q": clampi(
			roundi(entry.state.engine_rpm * 10.0), 0, Limits.ENGINE_RPM_Q_LIMIT
		),
		"shift_ticks": clampi(
			entry.state.shift_ticks_remaining, 0, Limits.SHIFT_TICKS_LIMIT
		),
		"steering_q": clampi(
			roundi(entry.state.steering_input * 10_000.0),
			-Limits.STEERING_STATE_Q_LIMIT, Limits.STEERING_STATE_Q_LIMIT
		),
		"slip_angle_q": clampi(
			roundi(entry.state.slip_angle * 10_000.0),
			-Limits.SLIP_ANGLE_Q_LIMIT, Limits.SLIP_ANGLE_Q_LIMIT
		),
		"wheel_slip_q": clampi(
			roundi(entry.state.wheel_slip * 10_000.0), 0, Limits.WHEEL_SLIP_Q_LIMIT
		),
		"lateral_accel_q": clampi(
			roundi(entry.state.lateral_acceleration * 1000.0),
			-Limits.LATERAL_ACCELERATION_Q_LIMIT, Limits.LATERAL_ACCELERATION_Q_LIMIT
		),
	}
	_append_airborne_bundle(output, entry.state)
	_append_contact_bundle(output, entry.state)
	return output


static func prediction_state_from_vehicle(state: VehicleState) -> Dictionary:
	if state == null:
		return {}
	var output := {
		"x_q": clampi(roundi(state.position.x * POSITION_SCALE), -Limits.WORLD_COORDINATE_Q_LIMIT, Limits.WORLD_COORDINATE_Q_LIMIT),
		"y_q": clampi(roundi(state.position.y * POSITION_SCALE), -Limits.WORLD_COORDINATE_Q_LIMIT, Limits.WORLD_COORDINATE_Q_LIMIT),
		"rotation_q": clampi(roundi(state.heading * ROTATION_SCALE), -Limits.ROTATION_Q_LIMIT, Limits.ROTATION_Q_LIMIT),
		"velocity_x_q": clampi(roundi(state.velocity.x * VELOCITY_SCALE), -Limits.VELOCITY_Q_LIMIT, Limits.VELOCITY_Q_LIMIT),
		"velocity_y_q": clampi(roundi(state.velocity.y * VELOCITY_SCALE), -Limits.VELOCITY_Q_LIMIT, Limits.VELOCITY_Q_LIMIT),
		"collision_layer": clampi(state.track_collision_layer, 1, 2),
		"collision_mask": clampi(state.track_collision_mask, 1, 3),
		"gear": clampi(state.gear, -1, 8),
		"engine_rpm_q": clampi(
			roundi(state.engine_rpm * 10.0), 0, Limits.ENGINE_RPM_Q_LIMIT
		),
		"shift_ticks": clampi(state.shift_ticks_remaining, 0, Limits.SHIFT_TICKS_LIMIT),
		"steering_q": clampi(
			roundi(state.steering_input * 10_000.0),
			-Limits.STEERING_STATE_Q_LIMIT, Limits.STEERING_STATE_Q_LIMIT
		),
		"slip_angle_q": clampi(
			roundi(state.slip_angle * 10_000.0),
			-Limits.SLIP_ANGLE_Q_LIMIT, Limits.SLIP_ANGLE_Q_LIMIT
		),
		"wheel_slip_q": clampi(
			roundi(state.wheel_slip * 10_000.0), 0, Limits.WHEEL_SLIP_Q_LIMIT
		),
		"lateral_accel_q": clampi(
			roundi(state.lateral_acceleration * 1000.0),
			-Limits.LATERAL_ACCELERATION_Q_LIMIT, Limits.LATERAL_ACCELERATION_Q_LIMIT
		),
	}
	_append_airborne_bundle(output, state)
	_append_contact_bundle(output, state)
	return output


static func apply_car_to_entry(car: Dictionary, entry: RaceEntry, track: RaceTrackQuery) -> bool:
	if entry == null or entry.state == null or track == null or not track.is_valid():
		return false
	for key in ["x_q", "y_q", "rotation_q", "velocity_x_q", "velocity_y_q", "lap", "checkpoint", "collision_layer", "collision_mask", "flags"]:
		if not car.has(key) or typeof(car[key]) != TYPE_INT:
			return false
	if not valid_contact_bundle(car):
		return false
	if not valid_airborne_bundle(car):
		return false
	entry.previous_state = entry.state.duplicate_state()
	entry.state.position = Vector2(float(car["x_q"]) / POSITION_SCALE, float(car["y_q"]) / POSITION_SCALE)
	entry.state.velocity = Vector2(float(car["velocity_x_q"]) / VELOCITY_SCALE, float(car["velocity_y_q"]) / VELOCITY_SCALE)
	entry.state.heading = float(car["rotation_q"]) / ROTATION_SCALE
	entry.state.track_collision_layer = int(car["collision_layer"])
	entry.state.track_collision_mask = int(car["collision_mask"])
	apply_dynamics_to_state(car, entry.state)
	apply_airborne_to_state(car, entry.state)
	apply_contact_to_state(car, entry.state)
	var projection := track.nearest_continuous(
		entry.state.position,
		entry.state.track_distance,
		entry.state.track_collision_layer,
		maxf(track.track_width * 4.0, 96.0)
	)
	if projection.is_empty():
		return false
	entry.state.track_distance = float(projection["distance_along"])
	entry.state.lateral_offset = float(projection["signed_lateral"])
	var surface := track.surface_context_at_distance(entry.state.track_distance)
	entry.state.track_collision_layer = int(surface.get("collision_layer", entry.state.track_collision_layer))
	# Preserve the authoritative transition mask while still deriving elevation
	# and bridge identity from the deterministic route distance.
	entry.state.track_elevation = float(surface.get("elevation_level", 0.0))
	entry.state.bridge_id = str(surface.get("bridge_id", ""))
	entry.state.is_offtrack = (int(car["flags"]) & FLAG_OFFTRACK) != 0
	var recovery_parity := 1 if (int(car["flags"]) & FLAG_RECOVERY_PARITY) != 0 else 0
	if (entry.state.recovery_hard_snap_serial & 1) != recovery_parity:
		entry.state.recovery_hard_snap_serial += 1
	if entry.lap_tracker != null:
		entry.lap_tracker.laps_completed = int(car["lap"])
		entry.lap_tracker.next_checkpoint = int(car["checkpoint"])
	if (int(car["flags"]) & FLAG_FINISHED) != 0:
		entry.status = &"finished"
	elif (int(car["flags"]) & FLAG_DNF) != 0:
		entry.status = &"dnf"
	else:
		entry.status = &"racing"
	return true


static func apply_airborne_to_state(source: Dictionary, state: VehicleState) -> bool:
	if state == null or not valid_airborne_bundle(source):
		return false
	var present := _present_field_count(source, AIRBORNE_FIELDS)
	if present == 0:
		state.vertical_offset_meters = 0.0
		state.vertical_velocity_mps = 0.0
		state.is_grounded = true
		return false
	state.vertical_offset_meters = float(source["vertical_offset_q"]) / VERTICAL_SCALE
	state.vertical_velocity_mps = float(source["vertical_velocity_q"]) / VERTICAL_SCALE
	state.is_grounded = int(source["grounded"]) == 1
	if state.is_grounded:
		state.vertical_offset_meters = 0.0
		state.vertical_velocity_mps = 0.0
	return true


static func valid_airborne_bundle(source: Dictionary) -> bool:
	var present := _present_field_count(source, AIRBORNE_FIELDS)
	if present == 0:
		return true
	if present != AIRBORNE_FIELDS.size():
		return false
	for field in AIRBORNE_FIELDS:
		if typeof(source[field]) != TYPE_INT:
			return false
	var offset_q := int(source["vertical_offset_q"])
	var velocity_q := int(source["vertical_velocity_q"])
	var grounded := int(source["grounded"])
	if offset_q < 0 or offset_q > Limits.VERTICAL_OFFSET_Q_LIMIT \
			or absi(velocity_q) > Limits.VERTICAL_VELOCITY_Q_LIMIT \
			or grounded < 0 or grounded > 1:
		return false
	return (grounded == 1 and offset_q == 0 and velocity_q == 0) \
			or (grounded == 0 and (offset_q > 0 or velocity_q > 0))


static func apply_contact_to_state(source: Dictionary, state: VehicleState) -> bool:
	if state == null or not valid_contact_bundle(source):
		return false
	var present := _present_field_count(source, CONTACT_FIELDS)
	if present == 0:
		state.vehicle_contact_serial = 0
		state.vehicle_contact_tick = -1
		state.vehicle_contact_speed = 0.0
		state.vehicle_contact_position = Vector2.ZERO
		state.vehicle_contact_normal = Vector2.RIGHT
		state.vehicle_contact_other_id = &""
		return true
	state.vehicle_contact_serial = int(source["contact_serial"])
	state.vehicle_contact_tick = int(source["contact_tick"])
	state.vehicle_contact_speed = float(source["contact_speed_q"]) / CONTACT_SPEED_SCALE
	state.vehicle_contact_position = Vector2(
		float(source["contact_x_q"]) / POSITION_SCALE,
		float(source["contact_y_q"]) / POSITION_SCALE
	)
	state.vehicle_contact_normal = Vector2(
		float(source["contact_normal_x_q"]) / CONTACT_NORMAL_SCALE,
		float(source["contact_normal_y_q"]) / CONTACT_NORMAL_SCALE
	).normalized()
	state.vehicle_contact_other_id = &""
	return true


static func valid_contact_bundle(source: Dictionary) -> bool:
	var present := _present_field_count(source, CONTACT_FIELDS)
	if present == 0:
		return true
	if present != CONTACT_FIELDS.size():
		return false
	for field in CONTACT_FIELDS:
		if typeof(source[field]) != TYPE_INT:
			return false
	var serial := int(source["contact_serial"])
	var tick := int(source["contact_tick"])
	var normal_x := int(source["contact_normal_x_q"])
	var normal_y := int(source["contact_normal_y_q"])
	var normal_length_squared := normal_x * normal_x + normal_y * normal_y
	return serial >= 0 and serial <= Limits.CONTACT_SERIAL_LIMIT \
		and tick >= -1 and tick <= Limits.CONTACT_TICK_LIMIT \
		and (serial == 0 or tick >= 0) \
		and int(source["contact_speed_q"]) >= 0 \
		and int(source["contact_speed_q"]) <= Limits.CONTACT_SPEED_Q_LIMIT \
		and absi(int(source["contact_x_q"])) <= Limits.WORLD_COORDINATE_Q_LIMIT \
		and absi(int(source["contact_y_q"])) <= Limits.WORLD_COORDINATE_Q_LIMIT \
		and absi(normal_x) <= Limits.CONTACT_NORMAL_Q_LIMIT \
		and absi(normal_y) <= Limits.CONTACT_NORMAL_Q_LIMIT \
		and normal_length_squared \
			>= Limits.CONTACT_NORMAL_LENGTH_Q_MIN * Limits.CONTACT_NORMAL_LENGTH_Q_MIN \
		and normal_length_squared \
			<= Limits.CONTACT_NORMAL_LENGTH_Q_MAX * Limits.CONTACT_NORMAL_LENGTH_Q_MAX


static func _append_contact_bundle(output: Dictionary, state: VehicleState) -> void:
	if state == null or state.vehicle_contact_serial <= 0:
		return
	var normal := state.vehicle_contact_normal.normalized() \
		if state.vehicle_contact_normal.length_squared() > 0.00000001 else Vector2.RIGHT
	output.merge({
		"contact_serial": clampi(
			state.vehicle_contact_serial, 0, Limits.CONTACT_SERIAL_LIMIT
		),
		"contact_tick": clampi(state.vehicle_contact_tick, 0, Limits.CONTACT_TICK_LIMIT),
		"contact_speed_q": clampi(
			roundi(state.vehicle_contact_speed * CONTACT_SPEED_SCALE),
			0,
			Limits.CONTACT_SPEED_Q_LIMIT
		),
		"contact_x_q": clampi(
			roundi(state.vehicle_contact_position.x * POSITION_SCALE),
			-Limits.WORLD_COORDINATE_Q_LIMIT,
			Limits.WORLD_COORDINATE_Q_LIMIT
		),
		"contact_y_q": clampi(
			roundi(state.vehicle_contact_position.y * POSITION_SCALE),
			-Limits.WORLD_COORDINATE_Q_LIMIT,
			Limits.WORLD_COORDINATE_Q_LIMIT
		),
		"contact_normal_x_q": clampi(
			roundi(normal.x * CONTACT_NORMAL_SCALE),
			-Limits.CONTACT_NORMAL_Q_LIMIT,
			Limits.CONTACT_NORMAL_Q_LIMIT
		),
		"contact_normal_y_q": clampi(
			roundi(normal.y * CONTACT_NORMAL_SCALE),
			-Limits.CONTACT_NORMAL_Q_LIMIT,
			Limits.CONTACT_NORMAL_Q_LIMIT
		),
	})


static func _append_airborne_bundle(output: Dictionary, state: VehicleState) -> void:
	if state == null:
		return
	var grounded := state.is_grounded
	output.merge({
		"vertical_offset_q": 0 if grounded else clampi(
			roundi(state.vertical_offset_meters * VERTICAL_SCALE),
			0,
			Limits.VERTICAL_OFFSET_Q_LIMIT
		),
		"vertical_velocity_q": 0 if grounded else clampi(
			roundi(state.vertical_velocity_mps * VERTICAL_SCALE),
			-Limits.VERTICAL_VELOCITY_Q_LIMIT,
			Limits.VERTICAL_VELOCITY_Q_LIMIT
		),
		"grounded": 1 if grounded else 0,
	})


static func _present_field_count(source: Dictionary, fields: Array) -> int:
	var present := 0
	for field in fields:
		if source.has(field):
			present += 1
	return present


static func apply_dynamics_to_state(source: Dictionary, state: VehicleState) -> bool:
	if state == null:
		return false
	var present := 0
	for field in DYNAMICS_FIELDS:
		if source.has(field):
			present += 1
	# Protocol-v1 snapshots produced before the Formula dynamics extension remain
	# readable. Their explicit compatibility defaults are first gear, idle RPM,
	# centered rack, and no measured slip/load.
	if present == 0:
		state.gear = 1
		state.engine_rpm = 4500.0
		state.shift_ticks_remaining = 0
		state.steering_input = 0.0
		state.slip_angle = 0.0
		state.wheel_slip = 0.0
		state.lateral_acceleration = 0.0
		return false
	if present != DYNAMICS_FIELDS.size():
		return false
	var previous_gear := state.gear
	state.gear = clampi(int(source["gear"]), -1, 8)
	state.engine_rpm = clampf(
		float(source["engine_rpm_q"]) / 10.0, 0.0,
		float(Limits.ENGINE_RPM_Q_LIMIT) / 10.0
	)
	state.shift_ticks_remaining = clampi(
		int(source["shift_ticks"]), 0, Limits.SHIFT_TICKS_LIMIT
	)
	state.steering_input = clampf(
		float(source["steering_q"]) / 10_000.0, -1.0, 1.0
	)
	state.slip_angle = clampf(
		float(source["slip_angle_q"]) / 10_000.0, -PI * 0.5, PI * 0.5
	)
	state.wheel_slip = clampf(
		float(source["wheel_slip_q"]) / 10_000.0, 0.0, 4.0
	)
	state.lateral_acceleration = clampf(
		float(source["lateral_accel_q"]) / 1000.0, -2000.0, 2000.0
	)
	if state.gear != previous_gear:
		state.shift_serial += 1
	return true


static func car_for_slot(cars: Array, slot: int) -> Dictionary:
	for car_value in cars:
		if car_value is Dictionary and int(car_value.get("slot", -1)) == slot:
			return car_value
	return {}


static func recovery_parity(car: Dictionary) -> int:
	return 1 if (int(car.get("flags", 0)) & FLAG_RECOVERY_PARITY) != 0 else 0
