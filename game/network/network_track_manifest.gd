class_name NetworkTrackManifest
extends RefCounted
## Canonical custom-track identity sent through the multiplayer ready gate.
## Every peer still compiles locally and verifies the full compile fingerprint.
## A compact, hashed centerline is also included so the cloud match process can
## run authoritative vehicle physics without trusting any phone during a race.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const NetworkLimitsType := preload("res://game/network/network_limits.gd")
const NetworkResultType := preload("res://game/network/network_result.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const RaceTrackQueryType := preload("res://game/race/track_query.gd")

const AUTHORITY_PATH_SCALE: int = 1000
const AUTHORITY_PATH_MAX_SAMPLES: int = 512
const AUTHORITY_PATH_MAX_BYTES: int = 48_000


static func build(definition: Variant, compiled_track: Variant) -> Dictionary:
	if definition == null or compiled_track == null:
		return {}
	var authority_path := build_authority_path(compiled_track)
	if authority_path.is_empty():
		return {}
	return {
		"track_definition": definition.to_dictionary(true),
		"source_hash": definition.calculated_content_hash(),
		"generator_version": int(definition.generator_version),
		"compiled_fingerprint": str(compiled_track.compile_hash),
		"authority_path": authority_path,
	}


static func validate(manifest: Variant) -> Dictionary:
	if typeof(manifest) != TYPE_DICTIONARY:
		return NetworkResultType.failure(&"track_manifest_malformed", "Track manifest must be an object.")
	var required := [
		"track_definition", "source_hash", "generator_version", "compiled_fingerprint",
		"authority_path",
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
	var authority_validation := validate_authority_path(manifest["authority_path"])
	if not authority_validation["ok"]:
		return authority_validation
	return NetworkResultType.success({
		"definition": definition,
		"source_hash": source_hash,
		"generator_version": int(generator_version_value),
		"compiled_fingerprint": fingerprint,
		"definition_bytes": encoded_size,
		"authority_path": authority_validation["value"],
	})


static func build_authority_path(compiled_track: Variant) -> Dictionary:
	if compiled_track == null or not compiled_track is Object:
		return {}
	var centerline_value: Variant = compiled_track.get("centerline")
	if not centerline_value is PackedVector2Array or centerline_value.size() < 3:
		return {}
	var centerline: PackedVector2Array = centerline_value
	var track_query := RaceTrackQueryType.from_compiled(compiled_track)
	if not track_query.is_valid():
		return {}
	var source_distances: PackedFloat64Array = PackedFloat64Array()
	source_distances.resize(centerline.size())
	var source_distance := 0.0
	for source_index in centerline.size():
		source_distances[source_index] = source_distance
		source_distance += centerline[source_index].distance_to(
			centerline[(source_index + 1) % centerline.size()]
		)
	var sample_count := mini(centerline.size(), AUTHORITY_PATH_MAX_SAMPLES)
	var centerline_q: Array = []
	var elevation_q: Array = []
	for sample_index in sample_count:
		var source_index := int(floor(float(sample_index) * float(centerline.size()) / float(sample_count)))
		var fixed := QuantizationType.vector2_to_fixed(centerline[source_index], AUTHORITY_PATH_SCALE)
		centerline_q.append([fixed.x, fixed.y])
		var context := track_query.surface_context_at_distance(source_distances[source_index])
		elevation_q.append(QuantizationType.to_fixed(
			clampf(float(context.get("elevation_level", 0.0)), 0.0, 1.0),
			AUTHORITY_PATH_SCALE
		))
	var path := {
		"scale": AUTHORITY_PATH_SCALE,
		"centerline_q": centerline_q,
		"elevation_q": elevation_q,
		"track_width_q": QuantizationType.to_fixed(float(compiled_track.get("track_width")), AUTHORITY_PATH_SCALE),
		"total_length_q": QuantizationType.to_fixed(float(compiled_track.get("total_length")), AUTHORITY_PATH_SCALE),
		"start_finish_distance_q": QuantizationType.to_fixed(float(compiled_track.get("start_finish_distance")), AUTHORITY_PATH_SCALE),
		"road_surface": str(compiled_track.get("road_surface")),
		"deterministic_seed": str(compiled_track.get("deterministic_seed")),
	}
	path["path_hash"] = CanonicalJsonType.sha256(path)
	return path


static func validate_authority_path(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return NetworkResultType.failure(&"authority_path_malformed", "Cloud authority path must be an object.")
	var path: Dictionary = value
	for key in [
		"scale", "centerline_q", "elevation_q", "track_width_q", "total_length_q",
		"start_finish_distance_q", "road_surface", "deterministic_seed", "path_hash",
	]:
		if not path.has(key):
			return NetworkResultType.failure(
				&"authority_path_malformed", "Cloud authority path is missing a field.", {"field": key}
			)
	if typeof(path["scale"]) != TYPE_INT or int(path["scale"]) != AUTHORITY_PATH_SCALE \
			or typeof(path["centerline_q"]) != TYPE_ARRAY \
			or typeof(path["elevation_q"]) != TYPE_ARRAY \
			or path["centerline_q"].size() < 3 \
			or path["centerline_q"].size() > AUTHORITY_PATH_MAX_SAMPLES \
			or path["elevation_q"].size() != path["centerline_q"].size():
		return NetworkResultType.failure(&"authority_path_malformed", "Cloud authority path has invalid sampling.")
	for point in path["centerline_q"]:
		if not point is Array or point.size() != 2 \
				or typeof(point[0]) != TYPE_INT or typeof(point[1]) != TYPE_INT \
				or absi(int(point[0])) > NetworkLimitsType.WORLD_COORDINATE_Q_LIMIT \
				or absi(int(point[1])) > NetworkLimitsType.WORLD_COORDINATE_Q_LIMIT:
			return NetworkResultType.failure(&"authority_path_malformed", "Cloud authority path contains an invalid point.")
	for elevation in path["elevation_q"]:
		if typeof(elevation) != TYPE_INT or int(elevation) < 0 or int(elevation) > AUTHORITY_PATH_SCALE:
			return NetworkResultType.failure(&"authority_path_malformed", "Cloud authority path contains an invalid elevation.")
	for integer_key in ["track_width_q", "total_length_q", "start_finish_distance_q"]:
		if typeof(path[integer_key]) != TYPE_INT:
			return NetworkResultType.failure(
				&"authority_path_malformed", "Cloud authority path has an invalid integer field.", {"field": integer_key}
			)
	if int(path["track_width_q"]) < AUTHORITY_PATH_SCALE \
			or int(path["track_width_q"]) > 4096 * AUTHORITY_PATH_SCALE \
			or int(path["total_length_q"]) <= 0 \
			or int(path["start_finish_distance_q"]) < 0 \
			or int(path["start_finish_distance_q"]) >= int(path["total_length_q"]) \
			or typeof(path["road_surface"]) != TYPE_STRING \
			or typeof(path["deterministic_seed"]) != TYPE_STRING \
			or not is_sha256(str(path["path_hash"])):
		return NetworkResultType.failure(&"authority_path_malformed", "Cloud authority path fields are outside safe bounds.")
	var encoded_size := JSON.stringify(path).to_utf8_buffer().size()
	if encoded_size > AUTHORITY_PATH_MAX_BYTES:
		return NetworkResultType.failure(&"authority_path_too_large", "Cloud authority path exceeds its payload budget.")
	var hash_input := path.duplicate(true)
	hash_input.erase("path_hash")
	if CanonicalJsonType.sha256(hash_input) != str(path["path_hash"]):
		return NetworkResultType.failure(&"authority_path_hash_mismatch", "Cloud authority path hash is invalid.")
	return NetworkResultType.success(path.duplicate(true))


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
