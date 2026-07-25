class_name ProfileExchange
extends RefCounted
## Human-portable export of non-secret device-local data. This deliberately
## excludes Nakama sessions/reconnect tokens, which never belong in profile JSON.

const CanonicalJsonType := preload("res://game/core/canonical_json.gd")

const FORMAT := "raceglyph-local-profile"
const FORMAT_VERSION := 1
const DEFAULT_EXPORT_DIRECTORY := "user://exports"
const DEFAULT_FILENAME := "raceglyph-local-data.json"
const MAX_EXPORT_BYTES := 2_000_000


static func encode(profile: Dictionary, exported_at_timestamp: int = 0) -> Dictionary:
	var export_profile: Dictionary = _without_private_runtime_fields(profile)
	var profile_json := CanonicalJsonType.stringify(export_profile)
	if profile_json.to_utf8_buffer().size() > MAX_EXPORT_BYTES:
		return _failure("profile_export_too_large", "Local data exceeds the portable export limit.")
	var envelope := {
		"format": FORMAT,
		"format_version": FORMAT_VERSION,
		"exported_at_timestamp": maxi(0, exported_at_timestamp),
		"profile_sha256": CanonicalJsonType.sha256(export_profile),
		"profile": export_profile,
	}
	return {"ok": true, "json": CanonicalJsonType.stringify(envelope), "envelope": envelope}


static func decode(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > MAX_EXPORT_BYTES:
		return _failure("profile_export_too_large", "Local data exceeds the portable export limit.")
	var parser := JSON.new()
	if parser.parse(text) != OK or not parser.data is Dictionary:
		return _failure("profile_export_malformed", "Local data export is not valid JSON.")
	var envelope: Dictionary = parser.data
	if envelope.keys().size() != 5 or str(envelope.get("format", "")) != FORMAT \
			or int(envelope.get("format_version", 0)) != FORMAT_VERSION:
		return _failure("profile_export_unsupported", "This is not a supported RaceGlyph local-data export.")
	if not envelope.get("profile") is Dictionary:
		return _failure("profile_export_missing", "Local data export has no profile payload.")
	var profile: Dictionary = envelope["profile"]
	if str(envelope.get("profile_sha256", "")) != CanonicalJsonType.sha256(profile):
		return _failure("profile_export_checksum_mismatch", "Local data export failed checksum verification.")
	return {"ok": true, "profile": profile.duplicate(true)}


static func export_to_file(
		profile: Dictionary,
		exported_at_timestamp: int,
		directory: String = DEFAULT_EXPORT_DIRECTORY
	) -> Dictionary:
	var encoded := encode(profile, exported_at_timestamp)
	if not encoded.get("ok", false):
		return encoded
	var absolute_directory := ProjectSettings.globalize_path(directory)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return _failure("profile_export_directory_failed", "The export folder could not be created.")
	var final_path := absolute_directory.path_join(DEFAULT_FILENAME)
	var temporary_path := final_path + ".tmp"
	var backup_path := final_path + ".bak"
	for stale_path in [temporary_path, backup_path]:
		if FileAccess.file_exists(stale_path):
			DirAccess.remove_absolute(stale_path)
	var serialized := str(encoded["json"])
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _failure("profile_export_write_failed", "Local data export could not be written.")
	file.store_string(serialized)
	file.flush()
	file.close()
	if FileAccess.get_file_as_string(temporary_path) != serialized:
		DirAccess.remove_absolute(temporary_path)
		return _failure("profile_export_verify_failed", "Local data export failed write verification.")
	var replaced := FileAccess.file_exists(final_path)
	if replaced and DirAccess.rename_absolute(final_path, backup_path) != OK:
		DirAccess.remove_absolute(temporary_path)
		return _failure("profile_export_replace_failed", "The previous local data export could not be replaced safely.")
	if DirAccess.rename_absolute(temporary_path, final_path) != OK:
		if replaced:
			DirAccess.rename_absolute(backup_path, final_path)
		return _failure("profile_export_install_failed", "The verified local data export could not be installed.")
	var installed := FileAccess.get_file_as_string(final_path)
	if installed != serialized or not decode(installed).get("ok", false):
		DirAccess.remove_absolute(final_path)
		if replaced:
			DirAccess.rename_absolute(backup_path, final_path)
		return _failure("profile_export_readback_failed", "The installed local data export failed read-back.")
	if replaced:
		DirAccess.remove_absolute(backup_path)
	return {
		"ok": true,
		"path": final_path,
		"filename": DEFAULT_FILENAME,
		"json": serialized,
		"replaced": replaced,
	}


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": code, "message": message}


static func _without_private_runtime_fields(value: Variant) -> Variant:
	if value is Dictionary:
		var clean: Dictionary = {}
		for key_value in value.keys():
			var key := str(key_value)
			if key.to_lower() in [
				"install_id", "device_id", "reconnect_token",
				"session_token", "auth_token", "access_token", "refresh_token",
			]:
				continue
			clean[key_value] = _without_private_runtime_fields(value[key_value])
		return clean
	if value is Array:
		var clean_array: Array = []
		for item in value:
			clean_array.append(_without_private_runtime_fields(item))
		return clean_array
	return value
