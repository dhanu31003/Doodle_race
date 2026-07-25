extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const ConfigScreenType := preload("res://game/ui/screens/offline_race_config_screen.gd")
const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_payload_configuration(test)
	_test_safe_bounds(test)
	_test_result_helpers(test)
	return test.result("offline_race_configuration")


func _test_payload_configuration(test: RefCounted) -> void:
	var base := CatalogType.race_payload("builtin-evergreen-oval", 3, "standard")
	base["source"] = "saved"
	base["display_name"] = "Exact Custom Circuit"
	base["location"] = "CUSTOM CREATION"
	base["_config_return_route"] = "tracks"
	var original_json := str(base["track_definition_json"])
	var original_source_hash := str(base["source_hash"])
	var original_compile_hash := str(base["compiled_hash"])
	var configured := ConfigScreenType.configured_payload(base, 8, "expert", 6, false)
	test.assert_equal(configured["laps"], 8, "setup emits the selected lap count")
	test.assert_equal(configured["difficulty"], "expert", "setup emits the selected AI difficulty")
	test.assert_equal(configured["grid_size"], 6, "setup emits the selected bounded grid size")
	test.assert_false(configured["collisions"], "setup emits the selected collision mode")
	test.assert_equal(configured["track_definition_json"], original_json, "setup preserves exact custom-track bytes")
	test.assert_equal(configured["source_hash"], original_source_hash, "setup preserves source verification")
	test.assert_equal(configured["compiled_hash"], original_compile_hash, "setup preserves compile verification")
	test.assert_equal(configured["source"], "saved", "setup preserves custom-track provenance")
	test.assert_false(configured.has("_config_return_route"), "private return routing never leaks into race authority")
	test.assert_equal(base["laps"], 3, "setup never mutates its incoming tour payload")
	test.assert_true(RaceScreenType.studio_return_payload(configured).get("editing_track_json", "") == original_json, "configured custom results return the exact definition to Track Studio")


func _test_safe_bounds(test: RefCounted) -> void:
	test.assert_equal(ConfigScreenType.validated_lap_count(5), 5, "supported lap count is retained")
	test.assert_equal(ConfigScreenType.validated_lap_count(99), 3, "unsupported lap count fails to the product default")
	test.assert_equal(ConfigScreenType.validated_difficulty(" EXPERT "), "expert", "difficulty input is normalized")
	test.assert_equal(ConfigScreenType.validated_difficulty("impossible"), "standard", "unknown difficulty fails to standard")
	test.assert_equal(ConfigScreenType.validated_grid_size(-10), 2, "grid size clamps to two drivers")
	test.assert_equal(ConfigScreenType.validated_grid_size(99), 12, "grid size clamps to twelve drivers")
	test.assert_equal(ConfigScreenType.validated_grid_size("twelve"), 12, "non-numeric grid size fails to twelve")
	test.assert_true(ConfigScreenType.validated_collisions("false"), "non-boolean collisions fail safely to enabled")
	test.assert_equal(RaceScreenType.validated_racer_count(1), 2, "race authority independently enforces minimum grid")
	test.assert_equal(RaceScreenType.validated_racer_count(13), 12, "race authority independently enforces maximum grid")
	test.assert_near(RaceScreenType.touch_control_lift_px(0.0), 0.0, 0.001, "zero reach offset keeps controls at the baseline")
	test.assert_near(RaceScreenType.touch_control_lift_px(1.0), 96.0, 0.001, "full reach offset lifts controls by ninety-six pixels")


func _test_result_helpers(test: RefCounted) -> void:
	var splits := [
		{"sector_index": 1, "duration": 24.1},
		{"sector_index": 2, "duration": 31.2},
		{"sector_index": 3, "duration": 22.9},
		{"sector_index": 1, "duration": 23.7},
	]
	var best := RaceScreenType.best_sector_times(splits)
	test.assert_near(best[0], 23.7, 0.0001, "results choose the best first-sector split")
	test.assert_near(best[1], 31.2, 0.0001, "results retain the best second-sector split")
	test.assert_near(best[2], 22.9, 0.0001, "results retain the best third-sector split")
	var failed_summary := {
		"race_result": {"ok": false},
		"best_lap_attempted": true,
		"best_lap_result": {"ok": false},
	}
	test.assert_equal(
		RaceScreenType.local_persistence_warning(failed_summary),
		"RESULT AND BEST LAP WERE NOT SAVED LOCALLY",
		"results expose a non-blocking warning when both local writes fail"
	)
	test.assert_equal(RaceScreenType.local_persistence_warning({
		"race_result": {"ok": true},
		"best_lap_attempted": true,
		"best_lap_result": {"ok": true},
	}), "", "successful local writes do not show a warning")
	var standings := [
		{"position": 1, "display_name": "YOU", "status": "finished", "finish_time_ms": 78200, "participant_id": "private-player-id"},
		{"position": 2, "display_name": "RIVAL", "status": "dnf", "finish_time_ms": -1, "dnf_reason": "time_limit", "participant_id": "private-rival-id"},
	]
	var share := RaceScreenType.share_results_text("Exact Custom Circuit", 78.2, standings)
	test.assert_true("Full classification:" in share and "1. YOU" in share and "2. RIVAL" in share, "share copy includes the complete display classification")
	test.assert_false("private-player-id" in share or "private-rival-id" in share, "share copy never exposes internal participant IDs")

