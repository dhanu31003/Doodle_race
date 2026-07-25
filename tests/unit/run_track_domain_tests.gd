extends SceneTree
## Execute with:
## godot --headless --path . --script res://tests/unit/run_track_domain_tests.gd

const SUITES: Array[Script] = [
	preload("res://tests/unit/test_stable_rng.gd"),
	preload("res://tests/unit/test_track_definition.gd"),
	preload("res://tests/unit/test_track_pipeline.gd"),
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
	print("Track domain tests: %d assertions, %d failed suites" % [assertion_count, failed_suites])
	quit(1 if failed_suites > 0 else 0)
