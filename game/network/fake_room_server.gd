class_name FakeRoomServer
extends RefCounted
## Deterministic in-memory authority for protocol and gameplay integration tests.
## This is not a security backend: reconnect tokens are deterministic fixtures.

const Limits := preload("res://game/network/network_limits.gd")
const Result := preload("res://game/network/network_result.gd")
const Protocol := preload("res://game/network/network_protocol.gd")
const TrackManifest := preload("res://game/network/network_track_manifest.gd")
const VehicleCatalog := preload("res://game/content/vehicle_catalog.gd")

var _rooms: Dictionary = {}
var _player_rooms: Dictionary = {}
var _event_queues: Dictionary = {}
var _rate_buckets: Dictionary = {}
var _now_ms: int = 0
var _server_tick: int = 0
var _tick_remainder: int = 0
var _room_serial: int = 0
var _join_serial: int = 0


func create_room(
		connection_id: String,
		display_name: String,
		cosmetics: Dictionary = {},
		compatibility: Dictionary = {}
	) -> Dictionary:
	var identity_check := _validate_identity(connection_id, display_name)
	if not identity_check["ok"]:
		return identity_check
	var cosmetic_check := _validate_cosmetics(cosmetics)
	if not cosmetic_check["ok"]:
		return cosmetic_check
	var compatibility_check := _validate_compatibility(compatibility)
	if not compatibility_check["ok"]:
		return compatibility_check
	if _player_rooms.has(connection_id):
		return Result.failure(&"already_in_room", "Player already belongs to a room.")
	if not _consume_rate("create:" + connection_id, Limits.ROOM_CREATE_ATTEMPTS_PER_MINUTE, 60_000):
		return Result.failure(&"room_create_rate_limited", "Too many room creation attempts.")
	_room_serial += 1
	var room_code := _room_code_for_serial(_room_serial)
	while _rooms.has(room_code):
		_room_serial += 1
		room_code = _room_code_for_serial(_room_serial)
	var room := {
		"code": room_code,
		"epoch": _room_serial,
		"state": str(Limits.ROOM_LOBBY),
		"host_id": connection_id,
		"members": {},
		"banned_members": {},
		"member_order": [],
		"track_manifest": {},
		"race_config": Limits.default_race_config(),
		"join_locked": false,
		"countdown": {},
		"latest_snapshot": {},
		"last_snapshot_sequence": -1,
		"last_snapshot_tick": -1,
		"server_sequence": 0,
		"close_reason": "",
	}
	_add_member(room, connection_id, display_name, cosmetic_check["value"], compatibility_check["value"])
	_rooms[room_code] = room
	_player_rooms[connection_id] = room_code
	return Result.success({
		"room_code": room_code,
		"reconnect_token": room["members"][connection_id]["reconnect_token"],
		"room": _room_view(room, connection_id),
	})


func join_room(
		connection_id: String,
		room_code: String,
		display_name: String,
		cosmetics: Dictionary = {},
		compatibility: Dictionary = {}
	) -> Dictionary:
	var identity_check := _validate_identity(connection_id, display_name)
	if not identity_check["ok"]:
		return identity_check
	var cosmetic_check := _validate_cosmetics(cosmetics)
	if not cosmetic_check["ok"]:
		return cosmetic_check
	var compatibility_check := _validate_compatibility(compatibility)
	if not compatibility_check["ok"]:
		return compatibility_check
	if _player_rooms.has(connection_id):
		return Result.failure(&"already_in_room", "Player already belongs to a room.")
	if not _consume_rate("join:" + connection_id, Limits.ROOM_JOIN_ATTEMPTS_PER_MINUTE, 60_000):
		return Result.failure(&"room_join_rate_limited", "Too many room join attempts.")
	var normalized_code := room_code.strip_edges().to_upper()
	if not _valid_room_code(normalized_code):
		return Result.failure(&"room_code_invalid", "Room code format is invalid.")
	if not _rooms.has(normalized_code):
		return Result.failure(&"room_not_found", "Private room was not found.")
	var room: Dictionary = _rooms[normalized_code]
	if bool(room.get("banned_members", {}).get(connection_id, false)):
		return Result.failure(&"kicked_from_room", "The host removed this identity from the room.")
	if room["state"] == str(Limits.ROOM_CLOSED):
		return Result.failure(&"room_closed", "Private room is closed.")
	if room["state"] == str(Limits.ROOM_COUNTDOWN) or room["state"] == str(Limits.ROOM_RACING) \
			or room["state"] == str(Limits.ROOM_RESULTS):
		return Result.failure(&"room_locked", "Race has already started.")
	if bool(room.get("join_locked", false)):
		return Result.failure(&"room_locked", "The host locked this starting grid.")
	if room["members"].size() >= Limits.MAX_PLAYERS:
		return Result.failure(&"room_full", "Private room already has 12 players.")
	_add_member(room, connection_id, display_name, cosmetic_check["value"], compatibility_check["value"])
	_player_rooms[connection_id] = normalized_code
	if not room["track_manifest"].is_empty():
		room["state"] = str(Limits.ROOM_TRACK_SYNC)
	_broadcast_room_config(room)
	return Result.success({
		"room_code": normalized_code,
		"reconnect_token": room["members"][connection_id]["reconnect_token"],
		"room": _room_view(room, connection_id),
		"track_manifest": room["track_manifest"].duplicate(true),
	})


func submit_track_manifest(connection_id: String, room_code: String, manifest: Dictionary) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["host_id"] != connection_id:
		return Result.failure(&"host_only", "Only the room host may select a track.")
	if bool(room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before changing the circuit.")
	if room["state"] == str(Limits.ROOM_COUNTDOWN) or room["state"] == str(Limits.ROOM_RACING) \
			or room["state"] == str(Limits.ROOM_RESULTS) or room["state"] == str(Limits.ROOM_CLOSED):
		return Result.failure(&"room_locked", "Track cannot change after countdown begins.")
	var validation := TrackManifest.validate(manifest)
	if not validation["ok"]:
		return validation
	room["track_manifest"] = manifest.duplicate(true)
	room["state"] = str(Limits.ROOM_TRACK_SYNC)
	room["countdown"] = {}
	for player_id in room["member_order"]:
		if not room["members"].has(player_id):
			continue
		var member: Dictionary = room["members"][player_id]
		member["ready"] = false
		member["generation_verified"] = false
		member["generation_error"] = ""
	_broadcast_room_event(room, Protocol.OP_TRACK_MANIFEST, manifest.duplicate(true))
	return Result.success({
		"state": room["state"],
		"track_identity": TrackManifest.identity(manifest),
	})


func submit_generation_report(connection_id: String, room_code: String, report: Dictionary) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	var member: Dictionary = access["value"]["member"]
	var phase_locked: bool = room["state"] == str(Limits.ROOM_COUNTDOWN) \
			or room["state"] == str(Limits.ROOM_RACING) \
			or room["state"] == str(Limits.ROOM_RESULTS) \
			or room["state"] == str(Limits.ROOM_CLOSED)
	if room["track_manifest"].is_empty():
		return Result.failure(&"track_not_selected", "Host has not selected a track.")
	for key in ["success", "source_hash", "generator_version", "compiled_fingerprint"]:
		if not report.has(key):
			return Result.failure(&"generation_report_malformed", "Generation report is missing a required field.", {"field": key})
	if typeof(report["success"]) != TYPE_BOOL or typeof(report["generator_version"]) != TYPE_INT \
			or typeof(report["source_hash"]) != TYPE_STRING \
			or typeof(report["compiled_fingerprint"]) != TYPE_STRING:
		return Result.failure(&"generation_report_malformed", "Generation report has invalid field types.")
	if not TrackManifest.is_sha256(report["source_hash"]) \
			or not TrackManifest.is_sha256(report["compiled_fingerprint"]):
		return Result.failure(&"generation_report_malformed", "Generation report hashes must be lowercase SHA-256 text.")
	if not report["success"]:
		member["generation_verified"] = false
		member["ready"] = false
		member["generation_error"] = _bounded_text(str(report.get("error", "generation_failed")), 128)
		if not phase_locked:
			room["state"] = str(Limits.ROOM_TRACK_SYNC)
		return Result.success({"generation_verified": false, "state": room["state"]})
	var expected := TrackManifest.identity(room["track_manifest"])
	if str(report["source_hash"]) != expected["source_hash"] \
			or int(report["generator_version"]) != expected["generator_version"] \
			or str(report["compiled_fingerprint"]) != expected["compiled_fingerprint"]:
		member["generation_verified"] = false
		member["ready"] = false
		member["generation_error"] = "track_identity_mismatch"
		if not phase_locked:
			room["state"] = str(Limits.ROOM_TRACK_SYNC)
		return Result.failure(
			&"track_identity_mismatch",
			"Locally generated track does not match the host manifest.",
			{"expected": expected}
		)
	member["generation_verified"] = true
	member["generation_error"] = ""
	if not phase_locked and _all_generation_verified(room):
		room["state"] = str(Limits.ROOM_READY)
	_broadcast_room_event(room, Protocol.OP_GENERATION_REPORT, {
		"player_id": connection_id,
		"generation_verified": true,
	})
	return Result.success({"generation_verified": true, "state": room["state"]})


func set_ready(connection_id: String, room_code: String, ready: bool) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	var member: Dictionary = access["value"]["member"]
	if room["state"] != str(Limits.ROOM_TRACK_SYNC) \
			and room["state"] != str(Limits.ROOM_READY):
		return Result.failure(&"ready_unavailable", "Readiness is available only while synchronizing the starting grid.")
	if ready and not member["generation_verified"]:
		return Result.failure(&"generation_not_verified", "Track generation must match before becoming ready.")
	member["ready"] = ready
	if _all_generation_verified(room):
		room["state"] = str(Limits.ROOM_READY)
	else:
		room["state"] = str(Limits.ROOM_TRACK_SYNC)
	_broadcast_room_event(room, Protocol.OP_READY_STATE, {
		"player_id": connection_id,
		"ready": ready,
	})
	return Result.success({"ready": ready, "all_ready": _all_ready(room), "state": room["state"]})


func set_race_config(connection_id: String, room_code: String, config: Dictionary) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["host_id"] != connection_id:
		return Result.failure(&"host_only", "Only the room host may change race rules.")
	if bool(room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before changing race rules.")
	if room["state"] in [
		str(Limits.ROOM_COUNTDOWN), str(Limits.ROOM_RACING),
		str(Limits.ROOM_RESULTS), str(Limits.ROOM_CLOSED),
	]:
		return Result.failure(&"room_locked", "Race rules cannot change after countdown begins.")
	var validation := _validate_race_config(config)
	if not validation["ok"]:
		return validation
	var normalized: Dictionary = validation["value"]
	if room["race_config"] == normalized:
		return Result.success({"changed": false, "race_config": normalized.duplicate(true)})
	room["race_config"] = normalized.duplicate(true)
	room["countdown"] = {}
	for player_id in room["member_order"]:
		if room["members"].has(player_id):
			room["members"][player_id]["ready"] = false
	if room["track_manifest"].is_empty():
		room["state"] = str(Limits.ROOM_LOBBY)
	else:
		room["state"] = str(Limits.ROOM_READY) if _all_generation_verified(room) else str(Limits.ROOM_TRACK_SYNC)
	_broadcast_room_config(room)
	return Result.success({
		"changed": true,
		"race_config": normalized.duplicate(true),
		"state": room["state"],
	})


func set_room_lock(connection_id: String, room_code: String, locked: bool) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["host_id"] != connection_id:
		return Result.failure(&"host_only", "Only the room host may lock the starting grid.")
	if room["state"] in [
		str(Limits.ROOM_COUNTDOWN), str(Limits.ROOM_RACING),
		str(Limits.ROOM_RESULTS), str(Limits.ROOM_CLOSED),
	]:
		return Result.failure(&"room_locked", "The starting grid cannot be unlocked after countdown begins.")
	var changed := bool(room.get("join_locked", false)) != locked
	room["join_locked"] = locked
	if changed:
		_broadcast_room_config(room)
	return Result.success({"changed": changed, "join_locked": locked, "state": room["state"]})


func start_countdown(connection_id: String, room_code: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["host_id"] != connection_id:
		return Result.failure(&"host_only", "Only the room host may start the countdown.")
	if room["state"] != str(Limits.ROOM_READY):
		return Result.failure(&"room_not_ready", "Room has not completed track synchronization.")
	if not bool(room.get("join_locked", false)):
		return Result.failure(&"room_not_locked", "Lock the starting grid before beginning countdown.")
	if not _all_ready(room):
		return Result.failure(&"players_not_ready", "Every connected participant must be ready.")
	for player_id in room["member_order"]:
		if room["members"].has(player_id) and not room["members"][player_id]["connected"]:
			return Result.failure(&"player_disconnected", "A participant is inside the reconnect window.")
	var countdown := {
		"issued_at_tick": _server_tick,
		"start_tick": _server_tick + Limits.COUNTDOWN_TICKS,
		"track_identity": TrackManifest.identity(room["track_manifest"]),
		"roster": _roster(room),
		"race_config": room["race_config"].duplicate(true),
	}
	room["countdown"] = countdown
	room["state"] = str(Limits.ROOM_COUNTDOWN)
	_broadcast_room_event(room, Protocol.OP_START_AT_TICK, countdown.duplicate(true))
	return Result.success({"countdown": countdown.duplicate(true), "state": room["state"]})


func kick_member(connection_id: String, room_code: String, player_id: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["host_id"] != connection_id:
		return Result.failure(&"host_only", "Only the room host may remove a driver.")
	if bool(room.get("join_locked", false)):
		return Result.failure(&"room_locked", "Unlock the starting grid before removing a driver.")
	if room["state"] == str(Limits.ROOM_COUNTDOWN) or room["state"] == str(Limits.ROOM_RACING) \
			or room["state"] == str(Limits.ROOM_RESULTS) or room["state"] == str(Limits.ROOM_CLOSED):
		return Result.failure(&"room_locked", "Drivers cannot be removed after countdown begins.")
	if player_id == connection_id or not room["members"].has(player_id):
		return Result.failure(&"kick_target_invalid", "Kick target is not a removable room member.")
	room["server_sequence"] = int(room["server_sequence"]) + 1
	_queue_event(player_id, Protocol.make_envelope(
		Protocol.OP_ROOM_ENDED, "server", int(room["server_sequence"]),
		int(room["epoch"]), {"reason": "kicked_by_host"}, _server_tick
	))
	room["banned_members"][player_id] = true
	_permanent_departure(room, player_id, "kicked_by_host", true)
	return Result.success({"kicked": true, "player_id": player_id, "room_epoch": room["epoch"]})


func request_rematch(connection_id: String, room_code: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	if room["state"] != str(Limits.ROOM_RESULTS):
		return Result.failure(&"rematch_unavailable", "Rematch is available only after authoritative results.")
	if room["host_id"] != connection_id:
		_broadcast_room_event(room, Protocol.OP_RACE_EVENT, {
			"type": "rematch_requested",
			"player_id": connection_id,
		}, connection_id)
		return Result.success({"requested": true, "host_restart": false})
	room["countdown"] = {}
	room["latest_snapshot"] = {}
	room["last_snapshot_sequence"] = -1
	room["last_snapshot_tick"] = -1
	for player_id in room["member_order"]:
		if room["members"].has(player_id):
			room["members"][player_id]["ready"] = false
	room["state"] = str(Limits.ROOM_READY) if _all_generation_verified(room) else str(Limits.ROOM_TRACK_SYNC)
	_broadcast_room_config(room)
	return Result.success({"requested": true, "host_restart": true, "state": room["state"]})


func handle_envelope(connection_id: String, room_code: String, message: Dictionary) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	var member: Dictionary = access["value"]["member"]
	if member["quarantined"]:
		return Result.failure(&"peer_quarantined", "Peer is quarantined after repeated malformed messages.")
	var validation := Protocol.validate_envelope(message, connection_id, int(room["epoch"]))
	if not validation["ok"]:
		_record_malformed(member)
		return validation
	var opcode := int(message["opcode"])
	if opcode != Protocol.OP_INPUT_FRAME and opcode != Protocol.OP_STATE_SNAPSHOT \
			and not _consume_rate(
				"control:%s:%s" % [room["code"], member["player_id"]],
				Limits.MAX_CONTROL_MESSAGES_PER_SECOND,
				1000
			):
		return Result.failure(&"control_rate_limited", "Control traffic exceeds the private-room message budget.")
	if opcode == Protocol.OP_ROOM_CONFIG and str(message["payload"].get("type", "")) == "race_config":
		return set_race_config(connection_id, room_code, message["payload"])
	if opcode == Protocol.OP_ROOM_CONFIG and str(message["payload"].get("type", "")) == "room_lock":
		if typeof(message["payload"].get("locked")) != TYPE_BOOL:
			return Result.failure(&"room_lock_invalid", "Room lock requires a Boolean state.")
		return set_room_lock(connection_id, room_code, bool(message["payload"]["locked"]))
	if opcode == Protocol.OP_RACE_EVENT and str(message["payload"].get("type", "")) == "kick_member":
		return kick_member(connection_id, room_code, str(message["payload"].get("player_id", "")))
	if opcode == Protocol.OP_RACE_EVENT and str(message["payload"].get("type", "")) == "rematch":
		return request_rematch(connection_id, room_code)
	if opcode == Protocol.OP_READY_STATE:
		if typeof(message["payload"].get("ready")) != TYPE_BOOL:
			return Result.failure(&"ready_malformed", "Ready state requires a Boolean value.")
		return set_ready(connection_id, room_code, bool(message["payload"]["ready"]))
	if room["state"] != str(Limits.ROOM_RACING):
		return Result.failure(&"race_not_running", "Race traffic is accepted only while racing.")
	if opcode == Protocol.OP_INPUT_FRAME:
		return _handle_input_frame(room, member, message)
	if opcode == Protocol.OP_STATE_SNAPSHOT:
		return _handle_state_snapshot(room, member, message)
	if opcode == Protocol.OP_RACE_EVENT:
		return _handle_race_event(room, member, message)
	return Result.failure(&"opcode_not_accepted", "Opcode is not accepted from a race peer on this channel.")


func suspend_connection(connection_id: String, room_code: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	var member: Dictionary = access["value"]["member"]
	member["connected"] = false
	member["disconnect_deadline_ms"] = _now_ms + Limits.RECONNECT_WINDOW_MS
	_broadcast_room_event(room, Protocol.OP_RACE_EVENT, {
		"type": "peer_disconnected",
		"player_id": connection_id,
		"reconnect_deadline_ms": member["disconnect_deadline_ms"],
	}, connection_id)
	return Result.success({
		"reconnect_deadline_ms": member["disconnect_deadline_ms"],
		"window_ms": Limits.RECONNECT_WINDOW_MS,
	})


func reconnect(connection_id: String, room_code: String, reconnect_token: String) -> Dictionary:
	var normalized_code := room_code.strip_edges().to_upper()
	if not _rooms.has(normalized_code):
		return Result.failure(&"room_not_found", "Private room was not found.")
	var room: Dictionary = _rooms[normalized_code]
	if not room["members"].has(connection_id):
		return Result.failure(&"resume_membership_missing", "Reconnect membership no longer exists.")
	var member: Dictionary = room["members"][connection_id]
	if member["connected"]:
		return Result.failure(&"already_connected", "Player is already connected.")
	if _now_ms > int(member["disconnect_deadline_ms"]):
		return Result.failure(&"reconnect_expired", "Reconnect window has expired.")
	if reconnect_token.is_empty() or reconnect_token != member["reconnect_token"]:
		return Result.failure(&"reconnect_token_invalid", "Reconnect token is invalid.")
	member["connected"] = true
	member["disconnect_deadline_ms"] = -1
	member["reconnect_count"] = int(member["reconnect_count"]) + 1
	member["reconnect_token"] = _token_for(normalized_code, connection_id, int(member["reconnect_count"]))
	_player_rooms[connection_id] = normalized_code
	_event_queues[connection_id] = []
	if room["host_id"] == connection_id and room["state"] == str(Limits.ROOM_COUNTDOWN) \
			and _server_tick >= int(room["countdown"].get("start_tick", 0)):
		room["countdown"]["issued_at_tick"] = _server_tick
		room["countdown"]["start_tick"] = _server_tick + Limits.COUNTDOWN_TICKS
		_broadcast_room_event(room, Protocol.OP_START_AT_TICK, room["countdown"].duplicate(true))
	_broadcast_room_event(room, Protocol.OP_RACE_EVENT, {
		"type": "peer_resumed",
		"player_id": connection_id,
	}, connection_id)
	return Result.success({
		"room": _room_view(room, connection_id),
		"reconnect_token": member["reconnect_token"],
		"authoritative_snapshot": room["latest_snapshot"].duplicate(true),
	})


func leave_room(connection_id: String, room_code: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	var room: Dictionary = access["value"]["room"]
	_permanent_departure(room, connection_id, "peer_left")
	return Result.success({
		"state": room["state"],
		"host_id": room["host_id"],
		"room_epoch": room["epoch"],
		"close_reason": room["close_reason"],
	})


func room_snapshot(connection_id: String, room_code: String) -> Dictionary:
	var access := _require_member(connection_id, room_code)
	if not access["ok"]:
		return access
	return Result.success(_room_view(access["value"]["room"], connection_id))


func drain_events(connection_id: String) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if _event_queues.has(connection_id):
		for event in _event_queues[connection_id]:
			events.append(event)
		_event_queues[connection_id] = []
	return events


func advance_time(delta_ms: int) -> void:
	if delta_ms < 0:
		return
	_now_ms += delta_ms
	var tick_units := _tick_remainder + delta_ms * Limits.SIMULATION_HZ
	_server_tick += tick_units / 1000
	_tick_remainder = tick_units % 1000
	for room_code in _rooms.keys():
		var room: Dictionary = _rooms[room_code]
		if room["state"] == str(Limits.ROOM_COUNTDOWN) and _host_connected(room) \
				and _server_tick >= int(room["countdown"].get("start_tick", Limits.MAX_SAFE_SEQUENCE)):
			room["state"] = str(Limits.ROOM_RACING)
			_broadcast_room_event(room, Protocol.OP_RACE_EVENT, {
				"type": "race_started",
				"tick": int(room["countdown"]["start_tick"]),
			})
		var order: Array = room["member_order"].duplicate()
		for player_id in order:
			if not room["members"].has(player_id):
				continue
			var member: Dictionary = room["members"][player_id]
			if not member["connected"] and int(member["disconnect_deadline_ms"]) >= 0 \
					and _now_ms > int(member["disconnect_deadline_ms"]):
				_permanent_departure(room, player_id, "reconnect_expired")


func current_tick() -> int:
	return _server_tick


func now_ms() -> int:
	return _now_ms


func _handle_input_frame(room: Dictionary, member: Dictionary, message: Dictionary) -> Dictionary:
	if not _consume_rate(
			"input:%s:%s" % [room["code"], member["player_id"]],
			Limits.MAX_INPUT_FRAMES_PER_SECOND,
			1000
		):
		return Result.failure(&"input_rate_limited", "Input submission exceeds 20 frames per second.")
	var sequence := int(message["seq"])
	var tick := int(message["tick"])
	if sequence <= int(member["last_input_sequence"]):
		return Result.failure(&"input_sequence_stale", "Input sequence is duplicate or out of order.")
	if tick < _server_tick - Limits.MAX_STALE_INPUT_TICKS:
		return Result.failure(&"input_tick_stale", "Input frame is too old.")
	if tick > _server_tick + Limits.MAX_FUTURE_INPUT_TICKS:
		return Result.failure(&"input_tick_future", "Input frame is too far ahead of authority.")
	if tick < int(member["last_input_tick"]):
		return Result.failure(&"input_tick_out_of_order", "Input tick moved backwards.")
	if int(message["payload"]["ack_host_tick"]) > _server_tick + Limits.MAX_FUTURE_INPUT_TICKS:
		return Result.failure(&"input_ack_future", "Acknowledged host tick is impossible.")
	member["last_input_sequence"] = sequence
	member["last_input_tick"] = tick
	if room["host_id"] != member["player_id"]:
		_queue_event(room["host_id"], message.duplicate(true))
	return Result.success({"accepted_sequence": sequence, "accepted_tick": tick})


func _handle_state_snapshot(room: Dictionary, member: Dictionary, message: Dictionary) -> Dictionary:
	if room["host_id"] != member["player_id"]:
		return Result.failure(&"host_only", "Only the simulation host may publish authoritative snapshots.")
	if not _consume_rate(
			"snapshot:%s:%s" % [room["code"], member["player_id"]],
			Limits.MAX_SNAPSHOTS_PER_SECOND,
			1000
		):
		return Result.failure(&"snapshot_rate_limited", "Snapshot publication exceeds 15 frames per second.")
	var sequence := int(message["seq"])
	var tick := int(message["tick"])
	if sequence <= int(room["last_snapshot_sequence"]):
		return Result.failure(&"snapshot_sequence_stale", "Snapshot sequence is duplicate or out of order.")
	if tick < int(room["last_snapshot_tick"]):
		return Result.failure(&"snapshot_tick_stale", "Snapshot tick moved backwards.")
	if tick > _server_tick + Limits.MAX_FUTURE_INPUT_TICKS:
		return Result.failure(&"snapshot_tick_future", "Snapshot is too far ahead of server time.")
	room["last_snapshot_sequence"] = sequence
	room["last_snapshot_tick"] = tick
	room["latest_snapshot"] = message.duplicate(true)
	for player_id in room["member_order"]:
		if player_id != room["host_id"] and room["members"].has(player_id) \
				and room["members"][player_id]["connected"]:
			_queue_event(player_id, message.duplicate(true))
	return Result.success({"accepted_sequence": sequence, "accepted_tick": tick})


func _handle_race_event(room: Dictionary, member: Dictionary, message: Dictionary) -> Dictionary:
	if room["host_id"] != member["player_id"]:
		return Result.failure(&"host_only", "Only the simulation host may publish race completion.")
	if str(message["payload"].get("type", "")) != "race_complete":
		return Result.failure(&"race_event_type_invalid", "Race event is not accepted from a peer.")
	room["state"] = str(Limits.ROOM_RESULTS)
	_broadcast_room_event(room, Protocol.OP_RACE_EVENT, message["payload"].duplicate(true))
	return Result.success({"state": room["state"], "results": message["payload"]["results"].size()})


func _add_member(
		room: Dictionary,
		player_id: String,
		display_name: String,
		cosmetics: Dictionary,
		compatibility: Dictionary
	) -> void:
	_join_serial += 1
	var slot := _first_free_slot(room)
	var member := {
		"player_id": player_id,
		"display_name": display_name.strip_edges(),
		"car_id": str(cosmetics["car_id"]),
		"team_id": str(cosmetics["team_id"]),
		"compatibility": compatibility.duplicate(true),
		"slot": slot,
		"join_order": _join_serial,
		"connected": true,
		"disconnect_deadline_ms": -1,
		"reconnect_count": 0,
		"reconnect_token": _token_for(room["code"], player_id, 0),
		"generation_verified": false,
		"generation_error": "",
		"ready": false,
		"last_input_sequence": -1,
		"last_input_tick": -1,
		"malformed_count": 0,
		"quarantined": false,
	}
	room["members"][player_id] = member
	room["member_order"].append(player_id)
	_event_queues[player_id] = []


func _permanent_departure(room: Dictionary, player_id: String, reason: String, preserve_event_queue: bool = false) -> void:
	if not room["members"].has(player_id):
		return
	var was_host: bool = room["host_id"] == player_id
	room["members"].erase(player_id)
	room["member_order"].erase(player_id)
	_player_rooms.erase(player_id)
	if not preserve_event_queue:
		_event_queues.erase(player_id)
	if not was_host:
		if not room["track_manifest"].is_empty() \
				and room["state"] != str(Limits.ROOM_COUNTDOWN) \
				and room["state"] != str(Limits.ROOM_RACING) \
				and room["state"] != str(Limits.ROOM_RESULTS) \
				and room["state"] != str(Limits.ROOM_CLOSED):
			room["state"] = str(Limits.ROOM_READY) if _all_generation_verified(room) else str(Limits.ROOM_TRACK_SYNC)
		_broadcast_room_event(room, Protocol.OP_RACE_EVENT, {
			"type": "peer_departed",
			"player_id": player_id,
			"reason": reason,
		})
		return
	if room["state"] == str(Limits.ROOM_COUNTDOWN) or room["state"] == str(Limits.ROOM_RACING) \
			or room["state"] == str(Limits.ROOM_RESULTS):
		_close_room(room, "simulation_host_departed")
		return
	var successor := _oldest_connected_member(room)
	if successor.is_empty():
		_close_room(room, "host_departed_empty_room")
		return
	room["host_id"] = successor
	room["epoch"] = int(room["epoch"]) + 1
	room["last_snapshot_sequence"] = -1
	room["last_snapshot_tick"] = -1
	if not room["track_manifest"].is_empty():
		room["state"] = str(Limits.ROOM_READY) if _all_generation_verified(room) else str(Limits.ROOM_TRACK_SYNC)
	_broadcast_room_config(room)


func _close_room(room: Dictionary, reason: String) -> void:
	room["state"] = str(Limits.ROOM_CLOSED)
	room["close_reason"] = reason
	_broadcast_room_event(room, Protocol.OP_ROOM_ENDED, {
		"reason": reason,
		"host_departure_policy": str(Limits.HOST_DEPARTURE_RACE_POLICY),
	})


func _require_member(connection_id: String, room_code: String) -> Dictionary:
	var normalized_code := room_code.strip_edges().to_upper()
	if not _rooms.has(normalized_code):
		return Result.failure(&"room_not_found", "Private room was not found.")
	var room: Dictionary = _rooms[normalized_code]
	if not room["members"].has(connection_id):
		return Result.failure(&"not_room_member", "Transport identity is not a room member.")
	return Result.success({"room": room, "member": room["members"][connection_id]})


func _validate_identity(connection_id: String, display_name: String) -> Dictionary:
	if connection_id.is_empty() or connection_id.to_utf8_buffer().size() > Limits.MAX_PLAYER_ID_BYTES:
		return Result.failure(&"player_id_invalid", "Player identifier is empty or too long.")
	for index in connection_id.length():
		var code := connection_id.unicode_at(index)
		if code < 33 or code > 126:
			return Result.failure(&"player_id_invalid", "Player identifier contains unsupported characters.")
	var clean_name := display_name.strip_edges()
	if clean_name.is_empty() or clean_name.length() > Limits.MAX_DISPLAY_NAME_LENGTH:
		return Result.failure(&"display_name_invalid", "Display name is empty or too long.")
	for index in clean_name.length():
		if clean_name.unicode_at(index) < 32:
			return Result.failure(&"display_name_invalid", "Display name contains a control character.")
	return Result.success()


func _validate_cosmetics(value: Dictionary) -> Dictionary:
	var car_id := str(value.get("car_id", VehicleCatalog.DEFAULT_CAR_ID))
	var team_id := str(value.get("team_id", VehicleCatalog.DEFAULT_TEAM_ID))
	if not VehicleCatalog.is_valid_pair(car_id, team_id):
		return Result.failure(&"cosmetics_invalid", "Car and fictional team selection is invalid.")
	return Result.success({"car_id": car_id, "team_id": team_id})


func _validate_compatibility(value: Dictionary) -> Dictionary:
	var hello := value if not value.is_empty() else Limits.compatibility_payload("linux")
	var platform := str(hello.get("platform", "")).strip_edges().to_lower()
	if str(hello.get("app_build", "")) != Limits.APP_BUILD_ID \
			or typeof(hello.get("protocol_version")) != TYPE_INT \
			or int(hello.get("protocol_version", 0)) != Limits.PROTOCOL_VERSION \
			or typeof(hello.get("track_schema_version")) != TYPE_INT \
			or int(hello.get("track_schema_version", 0)) != Limits.TRACK_SCHEMA_VERSION \
			or typeof(hello.get("generator_version")) != TYPE_INT \
			or int(hello.get("generator_version", 0)) != Limits.TRACK_GENERATOR_VERSION \
			or not Limits.SUPPORTED_PLATFORMS.has(platform):
		return Result.failure(
			&"update_required",
			"This build cannot join the room. Update RaceGlyph and try again.",
			{"required": Limits.compatibility_payload("supported-platform")}
		)
	return Result.success({
		"app_build": Limits.APP_BUILD_ID,
		"protocol_version": Limits.PROTOCOL_VERSION,
		"track_schema_version": Limits.TRACK_SCHEMA_VERSION,
		"generator_version": Limits.TRACK_GENERATOR_VERSION,
		"platform": platform,
	})


func _room_view(room: Dictionary, recipient_id: String) -> Dictionary:
	var view := _room_public_view(room)
	view["reconnect_token"] = room["members"].get(recipient_id, {}).get("reconnect_token", "")
	return view


func _room_public_view(room: Dictionary) -> Dictionary:
	return {
		"room_code": room["code"],
		"room_epoch": room["epoch"],
		"state": room["state"],
		"host_id": room["host_id"],
		"member_count": room["members"].size(),
		"members": _roster(room),
		"track_identity": TrackManifest.identity(room["track_manifest"]),
		"race_config": room["race_config"].duplicate(true),
		"join_locked": bool(room.get("join_locked", false)),
		"countdown": room["countdown"].duplicate(true),
		"close_reason": room["close_reason"],
	}


func _broadcast_room_config(room: Dictionary) -> void:
	_broadcast_room_event(room, Protocol.OP_ROOM_CONFIG, _room_public_view(room))


func _validate_race_config(config: Dictionary) -> Dictionary:
	if not config.has("laps") or not config.has("collisions") \
			or not Limits.is_valid_multiplayer_lap_count(config.get("laps")) \
			or typeof(config.get("collisions")) != TYPE_BOOL:
		return Result.failure(&"race_config_invalid", "Race rules require 1, 3, or 5 laps and a collision toggle.")
	return Result.success({
		"laps": int(config["laps"]),
		"collisions": bool(config["collisions"]),
	})


func _roster(room: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for player_id in room["member_order"]:
		if not room["members"].has(player_id):
			continue
		var member: Dictionary = room["members"][player_id]
		output.append({
			"player_id": member["player_id"],
			"display_name": member["display_name"],
			"car_id": member["car_id"],
			"team_id": member["team_id"],
			"slot": member["slot"],
			"connected": member["connected"],
			"generation_verified": member["generation_verified"],
			"ready": member["ready"],
			"is_host": room["host_id"] == player_id,
		})
	return output


func _all_generation_verified(room: Dictionary) -> bool:
	if room["members"].is_empty():
		return false
	for player_id in room["member_order"]:
		if room["members"].has(player_id) and not room["members"][player_id]["generation_verified"]:
			return false
	return true


func _all_ready(room: Dictionary) -> bool:
	if room["members"].is_empty():
		return false
	for player_id in room["member_order"]:
		if room["members"].has(player_id) and not room["members"][player_id]["ready"]:
			return false
	return true


func _first_free_slot(room: Dictionary) -> int:
	var occupied: Dictionary = {}
	for player_id in room["member_order"]:
		if room["members"].has(player_id):
			occupied[int(room["members"][player_id]["slot"])] = true
	for slot in Limits.MAX_PLAYERS:
		if not occupied.has(slot):
			return slot
	return -1


func _oldest_connected_member(room: Dictionary) -> String:
	for player_id in room["member_order"]:
		if room["members"].has(player_id) and room["members"][player_id]["connected"]:
			return player_id
	return ""


func _host_connected(room: Dictionary) -> bool:
	return room["members"].has(room["host_id"]) and room["members"][room["host_id"]]["connected"]


func _broadcast_room_event(room: Dictionary, opcode: int, payload: Dictionary, excluded_id: String = "") -> void:
	room["server_sequence"] = int(room["server_sequence"]) + 1
	var envelope := Protocol.make_envelope(
		opcode,
		"server",
		int(room["server_sequence"]),
		int(room["epoch"]),
		payload,
		_server_tick
	)
	for player_id in room["member_order"]:
		if player_id == excluded_id or not room["members"].has(player_id):
			continue
		if room["members"][player_id]["connected"]:
			_queue_event(player_id, envelope.duplicate(true))


func _queue_event(player_id: String, event: Dictionary) -> void:
	if not _event_queues.has(player_id):
		_event_queues[player_id] = []
	_event_queues[player_id].append(event)


func _record_malformed(member: Dictionary) -> void:
	member["malformed_count"] = int(member["malformed_count"]) + 1
	if int(member["malformed_count"]) >= Limits.MALFORMED_MESSAGES_BEFORE_QUARANTINE:
		member["quarantined"] = true


func _consume_rate(bucket_key: String, maximum: int, window_ms: int) -> bool:
	var timestamps: Array = _rate_buckets.get(bucket_key, [])
	while not timestamps.is_empty() and int(timestamps[0]) <= _now_ms - window_ms:
		timestamps.pop_front()
	if timestamps.size() >= maximum:
		_rate_buckets[bucket_key] = timestamps
		return false
	timestamps.append(_now_ms)
	_rate_buckets[bucket_key] = timestamps
	return true


func _room_code_for_serial(serial: int) -> String:
	var alphabet := Limits.ROOM_CODE_ALPHABET
	var value := serial
	var output := ""
	for _index in Limits.ROOM_CODE_LENGTH:
		output = alphabet[value % alphabet.length()] + output
		value /= alphabet.length()
	return output


func _valid_room_code(room_code: String) -> bool:
	if room_code.length() != Limits.ROOM_CODE_LENGTH:
		return false
	for index in room_code.length():
		if Limits.ROOM_CODE_ALPHABET.find(room_code[index]) < 0:
			return false
	return true


func _token_for(room_code: String, player_id: String, reconnect_count: int) -> String:
	return ("raceglyph-fake-v1|%s|%s|%d|%d" % [room_code, player_id, _join_serial, reconnect_count]).sha256_text()


func _bounded_text(value: String, maximum_length: int) -> String:
	return value if value.length() <= maximum_length else value.left(maximum_length)
