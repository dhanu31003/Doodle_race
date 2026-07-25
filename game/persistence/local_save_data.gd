class_name LocalSaveData
extends RefCounted
## In-memory representation of the current local-save payload.
## Invalid individual records are dropped with warnings; the checksum envelope
## is responsible for detecting whole-file corruption.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const GameSettingsType := preload("res://game/settings/game_settings.gd")
const SaveLimitsType := preload("res://game/persistence/save_limits.gd")

var schema_version: int = SaveLimitsType.SAVE_SCHEMA_VERSION
var revision: int = 0
var created_at_timestamp: int = 0
var updated_at_timestamp: int = 0
var settings: GameSettings = GameSettingsType.new()
var saved_tracks: Array[Dictionary] = []
var best_laps: Dictionary = {}
var race_results: Array[Dictionary] = []
var unlocks: Array[String] = []
var selected_car_id: String = ""
var selected_team_id: String = ""
var load_warnings: Array[String] = []
var was_migrated: bool = false
var unsupported_schema: bool = false


static func from_dictionary(input: Variant) -> LocalSaveData:
	var output := LocalSaveData.new()
	if not input is Dictionary:
		output.load_warnings.append("save.root_not_object")
		return output
	var original: Dictionary = input
	var source_version := _safe_int(original.get("schema_version"), 0)
	if source_version < 0 or source_version > SaveLimitsType.SAVE_SCHEMA_VERSION:
		output.unsupported_schema = true
		output.load_warnings.append("save.unsupported_schema")
		return output
	var data := _migrate_to_current(original, source_version)
	output.was_migrated = source_version != SaveLimitsType.SAVE_SCHEMA_VERSION
	output.schema_version = SaveLimitsType.SAVE_SCHEMA_VERSION
	output.revision = clampi(_safe_int(data.get("revision"), 0), 0, SaveLimitsType.MAX_SAFE_JSON_INTEGER)
	output.created_at_timestamp = _bounded_timestamp(data.get("created_at_timestamp"))
	output.updated_at_timestamp = _bounded_timestamp(data.get("updated_at_timestamp"))
	if output.updated_at_timestamp < output.created_at_timestamp:
		output.updated_at_timestamp = output.created_at_timestamp
	output.settings = GameSettingsType.from_dictionary(data.get("settings", {}))
	output.saved_tracks = _sanitize_tracks(data.get("saved_tracks"), output.load_warnings)
	output.best_laps = _sanitize_best_laps(data.get("best_laps"), output.load_warnings)
	output.race_results = _sanitize_results(data.get("race_results"), output.load_warnings)
	output.unlocks = _sanitize_unlocks(data.get("unlocks"), output.load_warnings)
	output.selected_car_id = sanitize_identifier(data.get("selected_car_id", ""), SaveLimitsType.MAX_VEHICLE_ID_BYTES)
	output.selected_team_id = sanitize_identifier(data.get("selected_team_id", ""), SaveLimitsType.MAX_CONTENT_ID_BYTES)
	return output


func to_dictionary() -> Dictionary:
	return {
		"schema_version": SaveLimitsType.SAVE_SCHEMA_VERSION,
		"revision": revision,
		"created_at_timestamp": created_at_timestamp,
		"updated_at_timestamp": updated_at_timestamp,
		"settings": settings.sanitized_copy().to_dictionary(),
		"saved_tracks": saved_tracks.duplicate(true),
		"best_laps": best_laps.duplicate(true),
		"race_results": race_results.duplicate(true),
		"unlocks": unlocks.duplicate(),
		"selected_car_id": selected_car_id,
		"selected_team_id": selected_team_id,
	}


func copy() -> LocalSaveData:
	return LocalSaveData.from_dictionary(to_dictionary())


static func sanitize_display_name(value: Variant, fallback: String = "Untitled Track") -> String:
	var clean := _clean_text(str(value), GameLimitsType.MAX_DISPLAY_NAME_LENGTH)
	return clean if not clean.is_empty() else fallback


static func sanitize_identifier(value: Variant, maximum_bytes: int = SaveLimitsType.MAX_CONTENT_ID_BYTES) -> String:
	var raw := str(value).strip_edges()
	var clean := ""
	for index in raw.length():
		var code := raw.unicode_at(index)
		var character := String.chr(code)
		if (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or "._:-".contains(character):
			if (clean + character).to_utf8_buffer().size() > maximum_bytes:
				break
			clean += character
	return clean


static func sanitize_metadata(input: Variant, definition_name: String, now_timestamp: int) -> Dictionary:
	var metadata: Dictionary = input if input is Dictionary else {}
	var created := _bounded_timestamp(metadata.get("created_at_timestamp", now_timestamp))
	var updated := _bounded_timestamp(metadata.get("updated_at_timestamp", now_timestamp))
	if updated < created:
		updated = created
	var thumbnail := _safe_thumbnail_path(metadata.get("thumbnail_path", ""))
	var tags := _sanitize_tags(metadata.get("tags", []))
	var source := str(metadata.get("source", "custom"))
	if source != "custom" and source != "imported" and source != "host":
		source = "custom"
	return {
		"display_name": sanitize_display_name(metadata.get("display_name", definition_name), definition_name),
		"created_at_timestamp": created,
		"updated_at_timestamp": updated,
		"favorite": metadata.get("favorite", false) if typeof(metadata.get("favorite", false)) == TYPE_BOOL else false,
		"source": source,
		"thumbnail_path": thumbnail,
		"tags": tags,
	}


static func _migrate_to_current(input: Dictionary, source_version: int) -> Dictionary:
	if source_version == SaveLimitsType.SAVE_SCHEMA_VERSION:
		return input.duplicate(true)
	# Prototype schema v0 aliases. The track definition itself remains governed
	# by TrackDefinition's independent schema and migration rules.
	var migrated := {
		"schema_version": SaveLimitsType.SAVE_SCHEMA_VERSION,
		"revision": _safe_int(input.get("revision"), 0),
		"created_at_timestamp": _bounded_timestamp(input.get("created_at_timestamp")),
		"updated_at_timestamp": _bounded_timestamp(input.get("updated_at_timestamp")),
		"settings": input.get("settings", {}),
		"saved_tracks": input.get("tracks", input.get("saved_tracks", [])),
		"race_results": input.get("results", input.get("race_results", [])),
		"unlocks": input.get("unlocked", input.get("unlocks", [])),
		"selected_car_id": input.get("selected_car", input.get("selected_car_id", "")),
		"selected_team_id": input.get("selected_team", input.get("selected_team_id", "")),
	}
	var legacy_best: Variant = input.get("best_times_ms", input.get("best_laps", {}))
	var migrated_best: Dictionary = {}
	if legacy_best is Dictionary:
		for key_variant in legacy_best.keys():
			var key := str(key_variant)
			var value: Variant = legacy_best[key_variant]
			if value is Dictionary:
				migrated_best[key] = value
			else:
				migrated_best[key] = {
					"time_ms": _safe_int(value),
					"vehicle_id": "",
					"achieved_at_timestamp": 0,
				}
	migrated["best_laps"] = migrated_best
	return migrated


static func _sanitize_tracks(value: Variant, warnings: Array[String]) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not value is Array:
		warnings.append("save.tracks_not_array")
		return output
	for raw_entry in value:
		if output.size() >= SaveLimitsType.MAX_SAVED_TRACKS:
			warnings.append("save.track_limit_applied")
			break
		if not raw_entry is Dictionary:
			warnings.append("save.track_entry_not_object")
			continue
		var definition_value: Variant = raw_entry.get("definition")
		if not definition_value is Dictionary:
			warnings.append("save.track_definition_missing")
			continue
		var definition := TrackDefinitionType.from_dictionary(definition_value)
		var raw_id := definition.track_id
		if raw_id.is_empty() or sanitize_identifier(raw_id, GameLimitsType.MAX_TRACK_ID_BYTES) != raw_id \
				or definition.content_hash.is_empty() or not definition.validate_schema().is_valid():
			warnings.append("save.track_definition_invalid")
			continue
		var metadata := sanitize_metadata(
			raw_entry.get("metadata", {}), definition.track_name, definition.updated_at_timestamp
		)
		output.append({
			"definition": definition.to_dictionary(true),
			"metadata": metadata,
		})
	return output


static func _sanitize_best_laps(value: Variant, warnings: Array[String]) -> Dictionary:
	var output: Dictionary = {}
	if not value is Dictionary:
		warnings.append("save.best_laps_not_object")
		return output
	var keys := PackedStringArray()
	for key_variant in value.keys():
		keys.append(str(key_variant))
	keys.sort()
	for raw_key in keys:
		if output.size() >= SaveLimitsType.MAX_BEST_LAPS:
			warnings.append("save.best_lap_limit_applied")
			break
		var track_id := sanitize_identifier(raw_key)
		var entry_value: Variant = value.get(raw_key)
		if track_id.is_empty() or not entry_value is Dictionary:
			warnings.append("save.best_lap_invalid")
			continue
		var entry: Dictionary = entry_value
		var time_ms := _safe_int(entry.get("time_ms"), 0)
		if time_ms <= 0 or time_ms > SaveLimitsType.MAX_RACE_TIME_MS:
			warnings.append("save.best_lap_invalid")
			continue
		output[track_id] = {
			"time_ms": time_ms,
			"vehicle_id": sanitize_identifier(entry.get("vehicle_id", ""), SaveLimitsType.MAX_VEHICLE_ID_BYTES),
			"achieved_at_timestamp": _bounded_timestamp(entry.get("achieved_at_timestamp")),
		}
	return output


static func _sanitize_results(value: Variant, warnings: Array[String]) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if not value is Array:
		warnings.append("save.results_not_array")
		return output
	var start := maxi(0, value.size() - SaveLimitsType.MAX_RACE_RESULTS)
	if start > 0:
		warnings.append("save.result_limit_applied")
	for index in range(start, value.size()):
		var raw: Variant = value[index]
		if not raw is Dictionary:
			warnings.append("save.result_invalid")
			continue
		var entry: Dictionary = raw
		var track_id := sanitize_identifier(entry.get("track_id", ""))
		var racer_count := clampi(_safe_int(entry.get("racer_count"), 1), 1, 12)
		var position := _safe_int(entry.get("position"), 0)
		var total_time_ms := _safe_int(entry.get("total_time_ms"), 0)
		if track_id.is_empty() or position < 1 or position > racer_count \
				or total_time_ms < 0 or total_time_ms > SaveLimitsType.MAX_RACE_TIME_MS:
			warnings.append("save.result_invalid")
			continue
		output.append({
			"track_id": track_id,
			"position": position,
			"racer_count": racer_count,
			"total_time_ms": total_time_ms,
			"finished": entry.get("finished", true) if typeof(entry.get("finished", true)) == TYPE_BOOL else true,
			"vehicle_id": sanitize_identifier(entry.get("vehicle_id", ""), SaveLimitsType.MAX_VEHICLE_ID_BYTES),
			"recorded_at_timestamp": _bounded_timestamp(entry.get("recorded_at_timestamp")),
		})
	return output


static func _sanitize_unlocks(value: Variant, warnings: Array[String]) -> Array[String]:
	var unique: Dictionary = {}
	if not value is Array:
		warnings.append("save.unlocks_not_array")
		return []
	for raw in value:
		var identifier := sanitize_identifier(raw)
		if not identifier.is_empty():
			unique[identifier] = true
	var keys := PackedStringArray()
	for key in unique.keys():
		keys.append(str(key))
	keys.sort()
	var output: Array[String] = []
	for key in keys:
		if output.size() >= SaveLimitsType.MAX_UNLOCKS:
			warnings.append("save.unlock_limit_applied")
			break
		output.append(key)
	return output


static func _sanitize_tags(value: Variant) -> Array[String]:
	var unique: Dictionary = {}
	if value is Array:
		for raw in value:
			var tag := _clean_text(str(raw), SaveLimitsType.MAX_TAG_LENGTH).to_lower()
			if not tag.is_empty():
				unique[tag] = true
	var keys := PackedStringArray()
	for key in unique.keys():
		keys.append(str(key))
	keys.sort()
	var output: Array[String] = []
	for key in keys:
		if output.size() >= SaveLimitsType.MAX_TRACK_TAGS:
			break
		output.append(key)
	return output


static func _safe_thumbnail_path(value: Variant) -> String:
	var path := str(value).strip_edges()
	if path.is_empty():
		return ""
	if not path.begins_with("user://") or path.contains("..") \
			or path.to_utf8_buffer().size() > SaveLimitsType.MAX_THUMBNAIL_PATH_BYTES:
		return ""
	return path


static func _clean_text(value: String, maximum_characters: int) -> String:
	var output := ""
	var previous_space := false
	for index in value.length():
		var code := value.unicode_at(index)
		if code < 32 or code == 127:
			continue
		var character := String.chr(code)
		var is_space := character == " " or character == "\t" or character == "\n" or character == "\r"
		if is_space:
			if output.is_empty() or previous_space:
				continue
			character = " "
		previous_space = is_space
		output += character
		if output.length() >= maximum_characters:
			break
	return output.strip_edges()


static func _bounded_timestamp(value: Variant) -> int:
	return clampi(_safe_int(value, 0), 0, SaveLimitsType.MAX_SAFE_JSON_INTEGER)


static func _safe_int(value: Variant, fallback: int = 0) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT:
		var parsed := float(value)
		if not is_nan(parsed) and not is_inf(parsed) and parsed == round(parsed):
			return int(parsed)
	return fallback
