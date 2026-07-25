class_name MultiplayerTransport
extends RefCounted
## Transport boundary shared by the deterministic fake and pinned Nakama
## adapter. No gameplay code depends on Nakama SDK types.

const Result := preload("res://game/network/network_result.gd")


func create_private_room(_display_name: String, _cosmetics: Dictionary = {}, _compatibility: Dictionary = {}) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement room creation.")


func join_private_room(_room_code: String, _display_name: String, _cosmetics: Dictionary = {}, _compatibility: Dictionary = {}) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement room join.")


func submit_track_manifest(_room_code: String, _manifest: Dictionary) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement track transfer.")


func submit_generation_report(_room_code: String, _report: Dictionary) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement generation reports.")


func set_ready(_room_code: String, _ready: bool) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement readiness.")


func set_race_config(_room_code: String, _config: Dictionary) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement race configuration.")


func set_room_lock(_room_code: String, _locked: bool) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement room locking.")


func start_countdown(_room_code: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement countdown start.")


func kick_member(_room_code: String, _player_id: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement member removal.")


func request_rematch(_room_code: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement rematch requests.")


func send_envelope(_room_code: String, _message: Dictionary) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement race messages.")


func reconnect(_room_code: String, _reconnect_token: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement reconnect.")


func suspend_connection(_room_code: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement disconnect.")


func leave_room(_room_code: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement room departure.")


func room_snapshot(_room_code: String) -> Dictionary:
	return Result.failure(&"transport_unavailable", "Transport does not implement room inspection.")


func drain_events() -> Array[Dictionary]:
	return []
