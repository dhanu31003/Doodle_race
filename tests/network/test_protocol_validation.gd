extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")
const LimitsType := preload("res://game/network/network_limits.gd")
const FakeServerType := preload("res://game/network/fake_room_server.gd")
const TransportType := preload("res://game/network/in_memory_transport.gd")
const EndpointType := preload("res://game/network/client/network_endpoint.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_envelope_validation(test)
	_test_malformed_peer_quarantine(test)
	_test_remote_endpoints_cannot_downgrade_tls(test)
	return test.result("network_protocol_validation")


func _test_envelope_validation(test: RefCounted) -> void:
	var wrong_root: Dictionary = ProtocolType.validate_envelope("not-an-object")
	test.assert_false(wrong_root["ok"], "non-object envelope must fail")
	test.assert_equal(_error_code(wrong_root), "message_malformed", "wrong-root code")
	var missing: Dictionary = ProtocolType.validate_envelope({})
	test.assert_false(missing["ok"], "missing envelope fields must fail")
	var valid_input := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		"player",
		1,
		7,
		{"steering": 0, "throttle": 1000, "brake": 0, "boost": false, "ack_host_tick": 12},
		12
	)
	test.assert_true(ProtocolType.validate_envelope(valid_input, "player", 7)["ok"], "well-formed input envelope must pass")
	var malicious_boost := valid_input.duplicate(true)
	malicious_boost["seq"] = 2
	malicious_boost["payload"]["boost"] = true
	var boost_result: Dictionary = ProtocolType.validate_envelope(malicious_boost, "player", 7)
	test.assert_false(boost_result["ok"], "multiplayer authority must reject malicious boost activation")
	test.assert_equal(_error_code(boost_result), "input_boost_disabled", "disabled boost error code")
	var spoofed := valid_input.duplicate(true)
	spoofed["sender_id"] = "attacker"
	var spoof_result: Dictionary = ProtocolType.validate_envelope(spoofed, "player", 7)
	test.assert_false(spoof_result["ok"], "claimed sender cannot override transport identity")
	test.assert_equal(_error_code(spoof_result), "sender_spoofed", "sender-spoof code")
	var stale_epoch := valid_input.duplicate(true)
	stale_epoch["room_epoch"] = 6
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(stale_epoch, "player", 7)),
		"room_epoch_stale",
		"stale epoch code"
	)
	var out_of_range := valid_input.duplicate(true)
	out_of_range["payload"]["steering"] = 1001
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(out_of_range, "player", 7)),
		"input_steering_invalid",
		"input values must not be silently clamped"
	)
	var oversized := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT,
		"player",
		2,
		7,
		{"blob": "x".repeat(LimitsType.MAX_MESSAGE_BYTES + 1)}
	)
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(oversized, "player", 7)),
		"message_too_large",
		"oversized payload code"
	)
	var duplicate_cars := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT,
		"host",
		1,
		7,
		{"cars": [_car_state(0), _car_state(0)]},
		12
	)
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(duplicate_cars, "host", 7)),
		"snapshot_slot_invalid",
		"duplicate authoritative car slots must fail"
	)
	var formula_car := _car_state(0)
	formula_car.merge({
		"gear": 5,
		"engine_rpm_q": 108_500,
		"shift_ticks": 3,
		"steering_q": -4200,
		"slip_angle_q": 910,
		"wheel_slip_q": 1250,
		"lateral_accel_q": -318_000,
		"vertical_offset_q": 3250,
		"vertical_velocity_q": -12_000,
		"grounded": 0,
		"contact_serial": 3,
		"contact_tick": 12,
		"contact_speed_q": 72_500,
		"contact_x_q": 250_000,
		"contact_y_q": -125_000,
		"contact_normal_x_q": 6000,
		"contact_normal_y_q": 8000,
	})
	var formula_snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "host", 2, 7, {"cars": [formula_car]}, 13
	)
	test.assert_true(
		ProtocolType.validate_envelope(formula_snapshot, "host", 7)["ok"],
		"complete bounded Formula drivetrain and tyre telemetry is accepted"
	)
	var incomplete_formula := formula_snapshot.duplicate(true)
	incomplete_formula["payload"]["cars"][0].erase("slip_angle_q")
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(incomplete_formula, "host", 7)),
		"snapshot_dynamics_incomplete",
		"partial Formula telemetry fails closed instead of mixing authority generations"
	)
	var excessive_rpm := formula_snapshot.duplicate(true)
	excessive_rpm["payload"]["cars"][0]["engine_rpm_q"] = LimitsType.ENGINE_RPM_Q_LIMIT + 1
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(excessive_rpm, "host", 7)),
		"snapshot_dynamics_out_of_range",
		"out-of-range Formula telemetry is rejected at the protocol boundary"
	)
	var incomplete_airborne := formula_snapshot.duplicate(true)
	incomplete_airborne["payload"]["cars"][0].erase("vertical_velocity_q")
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(incomplete_airborne, "host", 7)),
		"snapshot_airborne_incomplete",
		"partial vertical authority fails closed instead of mixing grounded state"
	)
	var malformed_airborne := formula_snapshot.duplicate(true)
	malformed_airborne["payload"]["cars"][0]["grounded"] = false
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(malformed_airborne, "host", 7)),
		"snapshot_airborne_malformed",
		"vertical authority uses deterministic fixed-point integers"
	)
	var incoherent_grounded := formula_snapshot.duplicate(true)
	incoherent_grounded["payload"]["cars"][0]["grounded"] = 1
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(incoherent_grounded, "host", 7)),
		"snapshot_airborne_out_of_range",
		"a grounded snapshot cannot carry stale height or vertical velocity"
	)
	var excessive_airborne := formula_snapshot.duplicate(true)
	excessive_airborne["payload"]["cars"][0]["vertical_offset_q"] = \
			LimitsType.VERTICAL_OFFSET_Q_LIMIT + 1
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(excessive_airborne, "host", 7)),
		"snapshot_airborne_out_of_range",
		"out-of-range airborne height is rejected at the protocol boundary"
	)
	var incomplete_contact := formula_snapshot.duplicate(true)
	incomplete_contact["payload"]["cars"][0].erase("contact_speed_q")
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(incomplete_contact, "host", 7)),
		"snapshot_contact_incomplete",
		"partial contact telemetry fails closed instead of mixing impact events"
	)
	var malformed_contact := formula_snapshot.duplicate(true)
	malformed_contact["payload"]["cars"][0]["contact_tick"] = "twelve"
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(malformed_contact, "host", 7)),
		"snapshot_contact_malformed",
		"non-integer contact telemetry is rejected at the protocol boundary"
	)
	var excessive_contact := formula_snapshot.duplicate(true)
	excessive_contact["payload"]["cars"][0]["contact_speed_q"] = LimitsType.CONTACT_SPEED_Q_LIMIT + 1
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(excessive_contact, "host", 7)),
		"snapshot_contact_out_of_range",
		"out-of-range impact speed is rejected at the protocol boundary"
	)
	var malformed_normal := formula_snapshot.duplicate(true)
	malformed_normal["payload"]["cars"][0]["contact_normal_x_q"] = 0
	malformed_normal["payload"]["cars"][0]["contact_normal_y_q"] = 0
	test.assert_equal(
		_error_code(ProtocolType.validate_envelope(malformed_normal, "host", 7)),
		"snapshot_contact_out_of_range",
		"non-unit impact normal is rejected at the protocol boundary"
	)
	var legacy_snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "host", 3, 7, {"cars": [_car_state(0)]}, 14
	)
	test.assert_true(
		ProtocolType.validate_envelope(legacy_snapshot, "host", 7)["ok"],
		"legacy protocol-v1 snapshots without Formula telemetry remain readable"
	)
	var rematch := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT, "player", 3, 7, {"type": "rematch"}, 12
	)
	test.assert_true(ProtocolType.validate_envelope(rematch, "player", 7)["ok"], "bounded rematch request is a valid explicit race event")
	var requested := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT, "server", 4, 7,
		{"type": "rematch_requested", "player_id": "player"}, 12
	)
	test.assert_true(ProtocolType.validate_envelope(requested, "server", 7)["ok"], "authoritative rematch notification binds a valid player identity")


func _test_malformed_peer_quarantine(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "quarantine-host")
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	# The room is not racing, but malformed-envelope validation happens first.
	for attempt in LimitsType.MALFORMED_MESSAGES_BEFORE_QUARANTINE:
		var malformed: Dictionary = host.send_envelope(code, {"attempt": attempt})
		test.assert_false(malformed["ok"], "malformed message %d must fail" % (attempt + 1))
	var plausible := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		"quarantine-host",
		1,
		int(created["value"]["room"]["room_epoch"]),
		{"steering": 0, "throttle": 0, "brake": 0, "boost": false, "ack_host_tick": 0},
		0
	)
	var quarantined: Dictionary = host.send_envelope(code, plausible)
	test.assert_false(quarantined["ok"], "repeatedly malformed peer must be quarantined")
	test.assert_equal(_error_code(quarantined), "peer_quarantined", "quarantine error code")


func _test_remote_endpoints_cannot_downgrade_tls(test: RefCounted) -> void:
	for local_host in ["127.0.0.1", "localhost", "::1", "10.0.2.2"]:
		var local := EndpointType.sanitize({"host": local_host, "scheme": "http"})
		test.assert_equal(local["scheme"], "http", "exact development host may use cleartext: %s" % local_host)
	var remote := EndpointType.sanitize({"host": "race.example.com", "scheme": "http"})
	test.assert_equal(remote["scheme"], "https", "remote host is upgraded to TLS")
	var invalid_scheme := EndpointType.sanitize({"host": "203.0.113.8", "scheme": "ws"})
	test.assert_equal(invalid_scheme["scheme"], "https", "invalid remote scheme fails closed to TLS")
	var lookalike := EndpointType.sanitize({"host": "localhost.example.com", "scheme": "http"})
	test.assert_equal(lookalike["scheme"], "https", "localhost lookalike cannot bypass TLS")
	var fallback := EndpointType.sanitize({"host": "bad host", "scheme": "http"})
	test.assert_equal(fallback["host"], EndpointType.defaults()["host"], "invalid host falls back to local default")
	test.assert_equal(fallback["scheme"], "http", "validated local fallback remains usable for development")


func _car_state(slot: int) -> Dictionary:
	return {
		"slot": slot,
		"x_q": 0,
		"y_q": 0,
		"rotation_q": 0,
		"velocity_x_q": 0,
		"velocity_y_q": 0,
		"lap": 0,
		"checkpoint": 0,
		"collision_layer": 1,
		"collision_mask": 1,
		"flags": 0,
	}


func _error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))
