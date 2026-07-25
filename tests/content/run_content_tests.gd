extends SceneTree

const SUITES: Array[Script] = [
	preload("res://tests/content/test_predefined_tracks.gd"),
	preload("res://tests/content/test_offline_race_config.gd"),
	preload("res://tests/ui/test_safe_area.gd"),
	preload("res://tests/content/test_track_canvas_authoring.gd"),
]


func _initialize() -> void:
	var failed_suites := 0
	var assertion_count := 0
	for suite_script in SUITES:
		var suite: RefCounted = suite_script.new()
		var suite_result: Dictionary = suite.run()
		assertion_count += int(suite_result.get("assertions", 0))
		if int(suite_result.get("assertions", 0)) == 0 or not bool(suite_result.get("passed", false)):
			failed_suites += 1
			print("FAIL %s" % suite_result.get("suite", "unknown"))
			for failure in suite_result.get("failures", []):
				print("  - %s" % failure)
		else:
			print("PASS %s (%d assertions)" % [suite_result["suite"], suite_result["assertions"]])
	print("Content tests: %d assertions, %d failed suites" % [assertion_count, failed_suites])
	quit(1 if failed_suites > 0 else 0)
