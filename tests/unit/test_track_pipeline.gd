extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const BridgeDefinitionType := preload("res://game/track/definition/bridge_crossing_definition.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const StrokeCleanerType := preload("res://game/track/generation/stroke_cleaner.gd")
const SplineType := preload("res://game/track/generation/closed_spline_resampler.gd")
const AnalyzerType := preload("res://game/track/generation/track_geometry_analyzer.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const ValidatorType := preload("res://game/track/validation/track_validator.gd")
const CompiledTrackType := preload("res://game/track/generation/compiled_track.gd")
const ValidationReportType := preload("res://game/track/validation/validation_report.gd")

const V1_FIXTURE := "res://tests/fixtures/tracks/stadium_v1.json"


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_cleanup_and_resampling(test)
	_test_deterministic_compile(test)
	_test_sharp_corner_recovery(test)
	_test_crossed_loop_bridge_recovery(test)
	_test_sharp_corner_property_sweep(test)
	_test_start_straight_float_tolerance(test)
	_test_crossing_detection(test)
	_test_parallel_surface_overlap(test)
	return test.result("track_compilation_pipeline")


func _test_cleanup_and_resampling(test: RefCounted) -> void:
	var noisy := PackedVector2Array([
		Vector2(0, 0), Vector2(0, 0), Vector2(100, 0), Vector2(101, 1),
		Vector2(100, 100), Vector2(0, 100), Vector2(0, 1), Vector2(0, 0),
	])
	var cleanup := StrokeCleanerType.clean_with_report(noisy, 1.5, 0.5, 4.0)
	test.assert_true(cleanup.duplicates_removed >= 2, "cleanup must remove duplicate samples and closing copy")
	test.assert_true(cleanup.is_closed, "four-sided stroke must become an implicit closed ring")
	var samples := SplineType.resample(cleanup.points, 5.0)
	test.assert_true(samples.size() >= GameLimitsType.MIN_RESAMPLED_POINTS, "arc resampler must emit enough points")
	var minimum_spacing := INF
	var maximum_spacing := 0.0
	for index in samples.size():
		var spacing := samples[index].distance_to(samples[(index + 1) % samples.size()])
		minimum_spacing = minf(minimum_spacing, spacing)
		maximum_spacing = maxf(maximum_spacing, spacing)
	test.assert_true(maximum_spacing - minimum_spacing < 0.25, "arc-length spacing must be nearly uniform")
	var analysis := AnalyzerType.analyze(samples)
	test.assert_equal(analysis.tangents.size(), samples.size(), "analysis tangent count")
	test.assert_equal(analysis.normals.size(), samples.size(), "analysis normal count")
	var bow_tie_analysis := AnalyzerType.analyze(PackedVector2Array([
		Vector2(0, 0), Vector2(100, 100), Vector2(100, 0), Vector2(0, 100),
	]))
	test.assert_equal(bow_tie_analysis.winding, &"ambiguous", "zero-area self-crossing geometry must not claim a false winding")


func _test_deterministic_compile(test: RefCounted) -> void:
	var definition := TrackDefinitionType.from_json(FileAccess.get_file_as_string(V1_FIXTURE))
	var first := CompilerType.compile(definition)
	var second := CompilerType.compile(definition)
	test.assert_true(first.track != null, "fixture must produce previewable compiled output")
	if first.track == null or second.track == null:
		return
	test.assert_equal(first.track.compile_hash, second.track.compile_hash, "identical definitions must compile byte-identically")
	test.assert_equal(first.track.compile_hash, "04f93604a6ab62cedf75ab18db2c8626b7ad623eb0c5a6d3ec09aa12594f1258", "compiled fixture hash must remain a golden generator-v2 contract")
	test.assert_equal(first.track.centerline, second.track.centerline, "deterministic centerline")
	test.assert_near(first.track.total_length, definition.target_length, 10.0, "compiled target length")
	test.assert_equal(first.track.direction, definition.direction, "compiler must enforce requested winding")
	test.assert_equal(AnalyzerType.analyze(first.track.centerline).winding, definition.direction, "actual centerline winding must match requested direction")
	test.assert_equal(first.track.left_edge.size(), first.track.centerline.size(), "left edge sample count")
	test.assert_equal(first.track.right_edge.size(), first.track.centerline.size(), "right edge sample count")
	test.assert_equal(first.track.deterministic_seed, definition.deterministic_seed, "compiled output must carry its deterministic seed")
	test.assert_true(first.report.is_valid(), "golden stadium must pass geometry validation: %s" % str(first.report.to_dictionary()))
	definition = TrackDefinitionType.from_json(FileAccess.get_file_as_string(V1_FIXTURE))
	definition.generator_version = 99
	definition.content_hash = ""
	var unsupported := CompilerType.compile(definition)
	test.assert_true(unsupported.track == null, "unsupported generator versions must not compile")
	test.assert_true(unsupported.report.has_code(&"compile.unsupported_generator_version"), "unsupported generator error code")
	definition = TrackDefinitionType.from_json(FileAccess.get_file_as_string(V1_FIXTURE))
	var malformed_compiled := first.track
	var saved_tangents := malformed_compiled.tangents
	malformed_compiled.tangents = PackedVector2Array()
	test.assert_true(ValidatorType.validate_compiled(definition, malformed_compiled).has_code(&"geometry.parallel_array_size_mismatch"), "malformed compiled parallel arrays must report instead of faulting")
	malformed_compiled.tangents = saved_tangents


func _test_sharp_corner_recovery(test: RefCounted) -> void:
	var cases := {
		"angular rectangle": PackedVector2Array([
			Vector2(0.50, 0.18), Vector2(0.86, 0.18), Vector2(0.86, 0.82),
			Vector2(0.14, 0.82), Vector2(0.14, 0.18),
		]),
		"narrow angular loop": PackedVector2Array([
			Vector2(0.50, 0.39), Vector2(0.90, 0.39), Vector2(0.90, 0.61),
			Vector2(0.10, 0.61), Vector2(0.10, 0.39),
		]),
		"screenshot hairpin": PackedVector2Array([
			Vector2(0.50, 0.22), Vector2(0.78, 0.22), Vector2(0.86, 0.28),
			Vector2(0.87, 0.68), Vector2(0.81, 0.77), Vector2(0.57, 0.77),
			Vector2(0.55, 0.62), Vector2(0.49, 0.53), Vector2(0.43, 0.62),
			Vector2(0.24, 0.63), Vector2(0.14, 0.56), Vector2(0.11, 0.38),
			Vector2(0.16, 0.25),
		]),
		"acute cusp": PackedVector2Array([
			Vector2(0.50, 0.17), Vector2(0.86, 0.17), Vector2(0.86, 0.82),
			Vector2(0.61, 0.82), Vector2(0.54, 0.52), Vector2(0.46, 0.78),
			Vector2(0.15, 0.82), Vector2(0.13, 0.18),
		]),
		"tiny-radius notch": PackedVector2Array([
			Vector2(0.50, 0.20), Vector2(0.87, 0.20), Vector2(0.87, 0.80),
			Vector2(0.58, 0.80), Vector2(0.55, 0.70), Vector2(0.52, 0.80),
			Vector2(0.13, 0.80), Vector2(0.13, 0.20),
		]),
		"repeated samples": PackedVector2Array([
			Vector2(0.50, 0.19), Vector2(0.70, 0.19), Vector2(0.700001, 0.190001),
			Vector2(0.86, 0.19), Vector2(0.86, 0.19), Vector2(0.86, 0.81),
			Vector2(0.50, 0.81), Vector2(0.14, 0.81), Vector2(0.14, 0.19),
			Vector2(0.50, 0.19),
		]),
		"tangled studio rosette": _tangled_studio_rosette(),
	}
	for case_name in cases:
		var source_definition := _sharp_definition(cases[case_name], "Case %s" % case_name)
		if case_name == "tangled studio rosette":
			source_definition.canvas_size = Vector2(1280.0, 720.0)
			source_definition.target_length = 3000.0
			source_definition.refresh_content_hash()
		var definition := source_definition.copy()
		var first := _compile_with_safe_grid(definition)
		var second := _compile_with_safe_grid(source_definition.copy())
		test.assert_true(first.track != null, "%s must produce compiled geometry: %s" % [case_name, str(first.report.to_dictionary())])
		if first.track == null or second.track == null:
			continue
		var required_radius := maxf(
			GameLimitsType.MIN_TURN_RADIUS,
			definition.track_width * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
		)
		var minimum_radius := _minimum_finite_radius(first.track.radii)
		test.assert_true(
			minimum_radius >= required_radius,
			"%s final minimum radius %.3f must meet %.3f" % [case_name, minimum_radius, required_radius]
		)
		test.assert_false(first.report.has_code(&"geometry.turn_radius_too_small"), "%s must never return the redraw radius error" % case_name)
		if case_name in [
			"narrow angular loop", "screenshot hairpin", "acute cusp",
			"tiny-radius notch", "tangled studio rosette",
		]:
			test.assert_true(first.report.has_code(&"geometry.turns_auto_smoothed"), "%s must report a non-error automatic rounding note" % case_name)
		if case_name == "tangled studio rosette":
			test.assert_equal(
				_auto_smoothing_detail(first, "fallback_method"),
				"harmonic_projection",
				"the tangled Studio loop exercises the deterministic safe fallback"
			)
		test.assert_false(first.report.has_code(&"geometry.road_surface_overlap"), "%s automatic rounding must not leave overlapping road" % case_name)
		test.assert_true(ValidatorType.find_crossings(first.track).is_empty(), "%s automatic rounding must not introduce self-crossings" % case_name)
		test.assert_true(first.report.is_valid(), "%s recovered circuit must be buildable: %s" % [case_name, str(first.report.to_dictionary())])
		test.assert_equal(first.track.compile_hash, second.track.compile_hash, "%s recovery must be deterministic" % case_name)
		test.assert_equal(first.track.centerline, second.track.centerline, "%s recovered samples must be byte-identical" % case_name)
	var impossible := TrackDefinitionType.create(
		PackedVector2Array([
			Vector2(0.5, 0.1), Vector2(0.9, 0.1), Vector2(0.9, 0.9),
			Vector2(0.1, 0.9), Vector2(0.1, 0.1),
		]),
		Vector2(256.0, 256.0),
		100.0,
		"Physically Impossible Radius Envelope"
	)
	impossible.target_length = 500.0
	impossible.refresh_content_hash()
	test.assert_true(impossible.validate_schema().is_valid(), "impossible-radius fixture remains schema-valid")
	var failed_recovery := CompilerType.compile(impossible)
	test.assert_true(failed_recovery.track == null, "exhausted/physically impossible recovery never returns the original unsafe centerline")
	test.assert_true(failed_recovery.report.has_code(&"compile.corner_rounding_failed"), "physical recovery failure has an explicit stable compiler error")
	test.assert_false(failed_recovery.report.has_code(&"geometry.turn_radius_too_small"), "physical recovery failure never falls through to the old redraw validator")


func _tangled_studio_rosette() -> PackedVector2Array:
	# Dense alternating lobes model the sort of unusual one-stroke circuit a
	# player draws on a phone: finite and non-crossing, but far beyond a simple
	# oval and intentionally hostile to sharp-corner recovery.
	var points := PackedVector2Array()
	const VERTEX_COUNT := 24
	for index in VERTEX_COUNT:
		var angle := -PI * 0.5 + TAU * float(index) / float(VERTEX_COUNT)
		var radius := 0.37 if index % 2 == 0 else 0.17
		if index % 6 == 1:
			radius += 0.035
		elif index % 6 == 3:
			radius -= 0.025
		points.append(Vector2(
			0.5 + cos(angle) * radius,
			0.5 + sin(angle) * radius * 0.72
		))
	points.append(points[0])
	return points


func _test_crossed_loop_bridge_recovery(test: RefCounted) -> void:
	# The first compile must retain clean point intersections so Track Studio can
	# discover them before the player explicitly publishes bridge declarations.
	var points := PackedVector2Array([
		Vector2(0.14, 0.20), Vector2(0.35, 0.17), Vector2(0.78, 0.72),
		Vector2(0.88, 0.65), Vector2(0.82, 0.45), Vector2(0.75, 0.25),
		Vector2(0.62, 0.18), Vector2(0.24, 0.75), Vector2(0.12, 0.66),
	])
	var definition := TrackDefinitionType.create(
		points, Vector2(1280.0, 720.0), 36.0, "Dense Bridge Preview"
	)
	definition.target_length = 2600.0
	definition.refresh_content_hash()
	var preview := CompilerType.compile(definition)
	if preview.track != null \
			and preview.report.has_code(&"geometry.start_straight_too_short"):
		definition.start_finish_distance = preview.track.suggested_start_finish_distance
		definition.refresh_content_hash()
		preview = CompilerType.compile(definition)
	test.assert_true(preview.track != null, "dense crossed loop publishes finite preview geometry before bridges are declared")
	test.assert_false(preview.report.has_code(&"compile.corner_rounding_failed"), "bridge preview never collapses into a corner-recovery failure")
	if preview.track == null:
		return
	var crossings := ValidatorType.find_crossings(preview.track)
	test.assert_true(not crossings.is_empty(), "dense crossed loop retains discoverable point intersections")
	test.assert_true(preview.report.has_code(&"geometry.undeclared_crossing"), "undeclared bridge preview fails closed with the explicit crossing code")
	for index in crossings.size():
		var crossing: Dictionary = crossings[index]
		definition.bridge_crossings.append(BridgeDefinitionType.new(
			"recovered-bridge-%02d" % (index + 1),
			QuantizationType.scalar(float(crossing["distance_a"])),
			QuantizationType.scalar(float(crossing["distance_b"])),
			BridgeDefinitionType.OVERPASS_A if index % 2 == 0 \
				else BridgeDefinitionType.OVERPASS_B
		))
	definition.refresh_content_hash()
	var declared := CompilerType.compile(definition)
	var repeated := CompilerType.compile(definition.copy())
	test.assert_true(declared.succeeded(), "explicit bridge declarations make the recovered crossed loop race-ready: %s" % str(declared.report.to_dictionary()))
	test.assert_false(declared.report.has_code(&"geometry.road_surface_overlap"), "declared bridge ramp windows resolve only crossing-local surface proximity")
	if declared.track != null and repeated.track != null:
		test.assert_equal(declared.track.compile_hash, repeated.track.compile_hash, "crossed-loop bridge recovery is byte-deterministic")


func _sharp_definition(points: PackedVector2Array, name: String) -> TrackDefinition:
	var definition := TrackDefinitionType.create(points, Vector2(1280.0, 720.0), 36.0, name)
	definition.target_length = 1400.0
	definition.direction = TrackDefinitionType.DIRECTION_CLOCKWISE
	definition.refresh_content_hash()
	return definition


func _test_sharp_corner_property_sweep(test: RefCounted) -> void:
	# A deterministic radial-polygon corpus spans coarse angular circuits,
	# alternating tiny-radius teeth, varied widths/lengths, and near-duplicate
	# samples. Every source polygon is finite, central, closed and non-crossing.
	for seed in 24:
		var vertex_count := 6 + (seed % 7) * 2
		var points := PackedVector2Array()
		for index in vertex_count:
			var angle := -PI * 0.5 + TAU * float(index) / float(vertex_count)
			var tooth := 0.045 if index % 2 == 0 else -0.045
			var harmonic := sin(angle * float(3 + seed % 4) + float(seed) * 0.37) * 0.025
			var radius := 0.285 + tooth + harmonic
			points.append(Vector2(
				0.5 + cos(angle) * radius,
				0.5 + sin(angle) * radius * 0.72
			))
		if seed % 3 == 0:
			points.insert(2, points[1].lerp(points[2], 0.0002))
		points.append(points[0])
		var definition := TrackDefinitionType.create(
			points,
			Vector2(1280.0, 720.0),
			float([30.0, 36.0, 44.0][seed % 3]),
			"Corner Sweep %02d" % seed
		)
		definition.target_length = float(1050 + seed * 19)
		definition.direction = TrackDefinitionType.DIRECTION_CLOCKWISE
		definition.refresh_content_hash()
		var first := CompilerType.compile(definition)
		var second := CompilerType.compile(definition.copy())
		test.assert_true(first.track != null, "sweep %02d must compile instead of falling back from rounding" % seed)
		test.assert_false(first.report.has_code(&"compile.corner_rounding_failed"), "sweep %02d must not exhaust corner recovery" % seed)
		test.assert_false(first.report.has_code(&"geometry.turn_radius_too_small"), "sweep %02d must not expose the redraw radius error" % seed)
		if first.track == null or second.track == null:
			continue
		var required := maxf(
			GameLimitsType.MIN_TURN_RADIUS,
			definition.track_width * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
		)
		test.assert_true(_minimum_finite_radius(first.track.radii) >= required, "sweep %02d output meets the measured radius envelope" % seed)
		test.assert_true(ValidatorType.find_crossings(first.track).is_empty(), "sweep %02d remains non-crossing" % seed)
		test.assert_false(first.report.has_code(&"geometry.road_surface_overlap"), "sweep %02d keeps disjoint road surfaces clear" % seed)
		test.assert_false(first.report.has_code(&"geometry.track_out_of_bounds"), "sweep %02d remains inside the safe canvas inset" % seed)
		test.assert_equal(first.track.centerline, second.track.centerline, "sweep %02d recovery is byte-deterministic" % seed)


func _compile_with_safe_grid(definition: TrackDefinition) -> TrackCompileResult:
	var result := CompilerType.compile(definition)
	if result.track != null and result.report.has_code(&"geometry.start_straight_too_short"):
		definition.start_finish_distance = result.track.suggested_start_finish_distance
		definition.refresh_content_hash()
		result = CompilerType.compile(definition)
	return result


func _minimum_finite_radius(radii: PackedFloat64Array) -> float:
	var minimum := INF
	for radius in radii:
		if not is_inf(radius):
			minimum = minf(minimum, radius)
	return minimum


func _auto_smoothing_detail(compiled: TrackCompileResult, key: String) -> Variant:
	for issue in compiled.report.issues:
		if issue.code == &"geometry.turns_auto_smoothed":
			return issue.details.get(key)
	return null


func _test_start_straight_float_tolerance(test: RefCounted) -> void:
	var definition := TrackDefinitionType.new()
	definition.pit_side = TrackDefinitionType.PIT_NONE
	var compiled := CompiledTrackType.new()
	compiled.sample_spacing = 6.0
	compiled.centerline = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(48.0, 0.0),
		Vector2(95.999906, 0.0), Vector2(95.999906, 10.0),
	])
	compiled.tangents = PackedVector2Array([
		Vector2.RIGHT, Vector2.RIGHT, Vector2.DOWN, Vector2.DOWN,
	])
	var report := ValidationReportType.new()
	ValidatorType._validate_start_and_pit(definition, compiled, report)
	test.assert_false(report.has_code(&"geometry.start_straight_too_short"), "95.999906m start straight passes the deterministic float tolerance")
	compiled.centerline[2].x = 95.98
	compiled.centerline[3].x = 95.98
	report = ValidationReportType.new()
	ValidatorType._validate_start_and_pit(definition, compiled, report)
	test.assert_true(report.has_code(&"geometry.start_straight_too_short"), "materially short start straight remains invalid")


func _test_crossing_detection(test: RefCounted) -> void:
	var definition := TrackDefinitionType.from_json(FileAccess.get_file_as_string(V1_FIXTURE))
	definition.control_points = PackedVector2Array([
		Vector2(0.2, 0.2), Vector2(0.8, 0.8), Vector2(0.8, 0.2), Vector2(0.2, 0.8)
	])
	definition.track_width = 20.0
	definition.target_length = 1200.0
	definition.content_hash = ""
	var compiled_result := CompilerType.compile(definition, 8.0)
	test.assert_true(compiled_result.track != null, "crossing shape must still compile for preview")
	if compiled_result.track != null:
		var crossings := ValidatorType.find_crossings(compiled_result.track)
		test.assert_true(crossings.size() >= 1, "bow-tie geometry must expose a crossing")
		test.assert_true(compiled_result.report.has_code(&"geometry.undeclared_crossing"), "undeclared crossing must be a stable validation error")


func _test_parallel_surface_overlap(test: RefCounted) -> void:
	var compiled := CompiledTrackType.new()
	compiled.track_width = 36.0
	compiled.sample_spacing = 20.0
	compiled.centerline = PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(170, 0), Vector2(220, 70),
		Vector2(170, 140), Vector2(100, 140), Vector2(0, 20), Vector2(100, 20),
		Vector2(170, 20), Vector2(230, -90), Vector2(-90, -90), Vector2(-50, 70),
	])
	var overlaps := ValidatorType.find_surface_overlaps(compiled)
	test.assert_true(not overlaps.is_empty(), "parallel road surfaces inside one track width must be rejected")
	if not overlaps.is_empty():
		test.assert_true(float(overlaps[0]["distance"]) < compiled.track_width, "overlap evidence reports the measured clearance")
