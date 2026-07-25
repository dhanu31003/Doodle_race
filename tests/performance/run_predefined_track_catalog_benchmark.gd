extends SceneTree
## Deterministic construction and mobile geometry budget for every first-party
## circuit. Host timings are deliberately loose regression ceilings; sample and
## triangle counts are the platform-neutral mobile gates.

const TestCaseType := preload("res://tests/support/test_case.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const QueryType := preload("res://game/race/track_query.gd")
const BuilderType := preload("res://game/presentation3d/track_mesh_builder_3d.gd")

const EXPECTED_TRACKS := 6
const MAX_AUTHORITY_SAMPLES := 768
const MOBILE_SAMPLE_STEP := 10.0
const MAX_MOBILE_SEGMENTS := 460
const MAX_MOBILE_TRIANGLES := 5520
const COLD_CATALOG_CEILING_MS := 5000.0
const COMPILE_AND_MESH_CEILING_MS := 7500.0
const SINGLE_TRACK_COMPILE_MESH_CEILING_MS := 2000.0
const WARM_LOOKUP_CEILING_MS := 1000.0
const WARM_LOOKUPS := 120


func _initialize() -> void:
	var test := TestCaseType.new()
	var cold_started := Time.get_ticks_usec()
	var items := CatalogType.all()
	var cold_ms := float(Time.get_ticks_usec() - cold_started) / 1000.0
	test.assert_equal(items.size(), EXPECTED_TRACKS, "benchmark covers every first-party circuit")
	test.assert_true(cold_ms <= COLD_CATALOG_CEILING_MS, "cold catalog generation stays inside the host regression ceiling")

	var maximum_samples := 0
	var maximum_segments := 0
	var maximum_triangles := 0
	var maximum_track_ms := 0.0
	var compile_started := Time.get_ticks_usec()
	var ids: PackedStringArray = []
	for item in items:
		var track_started := Time.get_ticks_usec()
		var definition: TrackDefinition = item["definition"]
		ids.append(definition.track_id)
		var result: TrackCompileResult = CompilerType.compile(definition)
		test.assert_true(result.succeeded(), "%s compiles inside the catalog benchmark" % definition.track_id)
		if not result.succeeded():
			continue
		maximum_samples = maxi(maximum_samples, result.track.centerline.size())
		test.assert_true(result.track.centerline.size() <= MAX_AUTHORITY_SAMPLES, "%s stays inside the authority sample budget" % definition.track_id)
		var query := QueryType.from_compiled(result.track)
		test.assert_true(query.is_valid(), "%s produces a valid race query in the benchmark" % definition.track_id)
		if not query.is_valid():
			continue
		var mesh_result := BuilderType.build(query, {"sample_step_authority": MOBILE_SAMPLE_STEP})
		test.assert_true(bool(mesh_result.get("ok", false)), "%s builds its mobile-density track mesh" % definition.track_id)
		if not bool(mesh_result.get("ok", false)):
			continue
		var stats: Dictionary = mesh_result["stats"]
		maximum_segments = maxi(maximum_segments, int(stats["segment_count"]))
		maximum_triangles = maxi(maximum_triangles, int(stats["triangles"]))
		test.assert_true(int(stats["segment_count"]) <= MAX_MOBILE_SEGMENTS, "%s stays inside the mobile longitudinal segment budget" % definition.track_id)
		test.assert_true(int(stats["triangles"]) <= MAX_MOBILE_TRIANGLES, "%s stays inside the complete track triangle budget" % definition.track_id)
		var track_ms := float(Time.get_ticks_usec() - track_started) / 1000.0
		maximum_track_ms = maxf(maximum_track_ms, track_ms)
		test.assert_true(track_ms <= SINGLE_TRACK_COMPILE_MESH_CEILING_MS, "%s compile plus mobile mesh stays inside the per-race load ceiling" % definition.track_id)
	var compile_mesh_ms := float(Time.get_ticks_usec() - compile_started) / 1000.0
	test.assert_true(compile_mesh_ms <= COMPILE_AND_MESH_CEILING_MS, "all release compiles and mobile meshes stay inside the host regression ceiling")

	var warm_started := Time.get_ticks_usec()
	for lookup_index in WARM_LOOKUPS:
		var item := CatalogType.by_id(ids[lookup_index % ids.size()])
		var definition: TrackDefinition = item["definition"]
		test.assert_equal(definition.track_id, ids[lookup_index % ids.size()], "warm catalog lookup returns the requested isolated definition")
	var warm_ms := float(Time.get_ticks_usec() - warm_started) / 1000.0
	test.assert_true(warm_ms <= WARM_LOOKUP_CEILING_MS, "canonical built-in cache keeps repeated lookup inside the host regression ceiling")

	print("BUILTIN_CATALOG_PERFORMANCE tracks=%d cold_ms=%.3f compile_mesh_ms=%.3f max_track_ms=%.3f warm_lookups=%d warm_ms=%.3f max_samples=%d max_segments=%d max_triangles=%d" % [
		items.size(), cold_ms, compile_mesh_ms, maximum_track_ms, WARM_LOOKUPS, warm_ms,
		maximum_samples, maximum_segments, maximum_triangles,
	])
	var result := test.result("predefined_track_catalog_performance")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)
