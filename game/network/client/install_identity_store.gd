class_name InstallIdentityStore
extends RefCounted
## Anonymous per-install identity for Nakama device authentication. This never
## consults a hardware identifier and is deliberately stored outside the
## ordinary local profile/export surface.

const DEFAULT_PATH := "user://network/install_identity.v1"
const PREFIX := "rg_install_"
const RANDOM_BYTES := 16

var storage_path: String = DEFAULT_PATH


func _init(path_override: String = "") -> void:
	if not path_override.is_empty():
		storage_path = path_override


func load_or_create() -> Dictionary:
	var existing := _read_existing()
	if is_valid(str(existing.get("install_id", ""))):
		return {"ok": true, "install_id": str(existing["install_id"]), "created": false}
	var directory := storage_path.get_base_dir()
	if not directory.is_empty():
		var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
			return _failure("install_identity_directory_failed", "Could not prepare anonymous identity storage.")
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(RANDOM_BYTES)
	if random_bytes.size() != RANDOM_BYTES:
		return _failure("install_identity_random_failed", "Could not generate anonymous install identity.")
	var install_id := PREFIX + random_bytes.hex_encode()
	var temporary_path := storage_path + ".tmp"
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _failure("install_identity_write_failed", "Could not store anonymous install identity.")
	file.store_string(JSON.stringify({"version": 1, "install_id": install_id}))
	file.flush()
	file.close()
	var absolute_path := ProjectSettings.globalize_path(storage_path)
	var absolute_temporary := ProjectSettings.globalize_path(temporary_path)
	if FileAccess.file_exists(storage_path):
		DirAccess.remove_absolute(absolute_path)
	var rename_error := DirAccess.rename_absolute(absolute_temporary, absolute_path)
	if rename_error != OK:
		DirAccess.remove_absolute(absolute_temporary)
		return _failure("install_identity_commit_failed", "Could not commit anonymous install identity.")
	var readback := _read_existing()
	if str(readback.get("install_id", "")) != install_id:
		return _failure("install_identity_readback_failed", "Anonymous install identity did not verify after saving.")
	return {"ok": true, "install_id": install_id, "created": true}


func delete_identity() -> Dictionary:
	# Move the live identity out of its well-known path before deleting it. If a
	# later cleanup fails, restore that move when possible so callers get either
	# a complete deletion or an explicit, recoverable failure state.
	var quarantine_path := storage_path + ".delete"
	var temporary_path := storage_path + ".tmp"
	var failed: Array[String] = []
	if FileAccess.file_exists(quarantine_path):
		if DirAccess.remove_absolute(ProjectSettings.globalize_path(quarantine_path)) != OK:
			return _failure("install_identity_delete_failed", "Could not clear a previous anonymous identity deletion.", [quarantine_path])
	var had_identity := FileAccess.file_exists(storage_path)
	if had_identity:
		var staged := DirAccess.rename_absolute(
			ProjectSettings.globalize_path(storage_path),
			ProjectSettings.globalize_path(quarantine_path)
		)
		if staged != OK:
			return _failure("install_identity_delete_failed", "Could not stage anonymous identity deletion.", [storage_path])
	if FileAccess.file_exists(temporary_path) \
			and DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path)) != OK:
		failed.append(temporary_path)
	if FileAccess.file_exists(quarantine_path) \
			and DirAccess.remove_absolute(ProjectSettings.globalize_path(quarantine_path)) != OK:
		failed.append(quarantine_path)
	if not failed.is_empty():
		if had_identity and not FileAccess.file_exists(storage_path) and FileAccess.file_exists(quarantine_path):
			DirAccess.rename_absolute(
				ProjectSettings.globalize_path(quarantine_path),
				ProjectSettings.globalize_path(storage_path)
			)
		return _failure("install_identity_delete_failed", "Anonymous identity deletion did not complete.", failed)
	return {"ok": true, "deleted": had_identity}


func _read_existing() -> Dictionary:
	if not FileAccess.file_exists(storage_path):
		return {}
	var file := FileAccess.open(storage_path, FileAccess.READ)
	if file == null or file.get_length() > 512:
		return {}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data


static func is_valid(value: String) -> bool:
	if not value.begins_with(PREFIX) or value.length() != PREFIX.length() + RANDOM_BYTES * 2:
		return false
	const HEX := "0123456789abcdef"
	for index in range(PREFIX.length(), value.length()):
		if HEX.find(value[index]) < 0:
			return false
	return true


func _failure(code: String, message: String, failed_paths: Array[String] = []) -> Dictionary:
	var error := {"code": code, "message": message}
	if not failed_paths.is_empty():
		error["failed_paths"] = failed_paths.duplicate()
	return {"ok": false, "error": error}
