class_name NetworkTrackManifest
extends RefCounted
## Canonical custom-track identity sent through the multiplayer ready gate.
## Generated geometry is never authoritative: every peer compiles locally and
## must report the same source hash, generator version, and compile fingerprint.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const NetworkLimitsType := preload("res://game/network/network_limits.gd")
const NetworkResultType := preload("res://game/network/network_result.gd")


static func build(definition: Variant, compiled_track: Variant) -> Dictionary:
	if definition == null or compiled_track == null:
		return {}
	return {
		"track_definition": definition.to_dictionary(true),
		"source_hash": definition.calculated_content_hash(),
		"generator_version": int(definition.generator_version),
		"compiled_fingerprint": str(compiled_track.compile_hash),
	}


static func validate(manifest: Variant) -> Dictionary:
	if typeof(manifest) != TYPE_DICTIONARY:
		return NetworkResultType.failure(&"track_manifest_malformed", "Track manifest must be an object.")
	var required := [
		"track_definition", "source_hash", "generator_version", "compiled_fingerprint"
	]
	for key in required:
		if not manifest.has(key):
			return NetworkResultType.failure(
				&"track_manifest_malformed", "Track manifest is missing a required field.", {"field": key}
			)
	if typeof(manifest["track_definition"]) != TYPE_DICTIONARY:
		return NetworkResultType.failure(&"track_definition_malformed", "Track definition must be an object.")
	var encoded_size := JSON.stringify(manifest["track_definition"]).to_utf8_buffer().size()
	if encoded_size > mini(GameLimitsType.MAX_TRACK_DEFINITION_BYTES, NetworkLimitsType.MAX_TRACK_DEFINITION_BYTES):
		return NetworkResultType.failure(
			&"track_definition_too_large",
			"Track definition exceeds the multiplayer payload limit.",
			{"actual_bytes": encoded_size, "maximum_bytes": NetworkLimitsType.MAX_TRACK_DEFINITION_BYTES}
		)
	var definition := TrackDefinitionType.from_dictionary(manifest["track_definition"])
	var schema_report = definition.validate_schema()
	if not schema_report.is_valid():
		return NetworkResultType.failure(
			&"track_definition_invalid",
			"Track definition failed schema validation.",
			{"report": schema_report.to_dictionary()}
		)
	var source_hash := str(manifest["source_hash"])
	var fingerprint := str(manifest["compiled_fingerprint"])
	if not is_sha256(source_hash) or not is_sha256(fingerprint):
		return NetworkResultType.failure(
			&"track_identity_malformed", "Track hashes must be lowercase SHA-256 text."
		)
	if source_hash != definition.calculated_content_hash():
		return NetworkResultType.failure(
			&"track_source_hash_mismatch", "Track source hash does not match its canonical definition."
		)
	var generator_version_value: Variant = manifest["generator_version"]
	if typeof(generator_version_value) != TYPE_INT or int(generator_version_value) <= 0:
		return NetworkResultType.failure(
			&"generator_version_invalid", "Generator version must be a positive integer."
		)
	if int(generator_version_value) != int(definition.generator_version):
		return NetworkResultType.failure(
			&"generator_version_mismatch", "Manifest and definition generator versions differ."
		)
	return NetworkResultType.success({
		"definition": definition,
		"source_hash": source_hash,
		"generator_version": int(generator_version_value),
		"compiled_fingerprint": fingerprint,
		"definition_bytes": encoded_size,
	})


static func identity(manifest: Dictionary) -> Dictionary:
	return {
		"source_hash": str(manifest.get("source_hash", "")),
		"generator_version": int(manifest.get("generator_version", 0)),
		"compiled_fingerprint": str(manifest.get("compiled_fingerprint", "")),
	}


static func is_sha256(value: String) -> bool:
	if value.length() != 64 or value != value.to_lower():
		return false
	const HEX := "0123456789abcdef"
	for index in value.length():
		if HEX.find(value[index]) < 0:
			return false
	return true
