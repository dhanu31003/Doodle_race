extends SceneTree
## Execute with tests/race/run_race_tests.sh so SCRIPT ERROR output is fatal.

const SUITES: Array[Script] = [
	preload("res://tests/race/test_vehicle_model.gd"),
	preload("res://tests/race/test_lap_tracker.gd"),
	preload("res://tests/race/test_ai_race_director.gd"),
	preload("res://tests/race/test_race_input_adapter.gd"),
	preload("res://tests/race/test_bridge_runtime.gd"),
	preload("res://tests/race/test_race_recovery_quality.gd"),
	preload("res://tests/race/test_sand_and_vehicle_contacts.gd"),
]


func _initialize() -> void:
	var failed_suites := 0
	var assertion_count := 0
	for suite_script in SUITES:
		var suite: RefCounted = suite_script.new()
		var suite_result: Dictionary = suite.run()
		assertion_count += int(suite_result.get("assertions", 0))
		if int(suite_result.get("assertions", 0)) == 0:
			failed_suites += 1
			print("FAIL %s (suite executed no assertions)" % suite_result.get("suite", "unknown"))
		elif bool(suite_result.get("passed", false)):
			print("PASS %s (%d assertions)" % [suite_result["suite"], suite_result["assertions"]])
		else:
			failed_suites += 1
			print("FAIL %s" % suite_result["suite"])
			for failure in suite_result["failures"]:
				print("  - %s" % failure)
	print("Race simulation tests: %d assertions, %d failed suites" % [assertion_count, failed_suites])
	quit(1 if failed_suites > 0 else 0)
