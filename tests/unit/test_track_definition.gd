extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")

const V1_FIXTURE := "res://tests/fixtures/tracks/stadium_v1.json"
const V0_FIXTURE := "res://tests/fixtures/tracks/legacy_v0.json"


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_v1_migration_round_trip_and_hash(test)
	_test_v0_migration(test)
	_test_strict_validation(test)
	return test.result("track_definition")


func _test_v1_migration_round_trip_and_hash(test: RefCounted) -> void:
	var definition := TrackDefinitionType.from_json(_read(V1_FIXTURE))
	test.assert_true(definition.validate_schema().is_valid(), "golden v1 fixture must migrate and validate")
	test.assert_equal(definition.schema_version, GameLimitsType.TRACK_SCHEMA_VERSION, "v1 fixture migrates to the current schema")
	test.assert_equal(definition.generator_version, GameLimitsType.TRACK_COMPILER_VERSION, "v1 fixture opts into current compiler authority")
	test.assert_equal(definition.road_surface, RoadSurfaceCatalogType.SMOOTH_ASPHALT, "v1 fixture preserves legacy clean-asphalt behavior")
	var canonical := definition.canonical_json(false)
	var reparsed := TrackDefinitionType.from_json(canonical)
	test.assert_equal(reparsed.canonical_json(false), canonical, "canonical definition must round-trip byte-for-byte")
	test.assert_equal(reparsed.calculated_content_hash(), definition.calculated_content_hash(), "content hash must survive round trip")
	test.assert_equal(
		definition.calculated_content_hash(),
		"cc842c24acac5ee671d96008d351ef0a283134bc5e8c9718f917553739acfe66",
		"migrated schema-v2 fixture SHA-256 remains a golden contract"
	)
	definition.refresh_content_hash()
	test.assert_true(definition.validate_schema().is_valid(), "refreshed stored hash must validate")


func _test_v0_migration(test: RefCounted) -> void:
	var migrated := TrackDefinitionType.from_json(_read(V0_FIXTURE))
	test.assert_equal(migrated.schema_version, GameLimitsType.TRACK_SCHEMA_VERSION, "legacy definition must migrate to the current schema")
	test.assert_equal(migrated.track_name, "Legacy Stadium", "legacy name must migrate")
	test.assert_equal(migrated.deterministic_seed, 424242, "legacy seed must migrate")
	test.assert_true(migrated.track_id.begins_with("migrated-"), "migration ID must be deterministic")
	test.assert_near(migrated.control_points[0].x, 0.35, 0.000001, "legacy pixel points must normalize against canvas")
	test.assert_equal(migrated.road_surface, RoadSurfaceCatalogType.SMOOTH_ASPHALT, "legacy migration defaults to smooth asphalt")
	test.assert_true(migrated.validate_schema().is_valid(), "migrated fixture must satisfy current validation")
	var migrated_again := TrackDefinitionType.from_dictionary(migrated.to_dictionary())
	test.assert_equal(migrated_again.canonical_json(true), migrated.canonical_json(true), "migration must be idempotent")


func _test_strict_validation(test: RefCounted) -> void:
	var definition := TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.control_points[0] = Vector2(1.1, 0.5)
	var report := definition.validate_schema()
	test.assert_false(report.is_valid(), "out-of-range normalized point must fail")
	test.assert_true(report.has_code(&"schema.point_out_of_bounds"), "point bounds issue code")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.road_surface = &"lava"
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.road_surface_invalid"), "unknown road surfaces fail deterministic schema validation")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.content_hash = "bad"
	test.assert_true(definition.validate_schema().has_code(&"schema.content_hash_mismatch"), "stale content hash must fail")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.control_points[0] = Vector2(NAN, 0.5)
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.point_non_finite"), "non-finite control points must fail")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.author_id = "x".repeat(40_000)
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.serialized_size_exceeded"), "canonical payloads above 32 KiB must fail")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.control_points.resize(257)
	for index in definition.control_points.size():
		definition.control_points[index] = Vector2(float(index % 16) / 16.0, float(index / 16) / 17.0)
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.point_count_out_of_bounds"), "definitions above 256 points must fail")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.target_length = 1600.0004
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.target_length_not_quantized"), "authority values off the fixed grid must fail")
	var malformed := TrackDefinitionType.from_json("{\"schema_version\":1,\"control_points\":\"not-an-array\"}")
	test.assert_true(malformed.validate_schema().has_code(&"schema.decode_error"), "malformed field types and missing fields must fail decoding")
	var unknown_payload: Dictionary = TrackDefinitionType.from_json(_read(V1_FIXTURE)).to_dictionary()
	unknown_payload["surprise_authority"] = true
	test.assert_true(TrackDefinitionType.from_dictionary(unknown_payload).validate_schema().has_code(&"schema.decode_error"), "unknown schema-v1 fields must fail decoding")
	var large_seed_definition := TrackDefinitionType.from_json(_read(V1_FIXTURE))
	large_seed_definition.deterministic_seed = 9_007_199_254_740_993
	large_seed_definition.content_hash = ""
	var large_seed_round_trip := TrackDefinitionType.from_json(
		large_seed_definition.canonical_json(true)
	)
	test.assert_equal(large_seed_round_trip.deterministic_seed, 9_007_199_254_740_993, "decimal-string seed wire format must preserve signed-64 values")
	var unsafe_numeric_seed := TrackDefinitionType.from_json(_read(V1_FIXTURE)).to_dictionary()
	unsafe_numeric_seed["deterministic_seed"] = 9_007_199_254_740_992
	test.assert_true(TrackDefinitionType.from_dictionary(unsafe_numeric_seed).validate_schema().has_code(&"schema.decode_error"), "legacy numeric seed above JSON-safe range must fail")
	var malformed_point := TrackDefinitionType.from_json(_read(V1_FIXTURE)).to_dictionary()
	malformed_point["control_points"] = [[[], 0], [0, 0], [1, 0], [0, 1]]
	malformed_point["content_hash"] = ""
	test.assert_true(TrackDefinitionType.from_dictionary(malformed_point).validate_schema().has_code(&"schema.decode_error"), "non-numeric nested point values must report without runtime casts")
	var malformed_bridge := TrackDefinitionType.from_json(_read(V1_FIXTURE)).to_dictionary()
	malformed_bridge["bridge_crossings"] = [{"crossing_id": "bad", "distance_a": [], "distance_b": 10, "overpass": "a"}]
	malformed_bridge["content_hash"] = ""
	test.assert_true(TrackDefinitionType.from_dictionary(malformed_bridge).validate_schema().has_code(&"schema.decode_error"), "malformed bridge values must report without runtime casts")
	var oversized_json := "{\"unknown\":\"" + "x".repeat(33_000) + "\"}"
	test.assert_true(TrackDefinitionType.from_json(oversized_json).validate_schema().has_code(&"schema.decode_error"), "incoming byte cap must run before JSON parsing/migration")
	definition = TrackDefinitionType.from_json(_read(V1_FIXTURE))
	definition.bridge_crossings.append(null)
	definition.content_hash = ""
	test.assert_true(definition.validate_schema().has_code(&"schema.bridge_null"), "null typed bridge entries must fail without interrupting validation")


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)
