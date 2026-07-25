extends SceneTree
## Focused logic, rendering-surface, accessibility and mobile-layout proof for
## the one-canvas race HUD instruments.

const TestCaseType := preload("res://tests/support/test_case.gd")
const EntryType := preload("res://game/race/race_entry.gd")
const TrackerType := preload("res://game/race/lap_tracker.gd")
const TelemetryType := preload("res://game/ui/components/race_telemetry_cluster.gd")
const StandingsType := preload("res://game/ui/components/race_standings_panel.gd")
const DesignSystemType := preload("res://game/ui/design_system.gd")

const MOBILE_VIEWPORT := Vector2(1280.0, 720.0)
const WIDE_MOBILE_VIEWPORT := Vector2(1560.0, 720.0)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test := TestCaseType.new()
	_test_authoritative_rows(test)
	_test_telemetry_sanitization(test)
	await _test_render_surfaces(test)
	DesignSystemType.configure_ui_scale(1.0)
	var result: Dictionary = test.result("race_hud_components")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
	else:
		print("FAIL %s" % result.suite)
		for failure in result.failures:
			print("  - %s" % failure)
	quit(0 if result.passed else 1)


func _test_authoritative_rows(test: RefCounted) -> void:
	var entries := _entries(14, 1900.0, 52.0)
	entries[11].status = EntryType.STATUS_DNF
	var rows := StandingsType.rows_from_authority(entries, &"driver-8", 1600.0)
	test.assert_equal(rows.size(), 12, "standings cap their paint surface at the supported twelve-car grid")
	test.assert_equal(int(rows[0]["position"]), 1, "authority order is preserved rather than re-sorted by the HUD")
	test.assert_equal(str(rows[0]["interval"]), "LEAD", "first authoritative row is labelled as race leader")
	test.assert_true(bool(rows[7]["is_player"]), "local participant is identified in its authoritative row")
	test.assert_equal(str(rows[7]["participant_id"]), "driver-8", "player highlight binds to participant id, not display-name text")
	test.assert_equal(str(rows[11]["interval"]), "OUT", "DNF authority status has a non-colour retirement cue")
	test.assert_equal(int(rows[11]["position"]), 12, "retired twelfth-place car remains visible in the full field")
	test.assert_true(str(rows[1]["interval"]).begins_with("+"), "following racers expose a compact progress interval")
	entries[1].lap_tracker.last_validated_progress = 200.0
	rows = StandingsType.rows_from_authority(entries, &"driver-8", 1600.0)
	test.assert_equal(str(rows[1]["interval"]), "+1L", "a full-lap progress deficit is reported as a lap interval")
	entries[0].display_name = "   "
	rows = StandingsType.rows_from_authority(entries, &"driver-8", 1600.0)
	test.assert_equal(str(rows[0]["display_name"]), "DRIVER", "empty authority display names fail closed to a readable label")


func _test_telemetry_sanitization(test: RefCounted) -> void:
	test.assert_near(TelemetryType.normalized_rev(6250.0, 12_500.0), 0.5, 0.0001, "rev band ratio derives directly from engine and redline RPM")
	test.assert_near(TelemetryType.normalized_rev(18_000.0, 12_500.0), 1.0, 0.0001, "rev band clamps beyond redline")
	test.assert_near(TelemetryType.normalized_rev(-100.0, 12_500.0), 0.0, 0.0001, "rev band rejects negative RPM")
	test.assert_near(TelemetryType.normalized_rev(NAN, 0.0), 0.0, 0.0001, "non-finite telemetry cannot poison the draw path")


func _test_render_surfaces(test: RefCounted) -> void:
	for fixture in [
		{"size": MOBILE_VIEWPORT, "scale": 0.85},
		{"size": MOBILE_VIEWPORT, "scale": 1.30},
		{"size": WIDE_MOBILE_VIEWPORT, "scale": 1.30},
	]:
		DesignSystemType.configure_ui_scale(float(fixture["scale"]))
		var canvas := Control.new()
		canvas.size = fixture["size"]
		root.add_child(canvas)
		var standings := StandingsType.new()
		standings.position = Vector2(28.0, 24.0)
		standings.size = StandingsType.BASE_SIZE
		standings.configure_accessibility(false, true)
		canvas.add_child(standings)
		var entries := _entries(12, 2400.0, 65.0)
		standings.update_standings(entries, &"driver-6", 2200.0, 2, 5, 64.283, 60)

		var telemetry := TelemetryType.new()
		telemetry.size = TelemetryType.BASE_SIZE
		telemetry.position = Vector2(
			float(fixture["size"].x) - TelemetryType.BASE_SIZE.x - 28.0,
			402.0
		)
		telemetry.configure_accessibility(false, true)
		canvas.add_child(telemetry)
		telemetry.update_telemetry(287, 7, 11_820.0, 12_500.0, false, 2, 5, 3, 64.283, 21.916)
		await process_frame
		await process_frame

		var telemetry_snapshot: Dictionary = telemetry.debug_snapshot()
		var standings_snapshot: Dictionary = standings.debug_snapshot()
		test.assert_equal(int(telemetry_snapshot["speed_kmh"]), 287, "mobile cluster paints authoritative speed at scale %.2f" % float(fixture["scale"]))
		test.assert_equal(str(telemetry_snapshot["gear"]), "7", "mobile cluster paints authoritative gear at scale %.2f" % float(fixture["scale"]))
		test.assert_equal(int(telemetry_snapshot["node_count"]), 1, "telemetry remains a single canvas node at scale %.2f" % float(fixture["scale"]))
		test.assert_equal(int(standings_snapshot["row_count"]), 12, "all twelve rankings remain present at scale %.2f" % float(fixture["scale"]))
		test.assert_equal(int(standings_snapshot["player_position"]), 6, "player rank remains explicit at scale %.2f" % float(fixture["scale"]))
		test.assert_equal(int(standings_snapshot["node_count"]), 1, "standings remain a single canvas node at scale %.2f" % float(fixture["scale"]))
		test.assert_true(Rect2(Vector2.ZERO, fixture["size"]).encloses(standings.get_rect()), "standings fit the mobile viewport at scale %.2f" % float(fixture["scale"]))
		test.assert_true(Rect2(Vector2.ZERO, fixture["size"]).encloses(telemetry.get_rect()), "telemetry fits the mobile viewport at scale %.2f" % float(fixture["scale"]))
		var simulated_touch_controls := Rect2(Vector2(float(fixture["size"].x) - 332.0, 570.0), Vector2(304.0, 124.0))
		test.assert_false(telemetry.get_rect().intersects(simulated_touch_controls), "telemetry clears enlarged right-hand touch controls at scale %.2f" % float(fixture["scale"]))
		test.assert_true("you" in standings.accessibility_name.to_lower(), "standings narrate the player row at scale %.2f" % float(fixture["scale"]))
		test.assert_true("kilometres per hour" in telemetry.accessibility_name.to_lower(), "telemetry exposes a spoken speed unit at scale %.2f" % float(fixture["scale"]))
		var initial_telemetry_paints := int(telemetry_snapshot["paint_updates"])
		for unused in 120:
			telemetry.update_telemetry(287, 7, 11_820.0, 12_500.0, false, 2, 5, 3, 64.283, 21.916)
		test.assert_equal(int(telemetry.debug_snapshot()["paint_updates"]), initial_telemetry_paints, "unchanged frame-rate telemetry performs no repaint or formatted-signature work")
		var displayed_progress := float(standings_snapshot["rows"][1]["progress"])
		entries[1].lap_tracker.last_validated_progress -= 100.0
		standings.update_standings(entries, &"driver-6", 2200.0, 2, 5, 64.300, 61)
		var throttled_snapshot: Dictionary = standings.debug_snapshot()
		test.assert_near(float(throttled_snapshot["rows"][1]["progress"]), displayed_progress, 0.001, "unchanged race order is text-throttled inside one authority interval")
		test.assert_equal(int(throttled_snapshot["authority_update_calls"]), 2, "standings receive the live authority call without rebuilding their node tree")
		test.assert_equal(int(throttled_snapshot["row_rebuilds"]), 1, "standings allocate no replacement row array inside the six-tick throttle window")
		test.assert_equal(int(throttled_snapshot["paint_updates"]), int(standings_snapshot["paint_updates"]), "throttled standings perform no redundant canvas repaint")
		standings.update_standings(entries, &"driver-6", 2200.0, 2, 5, 64.400, 66)
		var refreshed_snapshot: Dictionary = standings.debug_snapshot()
		test.assert_true(float(refreshed_snapshot["rows"][1]["progress"]) < displayed_progress, "progress intervals refresh on the bounded ten-hertz authority cadence")
		test.assert_equal(int(refreshed_snapshot["row_rebuilds"]), 2, "ten-hertz refresh performs exactly one bounded twelve-row rebuild")
		for sample in 120:
			telemetry.update_telemetry(200 + sample % 80, 6, 9000.0 + sample, 12_500.0, false, 2, 5, 3, 64.5 + sample / 60.0, 22.0)
		test.assert_equal(int(telemetry.debug_snapshot()["node_count"]), 1, "two seconds of frame-rate telemetry create no child controls or layout nodes")
		canvas.free()
		await process_frame


func _entries(count: int, leader_progress: float, spacing: float) -> Array:
	var output: Array = []
	for index in count:
		var entry := EntryType.new()
		entry.participant_id = StringName("driver-%d" % (index + 1))
		entry.display_name = "RACER %02d" % (index + 1)
		entry.grid_position = index + 1
		entry.status = EntryType.STATUS_RACING
		entry.lap_tracker = TrackerType.new()
		entry.lap_tracker.last_validated_progress = leader_progress - float(index) * spacing
		output.append(entry)
	return output
