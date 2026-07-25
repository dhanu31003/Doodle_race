extends Node
## Process-wide boundary for local persistence and runtime preferences.

signal profile_loaded(result: Dictionary)
signal settings_changed(settings: GameSettings)
signal tracks_changed()
signal persistence_error(result: Dictionary)

const RepositoryType := preload("res://game/persistence/local_profile_repository.gd")
const SettingsType := preload("res://game/settings/game_settings.gd")
const SettingsRuntimeType := preload("res://game/settings/settings_runtime.gd")
const TrackExchangeType := preload("res://game/persistence/track_exchange.gd")
const ProfileExchangeType := preload("res://game/persistence/profile_exchange.gd")
const IdentityStoreType := preload("res://game/network/client/install_identity_store.gd")

var repository: LocalProfileRepository
var startup_result: Dictionary = {}
var _settings: GameSettings = SettingsType.new()


func _ready() -> void:
	repository = RepositoryType.new()
	startup_result = repository.load()
	if startup_result.get("ok", false):
		_settings = repository.settings_snapshot()
		_apply_settings_runtime()
	else:
		persistence_error.emit(startup_result)
	profile_loaded.emit(startup_result.duplicate(true))


func is_ready() -> bool:
	return not startup_result.is_empty() and bool(startup_result.get("ok", false))


func settings() -> GameSettings:
	return _settings.sanitized_copy()


func selected_cosmetics() -> Dictionary:
	if not is_ready():
		return {"car_id": "", "team_id": ""}
	var snapshot := repository.snapshot()
	return {
		"car_id": snapshot.selected_car_id,
		"team_id": snapshot.selected_team_id,
	}


func set_selected_cosmetics(car_id: String, team_id: String) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.set_selected_cosmetics(car_id, team_id)
	if not result.get("ok", false):
		persistence_error.emit(result)
	return result


func update_settings(value: GameSettings) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.update_settings(value)
	if result.get("ok", false):
		_settings = repository.settings_snapshot()
		_apply_settings_runtime()
		settings_changed.emit(_settings.sanitized_copy())
	else:
		persistence_error.emit(result)
	return result


func save_track(definition: TrackDefinition, metadata: Dictionary = {}) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.upsert_track(definition, metadata)
	if result.get("ok", false):
		tracks_changed.emit()
	else:
		persistence_error.emit(result)
	return result


func get_track(track_id: String) -> TrackDefinition:
	if not is_ready():
		return null
	return repository.get_track(track_id)


func list_track_metadata() -> Array[Dictionary]:
	return repository.list_track_metadata() if is_ready() else []


func rename_track(track_id: String, new_name: String) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.rename_track(track_id, new_name)
	if result.get("ok", false):
		tracks_changed.emit()
	else:
		persistence_error.emit(result)
	return result


func delete_track(track_id: String) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.delete_track(track_id)
	if result.get("ok", false):
		tracks_changed.emit()
	else:
		persistence_error.emit(result)
	return result


func export_track(track_id: String) -> Dictionary:
	var definition := get_track(track_id)
	if definition == null:
		return {"ok": false, "error_code": "track_not_found", "message": "No saved circuit has that ID."}
	return TrackExchangeType.export_to_file(definition)


func export_local_data() -> Dictionary:
	if not is_ready():
		return _not_ready()
	var snapshot := repository.snapshot().to_dictionary()
	return ProfileExchangeType.export_to_file(
		snapshot,
		int(Time.get_unix_time_from_system())
	)


func record_race_result(result_data: Dictionary) -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.record_race_result(result_data)
	if not result.get("ok", false):
		persistence_error.emit(result)
	return result


func record_best_lap(track_id: String, time_ms: int, vehicle_id: String = "car-prime") -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.record_best_lap(track_id, time_ms, vehicle_id)
	if not result.get("ok", false):
		persistence_error.emit(result)
	return result


func reset_progress() -> Dictionary:
	if not is_ready():
		return _not_ready()
	var result := repository.reset_progress()
	if not result.get("ok", false):
		persistence_error.emit(result)
	return result


func delete_all_local_data() -> Dictionary:
	if repository == null:
		return _not_ready()
	# Close the in-memory transport first so bearer/reconnect state cannot
	# survive a local privacy deletion even if a filesystem operation fails.
	var network_session := get_node_or_null("/root/NetworkSession")
	if network_session != null and network_session.has_method("reset_session"):
		network_session.call("reset_session", true)
	var identity_result := IdentityStoreType.new().delete_identity()
	var profile_result := repository.delete_all_local_data()
	var complete: bool = bool(identity_result.get("ok", false)) and bool(profile_result.get("ok", false))
	if complete:
		startup_result = {"ok": true, "source": "defaults", "recovered": false}
		_settings = repository.settings_snapshot()
		_apply_settings_runtime()
		settings_changed.emit(_settings.sanitized_copy())
		tracks_changed.emit()
		return {
			"ok": true,
			"local_profile_deleted": true,
			"anonymous_identity_deleted": bool(identity_result.get("deleted", false)),
		}
	var failure := {
		"ok": false,
		"error_code": "local_data_delete_partial",
		"message": "Local data deletion did not fully complete. The network session was closed; retry deletion before sharing this device.",
		"profile_result": profile_result,
		"identity_result": identity_result,
	}
	persistence_error.emit(failure)
	return failure


func _apply_settings_runtime() -> void:
	SettingsRuntimeType.apply_audio(_settings)
	SettingsRuntimeType.apply_performance(_settings)
	var audio := get_node_or_null("/root/Audio")
	if audio != null:
		audio.call("apply_settings", _settings.to_dictionary())


func _not_ready() -> Dictionary:
	return {
		"ok": false,
		"error_code": "profile_not_ready",
		"message": str(startup_result.get("message", "Local profile is not ready.")),
	}
