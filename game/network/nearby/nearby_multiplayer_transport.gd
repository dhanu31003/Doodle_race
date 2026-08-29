class_name NearbyMultiplayerTransport
extends MultiplayerTransport
## Server-free Android private rooms. The creator phone owns lobby and race
## authority; Google Nearby supplies encrypted discovery and reliable bytes.

const Limits := preload("res://game/network/network_limits.gd")
const Protocol := preload("res://game/network/network_protocol.gd")
const BridgeType := preload("res://game/network/nearby/nearby_connection_bridge.gd")
const FakeServerType := preload("res://game/network/fake_room_server.gd")

const ROLE_NONE: StringName = &"none"
const ROLE_HOST: StringName = &"host"
const ROLE_GUEST: StringName = &"guest"
const WIRE_VERSION := 1
const DISCOVERY_PREFIX := "RG4"
const PERMISSION_TIMEOUT_MS := 30_000
const DISCOVERY_TIMEOUT_MS := 20_000
const CONNECTION_TIMEOUT_MS := 15_000
const REQUEST_TIMEOUT_MS := 10_000
const MAX_WIRE_CHARACTERS := 350_000

var _host_node: Node
var _bridge: Variant
var _role: StringName = ROLE_NONE
var _server: Variant
var _local_player_id := ""
var _display_name := ""
var _room_code := ""
var _room_epoch := 0
var _reconnect_token := ""
var _host_endpoint_id := ""
var _desired_room_code := ""
var _discovered_host_id := ""
var _advertising_ready := false
var _discovery_ready := false
var _permission_resolved := false
var _permission_granted := false
var _request_serial := 0
var _last_server_pump_ms := 0
var _closed := false

var _connected_endpoints: Dictionary = {}
var _endpoint_to_player: Dictionary = {}
var _player_to_endpoint: Dictionary = {}
var _responses: Dictionary = {}
var _events: Array[Dictionary] = []
var _room_cache: Dictionary = {}
var _last_operation_error: Dictionary = {}


func configure_test_bridge(value: Variant) -> void:
	_bridge = value


func authenticate_device_async(
		host_node: Node,
		device_id: String,
		display_name: String,
		_host: String = "",
		_port: int = 0,
		_server_key: String = "",
		_http_scheme: String = ""
	) -> Dictionary:
	if host_node == null or device_id.length() < 10 or display_name.strip_edges().is_empty():
		return Result.failure(&"nearby_configuration_invalid", "Nearby identity configuration is invalid.")
	_host_node = host_node
	_display_name = display_name.strip_edges().left(Limits.MAX_DISPLAY_NAME_LENGTH)
	_local_player_id = "nearby-%s" % device_id.sha256_text().left(24)
	_closed = false
	if _bridge == null:
		_bridge = BridgeType.new()
	var initialized: Dictionary = _bridge.initialize()
	if not initialized.get("ok", false):
		return initialized
	_bind_bridge()
	if not _bridge.has_required_permissions():
		_permission_resolved = false
		_permission_granted = false
		_bridge.request_required_permissions()
		var permission_wait := await _wait_until(
			func() -> bool: return _permission_resolved,
			PERMISSION_TIMEOUT_MS,
			&"nearby_permission_timeout",
			"Nearby permission approval timed out."
		)
		if not permission_wait["ok"]:
			return permission_wait
		if not _permission_granted:
			return Result.failure(
				&"nearby_permissions_denied",
				"Nearby devices permission is required to find and race friends nearby."
			)
	return Result.success({"user_id": _local_player_id, "transport": "nearby"})


func create_private_room(display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if _host_node == null or _bridge == null:
		return Result.failure(&"nearby_not_initialized", "Nearby must initialize before creating a room.")
	_role = ROLE_HOST
	_server = FakeServerType.new()
	var created: Dictionary = _server.create_room(
		_local_player_id, display_name, cosmetics, compatibility
	)
	if not created.get("ok", false):
		return created
	_apply_join_value(created["value"])
	_advertising_ready = false
	_last_operation_error.clear()
	_bridge.start_advertising(_advertisement_name(_room_code, display_name))
	var advertised := await _wait_until(
		func() -> bool: return _advertising_ready or not _last_operation_error.is_empty(),
		CONNECTION_TIMEOUT_MS,
		&"nearby_advertising_timeout",
		"Nearby room advertising timed out."
	)
	if not advertised["ok"]:
		return advertised
	if not _last_operation_error.is_empty():
		return {"ok": false, "error": _last_operation_error.duplicate(true)}
	_pump_host_server()
	return Result.success(created["value"].duplicate(true))


func join_private_room(room_code: String, display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if _host_node == null or _bridge == null:
		return Result.failure(&"nearby_not_initialized", "Nearby must initialize before joining a room.")
	_role = ROLE_GUEST
	_desired_room_code = room_code.strip_edges().to_upper()
	_discovered_host_id = ""
	_discovery_ready = false
	_last_operation_error.clear()
	_bridge.start_discovery()
	var discovered := await _wait_until(
		func() -> bool:
			return not _discovered_host_id.is_empty() or not _last_operation_error.is_empty(),
		DISCOVERY_TIMEOUT_MS,
		&"nearby_room_not_found",
		"No nearby RaceGlyph room with that code was found. Keep both devices awake and close together."
	)
	_bridge.stop_discovery()
	if not discovered["ok"]:
		return discovered
	if not _last_operation_error.is_empty():
		return {"ok": false, "error": _last_operation_error.duplicate(true)}
	_host_endpoint_id = _discovered_host_id
	_bridge.request_connection(_host_endpoint_id, _peer_endpoint_name(_display_name))
	var connected := await _wait_until(
		func() -> bool:
			return bool(_connected_endpoints.get(_host_endpoint_id, false)) \
					or not _last_operation_error.is_empty(),
		CONNECTION_TIMEOUT_MS,
		&"nearby_connection_timeout",
		"The nearby host did not complete the connection."
	)
	if not connected["ok"]:
		return connected
	if not _last_operation_error.is_empty():
		return {"ok": false, "error": _last_operation_error.duplicate(true)}
	var joined := await _request_host("join", {
		"player_id": _local_player_id,
		"room_code": _desired_room_code,
		"display_name": display_name,
		"cosmetics": cosmetics,
		"compatibility": compatibility,
	}, REQUEST_TIMEOUT_MS)
	if not joined.get("ok", false):
		return joined
	_apply_join_value(joined["value"])
	return Result.success(joined["value"].duplicate(true))


func submit_track_manifest(room_code: String, manifest: Dictionary) -> Dictionary:
	return await _room_operation("track_manifest", {"room_code": room_code, "manifest": manifest})


func submit_generation_report(room_code: String, report: Dictionary) -> Dictionary:
	return await _room_operation("generation_report", {"room_code": room_code, "report": report})


func set_ready(room_code: String, ready: bool) -> Dictionary:
	return await _room_operation("ready", {"room_code": room_code, "ready": ready})


func set_race_config(room_code: String, config: Dictionary) -> Dictionary:
	return await _room_operation("race_config", {"room_code": room_code, "config": config})


func set_room_lock(room_code: String, locked: bool) -> Dictionary:
	return await _room_operation("room_lock", {"room_code": room_code, "locked": locked})


func start_countdown(room_code: String) -> Dictionary:
	return await _room_operation("start_countdown", {"room_code": room_code})


func kick_member(room_code: String, player_id: String) -> Dictionary:
	return await _room_operation("kick", {"room_code": room_code, "player_id": player_id})


func request_rematch(room_code: String) -> Dictionary:
	return await _room_operation("rematch", {"room_code": room_code})


func send_envelope(room_code: String, message: Dictionary) -> Dictionary:
	if room_code.strip_edges().to_upper() != _room_code or _room_epoch <= 0:
		return Result.failure(&"nearby_not_joined", "Nearby transport is not joined to this room.")
	var expected_sender := _local_player_id
	var validation := Protocol.validate_envelope(message, expected_sender, _room_epoch)
	if not validation["ok"]:
		return validation
	var opcode := int(message.get("opcode", -1))
	if _role == ROLE_HOST:
		if opcode not in [Protocol.OP_STATE_SNAPSHOT, Protocol.OP_RACE_EVENT]:
			return Result.failure(&"nearby_host_envelope_invalid", "Host sent an unsupported peer-authority message.")
		_broadcast_wire({"v": WIRE_VERSION, "kind": "event", "event": message})
		return Result.success({"queued": true, "opcode": opcode})
	if _role != ROLE_GUEST or _host_endpoint_id.is_empty():
		return Result.failure(&"nearby_connection_lost", "The nearby host connection is unavailable.")
	if opcode != Protocol.OP_INPUT_FRAME:
		return Result.failure(&"nearby_guest_envelope_invalid", "Guests may send only bounded race inputs.")
	if not _send_wire(_host_endpoint_id, {"v": WIRE_VERSION, "kind": "race", "envelope": message}):
		return Result.failure(&"nearby_send_failed", "The nearby race input could not be sent.")
	return Result.success({"queued": true, "opcode": opcode})


func suspend_connection(_room_code_value: String) -> Dictionary:
	return Result.success({"suspended": true, "reconnect_token": _reconnect_token})


func reconnect(room_code: String, reconnect_token: String) -> Dictionary:
	if room_code.strip_edges().to_upper() != _room_code or reconnect_token != _reconnect_token:
		return Result.failure(&"nearby_reconnect_invalid", "Nearby room identity changed while the app was paused.")
	var connected := _role == ROLE_HOST or bool(_connected_endpoints.get(_host_endpoint_id, false))
	if not connected:
		return Result.failure(&"nearby_connection_lost", "The nearby connection ended while the app was paused.")
	return Result.success({
		"room_code": _room_code,
		"room_epoch": _room_epoch,
		"reconnect_token": _reconnect_token,
		"room": _room_cache.duplicate(true),
		"resume": {"type": "peer_resumed", "player_id": _local_player_id},
	})


func leave_room(room_code: String) -> Dictionary:
	if _role == ROLE_HOST:
		_broadcast_wire({"v": WIRE_VERSION, "kind": "closed", "reason": "host_left"})
		if _server != null and not _room_code.is_empty():
			_server.leave_room(_local_player_id, room_code)
		close()
		return Result.success({"left": true, "host_closed": true})
	if _role == ROLE_GUEST and not _host_endpoint_id.is_empty():
		var result := await _request_host("leave", {"room_code": room_code}, 2000)
		_bridge.disconnect_endpoint(_host_endpoint_id)
		close()
		return result if result.get("ok", false) else Result.success({"left": true, "local_only": true})
	close()
	return Result.success({"left": true})


func room_snapshot(room_code: String) -> Dictionary:
	if room_code.strip_edges().to_upper() != _room_code:
		return Result.failure(&"nearby_not_joined", "Nearby transport is not joined to this room.")
	if _role == ROLE_HOST and _server != null:
		_pump_host_server()
		var snapshot: Dictionary = _server.room_snapshot(_local_player_id, room_code)
		if snapshot.get("ok", false):
			_room_cache = snapshot["value"].duplicate(true)
		return snapshot
	return Result.success(_room_cache.duplicate(true)) if not _room_cache.is_empty() \
		else Result.failure(&"nearby_room_state_pending", "Nearby room state is still synchronizing.")


func drain_events() -> Array[Dictionary]:
	if _role == ROLE_HOST:
		_pump_host_server()
	var output := _events.duplicate(true)
	_events.clear()
	return output


func authority_mode() -> String:
	return "peer_host"


func transport_label() -> String:
	return "NEARBY • NO INTERNET"


func close() -> void:
	if _closed:
		return
	_closed = true
	if _bridge != null:
		_bridge.stop_all()
	_connected_endpoints.clear()
	_endpoint_to_player.clear()
	_player_to_endpoint.clear()
	_responses.clear()
	_role = ROLE_NONE
	_server = null


func _room_operation(operation: String, payload: Dictionary) -> Dictionary:
	if _role == ROLE_HOST:
		var result := _execute_host_operation(_local_player_id, operation, payload)
		_pump_host_server()
		return result
	if _role != ROLE_GUEST:
		return Result.failure(&"nearby_not_joined", "Join a nearby room first.")
	return await _request_host(operation, payload, REQUEST_TIMEOUT_MS)


func _execute_host_operation(player_id: String, operation: String, payload: Dictionary) -> Dictionary:
	if _server == null:
		return Result.failure(&"nearby_host_unavailable", "The nearby host authority is unavailable.")
	var code := str(payload.get("room_code", _room_code)).to_upper()
	match operation:
		"join":
			var joining_id := str(payload.get("player_id", ""))
			return _server.join_room(
				joining_id,
				str(payload.get("room_code", "")),
				str(payload.get("display_name", "")),
				payload.get("cosmetics", {}),
				payload.get("compatibility", {})
			)
		"track_manifest":
			return _server.submit_track_manifest(player_id, code, payload.get("manifest", {}))
		"generation_report":
			return _server.submit_generation_report(player_id, code, payload.get("report", {}))
		"ready":
			return _server.set_ready(player_id, code, bool(payload.get("ready", false)))
		"race_config":
			return _server.set_race_config(player_id, code, payload.get("config", {}))
		"room_lock":
			return _server.set_room_lock(player_id, code, bool(payload.get("locked", false)))
		"start_countdown":
			return _server.start_countdown(player_id, code)
		"kick":
			return _server.kick_member(player_id, code, str(payload.get("player_id", "")))
		"rematch":
			return _server.request_rematch(player_id, code)
		"leave":
			return _server.leave_room(player_id, code)
	return Result.failure(&"nearby_operation_invalid", "Nearby host received an unsupported operation.")


func _request_host(operation: String, payload: Dictionary, timeout_ms: int) -> Dictionary:
	if _host_endpoint_id.is_empty() or not bool(_connected_endpoints.get(_host_endpoint_id, false)):
		return Result.failure(&"nearby_connection_lost", "The nearby host connection is unavailable.")
	_request_serial += 1
	var request_id := "%s-%d" % [_local_player_id.right(8), _request_serial]
	if not _send_wire(_host_endpoint_id, {
		"v": WIRE_VERSION,
		"kind": "request",
		"id": request_id,
		"op": operation,
		"payload": payload,
	}):
		return Result.failure(&"nearby_send_failed", "The nearby room request could not be sent.")
	var waited := await _wait_until(
		func() -> bool: return _responses.has(request_id),
		timeout_ms,
		&"nearby_request_timeout",
		"The nearby host did not answer in time."
	)
	if not waited["ok"]:
		return waited
	var result: Dictionary = _responses.get(request_id, {}).duplicate(true)
	_responses.erase(request_id)
	return result


func _pump_host_server() -> void:
	if _role != ROLE_HOST or _server == null:
		return
	var now := Time.get_ticks_msec()
	if _last_server_pump_ms <= 0:
		_last_server_pump_ms = now
	var delta_ms := clampi(now - _last_server_pump_ms, 0, 250)
	_last_server_pump_ms = now
	if delta_ms > 0:
		_server.advance_time(delta_ms)
	_queue_server_events(_local_player_id, "")
	for player_id_value in _player_to_endpoint.keys():
		var player_id := str(player_id_value)
		_queue_server_events(player_id, str(_player_to_endpoint[player_id]))


func _queue_server_events(player_id: String, endpoint_id: String) -> void:
	for event in _server.drain_events(player_id):
		if endpoint_id.is_empty():
			_queue_event(event)
		else:
			_send_wire(endpoint_id, {"v": WIRE_VERSION, "kind": "event", "event": event})


func _on_message_received(endpoint_id: String, message: String) -> void:
	if message.length() > MAX_WIRE_CHARACTERS:
		return
	var parsed: Variant = JSON.parse_string(message)
	if not parsed is Dictionary or int(parsed.get("v", 0)) != WIRE_VERSION:
		return
	var kind := str(parsed.get("kind", ""))
	if _role == ROLE_HOST:
		_handle_host_wire(endpoint_id, kind, parsed)
	elif _role == ROLE_GUEST:
		_handle_guest_wire(endpoint_id, kind, parsed)


func _handle_host_wire(endpoint_id: String, kind: String, wire: Dictionary) -> void:
	if not bool(_connected_endpoints.get(endpoint_id, false)):
		return
	if kind == "request":
		var request_id := str(wire.get("id", "")).left(80)
		var operation := str(wire.get("op", ""))
		var payload: Dictionary = wire.get("payload", {}) if wire.get("payload", {}) is Dictionary else {}
		var player_id := str(_endpoint_to_player.get(endpoint_id, ""))
		if operation == "join":
			player_id = str(payload.get("player_id", ""))
			if player_id.is_empty() or _player_to_endpoint.has(player_id):
				_send_response(endpoint_id, request_id, Result.failure(&"nearby_identity_conflict", "Nearby player identity is already connected."))
				return
		var result := _execute_host_operation(player_id, operation, payload)
		if operation == "join" and result.get("ok", false):
			_endpoint_to_player[endpoint_id] = player_id
			_player_to_endpoint[player_id] = endpoint_id
		_send_response(endpoint_id, request_id, result)
		_pump_host_server()
		return
	if kind == "race":
		var player_id := str(_endpoint_to_player.get(endpoint_id, ""))
		var envelope: Dictionary = wire.get("envelope", {}) if wire.get("envelope", {}) is Dictionary else {}
		if player_id.is_empty():
			return
		var validation := Protocol.validate_envelope(envelope, player_id, _room_epoch)
		if not validation["ok"] or int(envelope.get("opcode", -1)) != Protocol.OP_INPUT_FRAME:
			return
		_pump_host_server()
		var accepted: Dictionary = _server.handle_envelope(player_id, _room_code, envelope)
		if accepted.get("ok", false):
			_queue_event(envelope)


func _handle_guest_wire(endpoint_id: String, kind: String, wire: Dictionary) -> void:
	if endpoint_id != _host_endpoint_id:
		return
	if kind == "response":
		var request_id := str(wire.get("id", ""))
		var result: Variant = wire.get("result")
		if not request_id.is_empty() and result is Dictionary:
			_responses[request_id] = result.duplicate(true)
		return
	if kind == "event" and wire.get("event") is Dictionary:
		_queue_event(wire["event"])
		return
	if kind == "closed":
		_queue_event(Protocol.make_envelope(
			Protocol.OP_ROOM_ENDED,
			"server",
			1,
			_room_epoch,
			{"reason": str(wire.get("reason", "host_left"))},
			0
		))


func _queue_event(event: Dictionary) -> void:
	if int(event.get("opcode", -1)) == Protocol.OP_ROOM_CONFIG \
			and event.get("payload") is Dictionary:
		_room_cache = event["payload"].duplicate(true)
	_events.append(event.duplicate(true))


func _send_response(endpoint_id: String, request_id: String, result: Dictionary) -> void:
	_send_wire(endpoint_id, {
		"v": WIRE_VERSION,
		"kind": "response",
		"id": request_id,
		"result": result,
	})


func _send_wire(endpoint_id: String, value: Dictionary) -> bool:
	if _bridge == null or endpoint_id.is_empty():
		return false
	return _bridge.send_message(endpoint_id, JSON.stringify(value))


func _broadcast_wire(value: Dictionary) -> void:
	for endpoint_id_value in _endpoint_to_player.keys():
		_send_wire(str(endpoint_id_value), value)


func _apply_join_value(value: Dictionary) -> void:
	_room_code = str(value.get("room_code", "")).to_upper()
	_room_epoch = int(value.get("room_epoch", value.get("room", {}).get("room_epoch", 0)))
	_reconnect_token = str(value.get("reconnect_token", "nearby-%s" % _local_player_id.sha256_text().left(24)))
	if value.get("room") is Dictionary:
		_room_cache = value["room"].duplicate(true)


func _bind_bridge() -> void:
	_bridge.permission_result.connect(_on_permission_result)
	_bridge.operation_failed.connect(_on_operation_failed)
	_bridge.advertising_started.connect(_on_advertising_started)
	_bridge.discovery_started.connect(_on_discovery_started)
	_bridge.endpoint_found.connect(_on_endpoint_found)
	_bridge.connection_result.connect(_on_connection_result)
	_bridge.endpoint_disconnected.connect(_on_endpoint_disconnected)
	_bridge.message_received.connect(_on_message_received)


func _on_permission_result(granted: bool, _reason: String) -> void:
	_permission_resolved = true
	_permission_granted = granted


func _on_operation_failed(operation: String, reason: String) -> void:
	_last_operation_error = {
		"code": "nearby_%s_failed" % operation,
		"message": "Nearby %s failed (%s)." % [operation, reason.left(80)],
	}


func _on_advertising_started() -> void:
	_advertising_ready = true


func _on_discovery_started() -> void:
	_discovery_ready = true


func _on_endpoint_found(endpoint_id: String, endpoint_name: String) -> void:
	if _role != ROLE_GUEST or _desired_room_code.is_empty():
		return
	var parts := endpoint_name.split("|", false, 2)
	if parts.size() >= 2 and parts[0] == DISCOVERY_PREFIX and parts[1].to_upper() == _desired_room_code:
		_discovered_host_id = endpoint_id


func _on_connection_result(endpoint_id: String, connected: bool, reason: String) -> void:
	_connected_endpoints[endpoint_id] = connected
	if not connected:
		_last_operation_error = {
			"code": "nearby_connection_refused",
			"message": "The nearby connection was refused (%s)." % reason.left(80),
		}


func _on_endpoint_disconnected(endpoint_id: String) -> void:
	_connected_endpoints.erase(endpoint_id)
	if _role == ROLE_HOST:
		var player_id := str(_endpoint_to_player.get(endpoint_id, ""))
		_endpoint_to_player.erase(endpoint_id)
		if not player_id.is_empty():
			_player_to_endpoint.erase(player_id)
			if _server != null and not _room_code.is_empty():
				_server.leave_room(player_id, _room_code)
				_pump_host_server()
	elif endpoint_id == _host_endpoint_id and not _closed:
		_queue_event(Protocol.make_envelope(
			Protocol.OP_ERROR,
			"server",
			1,
			_room_epoch,
			{"code": "nearby_connection_lost"},
			0
		))


func _wait_until(
		predicate: Callable,
		timeout_ms: int,
		error_code: StringName,
		error_message: String
	) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not bool(predicate.call()):
		if _closed or Time.get_ticks_msec() >= deadline:
			return Result.failure(error_code, error_message)
		await _host_node.get_tree().process_frame
	return Result.success({"completed": true})


static func _advertisement_name(code: String, display_name: String) -> String:
	return "%s|%s|%s" % [DISCOVERY_PREFIX, code.to_upper(), display_name.strip_edges().left(24)]


static func _peer_endpoint_name(display_name: String) -> String:
	return "RGP|%s" % display_name.strip_edges().left(24)
