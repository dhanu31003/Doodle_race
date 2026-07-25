extends SceneTree
## Executes the real Track Studio BUILD CIRCUIT action with a screenshot-like
## dense tangled loop and an in-memory persistence boundary.

const TestCaseType := preload("res://tests/support/test_case.gd")
const GameLimitsType := preload("res://game/config/game_limits.gd")
const TrackStudioType := preload("res://game/ui/screens/track_studio.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackQueryType := preload("res://game/race/track_query.gd")
const TrackMeshBuilderType := preload("res://game/presentation3d/track_mesh_builder_3d.gd")
const RoadSurfaceCatalogType := preload("res://game/content/road_surface_catalog.gd")


class InMemoryTrackServices extends RefCounted:
	var saved_definition: TrackDefinition

	func save_track(definition: TrackDefinition, _metadata: Dictionary = {}) -> Dictionary:
		saved_definition = definition.copy()
		return {"ok": true, "track_id": definition.track_id}

	func get_track(_track_id: String) -> TrackDefinition:
		return null if saved_definition == null else saved_definition.copy()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test := TestCaseType.new()
	root.size = Vector2i(1280, 720)
	var service := InMemoryTrackServices.new()
	var screen := TrackStudioType.new()
	screen.persistence_service_override = service
	screen.size = Vector2(1280.0, 720.0)
	root.add_child(screen)
	await process_frame
	await process_frame
	# This fixture validates authoring, not audio playback. Remove the autoload
	# before the button action so the headless runner cannot exit mid-WAV voice.
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		root.remove_child(audio)
		audio.free()
	var navigation := {"route": "", "payload": {}}
	screen.navigate_requested.connect(func(next_route: String, next_payload: Dictionary) -> void:
		navigation["route"] = next_route
		navigation["payload"] = next_payload.duplicate(true)
	)
	screen.canvas.points = _densify_closed_to_count(
		_screenshot_tangled_loop(), 237
	)
	test.assert_equal(
		screen.canvas.points.size(),
		237,
		"regression fixture matches the reported Track Studio capture count"
	)
	screen.canvas.track_changed.emit(screen.canvas.points.size(), true)
	screen.name_field.text = "Automatic Hairpin Recovery"
	screen.surface_option.select(RoadSurfaceCatalogType.style_index(
		RoadSurfaceCatalogType.BUMPY_ASPHALT
	))
	test.assert_false(screen.confirm_button.disabled, "closed angular stroke enables BUILD CIRCUIT")
	test.assert_true(
		screen.find_child("MoveGridHere", true, false) == null
				and screen.find_child("GridPositionReview", true, false) == null,
		"Track Studio contains no manual grid-position review page or accept button"
	)
	screen._confirm_track()
	await process_frame
	var route_payload: Dictionary = navigation["payload"]
	test.assert_equal(navigation["route"], "tour", "BUILD CIRCUIT automatically places the grid and proceeds to the circuit tour without a review page; status=%s" % screen.status_label.text)
	test.assert_true(service.saved_definition != null, "successful build persists the recovered definition")
	test.assert_true(bool(route_payload.get("auto_smoothed", false)), "tour payload records automatic corner rounding")
	test.assert_true("rounded automatically" in screen.status_label.text.to_lower(), "Studio presents rounding as a non-error build note")
	if service.saved_definition != null:
		test.assert_equal(
			service.saved_definition.road_surface,
			RoadSurfaceCatalogType.BUMPY_ASPHALT,
			"selecting Bumpy in WORLD persists the requested surface"
		)
		var routed_definition := TrackDefinition.from_json(str(
			route_payload.get("track_definition_json", "")
		))
		test.assert_equal(
			routed_definition.road_surface,
			RoadSurfaceCatalogType.BUMPY_ASPHALT,
			"tour and race configuration receive the selected Bumpy surface"
		)
		var compiled := TrackCompilerType.compile(service.saved_definition)
		var repeated := TrackCompilerType.compile(service.saved_definition.copy())
		test.assert_true(compiled.succeeded(), "saved sharp circuit recompiles cleanly: %s" % str(compiled.report.to_dictionary()))
		test.assert_false(compiled.report.has_code(&"compile.corner_rounding_failed"), "reported 237-point loop never returns the former corner-rounding failure")
		test.assert_true(repeated.succeeded(), "reported loop succeeds on a second independent compile")
		test.assert_false(compiled.report.has_code(&"geometry.turn_radius_too_small"), "saved circuit has no minimum-radius error")
		test.assert_true(compiled.report.has_code(&"geometry.turns_auto_smoothed"), "saved circuit retains deterministic recovery evidence")
		if compiled.track != null:
			var required := maxf(
				GameLimitsType.MIN_TURN_RADIUS,
				service.saved_definition.track_width * GameLimitsType.MIN_RADIUS_TO_WIDTH_RATIO
			)
			var measured := _minimum_finite_radius(compiled.track.radii)
			test.assert_true(measured >= required, "saved centerline meets the physical radius envelope")
			test.assert_equal(
				_auto_smoothing_detail(compiled, "fallback_method"), "local_corner_rounding",
				"dense unusual loop keeps its detailed silhouette through local fairing"
			)
			test.assert_true(
				int(_auto_smoothing_detail(compiled, "fairing_radius_samples")) == 1
						and float(_auto_smoothing_detail(compiled, "maximum_displacement"))
								<= service.saved_definition.track_width * 0.25,
				"automatic point rounding uses a tightly bounded local fairing radius"
			)
			test.assert_false(compiled.report.has_code(&"geometry.road_surface_overlap"), "safe fallback leaves no near-parallel road overlap")
			test.assert_true(compiled.track.centerline[0].distance_to(compiled.track.centerline[-1]) <= compiled.track.sample_spacing * 1.75, "recovered route remains closed at its seam")
			if repeated.track != null:
				test.assert_equal(compiled.track.centerline, repeated.track.centerline, "reported loop recovery is byte-deterministic")
			var query := TrackQueryType.from_compiled(compiled.track)
			var mesh_result := TrackMeshBuilderType.build(query)
			test.assert_true(
				bool(mesh_result.get("ok", false)),
				"persisted Bumpy circuit builds its complete race mesh"
			)
			if bool(mesh_result.get("ok", false)):
				var mesh: ArrayMesh = mesh_result["mesh"]
				var road_material := mesh.surface_get_material(1) as ShaderMaterial
				test.assert_true(
					road_material != null,
					"Bumpy race mesh uses the released surface shader"
				)
				if road_material != null:
					test.assert_equal(
						int(road_material.get_shader_parameter("surface_style")), 2,
						"Bumpy selection activates repaired-slab and crack visuals"
					)
					test.assert_true(
						float(road_material.get_shader_parameter("detail_strength")) >= 0.9,
						"Bumpy visual treatment is intentionally conspicuous"
					)
			print("SHARP_CORNER_PROOF source=screenshot-tangled-loop input_points=%d samples=%d minimum_radius=%.3f required_radius=%.3f displacement=%.3f fairing_radius=%d harmonics=%d compile_hash=%s" % [
				screen.canvas.points.size(), compiled.track.centerline.size(), measured, required,
				float(_auto_smoothing_detail(compiled, "maximum_displacement")),
				int(_auto_smoothing_detail(compiled, "fairing_radius_samples")),
				int(_auto_smoothing_detail(compiled, "fallback_harmonics")),
				compiled.track.compile_hash
			])
	root.remove_child(screen)
	screen.free()
	await process_frame
	var result := test.result("track_studio_sharp_corner_integration")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)


func _screenshot_tangled_loop() -> PackedVector2Array:
	# Digitized from the 237-point player report. Coordinates are relative to
	# the visible TrackCanvas, not the full screenshot, and preserve its long
	# upper switchback, nested lower return and several close parallel runs.
	return PackedVector2Array([
		Vector2(0.235, 0.257), Vector2(0.201, 0.291),
		Vector2(0.138, 0.309), Vector2(0.097, 0.355),
		Vector2(0.091, 0.437), Vector2(0.106, 0.501),
		Vector2(0.148, 0.541), Vector2(0.167, 0.541),
		Vector2(0.198, 0.455), Vector2(0.225, 0.417),
		Vector2(0.284, 0.415), Vector2(0.281, 0.475),
		Vector2(0.273, 0.535), Vector2(0.281, 0.577),
		Vector2(0.299, 0.595), Vector2(0.340, 0.587),
		Vector2(0.384, 0.561), Vector2(0.415, 0.533),
		Vector2(0.438, 0.481), Vector2(0.475, 0.433),
		Vector2(0.515, 0.401), Vector2(0.553, 0.401),
		Vector2(0.560, 0.423), Vector2(0.548, 0.477),
		Vector2(0.533, 0.541), Vector2(0.544, 0.557),
		Vector2(0.578, 0.529), Vector2(0.615, 0.489),
		Vector2(0.637, 0.457), Vector2(0.640, 0.413),
		Vector2(0.630, 0.369), Vector2(0.637, 0.333),
		Vector2(0.659, 0.317), Vector2(0.681, 0.317),
		Vector2(0.702, 0.337), Vector2(0.714, 0.369),
		Vector2(0.716, 0.431), Vector2(0.715, 0.489),
		Vector2(0.721, 0.525), Vector2(0.745, 0.545),
		Vector2(0.789, 0.559), Vector2(0.812, 0.541),
		Vector2(0.832, 0.489), Vector2(0.845, 0.421),
		Vector2(0.838, 0.341), Vector2(0.825, 0.283),
		Vector2(0.794, 0.267), Vector2(0.739, 0.267),
		Vector2(0.714, 0.253), Vector2(0.714, 0.229),
		Vector2(0.725, 0.193), Vector2(0.743, 0.175),
		Vector2(0.775, 0.177), Vector2(0.797, 0.163),
		Vector2(0.810, 0.141), Vector2(0.810, 0.121),
		Vector2(0.797, 0.103), Vector2(0.726, 0.111),
		Vector2(0.642, 0.111), Vector2(0.599, 0.111),
		Vector2(0.585, 0.127), Vector2(0.582, 0.159),
		Vector2(0.585, 0.199), Vector2(0.572, 0.231),
		Vector2(0.548, 0.237), Vector2(0.529, 0.225),
		Vector2(0.524, 0.199), Vector2(0.523, 0.149),
		Vector2(0.514, 0.115), Vector2(0.481, 0.103),
		Vector2(0.428, 0.105), Vector2(0.410, 0.115),
		Vector2(0.403, 0.139), Vector2(0.414, 0.171),
		Vector2(0.448, 0.203), Vector2(0.475, 0.219),
		Vector2(0.496, 0.245), Vector2(0.510, 0.287),
		Vector2(0.516, 0.333), Vector2(0.510, 0.359),
		Vector2(0.491, 0.375), Vector2(0.459, 0.377),
		Vector2(0.422, 0.379), Vector2(0.405, 0.369),
		Vector2(0.389, 0.333), Vector2(0.375, 0.283),
		Vector2(0.360, 0.233), Vector2(0.345, 0.203),
		Vector2(0.328, 0.193), Vector2(0.303, 0.193),
		Vector2(0.277, 0.205), Vector2(0.252, 0.229),
		Vector2(0.235, 0.257),
	])


func _densify_closed_to_count(
		vertices: PackedVector2Array,
		point_count: int
	) -> PackedVector2Array:
	var output := PackedVector2Array()
	if vertices.size() < 2 or point_count < 2:
		return output
	var segment_lengths := PackedFloat32Array()
	var total_length := 0.0
	for index in range(vertices.size() - 1):
		var segment_length := vertices[index].distance_to(vertices[index + 1])
		segment_lengths.append(segment_length)
		total_length += segment_length
	var segment_index := 0
	var traversed := 0.0
	for point_index in range(point_count - 1):
		var target := total_length * float(point_index) / float(point_count - 1)
		while segment_index < segment_lengths.size() - 1 \
				and traversed + segment_lengths[segment_index] < target:
			traversed += segment_lengths[segment_index]
			segment_index += 1
		var local_length := segment_lengths[segment_index]
		var amount := 0.0 if local_length <= 0.000001 \
			else (target - traversed) / local_length
		output.append(vertices[segment_index].lerp(
			vertices[segment_index + 1], amount
		))
	output.append(vertices[0])
	return output


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
