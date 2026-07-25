extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const LimitsType := preload("res://game/network/network_limits.gd")
const PredictionType := preload("res://game/network/client/prediction_reconciler.gd")
const InterpolatorType := preload("res://game/network/client/snapshot_interpolator.gd")
const SchedulerType := preload("res://game/network/client/network_send_scheduler.gd")
const SessionType := preload("res://game/network/client/private_multiplayer_session.gd")
const TransportType := preload("res://game/network/multiplayer_transport.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_send_cadence(test)
	_test_prediction_reconciliation(test)
	_test_snapshot_interpolation(test)
	_test_unexpected_transport_loss_enters_reconnect(test)
	return test.result("client_prediction_and_interpolation")


func _test_send_cadence(test: RefCounted) -> void:
	var scheduler := SchedulerType.new()
	scheduler.configure(200, 1)
	test.assert_equal(scheduler.input_hz, LimitsType.INPUT_SUBMISSION_MAX_HZ, "input cadence clamps to 20 Hz")
	test.assert_equal(scheduler.snapshot_hz, LimitsType.AUTHORITATIVE_SNAPSHOT_MIN_HZ, "snapshot cadence clamps to 10 Hz")
	scheduler.configure(20, 12)
	test.assert_true(scheduler.input_due(0), "first input is immediately due")
	scheduler.mark_input_sent(0)
	test.assert_false(scheduler.input_due(49), "20 Hz input cannot send before 50 ms")
	test.assert_true(scheduler.input_due(50), "20 Hz input is due at 50 ms")
	test.assert_true(scheduler.snapshot_due(0), "first snapshot is immediately due")
	scheduler.mark_snapshot_sent(0)
	test.assert_false(scheduler.snapshot_due(83), "12 Hz snapshot waits for ceiling interval")
	test.assert_true(scheduler.snapshot_due(84), "12 Hz snapshot is due at 84 ms")


func _test_prediction_reconciliation(test: RefCounted) -> void:
	var reconciler := PredictionType.new()
	reconciler.record_local_step(100, {"seq": 1, "delta_q": 100}, _motion_state(100))
	reconciler.record_local_step(101, {"seq": 2, "delta_q": 100}, _motion_state(200))
	reconciler.record_local_step(102, {"seq": 3, "delta_q": 100}, _motion_state(300))
	var reconciled: Dictionary = reconciler.reconcile(100, _motion_state(80), _simulate_step)
	test.assert_true(reconciled["ok"], "authoritative correction must reconcile")
	if not reconciled["ok"]:
		return
	test.assert_equal(reconciled["value"]["error_q"], [-20, 0], "correction error is measured at authority tick")
	test.assert_equal(reconciled["value"]["state"]["x_q"], 280, "pending inputs replay from authoritative state")
	test.assert_equal(reconciled["value"]["replayed_ticks"], [101, 102], "only unacknowledged ticks replay")
	test.assert_equal(reconciler.pending_input_count(), 2, "acknowledged input is discarded")
	test.assert_false(reconciled["value"]["hard_snap"], "small correction remains blendable")
	var large_correction: Dictionary = reconciler.reconcile(102, _motion_state(10_000), _simulate_step)
	test.assert_true(large_correction["ok"], "large authoritative correction remains valid")
	test.assert_true(large_correction["value"]["hard_snap"], "large divergence requests a hard snap")
	test.assert_equal(reconciler.pending_input_count(), 0, "latest authority acknowledges all pending inputs")


func _test_snapshot_interpolation(test: RefCounted) -> void:
	var interpolator := InterpolatorType.new()
	var first := {
		"tick": 100,
		"cars": [_interpolation_car(0, 0, 3_000_000)],
	}
	var second := {
		"tick": 110,
		"cars": [_interpolation_car(0, 1000, -3_000_000), _interpolation_car(1, 500, 0)],
	}
	first["cars"][0].merge({
		"vertical_offset_q": 0,
		"vertical_velocity_q": 0,
		"grounded": 1,
	}, true)
	second["cars"][0].merge({
		"vertical_offset_q": 4000,
		"vertical_velocity_q": 10_000,
		"grounded": 0,
	}, true)
	second["cars"][0].merge(_contact_bundle(3), true)
	test.assert_true(interpolator.push_snapshot(first)["ok"], "first interpolation snapshot")
	test.assert_true(interpolator.push_snapshot(second)["ok"], "second interpolation snapshot")
	var stale: Dictionary = interpolator.push_snapshot(second)
	test.assert_false(stale["ok"], "duplicate snapshot tick must be refused")
	var midpoint := interpolator.sample(105.0)
	test.assert_equal(midpoint["cars"].size(), 2, "new remote slot remains visible during interpolation")
	test.assert_equal(midpoint["cars"][0]["x_q"], 500, "fixed position interpolates at half tick")
	test.assert_near(float(midpoint["cars"][0]["rotation_q"]), 3_141_592.0, 2.0, "rotation follows shortest wrapped arc")
	test.assert_equal(midpoint["cars"][0]["contact_serial"], 3, "interpolation switches the complete discrete contact bundle at the sample boundary")
	test.assert_equal(midpoint["cars"][0]["contact_x_q"], 123_000, "interpolation never blends contact position across separate impacts")
	test.assert_equal(midpoint["cars"][0]["vertical_offset_q"], 2000, "airborne height interpolates in fixed-point authority")
	test.assert_equal(midpoint["cars"][0]["vertical_velocity_q"], 5000, "vertical velocity interpolates with airborne height")
	test.assert_equal(midpoint["cars"][0]["grounded"], 0, "grounded state switches discretely at the interpolation boundary")
	test.assert_equal(interpolator.sample_delayed(116)["tick"], 110, "six-tick render delay samples authoritative buffer")
	var partial_car := _interpolation_car(0, 1200, 0)
	partial_car["contact_serial"] = 4
	var partial := interpolator.push_snapshot({"tick": 120, "cars": [partial_car]})
	test.assert_false(partial["ok"], "interpolator rejects a partial contact bundle")
	var partial_airborne := _interpolation_car(0, 1200, 0)
	partial_airborne["vertical_offset_q"] = 100
	test.assert_false(
		interpolator.push_snapshot({"tick": 121, "cars": [partial_airborne]})["ok"],
		"interpolator rejects a partial airborne authority bundle"
	)


func _test_unexpected_transport_loss_enters_reconnect(test: RefCounted) -> void:
	var session := SessionType.new()
	session.configure_test_transport(TransportType.new(), "socket-player")
	session.room_code = "ABCDEF"
	session.room_epoch = 1
	session.set("_reconnect_token", "ephemeral-token")
	var error_event := ProtocolType.make_envelope(
		ProtocolType.OP_ERROR, "nakama", 0, 1, {"code": "nakama_socket_closed"}
	)
	session.call("_handle_event", error_event)
	test.assert_equal(str(session.connection_state), "reconnecting", "unexpected socket close pauses an active session for reconnect")
	test.assert_true(session.reconnect_remaining_ms() > 0, "unexpected socket close starts the bounded reconnect clock")
	var first_anchor := int(session.get("_background_suspend_ms"))
	session.call("_handle_event", error_event)
	test.assert_equal(int(session.get("_background_suspend_ms")), first_anchor, "duplicate socket callbacks cannot extend the reconnect window")
	session.reset_session(true)
	test.assert_equal(str(session.connection_state), "offline", "full session reset closes unexpected-loss state")
	test.assert_true(session.room_code.is_empty() and session.transport == null and session.reconnect_remaining_ms() == 0, "full session reset clears room, transport, and reconnect deadline")
	session.free()


func _simulate_step(state: Dictionary, input_frame: Dictionary, _tick: int) -> Dictionary:
	var next := state.duplicate(true)
	next["x_q"] = int(next["x_q"]) + int(input_frame.get("delta_q", 0))
	next["velocity_x_q"] = int(input_frame.get("delta_q", 0))
	return next


func _motion_state(x_q: int) -> Dictionary:
	return {
		"x_q": x_q,
		"y_q": 0,
		"rotation_q": 0,
		"velocity_x_q": 100,
		"velocity_y_q": 0,
	}


func _interpolation_car(slot: int, x_q: int, rotation_q: int) -> Dictionary:
	return {
		"slot": slot,
		"x_q": x_q,
		"y_q": 0,
		"rotation_q": rotation_q,
		"velocity_x_q": 0,
		"velocity_y_q": 0,
		"lap": 0,
		"checkpoint": 0,
		"collision_layer": 1,
		"collision_mask": 1,
		"flags": 0,
	}


func _contact_bundle(serial: int) -> Dictionary:
	return {
		"contact_serial": serial,
		"contact_tick": 104,
		"contact_speed_q": 45_000,
		"contact_x_q": 123_000,
		"contact_y_q": -87_000,
		"contact_normal_x_q": 6000,
		"contact_normal_y_q": 8000,
	}
