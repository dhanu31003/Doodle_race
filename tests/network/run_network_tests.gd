extends SceneTree
## Execute with tests/network/run_network_tests.sh so parse/runtime diagnostics
## are promoted to a failing process even if the engine exit code regresses.

const SUITES: Array[Script] = [
	preload("res://tests/network/test_protocol_validation.gd"),
	preload("res://tests/network/test_client_sync.gd"),
	preload("res://tests/network/test_fake_room_server.gd"),
	preload("res://tests/network/test_network_race_runtime.gd"),
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
	print("Network tests: %d assertions, %d failed suites" % [assertion_count, failed_suites])
	quit(1 if failed_suites > 0 else 0)
