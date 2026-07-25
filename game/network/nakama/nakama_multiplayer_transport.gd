class_name NakamaMultiplayerTransport
extends MultiplayerTransport
## Real Nakama adapter behind the transport-neutral RaceGlyph contract.
## The official SDK factory is instantiated as a child instead of requiring a
## project autoload, keeping integration explicit and testable.

const Limits := preload("res://game/network/network_limits.gd")
const Protocol := preload("res://game/network/network_protocol.gd")
const NakamaFactoryScript := preload("res://game/network/nakama/vendor/heroiclabs_nakama_godot/addons/com.heroiclabs.nakama/Nakama.gd")

const RPC_CREATE := "raceglyph_create_room"
const RPC_JOIN := "raceglyph_join_room"
const RPC_LEAVE := "raceglyph_leave_room"
const SDK_LOG_ERROR := 1
const RECONNECT_RETRY_BUDGET_MS := 18_000
const RECONNECT_RETRY_INITIAL_MS := 50
const RECONNECT_RETRY_MAX_MS := 500

var _host_node: Node
var _factory: Node
var _client: NakamaClient
var _session: NakamaSession
var _socket: NakamaSocket
var _events: Array[Dictionary] = []
var _room_state: Dictionary = {}
var _sequence_by_opcode: Dictionary = {}
var _match_id: String = ""
var _room_code: String = ""
var _reconnect_token: String = ""
var _room_epoch: int = 0
var _display_name: String = ""
var _last_server_tick: int = 0


func authenticate_device_async(
		host_node: Node,
		device_id: String,
		display_name: String,
		host: String = "127.0.0.1",
		port: int = 7350,
		server_key: String = "defaultkey",
		http_scheme: String = "http"
	) -> Dictionary:
	if host_node == null or device_id.length() < 10 or display_name.strip_edges().is_empty():
		return Result.failure(&"nakama_configuration_invalid", "Host node, device ID, or display name is invalid.")
	_host_node = host_node
	_display_name = display_name.strip_edges()
	_factory = NakamaFactoryScript.new()
	_factory.name = "RaceGlyphNakamaSDK"
	_host_node.add_child(_factory)
	# ERROR avoids logging bearer tokens and device-auth credentials in normal
	# client/test output while preserving actionable SDK failures.
	_client = _factory.create_client(server_key, host, port, http_scheme, 5, SDK_LOG_ERROR)
	var username := _safe_username(device_id)
	_session = await _client.authenticate_device_async(device_id, username, true, {
		"client": "raceglyph",
		"protocol": str(Limits.PROTOCOL_VERSION),
	})
	if _session == null or _session.is_exception() or not _session.is_valid():
		return Result.failure(&"nakama_device_auth_failed", "Nakama device authentication failed.")
	return await _open_socket()


func create_private_room(display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if not _authenticated():
		return Result.failure(&"nakama_not_authenticated", "Authenticate before creating a room.")
	_display_name = display_name.strip_edges()
	var hello := compatibility if not compatibility.is_empty() else Limits.compatibility_payload()
	var rpc_result := await _rpc(RPC_CREATE, {
		"display_name": _display_name,
		"car_id": str(cosmetics.get("car_id", "car-prime")),
		"team_id": str(cosmetics.get("team_id", "team-vector")),
		"compatibility": hello,
	})
	if not rpc_result["ok"]:
		return rpc_result
	return await _join_from_rpc(rpc_result["value"])


func join_private_room(room_code: String, display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if not _authenticated():
		return Result.failure(&"nakama_not_authenticated", "Authenticate before joining a room.")
	_display_name = display_name.strip_edges()
	var hello := compatibility if not compatibility.is_empty() else Limits.compatibility_payload()
	var rpc_result := await _rpc(RPC_JOIN, {
		"room_code": room_code.strip_edges().to_upper(),
		"display_name": _display_name,
		"car_id": str(cosmetics.get("car_id", "car-prime")),
		"team_id": str(cosmetics.get("team_id", "team-vector")),
		"compatibility": hello,
	})
	if not rpc_result["ok"]:
		return rpc_result
	return await _join_from_rpc(rpc_result["value"])


func submit_track_manifest(room_code: String, manifest: Dictionary) -> Dictionary:
	var prepared := _prepare_track_manifest(manifest)
	if not prepared["ok"]:
		return prepared
	return await _send_opcode(room_code, Protocol.OP_TRACK_MANIFEST, prepared["value"])


func _prepare_track_manifest(manifest: Dictionary) -> Dictionary:
	# Keep the TrackDefinition validation graph outside this SDK adapter's
	# compiled dependency closure. Godot 4.7 retains that mixed script graph at
	# one-shot process exit; a cache-ignored validator preserves the same strict
	# boundary and can be released before socket I/O begins.
	var manifest_validator := ResourceLoader.load(
		_manifest_validator_path(), "Script", ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	if manifest_validator == null:
		return Result.failure(
			&"track_manifest_validator_missing", "Track manifest validation is unavailable."
		)
	var validation: Dictionary = manifest_validator.call("validate", manifest)
	if not validation["ok"]:
		return validation
	# Send the decoded definition's canonical dictionary. Callers may provide
	# ordinary JSON arrays, while TrackDefinition stores coordinates as float32;
	# serializing the normalized definition ensures Nakama hashes the same bytes
	# that every Godot peer validated locally.
	var validated: Dictionary = validation["value"]
	var definition: Variant = validated["definition"]
	var wire_manifest := {
		"track_definition": definition.to_dictionary(true),
		"source_hash": str(validated["source_hash"]),
		"generator_version": int(validated["generator_version"]),
		"compiled_fingerprint": str(validated["compiled_fingerprint"]),
	}
	# The successful validation payload owns a decoded TrackDefinition. Release
	# it before suspending on socket I/O so completed coroutine state cannot keep
	# the track script/resource graph alive during one-shot test shutdown.
	validated.clear()
	validation.clear()
	definition = null
	manifest_validator = null
	return Result.success(wire_manifest)


static func _manifest_validator_path() -> String:
	# Build at runtime so Godot does not fold this back into a compile-time
	# preload and recreate the SDK/TrackDefinition retention cycle.
	return "/".join(PackedStringArray([
		"res:", "", "game", "network", "network_track_manifest.gd",
	]))


func submit_generation_report(room_code: String, report: Dictionary) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_GENERATION_REPORT, report)


func set_ready(room_code: String, ready: bool) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_READY_STATE, {"ready": ready})


func set_race_config(room_code: String, config: Dictionary) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_ROOM_CONFIG, {
		"type": "race_config",
		"laps": config.get("laps"),
		"collisions": config.get("collisions"),
	})


func set_room_lock(room_code: String, locked: bool) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_ROOM_CONFIG, {
		"type": "room_lock",
		"locked": locked,
	})


func start_countdown(room_code: String) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_START_AT_TICK, {"request_start": true})


func kick_member(room_code: String, player_id: String) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_RACE_EVENT, {
		"type": "kick_member",
		"player_id": player_id,
	})


func request_rematch(room_code: String) -> Dictionary:
	return await _send_opcode(room_code, Protocol.OP_RACE_EVENT, {"type": "rematch"})


func send_envelope(room_code: String, message: Dictionary) -> Dictionary:
	if not _joined(room_code):
		return Result.failure(&"nakama_not_joined", "Transport is not joined to this room.")
	var validation := Protocol.validate_envelope(message, _session.user_id, _room_epoch)
	if not validation["ok"]:
		return validation
	var completion = await _socket.send_match_state_async(_match_id, int(message["opcode"]), JSON.stringify(message))
	if completion != null and completion.has_method("is_exception") and completion.is_exception():
		return Result.failure(&"nakama_send_failed", "Nakama rejected the realtime send.")
	var opcode := int(message["opcode"])
	_sequence_by_opcode[opcode] = maxi(
		int(_sequence_by_opcode.get(opcode, 0)), int(message.get("seq", 0))
	)
	return Result.success({"queued": true, "opcode": int(message["opcode"])})


func reconnect(room_code: String, reconnect_token: String) -> Dictionary:
	if not _session_valid() or room_code.strip_edges().to_upper() != _room_code:
		return Result.failure(&"nakama_reconnect_invalid", "Reconnect room or session is invalid.")
	if reconnect_token != _reconnect_token:
		return Result.failure(&"reconnect_token_invalid", "Reconnect token does not match local membership.")
	if _socket == null or not _socket.is_connected_to_host():
		var opened := await _open_socket()
		if not opened["ok"]:
			return opened
	var deadline := Time.get_ticks_msec() + RECONNECT_RETRY_BUDGET_MS
	var retry_ms := RECONNECT_RETRY_INITIAL_MS
	while true:
		var joined = await _socket.join_match_async(_match_id, {"reconnect_token": reconnect_token})
		if joined != null and not joined.is_exception():
			break
		var reason := ""
		if joined != null and joined.has_method("get_exception") and joined.get_exception() != null:
			reason = str(joined.get_exception().message).to_lower()
		if not reason.contains("already_connected") or Time.get_ticks_msec() >= deadline:
			return Result.failure(
				&"nakama_reconnect_refused", "Nakama refused the reconnect attempt.", {"reason": reason}
			)
		await _host_node.get_tree().create_timer(float(retry_ms) / 1000.0).timeout
		retry_ms = mini(retry_ms * 2, RECONNECT_RETRY_MAX_MS)
	var resume_event := await wait_for_opcode_async(Protocol.OP_RESUME, 3000)
	if not resume_event["ok"]:
		return Result.failure(&"nakama_resume_timeout", "Nakama did not deliver reconnect state.")
	return Result.success({
		"room_code": _room_code,
		"match_id": _match_id,
		"room_epoch": _room_epoch,
		"reconnect_token": _reconnect_token,
		"resume": resume_event["value"]["payload"],
	})


func suspend_connection(room_code: String) -> Dictionary:
	if not _joined(room_code):
		return Result.failure(&"nakama_not_joined", "Transport is not joined to this room.")
	var completion = await _socket.leave_match_async(_match_id)
	if completion != null and completion.is_exception():
		return Result.failure(&"nakama_leave_failed", "Nakama did not acknowledge match leave.")
	return Result.success({"reconnect_token": _reconnect_token})


func simulate_socket_drop() -> Dictionary:
	if _socket == null:
		return Result.failure(&"nakama_socket_missing", "Nakama socket does not exist.")
	_socket.close()
	return Result.success({"closed": true})


func leave_room(room_code: String) -> Dictionary:
	if not _joined(room_code):
		return Result.failure(&"nakama_not_joined", "Transport is not joined to this room.")
	var leave_rpc := await _rpc(RPC_LEAVE, {"match_id": _match_id})
	if not leave_rpc["ok"]:
		return leave_rpc
	var departed_match_id := _match_id
	var completion = await _socket.leave_match_async(departed_match_id)
	var socket_acknowledged: bool = completion == null or not completion.is_exception()
	_clear_room_membership()
	return Result.success({"left": true, "socket_acknowledged": socket_acknowledged})


func room_snapshot(room_code: String) -> Dictionary:
	if room_code.strip_edges().to_upper() != _room_code or _room_state.is_empty():
		return Result.failure(&"room_snapshot_unavailable", "No authoritative room snapshot has arrived.")
	return Result.success(_room_state.duplicate(true))


func drain_events() -> Array[Dictionary]:
	var output := _events.duplicate(true)
	_events.clear()
	return output


func wait_for_opcode_async(opcode: int, timeout_ms: int = 3000) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		for index in _events.size():
			if int(_events[index].get("opcode", -1)) == opcode:
				var event := _events[index]
				_events.remove_at(index)
				return Result.success(event)
		await Engine.get_main_loop().process_frame
	return Result.failure(&"nakama_event_timeout", "Timed out waiting for authoritative match event.", {"opcode": opcode})


func session_user_id() -> String:
	return "" if _session == null else _session.user_id


func reconnect_token() -> String:
	return _reconnect_token


func room_epoch() -> int:
	return _room_epoch


func match_id() -> String:
	return _match_id


func close() -> void:
	if _socket != null:
		_socket.close()
	if is_instance_valid(_factory):
		_factory.queue_free()
	_socket = null
	_client = null
	_session = null
	_clear_room_membership()


func _rpc(rpc_id: String, payload: Dictionary) -> Dictionary:
	var response = await _client.rpc_async(_session, rpc_id, JSON.stringify(payload))
	if response == null or response.is_exception():
		return Result.failure(&"nakama_rpc_failed", "Nakama RPC request failed.", {"rpc": rpc_id})
	var parser := JSON.new()
	if parser.parse(response.payload) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return Result.failure(&"nakama_rpc_malformed", "Nakama RPC returned malformed JSON.", {"rpc": rpc_id})
	var value: Dictionary = parser.data
	if not bool(value.get("ok", false)):
		var error: Dictionary = value.get("error", {})
		return Result.failure(
			StringName(str(error.get("code", "nakama_rpc_refused"))),
			str(error.get("message", "Nakama RPC refused the request."))
		)
	return Result.success(value)


func _join_from_rpc(value: Dictionary) -> Dictionary:
	_match_id = str(value.get("match_id", ""))
	_room_code = str(value.get("room_code", "")).to_upper()
	_reconnect_token = str(value.get("reconnect_token", ""))
	_room_epoch = int(value.get("room_epoch", 0))
	if _match_id.is_empty() or _reconnect_token.is_empty() or _room_epoch <= 0:
		return Result.failure(&"nakama_rpc_malformed", "Room RPC omitted required join data.")
	var joined = await _socket.join_match_async(_match_id, {"reconnect_token": _reconnect_token})
	if joined == null or joined.is_exception():
		_clear_room_membership()
		return Result.failure(&"nakama_match_join_failed", "Nakama authoritative match join failed.")
	return Result.success({
		"room_code": _room_code,
		"match_id": _match_id,
		"room_epoch": _room_epoch,
		"reconnect_token": _reconnect_token,
	})


func _open_socket() -> Dictionary:
	_socket = _factory.create_socket_from(_client)
	_socket.received_match_state.connect(_on_match_state)
	_socket.received_error.connect(_on_socket_error)
	_socket.closed.connect(_on_socket_closed)
	_socket.connection_error.connect(_on_connection_error)
	var connected = await _socket.connect_async(_session, true, 5)
	if connected == null or connected.is_exception():
		return Result.failure(&"nakama_socket_connect_failed", "Nakama realtime socket connection failed.")
	return Result.success({"user_id": _session.user_id, "username": _session.username})


func _send_opcode(room_code: String, opcode: int, payload: Dictionary) -> Dictionary:
	return await send_envelope(room_code, _make_envelope(opcode, payload))


func _make_envelope(opcode: int, payload: Dictionary) -> Dictionary:
	var sequence := int(_sequence_by_opcode.get(opcode, 0)) + 1
	_sequence_by_opcode[opcode] = sequence
	return Protocol.make_envelope(
		opcode,
		_session.user_id,
		sequence,
		_room_epoch,
		payload,
		_estimated_sim_tick()
	)


func _on_match_state(match_state: Variant) -> void:
	var parser := JSON.new()
	if parser.parse(str(match_state.data)) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		_append_local_error("nakama_event_malformed")
		return
	var envelope: Dictionary = parser.data
	# Godot's JSON decoder represents every JSON number as a float. Normalize
	# only integer-valued protocol fields before applying the strict shared
	# validator; fractional, non-finite, and out-of-safe-range values remain
	# untouched and are rejected by validation.
	_normalize_wire_integers(envelope)
	var opcode := int(envelope.get("opcode", -1))
	if int(match_state.op_code) != opcode:
		_append_local_error("nakama_opcode_mismatch")
		return
	# Nakama supplies an authenticated presence for relayed peer data and no
	# presence for authoritative runtime broadcasts. Bind sender_id to that
	# transport identity so relayed inputs/snapshots remain valid without
	# trusting the envelope's claimed sender.
	var expected_sender := "server"
	if match_state.presence != null:
		expected_sender = str(match_state.presence.user_id)
	var validation := Protocol.validate_envelope(envelope, expected_sender)
	if not validation["ok"]:
		_append_local_error(str(validation["error"]["code"]))
		return
	if opcode == Protocol.OP_RESUME:
		var snapshot_value: Variant = envelope.get("payload", {}).get("authoritative_snapshot")
		if snapshot_value != null:
			if typeof(snapshot_value) != TYPE_DICTIONARY:
				_append_local_error("resume_snapshot_malformed")
				return
			var snapshot: Dictionary = snapshot_value
			_normalize_wire_integers(snapshot)
			var expected_host := str(_room_state.get("host_id", ""))
			var snapshot_validation := Protocol.validate_envelope(
				snapshot, expected_host, int(envelope["room_epoch"])
			)
			if not snapshot_validation["ok"] \
					or int(snapshot.get("opcode", -1)) != Protocol.OP_STATE_SNAPSHOT:
				_append_local_error("resume_snapshot_invalid")
				return
			snapshot_validation.clear()
	# OP_TRACK_MANIFEST validation owns a decoded TrackDefinition on success.
	validation.clear()
	var event_epoch := int(envelope.get("room_epoch", 0))
	if _room_epoch > 0:
		if opcode == Protocol.OP_ROOM_CONFIG:
			if event_epoch < _room_epoch:
				_append_local_error("room_epoch_stale")
				return
		elif event_epoch != _room_epoch:
			_append_local_error("room_epoch_stale")
			return
	_events.append(envelope.duplicate(true))
	_last_server_tick = maxi(_last_server_tick, int(envelope.get("tick", 0)))
	if opcode == Protocol.OP_ROOM_CONFIG:
		_room_state = envelope.get("payload", {}).duplicate(true)
		_room_epoch = int(_room_state.get("room_epoch", _room_epoch))
	elif opcode == Protocol.OP_RESUME:
		var rotated_token := str(envelope.get("payload", {}).get("reconnect_token", ""))
		if not rotated_token.is_empty():
			_reconnect_token = rotated_token
	elif opcode == Protocol.OP_ROOM_ENDED:
		_room_state["state"] = str(Limits.ROOM_CLOSED)
		_room_state["close_reason"] = str(envelope.get("payload", {}).get("reason", "room_ended"))


func _normalize_wire_integers(envelope: Dictionary) -> void:
	for key in ["protocol", "opcode", "room_epoch", "seq", "tick"]:
		_normalize_json_integer(envelope, key)
	var opcode := int(envelope.get("opcode", -1))
	var payload_value: Variant = envelope.get("payload")
	if typeof(payload_value) != TYPE_DICTIONARY:
		return
	var payload: Dictionary = payload_value
	if opcode == Protocol.OP_TRACK_MANIFEST:
		_normalize_json_integer(payload, "generator_version")
	elif opcode == Protocol.OP_ROOM_CONFIG:
		_normalize_json_integer(payload, "laps")
		var config_value: Variant = payload.get("race_config")
		if config_value is Dictionary:
			_normalize_json_integer(config_value, "laps")
		var countdown_value: Variant = payload.get("countdown")
		if countdown_value is Dictionary:
			_normalize_json_integer(countdown_value, "issued_at_tick")
			_normalize_json_integer(countdown_value, "start_tick")
			var countdown_config: Variant = countdown_value.get("race_config")
			if countdown_config is Dictionary:
				_normalize_json_integer(countdown_config, "laps")
	elif opcode == Protocol.OP_INPUT_FRAME:
		for key in ["steering", "throttle", "brake", "ack_host_tick"]:
			_normalize_json_integer(payload, key)
	elif opcode == Protocol.OP_START_AT_TICK:
		_normalize_json_integer(payload, "issued_at_tick")
		_normalize_json_integer(payload, "start_tick")
		var start_config: Variant = payload.get("race_config")
		if start_config is Dictionary:
			_normalize_json_integer(start_config, "laps")
	elif opcode == Protocol.OP_STATE_SNAPSHOT:
		_normalize_snapshot_cars(payload)
	elif opcode == Protocol.OP_RACE_EVENT:
		var event_type := str(payload.get("type", ""))
		if event_type == "race_started":
			_normalize_json_integer(payload, "tick")
		elif event_type == "race_complete":
			var results_value: Variant = payload.get("results")
			if results_value is Array:
				for result_value in results_value:
					if result_value is Dictionary:
						for key in ["slot", "position", "laps", "finish_time_ms"]:
							_normalize_json_integer(result_value, key)
	elif opcode == Protocol.OP_RESUME:
		var snapshot_value: Variant = payload.get("authoritative_snapshot")
		if typeof(snapshot_value) == TYPE_DICTIONARY:
			_normalize_wire_integers(snapshot_value)


func _normalize_snapshot_cars(payload: Dictionary) -> void:
	var cars_value: Variant = payload.get("cars")
	if typeof(cars_value) != TYPE_ARRAY:
		return
	for car_value in cars_value:
		if typeof(car_value) != TYPE_DICTIONARY:
			continue
		var car: Dictionary = car_value
		for key in [
			"slot", "x_q", "y_q", "rotation_q", "velocity_x_q",
			"velocity_y_q", "lap", "checkpoint", "collision_layer", "collision_mask", "flags",
			"gear", "engine_rpm_q", "shift_ticks", "steering_q", "slip_angle_q",
			"wheel_slip_q", "lateral_accel_q", "contact_serial", "contact_tick",
			"contact_speed_q", "contact_x_q", "contact_y_q", "contact_normal_x_q",
			"contact_normal_y_q",
		]:
			_normalize_json_integer(car, key)


func _normalize_json_integer(values: Dictionary, key: String) -> void:
	if not values.has(key) or typeof(values[key]) != TYPE_FLOAT:
		return
	var number := float(values[key])
	if is_nan(number) or is_inf(number) or number != floor(number) \
			or absf(number) > float(Limits.MAX_SAFE_SEQUENCE):
		return
	values[key] = int(number)


func _on_socket_error(_error: Variant) -> void:
	_append_local_error("nakama_socket_error")


func _on_socket_closed() -> void:
	_append_local_error("nakama_socket_closed")


func _on_connection_error(_error: Variant) -> void:
	_append_local_error("nakama_connection_error")


func _append_local_error(code: String, value: String = "") -> void:
	var payload := {"code": code}
	if not value.is_empty():
		payload["value"] = value
	_events.append({
		"protocol": Limits.PROTOCOL_VERSION,
		"opcode": Protocol.OP_ERROR,
		"room_epoch": _room_epoch,
		"sender_id": "nakama",
		"seq": 0,
		"payload": payload,
	})


func _authenticated() -> bool:
	return _session_valid() and _socket != null and _socket.is_connected_to_host()


func _session_valid() -> bool:
	return _session != null and _session.is_valid()


func _clear_room_membership() -> void:
	_match_id = ""
	_room_code = ""
	_reconnect_token = ""
	_room_epoch = 0
	_room_state.clear()
	_sequence_by_opcode.clear()
	_last_server_tick = 0


func _joined(room_code: String) -> bool:
	return _authenticated() and not _match_id.is_empty() \
		and room_code.strip_edges().to_upper() == _room_code


func _estimated_sim_tick() -> int:
	return _last_server_tick


func _safe_username(device_id: String) -> String:
	var compact := device_id.to_lower()
	for character in ["-", ":", ".", "/", " "]:
		compact = compact.replace(character, "_")
	return ("rg_" + compact).left(32)
