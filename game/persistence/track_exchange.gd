class_name TrackExchange
extends RefCounted
## Portable, bounded TrackDefinition envelope with verified atomic file export.

const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")

const FORMAT := "raceglyph-track"
const FORMAT_VERSION := 1
const DEFAULT_EXPORT_DIRECTORY := "user://exports"


static func encode(definition: TrackDefinition) -> Dictionary:
	if definition == null or not definition.validate_schema().is_valid():
		return _failure("track_invalid", "Only a valid circuit can be exported.")
	var compile_result: TrackCompileResult = CompilerType.compile(definition)
	if not compile_result.succeeded():
		return _failure("track_compile_failed", "The circuit failed deterministic verification.")
	var envelope := {
		"format": FORMAT,
		"format_version": FORMAT_VERSION,
		"definition": definition.to_dictionary(true),
		"source_hash": compile_result.track.source_hash,
		"compiled_hash": compile_result.track.compile_hash,
	}
	return {"ok": true, "json": CanonicalJsonType.stringify(envelope), "envelope": envelope}


static func decode(text: String) -> Dictionary:
	if text.to_utf8_buffer().size() > 40_960:
		return _failure("export_too_large", "Shared circuit data exceeds the supported size.")
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return _failure("export_malformed", "Shared circuit data is not valid JSON.")
	var envelope := parsed as Dictionary
	if envelope.keys().size() != 5 or str(envelope.get("format", "")) != FORMAT \
			or int(envelope.get("format_version", 0)) != FORMAT_VERSION:
		return _failure("export_format_unsupported", "This is not a supported RaceGlyph circuit file.")
	if not envelope.get("definition") is Dictionary:
		return _failure("export_definition_missing", "Shared circuit data has no TrackDefinition.")
	var definition: TrackDefinition = TrackDefinitionType.from_dictionary(envelope["definition"])
	if not definition.validate_schema().is_valid():
		return _failure("export_definition_invalid", "Shared circuit data failed schema or hash validation.")
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	if not compiled.succeeded():
		return _failure("export_compile_failed", "Shared circuit geometry is not race-safe.")
	if str(envelope.get("source_hash", "")) != compiled.track.source_hash \
			or str(envelope.get("compiled_hash", "")) != compiled.track.compile_hash:
		return _failure("export_fingerprint_mismatch", "Shared circuit fingerprints do not match its contents.")
	return {
		"ok": true,
		"definition": definition,
		"source_hash": compiled.track.source_hash,
		"compiled_hash": compiled.track.compile_hash,
	}


static func export_to_file(definition: TrackDefinition, directory: String = DEFAULT_EXPORT_DIRECTORY) -> Dictionary:
	var encoded := encode(definition)
	if not encoded.get("ok", false):
		return encoded
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		return _failure("export_directory_failed", "The export folder could not be created.")
	var filename := _safe_filename(definition.track_name, definition.track_id) + ".raceglyph-track.json"
	var final_path := absolute_directory.path_join(filename)
	var temporary_path := final_path + ".tmp"
	var backup_path := final_path + ".bak"
	for stale_path in [temporary_path, backup_path]:
		if FileAccess.file_exists(stale_path):
			DirAccess.remove_absolute(stale_path)
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return _failure("export_write_failed", "The circuit export could not be written.")
	file.store_string(str(encoded["json"]))
	file.flush()
	file.close()
	if FileAccess.get_file_as_string(temporary_path) != str(encoded["json"]):
		DirAccess.remove_absolute(temporary_path)
		return _failure("export_verify_failed", "The circuit export failed its write verification.")
	var replaced_existing := FileAccess.file_exists(final_path)
	if replaced_existing and DirAccess.rename_absolute(final_path, backup_path) != OK:
		DirAccess.remove_absolute(temporary_path)
		return _failure("export_replace_failed", "The previous export could not be replaced safely.")
	if DirAccess.rename_absolute(temporary_path, final_path) != OK:
		if replaced_existing:
			DirAccess.rename_absolute(backup_path, final_path)
		return _failure("export_install_failed", "The verified circuit export could not be installed.")
	if FileAccess.get_file_as_string(final_path) != str(encoded["json"]):
		DirAccess.remove_absolute(final_path)
		if replaced_existing:
			DirAccess.rename_absolute(backup_path, final_path)
		return _failure("export_readback_failed", "The installed circuit export failed read-back.")
	if replaced_existing:
		DirAccess.remove_absolute(backup_path)
	return {
		"ok": true,
		"path": final_path,
		"filename": filename,
		"json": encoded["json"],
		"replaced": replaced_existing,
	}


static func _safe_filename(display_name: String, fallback: String) -> String:
	var output := ""
	var raw := display_name.strip_edges().to_lower()
	for index in raw.length():
		var code := raw.unicode_at(index)
		if code >= 97 and code <= 122 or code >= 48 and code <= 57:
			output += String.chr(code)
		elif (code == 32 or code == 45 or code == 95) and not output.ends_with("-"):
			output += "-"
	output = output.trim_suffix("-").left(48)
	if output.is_empty():
		output = fallback.replace(":", "-").replace(".", "-").left(48)
	return output if not output.is_empty() else "raceglyph-circuit"


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": code, "message": message}
