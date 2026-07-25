class_name InMemoryTransport
extends MultiplayerTransport
## Per-player adapter over FakeRoomServer. Tests use the same transport surface
## intended for the future Nakama implementation.

var _server: Variant
var connection_id: String = ""


func _init(server: Variant = null, id: String = "") -> void:
	_server = server
	connection_id = id


func create_private_room(display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if _server == null:
		return Result.failure(&"transport_unavailable", "Fake server is not attached.")
	return _server.create_room(connection_id, display_name, cosmetics, compatibility)


func join_private_room(room_code: String, display_name: String, cosmetics: Dictionary = {}, compatibility: Dictionary = {}) -> Dictionary:
	if _server == null:
		return Result.failure(&"transport_unavailable", "Fake server is not attached.")
	return _server.join_room(connection_id, room_code, display_name, cosmetics, compatibility)


func submit_track_manifest(room_code: String, manifest: Dictionary) -> Dictionary:
	return _server.submit_track_manifest(connection_id, room_code, manifest)


func submit_generation_report(room_code: String, report: Dictionary) -> Dictionary:
	return _server.submit_generation_report(connection_id, room_code, report)


func set_ready(room_code: String, ready: bool) -> Dictionary:
	return _server.set_ready(connection_id, room_code, ready)


func set_race_config(room_code: String, config: Dictionary) -> Dictionary:
	return _server.set_race_config(connection_id, room_code, config)


func set_room_lock(room_code: String, locked: bool) -> Dictionary:
	return _server.set_room_lock(connection_id, room_code, locked)


func start_countdown(room_code: String) -> Dictionary:
	return _server.start_countdown(connection_id, room_code)


func kick_member(room_code: String, player_id: String) -> Dictionary:
	return _server.kick_member(connection_id, room_code, player_id)


func request_rematch(room_code: String) -> Dictionary:
	return _server.request_rematch(connection_id, room_code)


func send_envelope(room_code: String, message: Dictionary) -> Dictionary:
	return _server.handle_envelope(connection_id, room_code, message)


func reconnect(room_code: String, reconnect_token: String) -> Dictionary:
	return _server.reconnect(connection_id, room_code, reconnect_token)


func suspend_connection(room_code: String) -> Dictionary:
	return _server.suspend_connection(connection_id, room_code)


func leave_room(room_code: String) -> Dictionary:
	return _server.leave_room(connection_id, room_code)


func room_snapshot(room_code: String) -> Dictionary:
	return _server.room_snapshot(connection_id, room_code)


func drain_events() -> Array[Dictionary]:
	return _server.drain_events(connection_id)
