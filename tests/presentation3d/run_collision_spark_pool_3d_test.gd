extends SceneTree

const TestCaseType := preload("res://tests/support/test_case.gd")
const SparkPoolType := preload("res://game/presentation3d/collision_spark_pool_3d.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var test := TestCaseType.new()
	var pool := SparkPoolType.new()
	root.add_child(pool)
	await process_frame
	var initial: Dictionary = pool.presentation_snapshot()
	test.assert_equal(int(initial.get("pool_size", 0)), 6, "collision sparks use a fixed six-emitter pool")
	test.assert_equal(
		int(initial.get("total_particle_capacity", 0)), 84,
		"spark capacity is statically bounded to six fourteen-particle bursts"
	)
	test.assert_true(
		float(initial.get("maximum_lifetime_seconds", 99.0)) <= 0.361,
		"yellow contact sparks are deliberately short-lived"
	)
	test.assert_true(
		float(initial.get("spark_width_meters", 99.0)) <= 0.03
				and float(initial.get("spark_length_meters", 99.0)) <= 0.10,
		"each individual spark streak stays visually small at the contact point"
	)
	test.assert_true(
		bool(initial.get("yellow_emissive", false))
				and bool(initial.get("presentation_only", false)),
		"pool declares the requested yellow presentation-only contract"
	)

	var too_soft := pool.emit_contact(Vector3.ZERO, Vector3.RIGHT, 4.0, "soft:1")
	test.assert_false(too_soft, "sub-threshold paint rub cannot produce noisy spark spam")
	var accepted := pool.emit_contact(
		Vector3(4.0, 0.45, -2.0), Vector3(0.6, 0.0, 0.8), 96.0, "pair-a-b:42"
	)
	test.assert_true(accepted, "authoritative nonzero impact telemetry emits one spark burst")
	var duplicate := pool.emit_contact(
		Vector3(4.0, 0.45, -2.0), Vector3(-0.6, 0.0, -0.8), 96.0, "pair-a-b:42"
	)
	test.assert_false(duplicate, "the same authoritative event key cannot emit twice")
	var first_burst: Dictionary = pool.presentation_snapshot()
	test.assert_equal(int(first_burst.get("accepted_bursts", 0)), 1, "one serial-equivalent event produces one accepted burst")
	test.assert_near(
		(first_burst["last_world_position"] as Vector3).distance_to(Vector3(4.0, 0.45, -2.0)),
		0.0, 0.000001,
		"spark emitter is placed at the supplied collision contact point"
	)
	test.assert_near(
		(first_burst["last_world_normal"] as Vector3).length(), 1.0, 0.000001,
		"spark direction consumes a normalized world contact normal"
	)

	for index in 20:
		pool.emit_contact(
			Vector3(float(index), 0.3, 0.0), Vector3.RIGHT, 120.0,
			"bounded-event-%02d" % index
		)
	var saturated: Dictionary = pool.presentation_snapshot()
	test.assert_equal(int(saturated.get("pool_size", 0)), 6, "many impacts reuse rather than expand the emitter pool")
	test.assert_true(
		int(saturated.get("emitting_count", 99)) <= 6,
		"active spark emitter count cannot exceed the fixed pool"
	)
	test.assert_true(
		int(saturated.get("remembered_event_keys", 99)) <= 32,
		"event de-duplication memory is itself bounded"
	)

	pool.reset_pool()
	var reset: Dictionary = pool.presentation_snapshot()
	test.assert_equal(int(reset.get("accepted_bursts", -1)), 0, "race reset clears spark accounting")
	test.assert_equal(int(reset.get("emitting_count", -1)), 0, "race reset immediately stops every pooled emitter")

	root.remove_child(pool)
	pool.free()
	await process_frame
	var result: Dictionary = test.result("collision_spark_pool_3d")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
		quit(0)
		return
	print("FAIL %s" % result.suite)
	for failure in result.failures:
		print("  - %s" % failure)
	quit(1)
