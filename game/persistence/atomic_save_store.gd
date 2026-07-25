class_name AtomicSaveStore
extends RefCounted
## Crash-recoverable JSON envelope storage.
##
## A complete candidate is flushed and checksum-verified before the previous
## primary is copied to backup. Replacement uses a rollback rename, so startup
## can recover if the process stops between the two final renames.

const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const SaveLimitsType := preload("res://game/persistence/save_limits.gd")

const DEFAULT_SAVE_PATH := "user://raceglyph/local_save.json"

var _primary_path: String
var _backup_path: String
var _temp_path: String
var _rollback_path: String
var _corrupt_path: String


func _init(save_path: String = DEFAULT_SAVE_PATH) -> void:
	_primary_path = save_path if not save_path.is_empty() else DEFAULT_SAVE_PATH
	_backup_path = _primary_path + ".bak"
	_temp_path = _primary_path + ".tmp"
	_rollback_path = _primary_path + ".rollback"
	_corrupt_path = _primary_path + ".corrupt"


func write_payload(payload: Dictionary, revision: int, saved_at_timestamp: int) -> Dictionary:
	if revision < 0 or revision > SaveLimitsType.MAX_SAFE_JSON_INTEGER:
		return _failure("revision_invalid", "Save revision is outside the supported range.")
	if saved_at_timestamp < 0 or saved_at_timestamp > SaveLimitsType.MAX_SAFE_JSON_INTEGER:
		return _failure("timestamp_invalid", "Save timestamp is outside the supported range.")
	var envelope := {
		"envelope_schema_version": SaveLimitsType.ENVELOPE_SCHEMA_VERSION,
		"revision": revision,
		"saved_at_timestamp": saved_at_timestamp,
		"payload": payload,
		"payload_sha256": CanonicalJsonType.sha256(payload),
	}
	var encoded := CanonicalJsonType.stringify(envelope)
	if encoded.to_utf8_buffer().size() > SaveLimitsType.MAX_SAVE_BYTES:
		return _failure("save_too_large", "Local save exceeds the 4 MiB safety limit.")
	var directory_error := _ensure_parent_directory()
	if directory_error != OK:
		return _failure("directory_unavailable", "Could not create the local save directory.", directory_error)
	_recover_interrupted_write()
	var write_error := _write_text(_temp_path, encoded)
	if write_error != OK:
		return _failure("temporary_write_failed", "Could not write the temporary save.", write_error)
	var candidate := _decode_path(_temp_path)
	if not candidate.get("ok", false):
		_safe_remove(_temp_path)
		return _failure("temporary_verify_failed", "Temporary save failed verification.")

	var existing := _decode_path(_primary_path)
	if existing.get("ok", false):
		var backup_temp := _backup_path + ".tmp"
		var backup_error := _write_text(backup_temp, str(existing.get("raw", "")))
		if backup_error != OK:
			_safe_remove(_temp_path)
			return _failure("backup_write_failed", "Could not write the save backup.", backup_error)
		if not _decode_path(backup_temp).get("ok", false):
			_safe_remove(backup_temp)
			_safe_remove(_temp_path)
			return _failure("backup_verify_failed", "Save backup failed verification.")
		backup_error = _replace_file(backup_temp, _backup_path)
		if backup_error != OK:
			_safe_remove(_temp_path)
			return _failure("backup_replace_failed", "Could not install the save backup.", backup_error)
	elif existing.get("exists", false):
		_preserve_corrupt_primary()

	var replace_error := _replace_file(_temp_path, _primary_path)
	if replace_error != OK:
		return _failure("primary_replace_failed", "Could not install the new local save.", replace_error)
	return {
		"ok": true,
		"revision": revision,
		"path": _primary_path,
		"payload_sha256": envelope["payload_sha256"],
	}


func load_payload() -> Dictionary:
	_ensure_parent_directory()
	_recover_interrupted_write()
	var primary := _decode_path(_primary_path)
	if primary.get("ok", false):
		return _load_result(primary, "primary", false)

	var backup := _decode_path(_backup_path)
	if backup.get("ok", false):
		if primary.get("exists", false):
			_preserve_corrupt_primary()
		var repair_error := _write_text(_temp_path, str(backup.get("raw", "")))
		if repair_error == OK:
			repair_error = _replace_file(_temp_path, _primary_path)
		var recovered := _load_result(backup, "backup", true)
		if repair_error != OK:
			recovered["repair_error"] = repair_error
		return recovered

	if not primary.get("exists", false) and not backup.get("exists", false):
		return {
			"ok": true,
			"payload": {},
			"revision": 0,
			"saved_at_timestamp": 0,
			"source": "defaults",
			"recovered": false,
		}
	return _failure(
		"all_copies_invalid",
		"Both the primary local save and its backup are invalid."
	)


func delete_all_copies() -> Dictionary:
	var failed: Array[String] = []
	for path in [
		_primary_path, _backup_path, _temp_path, _rollback_path,
		_corrupt_path, _backup_path + ".tmp", _backup_path + ".rollback"
	]:
		if FileAccess.file_exists(path):
			var error := DirAccess.remove_absolute(_absolute(path))
			if error != OK:
				failed.append(path)
	return {
		"ok": failed.is_empty(),
		"failed_paths": failed,
	}


func primary_path() -> String:
	return _primary_path


func backup_path() -> String:
	return _backup_path


func corrupt_path() -> String:
	return _corrupt_path


func _decode_path(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "exists": false, "error_code": "missing"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "exists": true, "error_code": "open_failed"}
	if file.get_length() > SaveLimitsType.MAX_SAVE_BYTES:
		return {"ok": false, "exists": true, "error_code": "file_too_large"}
	var raw := file.get_as_text()
	return _decode_text(raw)


func _decode_text(raw: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(raw) != OK:
		return {"ok": false, "exists": true, "error_code": "invalid_json"}
	if not parser.data is Dictionary:
		return {"ok": false, "exists": true, "error_code": "invalid_root"}
	var envelope: Dictionary = parser.data
	var envelope_version := _safe_integer(envelope.get("envelope_schema_version"), -1)
	if envelope_version != SaveLimitsType.ENVELOPE_SCHEMA_VERSION:
		return {"ok": false, "exists": true, "error_code": "unsupported_envelope"}
	var revision := _safe_integer(envelope.get("revision"), -1)
	var saved_at := _safe_integer(envelope.get("saved_at_timestamp"), -1)
	if revision < 0 or revision > SaveLimitsType.MAX_SAFE_JSON_INTEGER \
			or saved_at < 0 or saved_at > SaveLimitsType.MAX_SAFE_JSON_INTEGER:
		return {"ok": false, "exists": true, "error_code": "invalid_authority_values"}
	var payload_value: Variant = envelope.get("payload")
	if not payload_value is Dictionary:
		return {"ok": false, "exists": true, "error_code": "invalid_payload"}
	var expected_hash: Variant = envelope.get("payload_sha256")
	if typeof(expected_hash) != TYPE_STRING or str(expected_hash).length() != 64:
		return {"ok": false, "exists": true, "error_code": "invalid_checksum"}
	var payload: Dictionary = payload_value
	if CanonicalJsonType.sha256(payload) != str(expected_hash):
		return {"ok": false, "exists": true, "error_code": "checksum_mismatch"}
	return {
		"ok": true,
		"exists": true,
		"payload": payload,
		"revision": revision,
		"saved_at_timestamp": saved_at,
		"payload_sha256": str(expected_hash),
		"raw": raw,
	}


func _recover_interrupted_write() -> void:
	var primary := _decode_path(_primary_path)
	if primary.get("ok", false):
		_safe_remove(_temp_path)
		_safe_remove(_rollback_path)
		return
	var candidate := _decode_path(_temp_path)
	if candidate.get("ok", false):
		if primary.get("exists", false):
			_preserve_corrupt_primary()
		_replace_file(_temp_path, _primary_path)
		_safe_remove(_rollback_path)
		return
	if not primary.get("exists", false) and FileAccess.file_exists(_rollback_path):
		DirAccess.rename_absolute(_absolute(_rollback_path), _absolute(_primary_path))
	_safe_remove(_temp_path)


func _preserve_corrupt_primary() -> void:
	if not FileAccess.file_exists(_primary_path):
		return
	_safe_remove(_corrupt_path)
	DirAccess.rename_absolute(_absolute(_primary_path), _absolute(_corrupt_path))


func _replace_file(source: String, target: String) -> Error:
	if not FileAccess.file_exists(source):
		return ERR_FILE_NOT_FOUND
	var rollback := target + ".rollback"
	_safe_remove(rollback)
	if FileAccess.file_exists(target):
		var move_old_error := DirAccess.rename_absolute(_absolute(target), _absolute(rollback))
		if move_old_error != OK:
			return move_old_error
	var move_new_error := DirAccess.rename_absolute(_absolute(source), _absolute(target))
	if move_new_error != OK:
		if FileAccess.file_exists(rollback):
			DirAccess.rename_absolute(_absolute(rollback), _absolute(target))
		return move_new_error
	_safe_remove(rollback)
	return OK


func _write_text(path: String, text: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.flush()
	var error := file.get_error()
	file.close()
	return error


func _ensure_parent_directory() -> Error:
	return DirAccess.make_dir_recursive_absolute(_absolute(_primary_path.get_base_dir()))


func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path)


func _safe_remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(_absolute(path))


func _load_result(decoded: Dictionary, source: String, recovered: bool) -> Dictionary:
	return {
		"ok": true,
		"payload": decoded["payload"],
		"revision": decoded["revision"],
		"saved_at_timestamp": decoded["saved_at_timestamp"],
		"payload_sha256": decoded["payload_sha256"],
		"source": source,
		"recovered": recovered,
	}


func _failure(code: String, message: String, os_error: int = OK) -> Dictionary:
	return {
		"ok": false,
		"error_code": code,
		"message": message,
		"os_error": os_error,
	}


func _safe_integer(value: Variant, fallback: int) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT:
		var parsed := float(value)
		if not is_nan(parsed) and not is_inf(parsed) and parsed == round(parsed):
			return int(parsed)
	return fallback
