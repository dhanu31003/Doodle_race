extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const FactoryType := preload("res://tests/race/race_test_factory.gd")
const LapTrackerType := preload("res://game/race/lap_tracker.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_valid_ordered_laps(test)
	_test_reverse_and_shortcut_rejection(test)
	return test.result("lap_checkpoint_authority")


func _test_valid_ordered_laps(test: RefCounted) -> void:
	var track := FactoryType.create_oval(128)
	var tracker := LapTrackerType.new()
	test.assert_true(tracker.configure(track, 2, 8), "valid track configures lap authority")
	var start := track.sample_at_distance(1.0)
	tracker.prime(start["position"])
	var distance := 1.0
	var tick := 0
	var sector_events: Array[Dictionary] = []
	while distance < track.total_length * 2.0 + 8.0 and not tracker.finished:
		distance += 4.0
		tick += 1
		var sample := track.sample_at_distance(distance)
		var event := tracker.update(sample["position"], sample["tangent"] * 240.0, 1.0 / 60.0, tick, float(tick) / 60.0)
		if event.get("sector", false):
			sector_events.append(event.duplicate(true))
	test.assert_equal(tracker.laps_completed, 2, "ordered forward gate crossings award both laps")
	test.assert_true(tracker.finished, "final ordered lap marks race finished")
	test.assert_true(tracker.finish_tick > 0 and tracker.finish_time > 0.0, "finish stores deterministic timing evidence")
	test.assert_near(tracker.validated_progress(), track.total_length * 2.0, 0.001, "finished classification progress is exact")
	test.assert_equal(LapTrackerType.sector_boundary_checkpoints(8), PackedInt32Array([3, 5, 8]), "three sector boundaries derive deterministically from ordered checkpoints")
	test.assert_equal(sector_events.size(), 6, "two complete laps emit exactly three sector events each")
	test.assert_equal(tracker.sector_splits.size(), 6, "authority retains every official sector split")
	var duration_sum := 0.0
	for index in tracker.sector_splits.size():
		var split: Dictionary = tracker.sector_splits[index]
		duration_sum += float(split["duration"])
		test.assert_equal(int(split["lap_number"]), index / 3 + 1, "sector split records its authoritative lap")
		test.assert_equal(int(split["sector_index"]), index % 3 + 1, "sector split order resets to one through three each lap")
		test.assert_true(float(split["duration"]) > 0.0, "every official sector duration is positive")
	test.assert_near(duration_sum, tracker.finish_time, 0.0001, "sector durations exactly partition the authoritative race time")
	var snapshot := tracker.sector_splits_snapshot()
	snapshot[0]["duration"] = 0.0
	test.assert_true(float(tracker.sector_splits[0]["duration"]) > 0.0, "sector snapshots cannot mutate lap authority")


func _test_reverse_and_shortcut_rejection(test: RefCounted) -> void:
	var track := FactoryType.create_oval(128)
	var reverse_tracker := LapTrackerType.new()
	reverse_tracker.configure(track, 1, 8)
	var distance := 1.0
	var sample := track.sample_at_distance(distance)
	reverse_tracker.prime(sample["position"])
	for tick in 360:
		distance -= 4.0
		sample = track.sample_at_distance(distance)
		reverse_tracker.update(sample["position"], -sample["tangent"] * 240.0, 1.0 / 60.0, tick, float(tick) / 60.0)
	test.assert_equal(reverse_tracker.laps_completed, 0, "reverse circulation cannot award a lap")
	test.assert_equal(reverse_tracker.next_checkpoint, 1, "reverse gates cannot advance checkpoint order")
	test.assert_true(reverse_tracker.reverse_distance > track.total_length * 0.7, "reverse travel is explicitly measured")
	test.assert_equal(reverse_tracker.sector_splits.size(), 0, "reverse circulation cannot create sector timing")
	var shortcut_tracker := LapTrackerType.new()
	shortcut_tracker.configure(track, 1, 8)
	sample = track.sample_at_distance(1.0)
	shortcut_tracker.prime(sample["position"])
	var shortcut := track.sample_at_distance(track.total_length * 0.30)
	var event := shortcut_tracker.update(shortcut["position"], shortcut["tangent"] * 200.0, 1.0 / 60.0, 1, 0.016)
	test.assert_true(event["invalid"], "implausible shortcut displacement is rejected")
	test.assert_equal(shortcut_tracker.next_checkpoint, 1, "rejected shortcut cannot advance an ordered gate")
	test.assert_equal(shortcut_tracker.laps_completed, 0, "rejected shortcut cannot complete a lap")
	test.assert_equal(shortcut_tracker.sector_splits.size(), 0, "rejected shortcut cannot create a sector split")
