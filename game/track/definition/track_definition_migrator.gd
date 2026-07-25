class_name TrackDefinitionMigrator
extends RefCounted
## Pure migrations into the current persisted TrackDefinition schema.

const GameLimitsType := preload("res://game/config/game_limits.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const QuantizationType := preload("res://game/core/quantization.gd")


static func migrate_to_current(input: Dictionary) -> Dictionary:
	var migrated := input.duplicate(true)
	var version := _safe_int(migrated.get("schema_version"), 0)
	while version < GameLimitsType.TRACK_SCHEMA_VERSION:
		match version:
			0:
				migrated = _migrate_v0_to_v1(migrated)
			1:
				migrated = _migrate_v1_to_v2(migrated)
			_:
				break
		var next_version := _safe_int(migrated.get("schema_version"), version)
		if next_version <= version:
			break
		version = next_version
	return migrated


static func supported_source_versions() -> PackedInt32Array:
	return PackedInt32Array([0, 1, 2])


static func _migrate_v0_to_v1(legacy: Dictionary) -> Dictionary:
	var base_for_id := legacy.duplicate(true)
	base_for_id.erase("track_id")
	var deterministic_id := "migrated-" + CanonicalJsonType.sha256(base_for_id).left(16)
	var canvas_value: Variant = legacy.get("canvas_size", legacy.get("size", [1920.0, 1080.0]))
	var legacy_points: Variant = legacy.get("control_points", legacy.get("points", []))
	var migrated := {
		"schema_version": 1,
		"generator_version": _safe_int(
			legacy.get("generator_version"), GameLimitsType.TRACK_COMPILER_VERSION
		),
		"track_id": str(legacy.get("track_id", deterministic_id)),
		"track_name": str(legacy.get("track_name", legacy.get("display_name", legacy.get("name", "Migrated Track")))),
		"author_id": str(legacy.get("author_id", "legacy")),
		"canvas_size": canvas_value,
		"control_points": _normalize_legacy_points(legacy_points, canvas_value),
		"direction": str(legacy.get("direction", "counter_clockwise" if _safe_bool(legacy.get("reverse_direction")) else "clockwise")),
		"target_length": _safe_float(legacy.get("target_length"), 1200.0),
		"track_width": _safe_float(legacy.get("track_width", legacy.get("width")), 72.0),
		"theme": str(legacy.get("theme", "classic")),
		"pit_side": str(legacy.get("pit_side", "none")),
		"decoration_density": _safe_float(legacy.get("decoration_density"), 0.5),
		"deterministic_seed": str(_safe_int(legacy.get("deterministic_seed", legacy.get("generation_seed", legacy.get("seed"))), 0)),
		"bridge_crossings": legacy.get("bridge_crossings", []),
		"start_finish_distance": _safe_float(legacy.get("start_finish_distance"), 0.0),
		# A v0 hash covered a different schema and cannot authenticate v1 bytes.
		"content_hash": "",
		"created_at_timestamp": _safe_int(legacy.get("created_at_timestamp"), 0),
		"updated_at_timestamp": _safe_int(legacy.get("updated_at_timestamp"), 0),
	}
	if _legacy_has_type_errors(legacy):
		migrated["_migration_error"] = "Legacy field has an invalid type or unsafe integer."
	return migrated


static func _migrate_v1_to_v2(legacy: Dictionary) -> Dictionary:
	var migrated := legacy.duplicate(true)
	migrated["schema_version"] = 2
	# Road-surface physics changed compiler authority. All schema-v1 tracks use
	# the old clean-asphalt behavior and are deterministically recompiled.
	migrated["generator_version"] = GameLimitsType.TRACK_COMPILER_VERSION
	migrated["road_surface"] = "smooth_asphalt"
	migrated["content_hash"] = ""
	return migrated


static func _normalize_legacy_points(points_value: Variant, canvas_value: Variant) -> Array:
	var output: Array = []
	if not points_value is Array:
		return output
	var canvas_x := 1920.0
	var canvas_y := 1080.0
	if canvas_value is Array and canvas_value.size() >= 2:
		canvas_x = maxf(_safe_float(canvas_value[0], canvas_x), 1.0)
		canvas_y = maxf(_safe_float(canvas_value[1], canvas_y), 1.0)
	elif canvas_value is Dictionary:
		canvas_x = maxf(_safe_float(canvas_value.get("x"), canvas_x), 1.0)
		canvas_y = maxf(_safe_float(canvas_value.get("y"), canvas_y), 1.0)
	var appears_normalized := true
	for point_value in points_value:
		var point := _legacy_point_to_array(point_value)
		if absf(_safe_float(point[0])) > 1.0 or absf(_safe_float(point[1])) > 1.0:
			appears_normalized = false
			break
	for point_value in points_value:
		var point := _legacy_point_to_array(point_value)
		if appears_normalized:
			output.append([
				QuantizationType.scalar(_safe_float(point[0]), GameLimitsType.NORMALIZED_QUANTUM),
				QuantizationType.scalar(_safe_float(point[1]), GameLimitsType.NORMALIZED_QUANTUM),
			])
		else:
			output.append([
				QuantizationType.scalar(_safe_float(point[0]) / canvas_x, GameLimitsType.NORMALIZED_QUANTUM),
				QuantizationType.scalar(_safe_float(point[1]) / canvas_y, GameLimitsType.NORMALIZED_QUANTUM),
			])
	return output


static func _legacy_point_to_array(value: Variant) -> Array:
	if value is Array and value.size() >= 2:
		return [_safe_float(value[0]), _safe_float(value[1])]
	if value is Dictionary:
		return [_safe_float(value.get("x")), _safe_float(value.get("y"))]
	if value is Vector2:
		return [value.x, value.y]
	return [0.0, 0.0]


static func _legacy_has_type_errors(legacy: Dictionary) -> bool:
	for key in ["generator_version", "created_at_timestamp", "updated_at_timestamp"]:
		if legacy.has(key) and not _is_safe_integer(legacy[key]):
			return true
	var seed_value: Variant = legacy.get("deterministic_seed", legacy.get("generation_seed", legacy.get("seed")))
	if seed_value != null and not _is_safe_integer(seed_value):
		return true
	for key in ["target_length", "track_width", "width", "decoration_density", "start_finish_distance"]:
		if legacy.has(key) and not _is_number(legacy[key]):
			return true
	for key in ["track_id", "track_name", "display_name", "name", "author_id", "direction", "theme", "pit_side"]:
		if legacy.has(key) and typeof(legacy[key]) != TYPE_STRING:
			return true
	if legacy.has("reverse_direction") and typeof(legacy["reverse_direction"]) != TYPE_BOOL:
		return true
	var canvas: Variant = legacy.get("canvas_size", legacy.get("size"))
	if canvas != null and not _is_coordinate_pair(canvas):
		return true
	var points: Variant = legacy.get("control_points", legacy.get("points"))
	if not points is Array:
		return true
	for point in points:
		if not _is_coordinate_pair(point):
			return true
	return false


static func _is_coordinate_pair(value: Variant) -> bool:
	if value is Vector2 or value is Vector2i:
		return true
	if value is Array:
		return value.size() == 2 and _is_number(value[0]) and _is_number(value[1])
	if value is Dictionary:
		return _is_number(value.get("x")) and _is_number(value.get("y"))
	return false


static func _is_safe_integer(value: Variant) -> bool:
	if not _is_number(value):
		return false
	var numeric := float(value)
	return not is_nan(numeric) and not is_inf(numeric) \
		and numeric == round(numeric) \
		and absf(numeric) <= float(GameLimitsType.MAX_SAFE_JSON_INTEGER)


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _safe_int(value: Variant, fallback: int = 0) -> int:
	if _is_number(value):
		var numeric := float(value)
		if not is_nan(numeric) and not is_inf(numeric):
			return int(numeric)
	return fallback


static func _safe_float(value: Variant, fallback: float = 0.0) -> float:
	return float(value) if _is_number(value) else fallback


static func _safe_bool(value: Variant, fallback: bool = false) -> bool:
	return value if typeof(value) == TYPE_BOOL else fallback
