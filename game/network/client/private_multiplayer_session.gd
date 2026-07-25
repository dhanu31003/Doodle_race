class_name PrivateMultiplayerSession
extends Node
## Persistent private-room client coordinator. It owns ephemeral transport
## credentials in memory, translates authoritative room events into a UI-safe
## snapshot, and locally compiles every received track before the ready gate.

signal session_changed(snapshot: Dictionary)
signal event_received(event: Dictionary)
signal session_error(error: Dictionary)
signal race_countdown_received(countdown: Dictionary)
signal race_started(start_tick: int)
signal room_ended(reason: String)
signal connection_transition_completed

const Limits := preload("res://game/network/network_limits.gd")
const Protocol := preload("res://game/network/network_protocol.gd")
const Result := preload("res://game/network/network_result.gd")
const Endpoint := preload("res://game/network/client/network_endpoint.gd")
const IdentityStore := preload("res://game/network/client/install_identity_store.gd")
const NAKAMA_TRANSPORT_PATH := "res://game/network/nakama/nakama_multiplayer_transport.gd"
const Manifest := preload("res://game/network/network_track_manifest.gd")
const Compiler := preload("res://game/track/generation/track_compiler.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const VehicleCatalog := preload("res://game/content/vehicle_catalog.gd")

const CONNECTION_OFFLINE: StringName = &"offline"
const CONNECTION_CONNECTING: StringName = &"connecting"
const CONNECTION_ONLINE: StringName = &"online"
const CONNECTION_RECONNECTING: StringName = &"reconnecting"
const CONNECTION_FAILED: StringName = &"failed"

var transport: MultiplayerTransport
var connection_state: StringName = CONNECTION_OFFLINE
var local_player_id: String = ""
var display_name: String = ""
var room_code: String = ""
var room_epoch: int = 0
var endpoint: Dictionary = Endpoint.defaults()

var _room: Dictionary = {}
var _reconnect_token: String = ""
var _current_definition: TrackDefinition
var _current_compiled: CompiledTrack
var _sequence_by_opcode: Dictionary = {}
var _last_server_tick: int = 0
var _tick_anchor_ms: int = 0
var _background_suspend_ms: int = -1
var _test_transport_injected := false
var _report_in_flight := false
var _closing := false
var _connection_generation := 0
var _suspend_in_flight := false
var _reconnect_in_flight := false
var _application_backgrounded := false
var _lifecycle_drive_in_flight := false


func _ready() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	poll_events()


func configure_test_transport(value: MultiplayerTransport, player_id: String) -> void:
	_close_transport()
	transport = value
	local_player_id = player_id
	connection_state = CONNECTION_ONLINE
	_test_transport_injected = true
	_emit_changed()


func connect_async(requested_name: String, requested_endpoint: Dictionary = {}) -> Dictionary:
	var name_result := validate_display_name(requested_name)
	if not name_result["ok"]:
		return name_result
	display_name = str(name_result["value"])
	endpoint = Endpoint.from_runtime_overrides(requested_endpoint)
	if _test_transport_injected and transport != null:
		connection_state = CONNECTION_ONLINE
		_emit_changed()
		return Result.success({"player_id": local_player_id, "endpoint": endpoint.duplicate(true)})
	connection_state = CONNECTION_CONNECTING
	_emit_changed()
	_close_transport()
	# Keep the comparatively large SDK graph cold for offline players and editor
	# smoke tests. Loading it only on an explicit Create/Join action also avoids
	# SDK resource-cache teardown noise in offline-only runs.
	var nakama_transport_script: Script = load(NAKAMA_TRANSPORT_PATH)
	if nakama_transport_script == null:
		return _fail_connection({"code": "transport_unavailable", "message": "Private-room transport could not be loaded."})
	transport = nakama_transport_script.new()
	var identity_result := IdentityStore.new().load_or_create()
	if not identity_result.get("ok", false):
		return _fail_connection(identity_result.get("error", {}))
	var authenticated: Dictionary = await transport.authenticate_device_async(
		self,
		str(identity_result["install_id"]),
		display_name,
		str(endpoint["host"]),
		int(endpoint["port"]),
		str(endpoint["server_key"]),
		str(endpoint["scheme"])
	)
	if not authenticated.get("ok", false):
		return _fail_connection(authenticated.get("error", {}))
	local_player_id = str(authenticated["value"].get("user_id", ""))
	if local_player_id.is_empty() and transport.has_method("session_user_id"):
		local_player_id = str(transport.call("session_user_id"))
	connection_state = CONNECTION_ONLINE
	_emit_changed()
	return Result.success({"player_id": local_player_id, "endpoint": endpoint.duplicate(true)})


func create_room_async(requested_name: String, requested_endpoint: Dictionary = {}) -> Dictionary:
	var connected := await connect_async(requested_name, requested_endpoint)
	if not connected["ok"]:
		return connected
	var created: Dictionary = await transport.create_private_room(
		display_name, _selected_cosmetics(), Limits.compatibility_payload()
	)
	if not created.get("ok", false):
		return _emit_failure(created)
	_apply_join_result(created["value"])
	poll_events()
	return Result.success(public_snapshot())


func join_room_async(code: String, requested_name: String, requested_endpoint: Dictionary = {}) -> Dictionary:
	var code_result := validate_room_code(code)
	if not code_result["ok"]:
		return code_result
	var connected := await connect_async(requested_name, requested_endpoint)
	if not connected["ok"]:
		return connected
	var joined: Dictionary = await transport.join_private_room(
		str(code_result["value"]), display_name, _selected_cosmetics(), Limits.compatibility_payload()
	)
	if not joined.get("ok", false):
		return _emit_failure(joined)
	_apply_join_result(joined["value"])
	poll_events()
	return Result.success(public_snapshot())


func select_track_async(definition: TrackDefinition) -> Dictionary:
	if not is_host():
		return Result.failure(&"host_only", "Only the room host can select a circuit.")
	if definition == null:
		return Result.failure(&"track_definition_missing", "Choose a valid circuit first.")
	if bool(_room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before changing the circuit.")
	var compiled_result: TrackCompileResult = Compiler.compile(definition)
	if not compiled_result.succeeded() or compiled_result.track == null:
		return Result.failure(&"track_compile_failed", "The selected circuit could not be compiled locally.")
	var manifest := Manifest.build(definition, compiled_result.track)
	var validation := Manifest.validate(manifest)
	if not validation["ok"]:
		return _emit_failure(validation)
	validation.clear()
	_current_definition = definition
	_current_compiled = compiled_result.track
	var submitted: Dictionary = await transport.submit_track_manifest(room_code, manifest)
	if not submitted.get("ok", false):
		return _emit_failure(submitted)
	# In-memory authority queues the broadcast synchronously; real Nakama will
	# report on the following process frames. Both paths use the same verifier.
	poll_events()
	return Result.success({"source_hash": manifest["source_hash"], "compiled_fingerprint": manifest["compiled_fingerprint"]})


func set_ready_async(ready: bool) -> Dictionary:
	if not is_joined():
		return Result.failure(&"not_room_member", "Join a private room first.")
	var result: Dictionary = await transport.set_ready(room_code, ready)
	if not result.get("ok", false):
		return _emit_failure(result)
	poll_events()
	return result


func update_race_config_async(laps: int, collisions: bool) -> Dictionary:
	if not is_host():
		return Result.failure(&"host_only", "Only the room host can change race rules.")
	var validation := validate_race_config(laps, collisions)
	if not validation["ok"]:
		return validation
	var state := str(_room.get("state", ""))
	if bool(_room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before changing race rules.")
	if state in [str(Limits.ROOM_COUNTDOWN), str(Limits.ROOM_RACING), str(Limits.ROOM_RESULTS), str(Limits.ROOM_CLOSED)]:
		return Result.failure(&"room_locked", "Race rules cannot change after countdown begins.")
	var result: Dictionary = await transport.set_race_config(room_code, validation["value"])
	if not result.get("ok", false):
		return _emit_failure(result)
	poll_events()
	return result


func set_room_lock_async(locked: bool) -> Dictionary:
	if not is_host():
		return Result.failure(&"host_only", "Only the room host can lock the starting grid.")
	var state := str(_room.get("state", ""))
	if state in [str(Limits.ROOM_COUNTDOWN), str(Limits.ROOM_RACING), str(Limits.ROOM_RESULTS), str(Limits.ROOM_CLOSED)]:
		return Result.failure(&"room_locked", "The starting grid cannot be unlocked after countdown begins.")
	var result: Dictionary = await transport.set_room_lock(room_code, locked)
	if not result.get("ok", false):
		return _emit_failure(result)
	if result.get("value", {}).has("join_locked"):
		_room["join_locked"] = bool(result["value"]["join_locked"])
	poll_events()
	return result


func start_race_async() -> Dictionary:
	if not is_host():
		return Result.failure(&"host_only", "Only the room host can start the race.")
	if not can_start():
		return Result.failure(&"players_not_ready", "Every connected driver must verify the circuit and be ready.")
	var result: Dictionary = await transport.start_countdown(room_code)
	if not result.get("ok", false):
		return _emit_failure(result)
	if result.get("value", {}).has("countdown"):
		_apply_countdown(result["value"]["countdown"])
	poll_events()
	return result


func kick_member_async(player_id: String) -> Dictionary:
	if not is_host():
		return Result.failure(&"host_only", "Only the room host can remove a driver.")
	if player_id.is_empty() or player_id == local_player_id:
		return Result.failure(&"kick_target_invalid", "Choose another room member to remove.")
	if bool(_room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before removing a driver.")
	var state := str(_room.get("state", ""))
	if state in [str(Limits.ROOM_COUNTDOWN), str(Limits.ROOM_RACING), str(Limits.ROOM_RESULTS), str(Limits.ROOM_CLOSED)]:
		return Result.failure(&"room_locked", "Drivers cannot be removed after countdown begins.")
	var result: Dictionary = await transport.kick_member(room_code, player_id)
	if not result.get("ok", false):
		return _emit_failure(result)
	poll_events()
	return result


func request_rematch_async() -> Dictionary:
	if not is_joined():
		return Result.failure(&"not_room_member", "Join a private room first.")
	if str(_room.get("state", "")) != str(Limits.ROOM_RESULTS):
		return Result.failure(&"rematch_unavailable", "Rematch is available after authoritative results.")
	var result: Dictionary = await transport.request_rematch(room_code)
	if not result.get("ok", false):
		return _emit_failure(result)
	poll_events()
	return result


func leave_async() -> Dictionary:
	if not is_joined() or transport == null:
		reset_session(false)
		return Result.success({"left": true})
	# Leaving is a local-first operation. Mobile Back/navigation must never wait
	# indefinitely for a damaged socket. Detach the transport, invalidate every
	# outstanding suspend/reconnect continuation, and clear membership before a
	# best-effort server departure finishes in the background.
	_closing = true
	var leaving_transport: MultiplayerTransport = transport
	var leaving_room := room_code
	transport = null
	reset_session(false)
	_closing = false
	_best_effort_leave_and_close(leaving_transport, leaving_room)
	await get_tree().process_frame
	return Result.success({"left": true, "local_reset": true})


func suspend_async() -> Dictionary:
	if not is_joined() or transport == null:
		return Result.success({"suspended": false})
	if _suspend_in_flight or _reconnect_in_flight:
		return Result.success({"suspended": false, "transition_in_flight": true})
	_suspend_in_flight = true
	var operation_generation := _connection_generation
	var operation_transport: MultiplayerTransport = transport
	var operation_room := room_code
	# Enter reconnecting synchronously so a RESUMED/FOCUS_IN notification that
	# arrives before the leave acknowledgement cannot be lost.
	connection_state = CONNECTION_RECONNECTING
	if _background_suspend_ms < 0:
		_background_suspend_ms = Time.get_ticks_msec()
	_emit_changed()
	var result: Dictionary = await operation_transport.suspend_connection(operation_room)
	_suspend_in_flight = false
	if not _connection_operation_is_current(
		operation_generation, operation_transport, operation_room
	):
		connection_transition_completed.emit()
		return Result.success({"suspended": false, "stale": true})
	if result.get("ok", false):
		var token := str(result.get("value", {}).get("reconnect_token", ""))
		if not token.is_empty():
			_reconnect_token = token
		_emit_changed()
	else:
		_emit_failure(result)
	connection_transition_completed.emit()
	return result


func reconnect_async() -> Dictionary:
	if transport == null or room_code.is_empty() or _reconnect_token.is_empty():
		return Result.failure(&"reconnect_unavailable", "This room can no longer be resumed.")
	if _suspend_in_flight or _reconnect_in_flight:
		return Result.success({"reconnected": false, "transition_in_flight": true})
	_reconnect_in_flight = true
	var operation_generation := _connection_generation
	var operation_transport: MultiplayerTransport = transport
	var operation_room := room_code
	var operation_token := _reconnect_token
	connection_state = CONNECTION_RECONNECTING
	_emit_changed()
	var result: Dictionary = await operation_transport.reconnect(
		operation_room, operation_token
	)
	_reconnect_in_flight = false
	if not _connection_operation_is_current(
		operation_generation, operation_transport, operation_room
	):
		connection_transition_completed.emit()
		return Result.success({"reconnected": false, "stale": true})
	if not result.get("ok", false):
		connection_state = CONNECTION_FAILED
		var failure := _emit_failure(result)
		connection_transition_completed.emit()
		return failure
	var value: Dictionary = result.get("value", {})
	var rotated := str(value.get("reconnect_token", ""))
	if not rotated.is_empty():
		_reconnect_token = rotated
	if value.get("room", {}) is Dictionary and not value.get("room", {}).is_empty():
		_room = value["room"].duplicate(true)
	connection_state = CONNECTION_ONLINE
	_background_suspend_ms = -1
	_emit_changed()
	var resume_payload: Dictionary = value.get("resume", {}) if value.get("resume", {}) is Dictionary else {}
	if resume_payload.is_empty():
		resume_payload = {
			"type": "peer_resumed",
			"player_id": local_player_id,
			"authoritative_snapshot": value.get("authoritative_snapshot", {}),
			"reconnect_token": _reconnect_token,
		}
	_handle_event(Protocol.make_envelope(
		Protocol.OP_RESUME, "server", 0, room_epoch,
		resume_payload, estimated_server_tick()
	))
	poll_events()
	connection_transition_completed.emit()
	return Result.success(public_snapshot())


func on_application_paused() -> void:
	if _application_backgrounded:
		return
	_application_backgrounded = true
	_drive_application_lifecycle_async()


func on_application_resumed() -> void:
	if not _application_backgrounded:
		return
	_application_backgrounded = false
	_drive_application_lifecycle_async()


func poll_events() -> Array[Dictionary]:
	if transport == null:
		return []
	var events := transport.drain_events()
	for event in events:
		_handle_event(event)
	if not room_code.is_empty():
		var snapshot_result := transport.room_snapshot(room_code)
		if snapshot_result.get("ok", false):
			var value: Dictionary = snapshot_result.get("value", {})
			if not value.is_empty():
				_apply_room(value)
	return events


func public_snapshot() -> Dictionary:
	var members_value: Variant = _room.get("members", [])
	var track_identity_value: Variant = _room.get("track_identity", {})
	var countdown_value: Variant = _room.get("countdown", {})
	return {
		"connection": str(connection_state),
		"joined": is_joined(),
		"room_code": room_code,
		"room_epoch": room_epoch,
		"local_player_id": local_player_id,
		"display_name": display_name,
		"state": str(_room.get("state", Limits.ROOM_LOBBY)),
		"host_id": str(_room.get("host_id", "")),
		"members": members_value.duplicate(true) if members_value is Array else [],
		"member_count": int(_room.get("member_count", 0)),
		"track_identity": track_identity_value.duplicate(true) if track_identity_value is Dictionary else {},
		"race_config": _authoritative_race_config(),
		"join_locked": bool(_room.get("join_locked", false)),
		"countdown": countdown_value.duplicate(true) if countdown_value is Dictionary else {},
		"close_reason": str(_room.get("close_reason", "")),
		"has_local_track": _current_definition != null and _current_compiled != null,
		"endpoint_label": "%s://%s:%d" % [endpoint.get("scheme", "http"), endpoint.get("host", ""), int(endpoint.get("port", 0))],
		"reconnect_remaining_ms": reconnect_remaining_ms(),
	}


func race_payload() -> Dictionary:
	if _current_definition == null or _current_compiled == null:
		return {}
	var race_config := _authoritative_race_config()
	if race_config.is_empty():
		return {}
	var members_value: Variant = _room.get("members", [])
	var countdown_value: Variant = _room.get("countdown", {})
	return {
		"network_mode": true,
		"track_definition_json": _current_definition.canonical_json(true),
		"source_hash": _current_compiled.source_hash,
		"compiled_hash": _current_compiled.compile_hash,
		"display_name": _current_definition.track_name,
		"room_code": room_code,
		"room_epoch": room_epoch,
		"roster": members_value.duplicate(true) if members_value is Array else [],
		"host_id": str(_room.get("host_id", "")),
		"local_player_id": local_player_id,
		"countdown": countdown_value.duplicate(true) if countdown_value is Dictionary else {},
		"laps": int(race_config["laps"]),
		"collisions": bool(race_config["collisions"]),
	}


func current_definition() -> TrackDefinition:
	return _current_definition


func current_compiled() -> CompiledTrack:
	return _current_compiled


func is_joined() -> bool:
	return transport != null and not room_code.is_empty() and room_epoch > 0


func is_host() -> bool:
	return is_joined() and str(_room.get("host_id", "")) == local_player_id


func local_member() -> Dictionary:
	for member_value in _room.get("members", []):
		if member_value is Dictionary and str(member_value.get("player_id", "")) == local_player_id:
			return member_value.duplicate(true)
	return {}


func can_start() -> bool:
	if not is_host() or str(_room.get("state", "")) != str(Limits.ROOM_READY):
		return false
	if not bool(_room.get("join_locked", false)):
		return false
	var members: Array = _room.get("members", [])
	if members.is_empty():
		return false
	for member_value in members:
		if not member_value is Dictionary:
			return false
		if not bool(member_value.get("connected", false)) \
				or not bool(member_value.get("generation_verified", false)) \
				or not bool(member_value.get("ready", false)):
			return false
	return true


func estimated_server_tick() -> int:
	if _tick_anchor_ms <= 0:
		return _last_server_tick
	var elapsed_ms := maxi(0, Time.get_ticks_msec() - _tick_anchor_ms)
	return _last_server_tick + elapsed_ms * Limits.SIMULATION_HZ / 1000


func reconnect_remaining_ms() -> int:
	if connection_state != CONNECTION_RECONNECTING or _background_suspend_ms < 0:
		return 0
	return maxi(0, Limits.RECONNECT_WINDOW_MS - (Time.get_ticks_msec() - _background_suspend_ms))


func make_envelope(opcode: int, payload: Dictionary, tick: int = -1) -> Dictionary:
	var sequence := int(_sequence_by_opcode.get(opcode, 0)) + 1
	_sequence_by_opcode[opcode] = sequence
	return Protocol.make_envelope(opcode, local_player_id, sequence, room_epoch, payload, tick)


func send_race_envelope(envelope: Dictionary) -> void:
	_send_race_envelope_async(envelope)


func reset_session(close_transport: bool = true) -> void:
	_connection_generation += 1
	if close_transport:
		_close_transport()
	room_code = ""
	room_epoch = 0
	_room.clear()
	_reconnect_token = ""
	_current_definition = null
	_current_compiled = null
	_sequence_by_opcode.clear()
	_last_server_tick = 0
	_tick_anchor_ms = 0
	_background_suspend_ms = -1
	connection_state = CONNECTION_OFFLINE
	_emit_changed()


static func validate_display_name(value: String) -> Dictionary:
	var clean := value.strip_edges()
	if clean.is_empty() or clean.length() > Limits.MAX_DISPLAY_NAME_LENGTH:
		return Result.failure(&"display_name_invalid", "Driver name must be 1–24 characters.")
	for index in clean.length():
		if clean.unicode_at(index) < 32:
			return Result.failure(&"display_name_invalid", "Driver name contains unsupported control characters.")
	return {"ok": true, "value": clean}


static func validate_room_code(value: String) -> Dictionary:
	var clean := value.strip_edges().to_upper()
	if clean.length() != Limits.ROOM_CODE_LENGTH:
		return Result.failure(&"room_code_invalid", "Room code must contain exactly six characters.")
	for index in clean.length():
		if Limits.ROOM_CODE_ALPHABET.find(clean[index]) < 0:
			return Result.failure(&"room_code_invalid", "Room code contains an unsupported character.")
	return {"ok": true, "value": clean}


static func validate_race_config(laps: Variant, collisions: Variant) -> Dictionary:
	if not Limits.is_valid_multiplayer_lap_count(laps) or typeof(collisions) != TYPE_BOOL:
		return Result.failure(&"race_config_invalid", "Choose 1, 3, or 5 laps and a valid collision setting.")
	return Result.success({"laps": int(laps), "collisions": bool(collisions)})


static func is_transport_loss_error(code: String) -> bool:
	return code in ["nakama_socket_error", "nakama_socket_closed", "nakama_connection_error"]


func _apply_join_result(value: Dictionary) -> void:
	room_code = str(value.get("room_code", "")).to_upper()
	room_epoch = int(value.get("room_epoch", value.get("room", {}).get("room_epoch", 0)))
	_reconnect_token = str(value.get("reconnect_token", ""))
	if value.get("room", {}) is Dictionary and not value.get("room", {}).is_empty():
		_apply_room(value["room"])
	else:
		_room = {
			"room_code": room_code,
			"room_epoch": room_epoch,
			"state": str(Limits.ROOM_LOBBY),
			"host_id": local_player_id,
			"members": [],
			"member_count": 0,
			"race_config": Limits.default_race_config(),
			"join_locked": false,
		}
	_emit_changed()


func _handle_event(event: Dictionary) -> void:
	var tick := int(event.get("tick", _last_server_tick))
	if tick >= _last_server_tick:
		_last_server_tick = tick
		_tick_anchor_ms = Time.get_ticks_msec()
	var opcode := int(event.get("opcode", -1))
	var payload: Dictionary = event.get("payload", {})
	match opcode:
		Protocol.OP_ROOM_CONFIG:
			_apply_room(payload)
		Protocol.OP_TRACK_MANIFEST:
			_verify_manifest_and_report_async(payload)
		Protocol.OP_GENERATION_REPORT:
			_update_member(payload, "generation_verified")
		Protocol.OP_READY_STATE:
			_update_member(payload, "ready")
		Protocol.OP_START_AT_TICK:
			_apply_countdown(payload)
		Protocol.OP_RACE_EVENT:
			_handle_race_event(payload)
		Protocol.OP_RESUME:
			var rotated := str(payload.get("reconnect_token", ""))
			if not rotated.is_empty():
				_reconnect_token = rotated
			connection_state = CONNECTION_ONLINE
		Protocol.OP_ROOM_ENDED:
			_room["state"] = str(Limits.ROOM_CLOSED)
			_room["close_reason"] = str(payload.get("reason", "room_ended"))
			room_ended.emit(str(_room["close_reason"]))
		Protocol.OP_ERROR:
			var error_code := str(payload.get("code", "network_error"))
			if is_transport_loss_error(error_code) and is_joined():
				if connection_state != CONNECTION_RECONNECTING:
					connection_state = CONNECTION_RECONNECTING
					_background_suspend_ms = Time.get_ticks_msec()
			elif is_transport_loss_error(error_code):
				connection_state = CONNECTION_FAILED
			var error := {"code": error_code, "message": _friendly_error(error_code)}
			session_error.emit(error)
	event_received.emit(event.duplicate(true))
	_emit_changed()


func _verify_manifest_and_report_async(manifest: Dictionary) -> void:
	if _report_in_flight:
		return
	_report_in_flight = true
	var validation := Manifest.validate(manifest)
	var report := {
		"success": false,
		"source_hash": str(manifest.get("source_hash", "0".repeat(64))),
		"generator_version": int(manifest.get("generator_version", 0)),
		"compiled_fingerprint": str(manifest.get("compiled_fingerprint", "0".repeat(64))),
		"error": "track_manifest_invalid",
	}
	if validation["ok"]:
		var decoded: TrackDefinition = validation["value"]["definition"]
		var compiled_result: TrackCompileResult = Compiler.compile(decoded)
		if compiled_result.succeeded() and compiled_result.track != null \
				and compiled_result.track.source_hash == str(manifest["source_hash"]) \
				and compiled_result.track.compile_hash == str(manifest["compiled_fingerprint"]):
			_current_definition = decoded
			_current_compiled = compiled_result.track
			report = {
				"success": true,
				"source_hash": compiled_result.track.source_hash,
				"generator_version": int(decoded.generator_version),
				"compiled_fingerprint": compiled_result.track.compile_hash,
			}
		else:
			report["error"] = "local_compile_fingerprint_mismatch"
	validation.clear()
	var submitted: Dictionary = await transport.submit_generation_report(room_code, report)
	_report_in_flight = false
	if not submitted.get("ok", false):
		_emit_failure(submitted)
	poll_events()


func _send_race_envelope_async(envelope: Dictionary) -> void:
	if transport == null or not is_joined():
		return
	var result: Dictionary = await transport.send_envelope(room_code, envelope)
	if not result.get("ok", false) and not _closing:
		_emit_failure(result)


func _apply_room(value: Dictionary) -> void:
	_room = value.duplicate(true)
	if not _room.get("members") is Array:
		_room["members"] = []
	if not _room.get("track_identity") is Dictionary:
		_room["track_identity"] = {}
	if not _room.get("countdown") is Dictionary:
		_room["countdown"] = {}
	room_code = str(_room.get("room_code", room_code)).to_upper()
	room_epoch = int(_room.get("room_epoch", room_epoch))
	_emit_changed()


func _apply_countdown(value: Dictionary) -> void:
	_room["countdown"] = value.duplicate(true)
	var countdown_config: Variant = value.get("race_config")
	if countdown_config is Dictionary:
		var validation := validate_race_config(countdown_config.get("laps"), countdown_config.get("collisions"))
		if validation["ok"]:
			_room["race_config"] = validation["value"].duplicate(true)
	_room["state"] = str(Limits.ROOM_COUNTDOWN)
	race_countdown_received.emit(value.duplicate(true))


func _handle_race_event(payload: Dictionary) -> void:
	match str(payload.get("type", "")):
		"race_started":
			_room["state"] = str(Limits.ROOM_RACING)
			race_started.emit(int(payload.get("tick", estimated_server_tick())))
		"peer_disconnected":
			_update_member({"player_id": payload.get("player_id", ""), "connected": false}, "connected")
		"peer_resumed":
			_update_member({"player_id": payload.get("player_id", ""), "connected": true}, "connected")
		"peer_departed":
			var departed := str(payload.get("player_id", ""))
			var kept: Array = []
			for member in _room.get("members", []):
				if str(member.get("player_id", "")) != departed:
					kept.append(member)
			_room["members"] = kept
			_room["member_count"] = kept.size()
		"race_complete":
			_room["state"] = str(Limits.ROOM_RESULTS)


func _update_member(payload: Dictionary, field: String) -> void:
	var player_id := str(payload.get("player_id", ""))
	var members: Array = _room.get("members", [])
	for member in members:
		if str(member.get("player_id", "")) == player_id and payload.has(field):
			member[field] = payload[field]
	_room["members"] = members


func _emit_failure(result: Dictionary) -> Dictionary:
	var error: Dictionary = result.get("error", {})
	if error.is_empty():
		error = {"code": "network_error", "message": "The private room request failed."}
	else:
		error = error.duplicate(true)
		error["message"] = _friendly_error(str(error.get("code", "network_error")), str(error.get("message", "")))
	session_error.emit(error)
	return {"ok": false, "error": error}


func _fail_connection(error_value: Dictionary) -> Dictionary:
	connection_state = CONNECTION_FAILED
	var result := {"ok": false, "error": error_value.duplicate(true)}
	_emit_changed()
	return _emit_failure(result)


func _friendly_error(code: String, fallback: String = "") -> String:
	match code:
		"nakama_device_auth_failed", "nakama_socket_connect_failed", "nakama_rpc_failed", "transport_unavailable":
			return "The private-room backend is unavailable. Offline Race is still ready to play."
		"nakama_socket_error", "nakama_socket_closed", "nakama_connection_error":
			return "Connection interrupted. Racing is paused while the 20-second reconnect window remains open."
		"room_not_found":
			return "That private room was not found. Check the six-character code and try again."
		"room_full":
			return "That private room already has 12 drivers."
		"room_locked":
			return "The host locked this starting grid. Unlock it before changing drivers, circuit, or rules."
		"kicked_from_room":
			return "The host removed this driver from the room. This invite cannot be reused on this device."
		"control_rate_limited":
			return "Too many lobby updates were sent at once. Wait a moment and try again."
		"ready_unavailable":
			return "Ready can change only after the circuit is synchronized and before countdown."
		"room_not_locked":
			return "Lock the starting grid before starting the race."
		"update_required":
			return "UPDATE REQUIRED • This build is incompatible with the private-room service. Update RaceGlyph before joining."
		"rematch_unavailable":
			return "Rematch becomes available after the host publishes authoritative results."
		"reconnect_expired", "resume_membership_missing", "nakama_resume_timeout":
			return "The 20-second reconnect window expired. Return to Private Room to join again."
		"track_identity_mismatch":
			return "Your locally generated circuit did not match the host. Ready is blocked for fairness."
		"input_boost_disabled":
			return "Boost is not available in private multiplayer races."
		"race_config_invalid":
			return "Race rules must use 1, 3, or 5 laps and a valid collision setting."
	return fallback if not fallback.is_empty() else "The private-room request could not be completed (%s)." % code


func _emit_changed() -> void:
	session_changed.emit(public_snapshot())


func _close_transport() -> void:
	_connection_generation += 1
	if transport != null and transport.has_method("close"):
		transport.call("close")
	transport = null


func _connection_operation_is_current(
		generation: int,
		expected_transport: MultiplayerTransport,
		expected_room: String
	) -> bool:
	return generation == _connection_generation \
			and transport == expected_transport \
			and room_code == expected_room \
			and not _closing


func _drive_application_lifecycle_async() -> void:
	if _lifecycle_drive_in_flight:
		return
	_lifecycle_drive_in_flight = true
	while true:
		if _suspend_in_flight or _reconnect_in_flight:
			await connection_transition_completed
			continue
		if _application_backgrounded:
			if is_joined() and connection_state == CONNECTION_ONLINE:
				await suspend_async()
				continue
			break
		if connection_state == CONNECTION_RECONNECTING:
			await reconnect_async()
			continue
		break
	_lifecycle_drive_in_flight = false


func _best_effort_leave_and_close(
		leaving_transport: MultiplayerTransport,
		leaving_room: String
	) -> void:
	if leaving_transport == null:
		return
	await leaving_transport.leave_room(leaving_room)
	if leaving_transport.has_method("close"):
		leaving_transport.call("close")


func _authoritative_race_config() -> Dictionary:
	var config_value: Variant = _room.get("race_config", Limits.default_race_config())
	var countdown_value: Variant = _room.get("countdown", {})
	if countdown_value is Dictionary and countdown_value.get("race_config") is Dictionary:
		config_value = countdown_value["race_config"]
	if not config_value is Dictionary:
		return {}
	var validation := validate_race_config(config_value.get("laps"), config_value.get("collisions"))
	return validation["value"].duplicate(true) if validation["ok"] else {}


func _selected_cosmetics() -> Dictionary:
	var services := get_node_or_null("/root/GameServices")
	var selected: Dictionary = services.call("selected_cosmetics") if services != null else {}
	var car_id := str(selected.get("car_id", VehicleCatalog.DEFAULT_CAR_ID))
	var team_id := str(selected.get("team_id", VehicleCatalog.DEFAULT_TEAM_ID))
	if not VehicleCatalog.is_valid_pair(car_id, team_id):
		return {"car_id": VehicleCatalog.DEFAULT_CAR_ID, "team_id": VehicleCatalog.DEFAULT_TEAM_ID}
	return {"car_id": car_id, "team_id": team_id}
