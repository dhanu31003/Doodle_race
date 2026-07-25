class_name NetworkProtocol
extends RefCounted
## Strict protocol-v2 envelope and payload validation. Transport identity is
## supplied separately and always wins over a claimed sender_id.

const Limits := preload("res://game/network/network_limits.gd")
const Result := preload("res://game/network/network_result.gd")

const OP_HELLO: int = 1
const OP_ROOM_CONFIG: int = 2
const OP_TRACK_MANIFEST: int = 3
const OP_TRACK_CHUNK: int = 4
const OP_GENERATION_REPORT: int = 5
const OP_READY_STATE: int = 6
const OP_START_AT_TICK: int = 7
const OP_INPUT_FRAME: int = 8
const OP_STATE_SNAPSHOT: int = 9
const OP_RACE_EVENT: int = 10
const OP_COSMETIC_EVENT: int = 11
const OP_PING_SAMPLE: int = 12
const OP_RESUME: int = 13
const OP_ROOM_ENDED: int = 14
const OP_ERROR: int = 15

const MIN_OPCODE: int = OP_HELLO
const MAX_OPCODE: int = OP_ERROR


static func make_envelope(
		opcode: int,
		sender_id: String,
		sequence: int,
		room_epoch: int,
		payload: Dictionary,
		tick: int = -1,
		request_id: String = ""
	) -> Dictionary:
	var envelope := {
		"protocol": Limits.PROTOCOL_VERSION,
		"opcode": opcode,
		"room_epoch": room_epoch,
		"sender_id": sender_id,
		"seq": sequence,
		"payload": payload,
	}
	if tick >= 0:
		envelope["tick"] = tick
	if not request_id.is_empty():
		envelope["request_id"] = request_id
	return envelope


static func validate_envelope(
		message: Variant,
		expected_sender_id: String = "",
		expected_room_epoch: int = -1
	) -> Dictionary:
	if typeof(message) != TYPE_DICTIONARY:
		return Result.failure(&"message_malformed", "Message envelope must be an object.")
	var encoded_size := JSON.stringify(message).to_utf8_buffer().size()
	if encoded_size > Limits.MAX_MESSAGE_BYTES:
		return Result.failure(
			&"message_too_large", "Message exceeds the wire-size limit.",
			{"actual_bytes": encoded_size, "maximum_bytes": Limits.MAX_MESSAGE_BYTES}
		)
	for key in ["protocol", "opcode", "room_epoch", "sender_id", "seq", "payload"]:
		if not message.has(key):
			return Result.failure(&"message_malformed", "Message is missing a required field.", {"field": key})
	if typeof(message["protocol"]) != TYPE_INT or int(message["protocol"]) != Limits.PROTOCOL_VERSION:
		return Result.failure(&"protocol_mismatch", "Unsupported multiplayer protocol version.")
	if typeof(message["opcode"]) != TYPE_INT:
		return Result.failure(&"opcode_invalid", "Opcode must be an integer.")
	var opcode := int(message["opcode"])
	if opcode < MIN_OPCODE or opcode > MAX_OPCODE:
		return Result.failure(&"opcode_invalid", "Opcode is outside the protocol-v2 registry.")
	if typeof(message["room_epoch"]) != TYPE_INT or int(message["room_epoch"]) <= 0:
		return Result.failure(&"room_epoch_invalid", "Room epoch must be a positive integer.")
	if expected_room_epoch > 0 and int(message["room_epoch"]) != expected_room_epoch:
		return Result.failure(&"room_epoch_stale", "Message belongs to a stale room epoch.")
	var sender_id := str(message["sender_id"])
	if not _valid_identifier(sender_id, Limits.MAX_PLAYER_ID_BYTES):
		return Result.failure(&"sender_invalid", "Sender identifier is invalid.")
	if not expected_sender_id.is_empty() and sender_id != expected_sender_id:
		return Result.failure(&"sender_spoofed", "Envelope sender does not match transport identity.")
	if typeof(message["seq"]) != TYPE_INT or int(message["seq"]) < 0 \
			or int(message["seq"]) > Limits.MAX_SAFE_SEQUENCE:
		return Result.failure(&"sequence_invalid", "Sequence must be a non-negative safe integer.")
	if typeof(message["payload"]) != TYPE_DICTIONARY:
		return Result.failure(&"payload_malformed", "Message payload must be an object.")
	if message.has("request_id"):
		var request_id := str(message["request_id"])
		if request_id.is_empty() or request_id.to_utf8_buffer().size() > Limits.MAX_REQUEST_ID_BYTES:
			return Result.failure(&"request_id_invalid", "Request identifier is invalid.")
	if opcode == OP_INPUT_FRAME:
		return validate_input_frame(message)
	if opcode == OP_STATE_SNAPSHOT:
		return validate_state_snapshot(message)
	if opcode == OP_RACE_EVENT:
		return validate_race_event(message)
	if opcode == OP_TRACK_MANIFEST:
		var track_validation := _validate_track_manifest(message["payload"])
		if not track_validation["ok"]:
			return track_validation
		# Envelope callers only need acceptance. Drop the decoded definition owned
		# by the validator before returning across any asynchronous transport call.
		track_validation.clear()
	return Result.success({"opcode": opcode, "bytes": encoded_size})


static func _validate_track_manifest(payload: Dictionary) -> Dictionary:
	var validator := ResourceLoader.load(
		_track_manifest_validator_path(), "Script", ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	if validator == null:
		return Result.failure(
			&"track_manifest_validator_missing", "Track manifest validation is unavailable."
		)
	var validation: Dictionary = validator.call("validate", payload)
	validator = null
	return validation


static func _track_manifest_validator_path() -> String:
	return "/".join(PackedStringArray([
		"res:", "", "game", "network", "network_track_manifest.gd",
	]))


static func validate_input_frame(message: Dictionary) -> Dictionary:
	if not message.has("tick") or typeof(message["tick"]) != TYPE_INT or int(message["tick"]) < 0:
		return Result.failure(&"input_tick_invalid", "Input frame requires a non-negative integer tick.")
	var payload: Dictionary = message["payload"]
	for key in ["steering", "throttle", "brake", "boost", "ack_host_tick"]:
		if not payload.has(key):
			return Result.failure(&"input_malformed", "Input frame is missing a required field.", {"field": key})
	if typeof(payload["steering"]) != TYPE_INT \
			or int(payload["steering"]) < Limits.STEERING_MIN \
			or int(payload["steering"]) > Limits.STEERING_MAX:
		return Result.failure(&"input_steering_invalid", "Steering is outside the fixed wire range.")
	for pedal in ["throttle", "brake"]:
		if typeof(payload[pedal]) != TYPE_INT \
				or int(payload[pedal]) < Limits.PEDAL_MIN \
				or int(payload[pedal]) > Limits.PEDAL_MAX:
			return Result.failure(&"input_pedal_invalid", "Pedal value is outside the fixed wire range.", {"field": pedal})
	if typeof(payload["boost"]) != TYPE_BOOL:
		return Result.failure(&"input_boost_invalid", "Boost must be a boolean.")
	# Protocol v2 retains the original v1 field so archived envelopes remain structurally
	# decodable, but RaceGlyph multiplayer deliberately ships conventional
	# steering and pedals only. Never allow a peer to activate the dormant
	# offline nitro mechanic through the network authority boundary.
	if bool(payload["boost"]):
		return Result.failure(&"input_boost_disabled", "Boost is disabled in multiplayer races.")
	if typeof(payload["ack_host_tick"]) != TYPE_INT or int(payload["ack_host_tick"]) < 0:
		return Result.failure(&"input_ack_invalid", "Acknowledged host tick must be non-negative.")
	return Result.success({"tick": int(message["tick"])})


static func validate_state_snapshot(message: Dictionary) -> Dictionary:
	if not message.has("tick") or typeof(message["tick"]) != TYPE_INT or int(message["tick"]) < 0:
		return Result.failure(&"snapshot_tick_invalid", "State snapshot requires a non-negative integer tick.")
	var payload: Dictionary = message["payload"]
	if not payload.has("cars") or typeof(payload["cars"]) != TYPE_ARRAY:
		return Result.failure(&"snapshot_malformed", "State snapshot requires a cars array.")
	var cars: Array = payload["cars"]
	if cars.size() > Limits.MAX_PLAYERS:
		return Result.failure(&"snapshot_too_many_cars", "State snapshot exceeds the car-slot limit.")
	var seen_slots: Dictionary = {}
	for car_value in cars:
		if typeof(car_value) != TYPE_DICTIONARY:
			return Result.failure(&"snapshot_car_malformed", "Every snapshot car must be an object.")
		var car: Dictionary = car_value
		for key in ["slot", "x_q", "y_q", "rotation_q", "velocity_x_q", "velocity_y_q", "lap", "checkpoint", "collision_layer", "collision_mask", "flags"]:
			if not car.has(key) or typeof(car[key]) != TYPE_INT:
				return Result.failure(&"snapshot_car_malformed", "Snapshot car field is missing or not an integer.", {"field": key})
		var slot := int(car["slot"])
		if slot < 0 or slot >= Limits.MAX_PLAYERS or seen_slots.has(slot):
			return Result.failure(&"snapshot_slot_invalid", "Snapshot car slots must be unique and in range.")
		seen_slots[slot] = true
		if absi(int(car["x_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT \
				or absi(int(car["y_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT:
			return Result.failure(&"snapshot_position_invalid", "Snapshot position exceeds the fixed wire range.")
		if absi(int(car["velocity_x_q"])) > Limits.VELOCITY_Q_LIMIT \
				or absi(int(car["velocity_y_q"])) > Limits.VELOCITY_Q_LIMIT:
			return Result.failure(&"snapshot_velocity_invalid", "Snapshot velocity exceeds the fixed wire range.")
		if absi(int(car["rotation_q"])) > Limits.ROTATION_Q_LIMIT:
			return Result.failure(&"snapshot_rotation_invalid", "Snapshot rotation exceeds the fixed wire range.")
		if int(car["collision_layer"]) < 1 or int(car["collision_layer"]) > 2 \
				or int(car["collision_mask"]) < 1 or int(car["collision_mask"]) > 3 \
				or (int(car["collision_mask"]) & int(car["collision_layer"])) == 0:
			return Result.failure(&"snapshot_collision_surface_invalid", "Snapshot collision surface is invalid.")
		if int(car["lap"]) < 0 or int(car["checkpoint"]) < 0 or int(car["flags"]) < 0:
			return Result.failure(&"snapshot_progress_invalid", "Snapshot progress and flags must be non-negative.")
		var dynamics_validation := _validate_optional_vehicle_dynamics(car)
		if not dynamics_validation["ok"]:
			return dynamics_validation
		var airborne_validation := _validate_optional_vehicle_airborne(car)
		if not airborne_validation["ok"]:
			return airborne_validation
		var contact_validation := _validate_optional_vehicle_contact(car)
		if not contact_validation["ok"]:
			return contact_validation
	return Result.success({"tick": int(message["tick"]), "car_count": cars.size()})


static func _validate_optional_vehicle_dynamics(car: Dictionary) -> Dictionary:
	var fields := [
		"gear", "engine_rpm_q", "shift_ticks", "steering_q", "slip_angle_q",
		"wheel_slip_q", "lateral_accel_q",
	]
	var present := 0
	for field in fields:
		if car.has(field):
			present += 1
	if present == 0:
		return Result.success({"legacy_dynamics": true})
	if present != fields.size():
		return Result.failure(
			&"snapshot_dynamics_incomplete",
			"Formula dynamics fields must be supplied as one complete telemetry set."
		)
	for field in fields:
		if typeof(car[field]) != TYPE_INT:
			return Result.failure(
				&"snapshot_dynamics_malformed",
				"Formula dynamics telemetry must use fixed-point integers.",
				{"field": field}
			)
	if int(car["gear"]) < -1 or int(car["gear"]) > 8 \
			or int(car["engine_rpm_q"]) < 0 \
			or int(car["engine_rpm_q"]) > Limits.ENGINE_RPM_Q_LIMIT \
			or int(car["shift_ticks"]) < 0 \
			or int(car["shift_ticks"]) > Limits.SHIFT_TICKS_LIMIT \
			or absi(int(car["steering_q"])) > Limits.STEERING_STATE_Q_LIMIT \
			or absi(int(car["slip_angle_q"])) > Limits.SLIP_ANGLE_Q_LIMIT \
			or int(car["wheel_slip_q"]) < 0 \
			or int(car["wheel_slip_q"]) > Limits.WHEEL_SLIP_Q_LIMIT \
			or absi(int(car["lateral_accel_q"])) > Limits.LATERAL_ACCELERATION_Q_LIMIT:
		return Result.failure(
			&"snapshot_dynamics_out_of_range",
			"Formula dynamics telemetry exceeds its fixed wire range."
		)
	return Result.success({"legacy_dynamics": false})


static func _validate_optional_vehicle_airborne(car: Dictionary) -> Dictionary:
	var fields := ["vertical_offset_q", "vertical_velocity_q", "grounded"]
	var present := 0
	for field in fields:
		if car.has(field):
			present += 1
	if present == 0:
		return Result.success({"legacy_airborne": true})
	if present != fields.size():
		return Result.failure(
			&"snapshot_airborne_incomplete",
			"Vertical vehicle state must be supplied as one complete authority set."
		)
	for field in fields:
		if typeof(car[field]) != TYPE_INT:
			return Result.failure(
				&"snapshot_airborne_malformed",
				"Vertical vehicle state must use fixed-point integers.",
				{"field": field}
			)
	var offset_q := int(car["vertical_offset_q"])
	var velocity_q := int(car["vertical_velocity_q"])
	var grounded := int(car["grounded"])
	var bounded := offset_q >= 0 \
			and offset_q <= Limits.VERTICAL_OFFSET_Q_LIMIT \
			and absi(velocity_q) <= Limits.VERTICAL_VELOCITY_Q_LIMIT \
			and grounded >= 0 and grounded <= 1
	var coherent := (grounded == 1 and offset_q == 0 and velocity_q == 0) \
			or (grounded == 0 and (offset_q > 0 or velocity_q > 0))
	if not bounded or not coherent:
		return Result.failure(
			&"snapshot_airborne_out_of_range",
			"Vertical vehicle state is outside its finite physical authority bounds."
		)
	return Result.success({"legacy_airborne": false})


static func _validate_optional_vehicle_contact(car: Dictionary) -> Dictionary:
	var fields := [
		"contact_serial", "contact_tick", "contact_speed_q", "contact_x_q", "contact_y_q",
		"contact_normal_x_q", "contact_normal_y_q",
	]
	var present := 0
	for field in fields:
		if car.has(field):
			present += 1
	if present == 0:
		return Result.success({"legacy_contact": true})
	if present != fields.size():
		return Result.failure(
			&"snapshot_contact_incomplete",
			"Vehicle contact fields must be supplied as one complete event set."
		)
	for field in fields:
		if typeof(car[field]) != TYPE_INT:
			return Result.failure(
				&"snapshot_contact_malformed",
				"Vehicle contact telemetry must use fixed-point integers.",
				{"field": field}
			)
	var serial := int(car["contact_serial"])
	var tick := int(car["contact_tick"])
	var normal_x := int(car["contact_normal_x_q"])
	var normal_y := int(car["contact_normal_y_q"])
	var normal_length_squared := normal_x * normal_x + normal_y * normal_y
	if serial < 0 or serial > Limits.CONTACT_SERIAL_LIMIT \
			or tick < -1 or tick > Limits.CONTACT_TICK_LIMIT \
			or (serial > 0 and tick < 0) \
			or int(car["contact_speed_q"]) < 0 \
			or int(car["contact_speed_q"]) > Limits.CONTACT_SPEED_Q_LIMIT \
			or absi(int(car["contact_x_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT \
			or absi(int(car["contact_y_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT \
			or absi(normal_x) > Limits.CONTACT_NORMAL_Q_LIMIT \
			or absi(normal_y) > Limits.CONTACT_NORMAL_Q_LIMIT \
			or normal_length_squared \
				< Limits.CONTACT_NORMAL_LENGTH_Q_MIN * Limits.CONTACT_NORMAL_LENGTH_Q_MIN \
			or normal_length_squared \
				> Limits.CONTACT_NORMAL_LENGTH_Q_MAX * Limits.CONTACT_NORMAL_LENGTH_Q_MAX:
		return Result.failure(
			&"snapshot_contact_out_of_range",
			"Vehicle contact telemetry exceeds its fixed wire range."
		)
	return Result.success({"legacy_contact": false})


static func validate_race_event(message: Dictionary) -> Dictionary:
	var payload: Dictionary = message["payload"]
	var event_type := str(payload.get("type", ""))
	if event_type.is_empty() or event_type.length() > 40:
		return Result.failure(&"race_event_type_invalid", "Race event type is invalid.")
	if event_type == "kick_member":
		var target := str(payload.get("player_id", ""))
		if not _valid_identifier(target, Limits.MAX_PLAYER_ID_BYTES):
			return Result.failure(&"kick_target_invalid", "Kick target is invalid.")
		return Result.success({"type": event_type})
	if event_type == "rematch":
		return Result.success({"type": event_type})
	if event_type == "race_complete":
		var results_value: Variant = payload.get("results")
		if typeof(results_value) != TYPE_ARRAY or results_value.is_empty() \
				or results_value.size() > Limits.MAX_PLAYERS:
			return Result.failure(&"race_results_invalid", "Authoritative results array is invalid.")
		var players: Dictionary = {}
		var slots: Dictionary = {}
		var positions: Dictionary = {}
		for result_value in results_value:
			if typeof(result_value) != TYPE_DICTIONARY:
				return Result.failure(&"race_result_invalid", "Every authoritative result must be an object.")
			var result: Dictionary = result_value
			for key in ["player_id", "slot", "position", "status", "laps", "finish_time_ms", "dnf_reason"]:
				if not result.has(key):
					return Result.failure(&"race_result_invalid", "Authoritative result is missing a field.", {"field": key})
			var player_id := str(result["player_id"])
			var slot := int(result["slot"])
			var position := int(result["position"])
			if not _valid_identifier(player_id, Limits.MAX_PLAYER_ID_BYTES) or players.has(player_id) \
					or typeof(result["slot"]) != TYPE_INT or slot < 0 or slot >= Limits.MAX_PLAYERS or slots.has(slot) \
					or typeof(result["position"]) != TYPE_INT or position < 1 or position > results_value.size() or positions.has(position):
				return Result.failure(&"race_result_identity_invalid", "Authoritative result identity or ordering is invalid.")
			if str(result["status"]) not in ["finished", "dnf"] \
					or typeof(result["laps"]) != TYPE_INT or int(result["laps"]) < 0 or int(result["laps"]) > 99 \
					or typeof(result["finish_time_ms"]) != TYPE_INT or int(result["finish_time_ms"]) < 0 \
					or str(result["dnf_reason"]).length() > 40:
				return Result.failure(&"race_result_progress_invalid", "Authoritative result progress is invalid.")
			players[player_id] = true
			slots[slot] = true
			positions[position] = true
		return Result.success({"type": event_type, "result_count": results_value.size()})
	if event_type in ["peer_disconnected", "peer_resumed", "peer_departed", "rematch_requested"]:
		if not _valid_identifier(str(payload.get("player_id", "")), Limits.MAX_PLAYER_ID_BYTES):
			return Result.failure(&"race_event_player_invalid", "Race event player is invalid.")
		return Result.success({"type": event_type})
	if event_type == "race_started":
		if typeof(payload.get("tick")) != TYPE_INT or int(payload["tick"]) < 0:
			return Result.failure(&"race_start_tick_invalid", "Race start tick is invalid.")
		return Result.success({"type": event_type})
	return Result.failure(&"race_event_type_invalid", "Race event type is not recognized.")


static func _valid_identifier(value: String, maximum_bytes: int) -> bool:
	if value.is_empty() or value.to_utf8_buffer().size() > maximum_bytes:
		return false
	for index in value.length():
		var code := value.unicode_at(index)
		if code < 33 or code > 126:
			return false
	return true
