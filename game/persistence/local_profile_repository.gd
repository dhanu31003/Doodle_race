class_name LocalProfileRepository
extends RefCounted
## Transactional API for RaceGlyph's device-local state.
##
## Mutations are rolled back in memory if persistence fails. Callers may batch
## with persist=false and finish with save_now(), but user-facing actions should
## normally keep the default immediate write.

const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const GameSettingsType := preload("res://game/settings/game_settings.gd")
const AtomicSaveStoreType := preload("res://game/persistence/atomic_save_store.gd")
const LocalSaveDataType := preload("res://game/persistence/local_save_data.gd")
const SaveLimitsType := preload("res://game/persistence/save_limits.gd")

var _store: AtomicSaveStore
var _clock: Callable
var _data: LocalSaveData
var _loaded: bool = false


func _init(save_path: String = AtomicSaveStoreType.DEFAULT_SAVE_PATH, clock: Callable = Callable()) -> void:
	_store = AtomicSaveStoreType.new(save_path)
	_clock = clock
	_data = LocalSaveDataType.new()


func load() -> Dictionary:
	var load_result := _store.load_payload()
	if not load_result.get("ok", false):
		return load_result
	var payload: Dictionary = load_result.get("payload", {})
	if payload.is_empty() and load_result.get("source") == "defaults":
		_data = LocalSaveDataType.new()
		_data.created_at_timestamp = _now()
		_data.updated_at_timestamp = _data.created_at_timestamp
		_loaded = true
		return {
			"ok": true,
			"source": "defaults",
			"recovered": false,
			"migrated": false,
			"warnings": [],
		}

	var decoded := LocalSaveDataType.from_dictionary(payload)
	if decoded.unsupported_schema:
		return _failure("unsupported_save_schema", "This local save was created by a newer game version.")
	var envelope_revision := int(load_result.get("revision", 0))
	if decoded.revision != envelope_revision:
		decoded.load_warnings.append("save.revision_reconciled")
		decoded.revision = envelope_revision
	_data = decoded
	_loaded = true
	var migrated := decoded.was_migrated
	if migrated:
		var migration_write := save_now()
		if not migration_write.get("ok", false):
			_loaded = false
			return _failure("migration_write_failed", "The old save was read but its migrated copy could not be installed.")
	return {
		"ok": true,
		"source": load_result.get("source", "primary"),
		"recovered": load_result.get("recovered", false),
		"migrated": migrated,
		"revision": _data.revision,
		"warnings": _data.load_warnings.duplicate(),
	}


func save_now() -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var previous_revision := _data.revision
	var previous_updated := _data.updated_at_timestamp
	_data.revision = previous_revision + 1
	_data.updated_at_timestamp = maxi(_data.created_at_timestamp, _now())
	var result := _store.write_payload(_data.to_dictionary(), _data.revision, _data.updated_at_timestamp)
	if not result.get("ok", false):
		_data.revision = previous_revision
		_data.updated_at_timestamp = previous_updated
	return result


func snapshot() -> LocalSaveData:
	if not _loaded:
		return LocalSaveDataType.new()
	return _data.copy()


func settings_snapshot() -> GameSettings:
	return _data.settings.sanitized_copy() if _loaded else GameSettingsType.new()


func update_settings(value: GameSettings, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	if value == null:
		return _failure("settings_missing", "Settings cannot be null.")
	var before := _data.copy()
	_data.settings = value.sanitized_copy()
	return _finish_mutation(before, persist, {"settings": _data.settings.to_dictionary()})


func upsert_track(definition: Variant, metadata: Dictionary = {}, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	if definition == null or not definition.has_method("to_dictionary"):
		return _failure("track_missing", "A TrackDefinition is required.")
	var candidate := TrackDefinitionType.from_dictionary(definition.to_dictionary(true))
	var clean_id := LocalSaveDataType.sanitize_identifier(candidate.track_id, 96)
	if clean_id.is_empty() or clean_id != candidate.track_id:
		return _failure("track_id_invalid", "Track ID contains unsupported characters or is empty.")
	var now := _now()
	var index := _find_track_index(clean_id)
	if index < 0 and _data.saved_tracks.size() >= SaveLimitsType.MAX_SAVED_TRACKS:
		return _failure("track_limit_reached", "The local custom-track limit has been reached.")
	var existing_metadata: Dictionary = {}
	if index >= 0:
		existing_metadata = _data.saved_tracks[index].get("metadata", {}).duplicate(true)
	var merged_metadata := existing_metadata
	merged_metadata.merge(metadata, true)
	var clean_name := LocalSaveDataType.sanitize_display_name(
		merged_metadata.get("display_name", candidate.track_name), "Untitled Track"
	)
	candidate.track_name = clean_name
	if index >= 0:
		candidate.created_at_timestamp = int(existing_metadata.get("created_at_timestamp", candidate.created_at_timestamp))
	else:
		candidate.created_at_timestamp = now
	candidate.updated_at_timestamp = now
	candidate.refresh_content_hash()
	var validation := candidate.validate_schema()
	if not validation.is_valid():
		return {
			"ok": false,
			"error_code": "track_invalid",
			"message": "TrackDefinition failed schema validation.",
			"issues": validation.to_dictionary().get("issues", []),
		}
	merged_metadata["display_name"] = clean_name
	merged_metadata["created_at_timestamp"] = candidate.created_at_timestamp
	merged_metadata["updated_at_timestamp"] = now
	var clean_metadata := LocalSaveDataType.sanitize_metadata(merged_metadata, clean_name, now)
	if CanonicalJsonType.stringify(clean_metadata).to_utf8_buffer().size() > SaveLimitsType.MAX_TRACK_METADATA_BYTES:
		return _failure("track_metadata_too_large", "Track metadata exceeds the supported size.")
	var entry := {
		"definition": candidate.to_dictionary(true),
		"metadata": clean_metadata,
	}
	var before := _data.copy()
	if index >= 0:
		_data.saved_tracks[index] = entry
	else:
		_data.saved_tracks.append(entry)
	return _finish_mutation(before, persist, {
		"track_id": clean_id,
		"content_hash": candidate.content_hash,
		"created": index < 0,
	})


func get_track(track_id: String) -> Variant:
	if not _loaded:
		return null
	var index := _find_track_index(track_id)
	if index < 0:
		return null
	return TrackDefinitionType.from_dictionary(_data.saved_tracks[index]["definition"])


func list_track_metadata() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not _loaded:
		return output
	for entry in _data.saved_tracks:
		var definition: Dictionary = entry.get("definition", {})
		var metadata: Dictionary = entry.get("metadata", {}).duplicate(true)
		metadata["track_id"] = str(definition.get("track_id", ""))
		metadata["content_hash"] = str(definition.get("content_hash", ""))
		output.append(metadata)
	# Stable insertion sort: newest edit first, then Track ID ascending.
	for index in range(1, output.size()):
		var candidate := output[index]
		var cursor := index - 1
		while cursor >= 0 and _metadata_before(candidate, output[cursor]):
			output[cursor + 1] = output[cursor]
			cursor -= 1
		output[cursor + 1] = candidate
	return output


func rename_track(track_id: String, new_name: String, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var index := _find_track_index(track_id)
	if index < 0:
		return _failure("track_not_found", "No saved track has that ID.")
	var clean_name := LocalSaveDataType.sanitize_display_name(new_name, "")
	if clean_name.is_empty():
		return _failure("track_name_invalid", "Track name cannot be empty.")
	var before := _data.copy()
	var definition := TrackDefinitionType.from_dictionary(_data.saved_tracks[index]["definition"])
	definition.track_name = clean_name
	definition.updated_at_timestamp = _now()
	definition.refresh_content_hash()
	_data.saved_tracks[index]["definition"] = definition.to_dictionary(true)
	_data.saved_tracks[index]["metadata"]["display_name"] = clean_name
	_data.saved_tracks[index]["metadata"]["updated_at_timestamp"] = definition.updated_at_timestamp
	return _finish_mutation(before, persist, {
		"track_id": track_id,
		"display_name": clean_name,
		"content_hash": definition.content_hash,
	})


func delete_track(track_id: String, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var index := _find_track_index(track_id)
	if index < 0:
		return _failure("track_not_found", "No saved track has that ID.")
	var before := _data.copy()
	_data.saved_tracks.remove_at(index)
	return _finish_mutation(before, persist, {"track_id": track_id, "deleted": true})


func record_best_lap(
		track_id: String,
		time_ms: int,
		vehicle_id: String = "",
		achieved_at_timestamp: int = -1,
		persist: bool = true
	) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var clean_track_id := LocalSaveDataType.sanitize_identifier(track_id)
	if clean_track_id.is_empty() or clean_track_id != track_id:
		return _failure("track_id_invalid", "Track ID is invalid.")
	if time_ms <= 0 or time_ms > SaveLimitsType.MAX_RACE_TIME_MS:
		return _failure("lap_time_invalid", "Lap time is outside the supported range.")
	var existing: Dictionary = _data.best_laps.get(clean_track_id, {})
	if not existing.is_empty() and int(existing.get("time_ms", SaveLimitsType.MAX_RACE_TIME_MS)) <= time_ms:
		return {"ok": true, "improved": false, "best_lap": existing.duplicate(true)}
	if existing.is_empty() and _data.best_laps.size() >= SaveLimitsType.MAX_BEST_LAPS:
		return _failure("best_lap_limit_reached", "The best-lap record limit has been reached.")
	var before := _data.copy()
	var achieved := _now() if achieved_at_timestamp < 0 else achieved_at_timestamp
	var entry := {
		"time_ms": time_ms,
		"vehicle_id": LocalSaveDataType.sanitize_identifier(vehicle_id, SaveLimitsType.MAX_VEHICLE_ID_BYTES),
		"achieved_at_timestamp": clampi(achieved, 0, SaveLimitsType.MAX_SAFE_JSON_INTEGER),
	}
	_data.best_laps[clean_track_id] = entry
	return _finish_mutation(before, persist, {"improved": true, "best_lap": entry.duplicate(true)})


func record_race_result(result: Dictionary, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var track_id := LocalSaveDataType.sanitize_identifier(result.get("track_id", ""))
	var racer_count := clampi(_safe_int(result.get("racer_count"), 1), 1, 12)
	var position := _safe_int(result.get("position"), 0)
	var total_time_ms := _safe_int(result.get("total_time_ms"), 0)
	if track_id.is_empty() or position < 1 or position > racer_count \
			or total_time_ms < 0 or total_time_ms > SaveLimitsType.MAX_RACE_TIME_MS:
		return _failure("race_result_invalid", "Race result contains invalid authority values.")
	var before := _data.copy()
	var entry := {
		"track_id": track_id,
		"position": position,
		"racer_count": racer_count,
		"total_time_ms": total_time_ms,
		"finished": result.get("finished", true) if typeof(result.get("finished", true)) == TYPE_BOOL else true,
		"vehicle_id": LocalSaveDataType.sanitize_identifier(result.get("vehicle_id", ""), SaveLimitsType.MAX_VEHICLE_ID_BYTES),
		"recorded_at_timestamp": clampi(_safe_int(result.get("recorded_at_timestamp"), _now()), 0, SaveLimitsType.MAX_SAFE_JSON_INTEGER),
	}
	_data.race_results.append(entry)
	while _data.race_results.size() > SaveLimitsType.MAX_RACE_RESULTS:
		_data.race_results.pop_front()
	return _finish_mutation(before, persist, {"result": entry.duplicate(true)})


func unlock_content(content_id: String, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var clean_id := LocalSaveDataType.sanitize_identifier(content_id)
	if clean_id.is_empty() or clean_id != content_id:
		return _failure("unlock_id_invalid", "Unlock ID is invalid.")
	if _data.unlocks.has(clean_id):
		return {"ok": true, "created": false, "content_id": clean_id}
	if _data.unlocks.size() >= SaveLimitsType.MAX_UNLOCKS:
		return _failure("unlock_limit_reached", "The local unlock limit has been reached.")
	var before := _data.copy()
	_data.unlocks.append(clean_id)
	_data.unlocks.sort()
	return _finish_mutation(before, persist, {"created": true, "content_id": clean_id})


func set_selected_cosmetics(car_id: String, team_id: String, persist: bool = true) -> Dictionary:
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var clean_car := LocalSaveDataType.sanitize_identifier(car_id, SaveLimitsType.MAX_VEHICLE_ID_BYTES)
	var clean_team := LocalSaveDataType.sanitize_identifier(team_id)
	if clean_car != car_id or clean_team != team_id:
		return _failure("cosmetic_id_invalid", "Car or team ID is invalid.")
	var before := _data.copy()
	_data.selected_car_id = clean_car
	_data.selected_team_id = clean_team
	return _finish_mutation(before, persist, {
		"selected_car_id": clean_car,
		"selected_team_id": clean_team,
	})


func reset_progress(persist: bool = true) -> Dictionary:
	# Custom tracks and user preferences are intentionally retained. This is the
	# explicit progression reset surfaced by Settings; full deletion is separate.
	var ready := _ensure_loaded()
	if not ready.get("ok", false):
		return ready
	var before := _data.copy()
	_data.best_laps.clear()
	_data.race_results.clear()
	_data.unlocks.clear()
	_data.selected_car_id = ""
	_data.selected_team_id = ""
	return _finish_mutation(before, persist, {"progress_reset": true})


func delete_all_local_data() -> Dictionary:
	# Explicit privacy/delete API. No implicit gameplay path calls this method.
	var deletion := _store.delete_all_copies()
	if deletion.get("ok", false):
		_data = LocalSaveDataType.new()
		_data.created_at_timestamp = _now()
		_data.updated_at_timestamp = _data.created_at_timestamp
		_loaded = true
	return deletion


func export_payload_json() -> String:
	return CanonicalJsonType.stringify(_data.to_dictionary()) if _loaded else ""


func store() -> AtomicSaveStore:
	return _store


func _finish_mutation(before: LocalSaveData, persist: bool, extra: Dictionary) -> Dictionary:
	if not persist:
		var deferred := {"ok": true, "persisted": false}
		deferred.merge(extra, true)
		return deferred
	var saved := save_now()
	if not saved.get("ok", false):
		_data = before
		return saved
	var output := {"ok": true, "persisted": true, "revision": _data.revision}
	output.merge(extra, true)
	return output


func _find_track_index(track_id: String) -> int:
	for index in _data.saved_tracks.size():
		var definition: Dictionary = _data.saved_tracks[index].get("definition", {})
		if str(definition.get("track_id", "")) == track_id:
			return index
	return -1


func _ensure_loaded() -> Dictionary:
	if _loaded:
		return {"ok": true}
	return _failure("repository_not_loaded", "Call load() before using local persistence.")


func _now() -> int:
	var value: Variant = _clock.call() if _clock.is_valid() else Time.get_unix_time_from_system()
	return clampi(_safe_int(value, 0), 0, SaveLimitsType.MAX_SAFE_JSON_INTEGER)


static func _metadata_before(left: Dictionary, right: Dictionary) -> bool:
	var left_updated := int(left.get("updated_at_timestamp", 0))
	var right_updated := int(right.get("updated_at_timestamp", 0))
	if left_updated != right_updated:
		return left_updated > right_updated
	return str(left.get("track_id", "")) < str(right.get("track_id", ""))


static func _safe_int(value: Variant, fallback: int = 0) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT:
		var parsed := float(value)
		if not is_nan(parsed) and not is_inf(parsed) and parsed == round(parsed):
			return int(parsed)
	return fallback


static func _failure(code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"error_code": code,
		"message": message,
	}
