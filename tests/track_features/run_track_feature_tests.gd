extends SceneTree
## Execute with tests/track_features/run_track_feature_tests.sh so Godot script
## errors are treated as failures even if the engine process exits successfully.

const SUITES: Array[Script] = [
	preload("res://tests/track_features/test_track_world_features.gd"),
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
	print("Track feature tests: %d assertions, %d failed suites" % [assertion_count, failed_suites])
	quit(1 if failed_suites > 0 else 0)
