class_name TrackDefinition
extends RefCounted
## Persisted, content-addressed v1 schema for a closed user-authored track.
## Control points are normalized to the canvas and quantized to 1e-6.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const ValidationReportType := preload("res://game/track/validation/validation_report.gd")
const MigratorType := preload("res://game/track/definition/track_definition_migrator.gd")
const BridgeCrossingType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

const DIRECTION_CLOCKWISE: StringName = &"clockwise"
const DIRECTION_COUNTER_CLOCKWISE: StringName = &"counter_clockwise"
const PIT_NONE: StringName = &"none"
const PIT_LEFT: StringName = &"left"
const PIT_RIGHT: StringName = &"right"

var schema_version: int = GameLimitsType.TRACK_SCHEMA_VERSION
var generator_version: int = GameLimitsType.TRACK_COMPILER_VERSION
var track_id: String = ""
var track_name: String = "Untitled Track"
var author_id: String = ""
var canvas_size: Vector2 = Vector2(1920.0, 1080.0)
var control_points: PackedVector2Array = PackedVector2Array()
var direction: StringName = DIRECTION_CLOCKWISE
var target_length: float = 1200.0
var track_width: float = 72.0
var theme: StringName = &"classic"
var road_surface: StringName = RoadSurfaceCatalogType.SMOOTH_ASPHALT
var pit_side: StringName = PIT_NONE
var decoration_density: float = 0.5
var deterministic_seed: int = 0
var bridge_crossings: Array[BridgeCrossingDefinition] = []
var start_finish_distance: float = 0.0
var content_hash: String = ""
var created_at_timestamp: int = 0
var updated_at_timestamp: int = 0
var _decode_errors: Array[Dictionary] = []


static func create(
		normalized_points: PackedVector2Array,
		size: Vector2,
		width: float,
		name: String = "Untitled Track",
		id: String = "",
		seed: int = 0
	) -> TrackDefinition:
	var definition := TrackDefinition.new()
	definition.track_name = name
	definition.canvas_size = QuantizationType.vector2(size)
	definition.track_width = QuantizationType.scalar(width)
	definition.control_points = QuantizationType.packed_vector2(
		normalized_points, GameLimitsType.NORMALIZED_QUANTUM
	)
	definition.deterministic_seed = seed
	definition.track_id = id
	if definition.track_id.is_empty():
		definition.track_id = definition.derived_track_id()
	definition.refresh_content_hash()
	return definition


static func from_dictionary(input: Dictionary) -> TrackDefinition:
	var raw_size := JSON.stringify(input).to_utf8_buffer().size()
	if raw_size > GameLimitsType.MAX_TRACK_DEFINITION_BYTES:
		var oversized := TrackDefinition.new()
		oversized._decode_errors.append({
			"path": "",
			"message": "Incoming definition exceeds the 32 KiB limit.",
		})
		return oversized
	var data := MigratorType.migrate_to_current(input)
	var definition := TrackDefinition.new()
	definition._decode_errors = _collect_decode_errors(data)
	definition.schema_version = _safe_int(data.get("schema_version"), 0)
	definition.generator_version = _safe_int(data.get("generator_version"), 0)
	definition.track_id = str(data.get("track_id", ""))
	definition.track_name = str(data.get("track_name", "Untitled Track"))
	definition.author_id = str(data.get("author_id", ""))
	definition.canvas_size = _variant_to_vector2(data.get("canvas_size", Vector2.ZERO))
	definition.control_points = _variant_to_points(data.get("control_points", []))
	definition.direction = StringName(str(data.get("direction", "clockwise")))
	definition.target_length = _safe_float(data.get("target_length"), 0.0)
	definition.track_width = _safe_float(data.get("track_width"), 0.0)
	definition.theme = StringName(str(data.get("theme", "")))
	definition.road_surface = StringName(str(data.get(
		"road_surface", RoadSurfaceCatalogType.SMOOTH_ASPHALT
	)))
	definition.pit_side = StringName(str(data.get("pit_side", "none")))
	definition.decoration_density = _safe_float(data.get("decoration_density"), 0.0)
	definition.deterministic_seed = _safe_int(data.get("deterministic_seed"), 0)
	definition.bridge_crossings = _variant_to_crossings(data.get("bridge_crossings", []))
	definition.start_finish_distance = _safe_float(data.get("start_finish_distance"), 0.0)
	definition.content_hash = str(data.get("content_hash", ""))
	definition.created_at_timestamp = _safe_int(data.get("created_at_timestamp"), 0)
	definition.updated_at_timestamp = _safe_int(data.get("updated_at_timestamp"), 0)
	return definition


static func from_json(json_text: String) -> TrackDefinition:
	if json_text.to_utf8_buffer().size() > GameLimitsType.MAX_TRACK_DEFINITION_BYTES:
		var oversized := TrackDefinition.new()
		oversized._decode_errors.append({
			"path": "",
			"message": "Incoming definition exceeds the 32 KiB limit.",
		})
		return oversized
	var parser := JSON.new()
	var parse_error := parser.parse(json_text)
	if parse_error != OK:
		var malformed := TrackDefinition.new()
		malformed._decode_errors.append({
			"path": "",
			"message": "Invalid JSON at line %d: %s" % [
				parser.get_error_line(), parser.get_error_message()
			],
		})
		return malformed
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		var wrong_root := TrackDefinition.new()
		wrong_root._decode_errors.append({
			"path": "",
			"message": "Track definition root must be an object.",
		})
		return wrong_root
	return from_dictionary(parsed)


func to_dictionary(include_content_hash: bool = true) -> Dictionary:
	var serialized_points: Array = []
	for point in control_points:
		serialized_points.append([point.x, point.y])
	var serialized_crossings: Array[Dictionary] = []
	for crossing in bridge_crossings:
		serialized_crossings.append({} if crossing == null else crossing.to_dictionary())
	var data := {
		"schema_version": schema_version,
		"generator_version": generator_version,
		"track_id": track_id,
		"track_name": track_name,
		"author_id": author_id,
		"canvas_size": [canvas_size.x, canvas_size.y],
		"control_points": serialized_points,
		"direction": str(direction),
		"target_length": target_length,
		"track_width": track_width,
		"theme": str(theme),
		"road_surface": str(road_surface),
		"pit_side": str(pit_side),
		"decoration_density": decoration_density,
		# Decimal text preserves the full signed-64-bit seed through JSON and JS.
		"deterministic_seed": str(deterministic_seed),
		"bridge_crossings": serialized_crossings,
		"start_finish_distance": start_finish_distance,
		"created_at_timestamp": created_at_timestamp,
		"updated_at_timestamp": updated_at_timestamp,
	}
	if include_content_hash:
		data["content_hash"] = content_hash
	return data


func canonical_json(include_content_hash: bool = false) -> String:
	return CanonicalJsonType.stringify(to_dictionary(include_content_hash))


func calculated_content_hash() -> String:
	return canonical_json(false).sha256_text()


func refresh_content_hash() -> String:
	content_hash = calculated_content_hash()
	return content_hash


func serialized_size_bytes() -> int:
	return canonical_json(true).to_utf8_buffer().size()


func derived_track_id() -> String:
	var id_source := to_dictionary(false)
	id_source["track_id"] = ""
	return "track-" + CanonicalJsonType.sha256(id_source).left(16)


func denormalized_control_points() -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(control_points.size())
	for index in control_points.size():
		output[index] = QuantizationType.vector2(Vector2(
			control_points[index].x * canvas_size.x,
			control_points[index].y * canvas_size.y
		))
	return output


func validate_schema() -> ValidationReport:
	var report := ValidationReportType.new()
	for decode_error in _decode_errors:
		report.add_error(
			&"schema.decode_error",
			str(decode_error.get("message", "Malformed schema value.")),
			str(decode_error.get("path", ""))
		)
	_validate_identity(report)
	_validate_canvas(report)
	_validate_track_values(report)
	_validate_points(report)
	_validate_crossings(report)
	_validate_hash_and_size(report)
	return report


func copy() -> TrackDefinition:
	return TrackDefinition.from_dictionary(to_dictionary(true))


func _validate_identity(report: ValidationReport) -> void:
	if schema_version != GameLimitsType.TRACK_SCHEMA_VERSION:
		report.add_error(&"schema.unsupported_version", "Unsupported track schema version.", "schema_version")
	if generator_version <= 0:
		report.add_error(&"schema.generator_version_invalid", "Generator version must be positive.", "generator_version")
	if track_id.to_utf8_buffer().size() > GameLimitsType.MAX_TRACK_ID_BYTES:
		report.add_error(&"schema.track_id_too_long", "Track ID is too long.", "track_id")
	if track_name.strip_edges().is_empty():
		report.add_error(&"schema.name_empty", "Track name cannot be empty.", "track_name")
	elif track_name.length() > GameLimitsType.MAX_DISPLAY_NAME_LENGTH:
		report.add_error(&"schema.name_too_long", "Track name is too long.", "track_name")
	if author_id.to_utf8_buffer().size() > GameLimitsType.MAX_AUTHOR_ID_BYTES:
		report.add_error(&"schema.author_id_too_long", "Author ID is too long.", "author_id")
	if str(theme).is_empty() or str(theme).to_utf8_buffer().size() > GameLimitsType.MAX_THEME_BYTES:
		report.add_error(&"schema.theme_invalid", "Theme identifier is invalid.", "theme")
	if str(road_surface).to_utf8_buffer().size() > GameLimitsType.MAX_ROAD_SURFACE_BYTES \
			or not RoadSurfaceCatalogType.is_supported(road_surface):
		report.add_error(
			&"schema.road_surface_invalid",
			"Road surface identifier is not supported.",
			"road_surface"
		)
	if direction != DIRECTION_CLOCKWISE and direction != DIRECTION_COUNTER_CLOCKWISE:
		report.add_error(&"schema.direction_invalid", "Direction must be clockwise or counter_clockwise.", "direction")
	if pit_side != PIT_NONE and pit_side != PIT_LEFT and pit_side != PIT_RIGHT:
		report.add_error(&"schema.pit_side_invalid", "Pit side must be none, left, or right.", "pit_side")
	if created_at_timestamp < 0 or updated_at_timestamp < created_at_timestamp \
			or created_at_timestamp > GameLimitsType.MAX_SAFE_JSON_INTEGER \
			or updated_at_timestamp > GameLimitsType.MAX_SAFE_JSON_INTEGER:
		report.add_error(&"schema.timestamps_invalid", "Creation/update timestamps are inconsistent.", "updated_at_timestamp")


func _validate_canvas(report: ValidationReport) -> void:
	if not QuantizationType.is_finite_vector2(canvas_size):
		report.add_error(&"schema.canvas_non_finite", "Canvas size must be finite.", "canvas_size")
		return
	if canvas_size.x < GameLimitsType.MIN_CANVAS_SIDE or canvas_size.y < GameLimitsType.MIN_CANVAS_SIDE \
			or canvas_size.x > GameLimitsType.MAX_CANVAS_SIDE or canvas_size.y > GameLimitsType.MAX_CANVAS_SIDE:
		report.add_error(&"schema.canvas_out_of_bounds", "Canvas dimensions are outside supported bounds.", "canvas_size")
	if canvas_size.x * canvas_size.y > GameLimitsType.MAX_CANVAS_AREA:
		report.add_error(&"schema.canvas_area_exceeded", "Canvas area is too large.", "canvas_size")
	if not _vector_on_grid(canvas_size, GameLimitsType.COORDINATE_QUANTUM):
		report.add_error(&"schema.canvas_not_quantized", "Canvas size must use the coordinate fixed grid.", "canvas_size")


func _validate_track_values(report: ValidationReport) -> void:
	if not QuantizationType.is_finite_scalar(target_length) \
			or target_length < GameLimitsType.MIN_TRACK_LENGTH \
			or target_length > GameLimitsType.MAX_TARGET_LENGTH:
		report.add_error(&"schema.target_length_invalid", "Target length is outside supported bounds.", "target_length")
	elif not _scalar_on_grid(target_length, GameLimitsType.COORDINATE_QUANTUM):
		report.add_error(&"schema.target_length_not_quantized", "Target length must use the coordinate fixed grid.", "target_length")
	if not QuantizationType.is_finite_scalar(track_width) \
			or track_width < GameLimitsType.MIN_TRACK_WIDTH \
			or track_width > GameLimitsType.MAX_TRACK_WIDTH:
		report.add_error(&"schema.width_out_of_bounds", "Track width is outside supported bounds.", "track_width")
	elif not _scalar_on_grid(track_width, GameLimitsType.COORDINATE_QUANTUM):
		report.add_error(&"schema.width_not_quantized", "Track width must use the coordinate fixed grid.", "track_width")
	if QuantizationType.is_finite_vector2(canvas_size) and track_width * 2.0 >= minf(canvas_size.x, canvas_size.y):
		report.add_error(&"schema.width_exceeds_canvas", "Track width is too large for the canvas.", "track_width")
	if not QuantizationType.is_finite_scalar(decoration_density) \
			or decoration_density < GameLimitsType.MIN_DECORATION_DENSITY \
			or decoration_density > GameLimitsType.MAX_DECORATION_DENSITY:
		report.add_error(&"schema.decoration_density_invalid", "Decoration density must be in [0, 1].", "decoration_density")
	elif not _scalar_on_grid(decoration_density, GameLimitsType.NORMALIZED_QUANTUM):
		report.add_error(&"schema.decoration_density_not_quantized", "Decoration density must use the normalized fixed grid.", "decoration_density")
	if not QuantizationType.is_finite_scalar(start_finish_distance) or start_finish_distance < 0.0 \
			or (QuantizationType.is_finite_scalar(target_length) and start_finish_distance >= target_length):
		report.add_error(&"schema.start_finish_distance_invalid", "Start/finish distance must lie on the target lap.", "start_finish_distance")
	elif not _scalar_on_grid(start_finish_distance, GameLimitsType.COORDINATE_QUANTUM):
		report.add_error(&"schema.start_finish_distance_not_quantized", "Start/finish distance must use the coordinate fixed grid.", "start_finish_distance")


func _validate_points(report: ValidationReport) -> void:
	if control_points.size() < GameLimitsType.MIN_CONTROL_POINTS or control_points.size() > GameLimitsType.MAX_CONTROL_POINTS:
		report.add_error(&"schema.point_count_out_of_bounds", "Control-point count is outside supported bounds.", "control_points")
	for index in control_points.size():
		var point := control_points[index]
		if not QuantizationType.is_finite_vector2(point):
			report.add_error(&"schema.point_non_finite", "Control point %d must be finite." % index, "control_points[%d]" % index)
		elif point.x < 0.0 or point.y < 0.0 or point.x > 1.0 or point.y > 1.0:
			report.add_error(&"schema.point_out_of_bounds", "Normalized control point %d lies outside [0, 1]." % index, "control_points[%d]" % index)
		elif not _vector_on_grid(point, GameLimitsType.NORMALIZED_QUANTUM):
			report.add_error(&"schema.point_not_quantized", "Control point %d is not on the normalized fixed grid." % index, "control_points[%d]" % index)


func _validate_crossings(report: ValidationReport) -> void:
	if bridge_crossings.size() > GameLimitsType.MAX_BRIDGE_CROSSINGS:
		report.add_error(&"schema.too_many_bridge_crossings", "Too many bridge crossing declarations.", "bridge_crossings")
	var seen_ids: Dictionary = {}
	for index in bridge_crossings.size():
		var crossing := bridge_crossings[index]
		var path := "bridge_crossings[%d]" % index
		if crossing == null:
			report.add_error(
				&"schema.bridge_null",
				"Bridge crossing declaration cannot be null.",
				path
			)
			continue
		if crossing.crossing_id.is_empty() or seen_ids.has(crossing.crossing_id):
			report.add_error(&"schema.bridge_id_invalid", "Bridge crossing IDs must be non-empty and unique.", path + ".crossing_id")
		seen_ids[crossing.crossing_id] = true
		if not QuantizationType.is_finite_scalar(crossing.distance_a) or not QuantizationType.is_finite_scalar(crossing.distance_b) \
				or crossing.distance_a < 0.0 or crossing.distance_b < 0.0 \
				or crossing.distance_a >= target_length or crossing.distance_b >= target_length:
			report.add_error(&"schema.bridge_distance_invalid", "Bridge crossing distances must lie on the target lap.", path)
		elif not _scalar_on_grid(crossing.distance_a, GameLimitsType.COORDINATE_QUANTUM) \
				or not _scalar_on_grid(crossing.distance_b, GameLimitsType.COORDINATE_QUANTUM):
			report.add_error(&"schema.bridge_distance_not_quantized", "Bridge distances must use the coordinate fixed grid.", path)
		if crossing.overpass != BridgeCrossingType.OVERPASS_A and crossing.overpass != BridgeCrossingType.OVERPASS_B:
			report.add_error(&"schema.bridge_overpass_invalid", "Bridge overpass must be a or b.", path + ".overpass")


func _validate_hash_and_size(report: ValidationReport) -> void:
	if not content_hash.is_empty() and content_hash != calculated_content_hash():
		report.add_error(&"schema.content_hash_mismatch", "Stored content hash does not match canonical content.", "content_hash")
	var actual_size := serialized_size_bytes()
	if actual_size > GameLimitsType.MAX_TRACK_DEFINITION_BYTES:
		report.add_error(&"schema.serialized_size_exceeded", "Track definition exceeds the 32 KiB limit.", "", {"actual_bytes": actual_size, "maximum_bytes": GameLimitsType.MAX_TRACK_DEFINITION_BYTES})


static func _variant_to_vector2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() >= 2:
		return Vector2(_safe_float(value[0]), _safe_float(value[1]))
	if value is Dictionary:
		return Vector2(_safe_float(value.get("x")), _safe_float(value.get("y")))
	return Vector2.ZERO


static func _variant_to_points(value: Variant) -> PackedVector2Array:
	var points := PackedVector2Array()
	if value is PackedVector2Array:
		return value
	if value is Array:
		for item in value:
			points.append(_variant_to_vector2(item))
	return points


static func _variant_to_crossings(value: Variant) -> Array[BridgeCrossingDefinition]:
	var crossings: Array[BridgeCrossingDefinition] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				crossings.append(BridgeCrossingType.from_dictionary(item))
	return crossings


static func _collect_decode_errors(data: Dictionary) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	var expected_keys := PackedStringArray([
		"schema_version", "generator_version", "track_id", "track_name", "author_id",
		"canvas_size", "control_points", "direction", "target_length", "track_width",
		"theme", "road_surface", "pit_side", "decoration_density", "deterministic_seed",
		"bridge_crossings", "start_finish_distance", "content_hash",
		"created_at_timestamp", "updated_at_timestamp",
	])
	for key in expected_keys:
		if not data.has(key):
			errors.append({"path": key, "message": "Required field is missing."})
	for key_variant in data.keys():
		var key := str(key_variant)
		if not expected_keys.has(key):
			errors.append({"path": key, "message": "Unknown schema-v2 field."})
	_expect_integral_number(data, "schema_version", errors)
	_expect_integral_number(data, "generator_version", errors)
	_expect_type(data, "track_id", [TYPE_STRING], errors)
	_expect_type(data, "track_name", [TYPE_STRING], errors)
	_expect_type(data, "author_id", [TYPE_STRING], errors)
	_expect_type(data, "direction", [TYPE_STRING], errors)
	_expect_type(data, "theme", [TYPE_STRING], errors)
	_expect_type(data, "road_surface", [TYPE_STRING], errors)
	_expect_type(data, "pit_side", [TYPE_STRING], errors)
	_expect_type(data, "content_hash", [TYPE_STRING], errors)
	_expect_seed(data, errors)
	_expect_integral_number(data, "created_at_timestamp", errors)
	_expect_integral_number(data, "updated_at_timestamp", errors)
	for numeric_field in [
		"target_length", "track_width", "decoration_density", "start_finish_distance"
	]:
		_expect_type(data, numeric_field, [TYPE_INT, TYPE_FLOAT], errors)
	_validate_vector_array_shape(data.get("canvas_size"), "canvas_size", false, errors)
	var points_value: Variant = data.get("control_points")
	if points_value is PackedVector2Array:
		pass
	elif points_value is Array:
		for index in points_value.size():
			_validate_vector_array_shape(
				points_value[index], "control_points[%d]" % index, true, errors
			)
	else:
		errors.append({"path": "control_points", "message": "Expected an array of coordinate pairs."})
	var crossings_value: Variant = data.get("bridge_crossings")
	if crossings_value is Array:
		for index in crossings_value.size():
			_validate_crossing_shape(crossings_value[index], index, errors)
	else:
		errors.append({"path": "bridge_crossings", "message": "Expected an array."})
	return errors


static func _expect_type(
		data: Dictionary,
		key: String,
		allowed_types: Array,
		errors: Array[Dictionary]
	) -> void:
	if data.has(key) and not allowed_types.has(typeof(data[key])):
		errors.append({"path": key, "message": "Field has the wrong JSON type."})


static func _expect_integral_number(
		data: Dictionary,
		key: String,
		errors: Array[Dictionary]
	) -> void:
	if not data.has(key):
		return
	var value: Variant = data[key]
	if not _is_number(value):
		errors.append({"path": key, "message": "Field must be an integer-valued JSON number."})
		return
	var numeric := float(value)
	if is_nan(numeric) or is_inf(numeric) or numeric != round(numeric):
		errors.append({"path": key, "message": "Field must be an integer-valued JSON number."})
	elif absf(numeric) > float(GameLimitsType.MAX_SAFE_JSON_INTEGER):
		errors.append({"path": key, "message": "Numeric field exceeds the JSON-safe integer range."})


static func _expect_seed(data: Dictionary, errors: Array[Dictionary]) -> void:
	if not data.has("deterministic_seed"):
		return
	var value: Variant = data["deterministic_seed"]
	if typeof(value) == TYPE_STRING:
		var seed_text := str(value)
		if not seed_text.is_valid_int() or str(seed_text.to_int()) != seed_text:
			errors.append({
				"path": "deterministic_seed",
				"message": "Seed must be a canonical signed decimal string.",
			})
	elif _is_number(value):
		var numeric := float(value)
		if is_nan(numeric) or is_inf(numeric) or numeric != round(numeric) \
				or absf(numeric) > float(GameLimitsType.MAX_SAFE_JSON_INTEGER):
			errors.append({
				"path": "deterministic_seed",
				"message": "Legacy numeric seeds must be JSON-safe integers.",
			})
	else:
		errors.append({
			"path": "deterministic_seed",
			"message": "Seed must be decimal text.",
		})


static func _validate_vector_array_shape(
		value: Variant,
		path: String,
		allow_vector: bool,
		errors: Array[Dictionary]
	) -> void:
	if allow_vector and (value is Vector2 or value is Vector2i):
		return
	if not value is Array or value.size() != 2:
		errors.append({"path": path, "message": "Expected exactly two numeric coordinates."})
		return
	if not _is_number(value[0]) or not _is_number(value[1]):
		errors.append({"path": path, "message": "Coordinates must be JSON numbers."})


static func _validate_crossing_shape(
		value: Variant,
		index: int,
		errors: Array[Dictionary]
	) -> void:
	var path := "bridge_crossings[%d]" % index
	if not value is Dictionary:
		errors.append({"path": path, "message": "Bridge declaration must be an object."})
		return
	var expected := PackedStringArray(["crossing_id", "distance_a", "distance_b", "overpass"])
	for key in expected:
		if not value.has(key):
			errors.append({"path": path + "." + key, "message": "Required bridge field is missing."})
	for key_variant in value.keys():
		var key := str(key_variant)
		if not expected.has(key):
			errors.append({"path": path + "." + key, "message": "Unknown bridge field."})
	if value.has("crossing_id") and typeof(value["crossing_id"]) != TYPE_STRING:
		errors.append({"path": path + ".crossing_id", "message": "Bridge ID must be a string."})
	if value.has("overpass") and typeof(value["overpass"]) != TYPE_STRING:
		errors.append({"path": path + ".overpass", "message": "Overpass branch must be a string."})
	for key in ["distance_a", "distance_b"]:
		if value.has(key) and not _is_number(value[key]):
			errors.append({"path": path + "." + key, "message": "Bridge distance must be numeric."})


static func _scalar_on_grid(value: float, quantum: float) -> bool:
	# Decimal JSON text round-trips through binary floating point with sub-ULP
	# noise. Keep schema validation strict while tolerating only that noise.
	return absf(value - QuantizationType.scalar(value, quantum)) <= quantum * 0.000001


static func _vector_on_grid(value: Vector2, quantum: float) -> bool:
	# Vector2/PackedVector2Array store float32 values. Re-quantizing through a
	# Vector2 applies the same representation before comparison.
	return value == QuantizationType.vector2(value, quantum)


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _safe_int(value: Variant, fallback: int = 0) -> int:
	if typeof(value) == TYPE_INT:
		return value
	if typeof(value) == TYPE_FLOAT and not is_nan(value) and not is_inf(value):
		return int(value)
	if typeof(value) == TYPE_STRING and str(value).is_valid_int():
		return str(value).to_int()
	return fallback


static func _safe_float(value: Variant, fallback: float = 0.0) -> float:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		return float(value)
	return fallback
