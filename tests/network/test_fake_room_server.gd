extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const FakeServerType := preload("res://game/network/fake_room_server.gd")
const TransportType := preload("res://game/network/in_memory_transport.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")
const LimitsType := preload("res://game/network/network_limits.gd")
const ManifestType := preload("res://game/network/network_track_manifest.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const TrackCompilerType := preload("res://game/track/generation/track_compiler.gd")

func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_twelve_player_happy_path(test)
	_test_track_mismatch_and_ready_gate(test)
	_test_host_race_config_authority(test)
	_test_authoritative_fictional_cosmetics(test)
	_test_compatibility_handshake_and_grid_lock(test)
	_test_reconnect_and_host_transfer(test)
	_test_host_kick_before_start(test)
	_test_results_rematch_authority(test)
	_test_wire_rate_limits(test)
	return test.result("fake_multiplayer_room_server")


func _test_results_rematch_authority(test: RefCounted) -> void:
	var fixture := _ready_race("rematch-host", "rematch-guest")
	var host: RefCounted = fixture["host"]
	var guest: RefCounted = fixture["guest"]
	var code := str(fixture["code"])
	var epoch := int(fixture["epoch"])
	var complete := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT, "rematch-host", 1, epoch,
		{"type": "race_complete", "results": [
			{"player_id": "rematch-host", "slot": 0, "position": 1, "status": "finished", "laps": 3, "finish_time_ms": 90000, "dnf_reason": ""},
			{"player_id": "rematch-guest", "slot": 1, "position": 2, "status": "finished", "laps": 3, "finish_time_ms": 91000, "dnf_reason": ""},
		]}, fixture["server"].current_tick()
	)
	test.assert_true(host.send_envelope(code, complete)["ok"], "host publishes authoritative results before rematch")
	var guest_request: Dictionary = guest.request_rematch(code)
	test.assert_true(guest_request["ok"] and not bool(guest_request["value"]["host_restart"]), "guest rematch is a request rather than unauthorized restart")
	var host_notified := false
	for event in host.drain_events():
		if int(event.get("opcode", -1)) == ProtocolType.OP_RACE_EVENT \
				and str(event.get("payload", {}).get("type", "")) == "rematch_requested" \
				and str(event.get("payload", {}).get("player_id", "")) == "rematch-guest":
			host_notified = true
	test.assert_true(host_notified, "authority relays guest rematch request only as identity-bound intent")
	var restarted: Dictionary = host.request_rematch(code)
	test.assert_true(restarted["ok"] and bool(restarted["value"]["host_restart"]), "host restarts the verified room from results")
	var room: Dictionary = host.room_snapshot(code)["value"]
	test.assert_equal(room["state"], str(LimitsType.ROOM_READY), "rematch returns to verified READY state")
	test.assert_true(bool(room["join_locked"]), "rematch preserves the locked grid until host explicitly reopens it")
	for member in room["members"]:
		test.assert_false(bool(member["ready"]), "rematch resets every ready acknowledgement")


func _test_authoritative_fictional_cosmetics(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "cosmetics-host")
	var guest := TransportType.new(server, "cosmetics-guest")
	var invalid := host.create_private_room("Host", {"car_id": "car-ferrari", "team_id": "team-real"})
	test.assert_false(invalid["ok"], "real-world or unknown cosmetics are refused")
	test.assert_equal(_error_code(invalid), "cosmetics_invalid", "invalid cosmetics use an explicit refusal code")
	var created := host.create_private_room("Host", {"car_id": "car-cinder", "team_id": "team-cinder"})
	test.assert_true(created["ok"], "host can create with a fictional catalog identity")
	if not created["ok"]:
		return
	var code := str(created["value"]["room_code"])
	var joined := guest.join_private_room(code, "Guest", {"car_id": "car-jade", "team_id": "team-jade"})
	test.assert_true(joined["ok"], "guest can join with a distinct fictional catalog identity")
	var members: Array = host.room_snapshot(code)["value"]["members"]
	test.assert_equal(members[0].get("car_id"), "car-cinder", "authority preserves host car identity")
	test.assert_equal(members[0].get("team_id"), "team-cinder", "authority preserves host fictional team identity")
	test.assert_equal(members[1].get("car_id"), "car-jade", "authority preserves guest car identity")
	test.assert_equal(members[1].get("team_id"), "team-jade", "authority preserves guest fictional team identity")


func _test_compatibility_handshake_and_grid_lock(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "lock-host")
	for mismatch in [
		{"app_build": "0.1.0"},
		{"protocol_version": 1},
		{"app_build": "9.9.9"},
		{"protocol_version": 99},
		{"track_schema_version": 99},
		{"generator_version": 99},
		{"platform": "unsupported-console"},
	]:
		var hello := LimitsType.compatibility_payload("linux")
		hello.merge(mismatch, true)
		var refused := host.create_private_room("Host", {}, hello)
		test.assert_false(refused["ok"], "incompatible hello tuple must be refused before room admission")
		test.assert_equal(_error_code(refused), "update_required", "compatibility mismatch has explicit update-required code")
	var created := host.create_private_room("Host")
	test.assert_true(created["ok"], "current compatibility tuple creates room")
	if not created["ok"]:
		return
	var code := str(created["value"]["room_code"])
	var guest := TransportType.new(server, "lock-guest")
	var outsider := TransportType.new(server, "lock-outsider")
	test.assert_true(guest.join_private_room(code, "Guest")["ok"], "guest joins while grid is open")
	var guest_lock := guest.set_room_lock(code, true)
	test.assert_false(guest_lock["ok"], "guest cannot lock the grid")
	test.assert_equal(_error_code(guest_lock), "host_only", "guest lock refusal is host-only")
	var locked := host.set_room_lock(code, true)
	test.assert_true(locked["ok"], "host explicitly locks grid independently of countdown")
	test.assert_true(bool(host.room_snapshot(code)["value"]["join_locked"]), "public room state exposes locked grid")
	var denied_join := outsider.join_private_room(code, "Outsider")
	test.assert_false(denied_join["ok"], "grid lock prevents a new join")
	test.assert_equal(_error_code(denied_join), "room_locked", "locked-grid join refusal code")
	var denied_rules := host.set_race_config(code, {"laps": 5, "collisions": false})
	test.assert_equal(_error_code(denied_rules), "room_locked", "grid lock freezes authoritative race rules")
	var denied_kick := host.kick_member(code, "lock-guest")
	test.assert_equal(_error_code(denied_kick), "room_locked", "grid lock freezes roster removal")
	var unlocked := host.set_room_lock(code, false)
	test.assert_true(unlocked["ok"], "host can reopen grid before countdown")
	test.assert_true(outsider.join_private_room(code, "Outsider")["ok"], "join succeeds again after explicit unlock")


func _test_host_race_config_authority(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "rules-host")
	var guest := TransportType.new(server, "rules-guest")
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	guest.join_private_room(code, "Guest")
	var initial: Dictionary = host.room_snapshot(code)["value"]
	test.assert_equal(initial["race_config"], {"laps": 3, "collisions": true}, "new rooms expose authoritative default race rules")
	var unauthorized: Dictionary = guest.set_race_config(code, {"laps": 5, "collisions": false})
	test.assert_false(unauthorized["ok"], "guest cannot change race rules")
	test.assert_equal(_error_code(unauthorized), "host_only", "guest race-rule refusal code")
	for invalid in [
		{"laps": 2, "collisions": true},
		{"laps": 3.0, "collisions": true},
		{"laps": 3, "collisions": 1},
	]:
		var refused: Dictionary = host.set_race_config(code, invalid)
		test.assert_false(refused["ok"], "invalid race rule tuple must be refused")
		test.assert_equal(_error_code(refused), "race_config_invalid", "invalid race-rule refusal code")

	var manifest := _compiled_manifest()
	host.submit_track_manifest(code, manifest)
	var report := _matching_generation_report(manifest)
	host.submit_generation_report(code, report)
	guest.submit_generation_report(code, report)
	host.set_ready(code, true)
	guest.set_ready(code, true)
	var configured: Dictionary = host.set_race_config(code, {"laps": 5, "collisions": false})
	test.assert_true(configured["ok"], "host can select a bounded race-rule tuple")
	var after: Dictionary = guest.room_snapshot(code)["value"]
	test.assert_equal(after["race_config"], {"laps": 5, "collisions": false}, "all peers inspect the same authoritative race rules")
	for member in after["members"]:
		test.assert_false(bool(member["ready"]), "a changed race-rule tuple resets every ready flag")
	var saw_full_config := false
	for event in guest.drain_events():
		if int(event.get("opcode", -1)) == ProtocolType.OP_ROOM_CONFIG \
				and event.get("payload", {}).get("race_config", {}) == {"laps": 5, "collisions": false} \
				and event.get("payload", {}).has("members"):
			saw_full_config = true
	test.assert_true(saw_full_config, "race-rule broadcast is a complete public room snapshot")

	host.set_ready(code, true)
	guest.set_ready(code, true)
	var same: Dictionary = host.set_race_config(code, {"laps": 5, "collisions": false})
	test.assert_true(same["ok"] and not bool(same["value"]["changed"]), "unchanged race rules are idempotent")
	test.assert_true(bool(host.room_snapshot(code)["value"]["members"][0]["ready"]), "idempotent race rules do not reset readiness")
	var epoch := int(after["room_epoch"])
	var envelope := ProtocolType.make_envelope(
		ProtocolType.OP_ROOM_CONFIG, "rules-host", 1, epoch,
		{"type": "race_config", "laps": 1, "collisions": true}
	)
	test.assert_true(host.send_envelope(code, envelope)["ok"], "fake protocol accepts a valid host race-config envelope")
	host.set_ready(code, true)
	guest.set_ready(code, true)
	test.assert_true(host.set_room_lock(code, true)["ok"], "host locks rules fixture grid before start")
	var countdown: Dictionary = host.start_countdown(code)
	test.assert_true(countdown["ok"], "room can start after acknowledging changed rules")
	test.assert_equal(countdown["value"]["countdown"]["race_config"], {"laps": 1, "collisions": true}, "countdown locks and repeats authoritative race rules")
	var locked: Dictionary = host.set_race_config(code, {"laps": 3, "collisions": true})
	test.assert_false(locked["ok"], "race rules lock when countdown begins")
	test.assert_equal(_error_code(locked), "room_locked", "post-countdown race-rule refusal code")


func _test_twelve_player_happy_path(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var clients: Array = []
	for index in LimitsType.MAX_PLAYERS:
		clients.append(TransportType.new(server, "player-%02d" % (index + 1)))
	var created: Dictionary = clients[0].create_private_room("Driver 1")
	test.assert_true(created["ok"], "host must create a private room")
	if not created["ok"]:
		return
	var room_code := str(created["value"]["room_code"])
	test.assert_equal(room_code.length(), LimitsType.ROOM_CODE_LENGTH, "room code length")
	for index in range(1, LimitsType.MAX_PLAYERS):
		var joined: Dictionary = clients[index].join_private_room(room_code, "Driver %d" % (index + 1))
		test.assert_true(joined["ok"], "player %d must join" % (index + 1))
	var overflow := TransportType.new(server, "player-13")
	var full_result: Dictionary = overflow.join_private_room(room_code, "Driver 13")
	test.assert_false(full_result["ok"], "thirteenth player must be refused")
	test.assert_equal(_error_code(full_result), "room_full", "full-room error code")

	var manifest := _compiled_manifest()
	test.assert_false(manifest.is_empty(), "golden track must compile for multiplayer")
	if manifest.is_empty():
		return
	var selected: Dictionary = clients[0].submit_track_manifest(room_code, manifest)
	test.assert_true(selected["ok"], "host must select canonical custom track")
	var report := _matching_generation_report(manifest)
	for index in clients.size():
		var generated: Dictionary = clients[index].submit_generation_report(room_code, report)
		test.assert_true(generated["ok"], "player %d generation report must match" % (index + 1))
		var ready_result: Dictionary = clients[index].set_ready(room_code, true)
		test.assert_true(ready_result["ok"], "player %d must become ready" % (index + 1))
	var lobby: Dictionary = clients[0].room_snapshot(room_code)
	test.assert_true(lobby["ok"], "host must inspect ready room")
	test.assert_equal(lobby["value"]["member_count"], LimitsType.MAX_PLAYERS, "room must retain all 12 players")
	test.assert_equal(lobby["value"]["state"], str(LimitsType.ROOM_READY), "room must reach READY")
	var slots: Dictionary = {}
	for member in lobby["value"]["members"]:
		slots[int(member["slot"])] = true
	test.assert_equal(slots.size(), LimitsType.MAX_PLAYERS, "every racer must have a unique slot")

	test.assert_true(clients[0].set_room_lock(room_code, true)["ok"], "host locks twelve-driver grid before start")
	var countdown: Dictionary = clients[0].start_countdown(room_code)
	test.assert_true(countdown["ok"], "ready host must start countdown")
	if not countdown["ok"]:
		return
	test.assert_equal(
		countdown["value"]["countdown"]["start_tick"],
		server.current_tick() + LimitsType.COUNTDOWN_TICKS,
		"countdown start snapshot must use deterministic future tick"
	)
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000 - 1)
	test.assert_equal(
		clients[0].room_snapshot(room_code)["value"]["state"],
		str(LimitsType.ROOM_COUNTDOWN),
		"race must not begin a millisecond early"
	)
	server.advance_time(1)
	test.assert_equal(
		clients[0].room_snapshot(room_code)["value"]["state"],
		str(LimitsType.ROOM_RACING),
		"race must begin on the scheduled tick"
	)

	var guest_input := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		"player-02",
		1,
		int(lobby["value"]["room_epoch"]),
		{"steering": 200, "throttle": 1000, "brake": 0, "boost": false, "ack_host_tick": server.current_tick()},
		server.current_tick()
	)
	test.assert_true(clients[1].send_envelope(room_code, guest_input)["ok"], "guest input must reach authority")
	test.assert_true(_events_have_opcode(clients[0].drain_events(), ProtocolType.OP_INPUT_FRAME), "host must receive guest input frame")

	var snapshot_cars: Array = []
	for slot in LimitsType.MAX_PLAYERS:
		snapshot_cars.append(_car_state(slot, slot * 1000, 0))
	var host_snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT,
		"player-01",
		1,
		int(lobby["value"]["room_epoch"]),
		{"cars": snapshot_cars},
		server.current_tick()
	)
	test.assert_true(clients[0].send_envelope(room_code, host_snapshot)["ok"], "host snapshot must be accepted")
	var snapshot_events: Array = clients[1].drain_events()
	test.assert_true(_events_have_opcode(snapshot_events, ProtocolType.OP_STATE_SNAPSHOT), "guest must receive authoritative snapshot")
	test.assert_true(_events_preserve_formula_dynamics(snapshot_events), "fake authority relay preserves Formula drivetrain and tyre telemetry")

	var departed: Dictionary = clients[0].leave_room(room_code)
	test.assert_true(departed["ok"], "host departure must be handled")
	test.assert_equal(departed["value"]["state"], str(LimitsType.ROOM_CLOSED), "in-race host departure must close v1 room")
	test.assert_equal(departed["value"]["close_reason"], "simulation_host_departed", "host-loss reason must be explicit")


func _test_track_mismatch_and_ready_gate(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "host")
	var guest := TransportType.new(server, "guest")
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	test.assert_true(guest.join_private_room(code, "Guest")["ok"], "guest joins mismatch fixture")
	var manifest := _compiled_manifest()
	var bad_manifest := manifest.duplicate(true)
	bad_manifest["source_hash"] = "0".repeat(64)
	var bad_selection: Dictionary = host.submit_track_manifest(code, bad_manifest)
	test.assert_false(bad_selection["ok"], "server must refuse a noncanonical source hash")
	test.assert_equal(_error_code(bad_selection), "track_source_hash_mismatch", "source-hash refusal code")
	test.assert_true(host.submit_track_manifest(code, manifest)["ok"], "canonical manifest must be accepted")
	var report := _matching_generation_report(manifest)
	test.assert_true(host.submit_generation_report(code, report)["ok"], "host generation report")
	test.assert_true(host.set_room_lock(code, true)["ok"], "host locks synchronized grid before readiness gate")
	var early_start: Dictionary = host.start_countdown(code)
	test.assert_false(early_start["ok"], "countdown must refuse an unverified guest")
	var mismatch := report.duplicate(true)
	mismatch["compiled_fingerprint"] = "f".repeat(64)
	if mismatch["compiled_fingerprint"] == report["compiled_fingerprint"]:
		mismatch["compiled_fingerprint"] = "e".repeat(64)
	var mismatch_result: Dictionary = guest.submit_generation_report(code, mismatch)
	test.assert_false(mismatch_result["ok"], "compiled fingerprint mismatch must be refused")
	test.assert_equal(_error_code(mismatch_result), "track_identity_mismatch", "fingerprint mismatch code")
	var blocked_ready: Dictionary = guest.set_ready(code, true)
	test.assert_false(blocked_ready["ok"], "mismatched guest cannot become ready")
	test.assert_equal(_error_code(blocked_ready), "generation_not_verified", "ready-gate error code")
	test.assert_true(guest.submit_generation_report(code, report)["ok"], "corrected guest report must pass")
	test.assert_true(host.set_ready(code, true)["ok"], "host can become ready")
	test.assert_true(guest.set_ready(code, true)["ok"], "verified guest can become ready")
	test.assert_true(host.start_countdown(code)["ok"], "all-ready room can count down")
	var host_token := str(created["value"]["reconnect_token"])
	test.assert_true(host.suspend_connection(code)["ok"], "countdown host receives reconnect window")
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000)
	test.assert_equal(guest.room_snapshot(code)["value"]["state"], str(LimitsType.ROOM_COUNTDOWN), "countdown pauses while host is disconnected")
	var host_resumed: Dictionary = host.reconnect(code, host_token)
	test.assert_true(host_resumed["ok"], "host can resume a paused countdown")
	test.assert_equal(
		host_resumed["value"]["room"]["countdown"]["start_tick"],
		server.current_tick() + LimitsType.COUNTDOWN_TICKS,
		"resumed host receives a fresh synchronized countdown"
	)
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000)
	test.assert_equal(guest.room_snapshot(code)["value"]["state"], str(LimitsType.ROOM_RACING), "rescheduled countdown reaches racing")
	test.assert_true(guest.submit_generation_report(code, report)["ok"], "reconnected peer may re-verify the same compiled track")
	test.assert_equal(
		guest.room_snapshot(code)["value"]["state"], str(LimitsType.ROOM_RACING),
		"idempotent generation verification cannot demote a racing room"
	)


func _test_reconnect_and_host_transfer(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "host-r")
	var guest := TransportType.new(server, "guest-r")
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	var joined: Dictionary = guest.join_private_room(code, "Guest")
	var first_token := str(joined["value"]["reconnect_token"])
	test.assert_true(guest.suspend_connection(code)["ok"], "guest disconnect starts reconnect window")
	server.advance_time(LimitsType.RECONNECT_WINDOW_MS - 1)
	var resumed: Dictionary = guest.reconnect(code, first_token)
	test.assert_true(resumed["ok"], "guest must reconnect inside window")
	var rotated_token := str(resumed["value"]["reconnect_token"])
	test.assert_true(rotated_token != first_token, "successful reconnect must rotate token")
	test.assert_true(guest.suspend_connection(code)["ok"], "guest can disconnect again")
	var replayed: Dictionary = guest.reconnect(code, first_token)
	test.assert_false(replayed["ok"], "rotated reconnect token cannot be replayed")
	test.assert_equal(_error_code(replayed), "reconnect_token_invalid", "token replay error code")
	test.assert_true(guest.reconnect(code, rotated_token)["ok"], "current reconnect token must work")
	var current_token := str(guest.room_snapshot(code)["value"]["reconnect_token"])
	test.assert_true(guest.suspend_connection(code)["ok"], "disconnect before expiry test")
	server.advance_time(LimitsType.RECONNECT_WINDOW_MS + 1)
	var expired: Dictionary = guest.reconnect(code, current_token)
	test.assert_false(expired["ok"], "expired reconnect membership must be refused")
	test.assert_equal(_error_code(expired), "resume_membership_missing", "expired membership error code")
	test.assert_equal(host.room_snapshot(code)["value"]["member_count"], 1, "expired lobby guest releases slot")

	var transfer_server := FakeServerType.new()
	var first_host := TransportType.new(transfer_server, "transfer-host")
	var first_guest := TransportType.new(transfer_server, "transfer-guest-1")
	var second_guest := TransportType.new(transfer_server, "transfer-guest-2")
	var transfer_created: Dictionary = first_host.create_private_room("Host")
	var transfer_code := str(transfer_created["value"]["room_code"])
	first_guest.join_private_room(transfer_code, "Guest 1")
	second_guest.join_private_room(transfer_code, "Guest 2")
	var original_epoch := int(transfer_created["value"]["room"]["room_epoch"])
	var transfer: Dictionary = first_host.leave_room(transfer_code)
	test.assert_true(transfer["ok"], "lobby host departure must be handled")
	test.assert_equal(transfer["value"]["host_id"], "transfer-guest-1", "oldest connected guest becomes lobby host")
	test.assert_equal(transfer["value"]["room_epoch"], original_epoch + 1, "host transfer must advance room epoch")


func _test_wire_rate_limits(test: RefCounted) -> void:
	var fixture := _ready_race()
	var server: RefCounted = fixture["server"]
	var host: RefCounted = fixture["host"]
	var guest: RefCounted = fixture["guest"]
	var code: String = fixture["code"]
	var epoch: int = fixture["epoch"]
	for sequence in range(1, LimitsType.MAX_INPUT_FRAMES_PER_SECOND + 1):
		var message := ProtocolType.make_envelope(
			ProtocolType.OP_INPUT_FRAME,
			"rate-guest",
			sequence,
			epoch,
			{"steering": 0, "throttle": 800, "brake": 0, "boost": false, "ack_host_tick": server.current_tick()},
			server.current_tick()
		)
		test.assert_true(guest.send_envelope(code, message)["ok"], "input frame %d inside 20 Hz cap" % sequence)
		server.advance_time(40)
	var overflow_input := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		"rate-guest",
		LimitsType.MAX_INPUT_FRAMES_PER_SECOND + 1,
		epoch,
		{"steering": 0, "throttle": 800, "brake": 0, "boost": false, "ack_host_tick": server.current_tick()},
		server.current_tick()
	)
	var input_limit: Dictionary = guest.send_envelope(code, overflow_input)
	test.assert_false(input_limit["ok"], "twenty-first input inside one second must be rate-limited")
	test.assert_equal(_error_code(input_limit), "input_rate_limited", "input rate-limit code")
	server.advance_time(1001)
	test.assert_true(guest.send_envelope(code, overflow_input)["ok"], "input budget must recover after sliding window")

	var snapshot_fixture := _ready_race("snapshot-host", "snapshot-guest")
	server = snapshot_fixture["server"]
	host = snapshot_fixture["host"]
	code = snapshot_fixture["code"]
	epoch = snapshot_fixture["epoch"]
	for sequence in range(1, LimitsType.MAX_SNAPSHOTS_PER_SECOND + 1):
		var snapshot := ProtocolType.make_envelope(
			ProtocolType.OP_STATE_SNAPSHOT,
			"snapshot-host",
			sequence,
			epoch,
			{"cars": [_car_state(0, sequence * 10, 0), _car_state(1, 0, sequence * 10)]},
			server.current_tick()
		)
		test.assert_true(host.send_envelope(code, snapshot)["ok"], "snapshot %d inside 15 Hz cap" % sequence)
		server.advance_time(50)
	var overflow_snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT,
		"snapshot-host",
		LimitsType.MAX_SNAPSHOTS_PER_SECOND + 1,
		epoch,
		{"cars": [_car_state(0, 999, 0)]},
		server.current_tick()
	)
	var snapshot_limit: Dictionary = host.send_envelope(code, overflow_snapshot)
	test.assert_false(snapshot_limit["ok"], "sixteenth snapshot inside one second must be rate-limited")
	test.assert_equal(_error_code(snapshot_limit), "snapshot_rate_limited", "snapshot rate-limit code")

	server = FakeServerType.new()
	var control_host := TransportType.new(server, "control-host")
	guest = TransportType.new(server, "control-guest")
	var control_created: Dictionary = control_host.create_private_room("Host")
	code = str(control_created["value"]["room_code"])
	guest.join_private_room(code, "Guest")
	var control_manifest := _compiled_manifest()
	control_host.submit_track_manifest(code, control_manifest)
	var control_report := _matching_generation_report(control_manifest)
	control_host.submit_generation_report(code, control_report)
	guest.submit_generation_report(code, control_report)
	epoch = int(control_host.room_snapshot(code)["value"]["room_epoch"])
	for sequence in range(1, LimitsType.MAX_CONTROL_MESSAGES_PER_SECOND + 1):
		var ready_toggle := ProtocolType.make_envelope(
			ProtocolType.OP_READY_STATE,
			"control-guest",
			sequence,
			epoch,
			{"ready": sequence % 2 == 0},
			server.current_tick()
		)
		test.assert_true(
			guest.send_envelope(code, ready_toggle)["ok"],
			"control message %d stays inside the bounded rate" % sequence
		)
	var overflow_control := ProtocolType.make_envelope(
		ProtocolType.OP_READY_STATE,
		"control-guest",
		LimitsType.MAX_CONTROL_MESSAGES_PER_SECOND + 1,
		epoch,
		{"ready": true},
		server.current_tick()
	)
	var control_limit: Dictionary = guest.send_envelope(code, overflow_control)
	test.assert_false(control_limit["ok"], "control traffic above twelve messages per second is rate-limited")
	test.assert_equal(_error_code(control_limit), "control_rate_limited", "control rate-limit code")
	server.advance_time(1001)
	overflow_control["seq"] = LimitsType.MAX_CONTROL_MESSAGES_PER_SECOND + 2
	test.assert_true(guest.send_envelope(code, overflow_control)["ok"], "control budget recovers after its sliding window")


func _test_host_kick_before_start(test: RefCounted) -> void:
	var server := FakeServerType.new()
	var host := TransportType.new(server, "kick-host")
	var guest := TransportType.new(server, "kick-guest")
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	test.assert_true(guest.join_private_room(code, "Guest")["ok"], "kick fixture guest joins")
	var epoch := int(host.room_snapshot(code)["value"]["room_epoch"])
	var unauthorized: Dictionary = guest.kick_member(code, "kick-host")
	test.assert_false(unauthorized["ok"], "non-host cannot kick a room member")
	test.assert_equal(_error_code(unauthorized), "host_only", "non-host kick refusal code")
	var kicked: Dictionary = host.kick_member(code, "kick-guest")
	test.assert_true(kicked["ok"], "host can kick a guest before countdown")
	var after: Dictionary = host.room_snapshot(code)["value"]
	test.assert_equal(after["member_count"], 1, "kicked member releases its slot")
	test.assert_equal(after["room_epoch"], epoch, "guest kick does not rotate host epoch")
	var kicked_events := guest.drain_events()
	var saw_kicked_reason := false
	for event in kicked_events:
		if int(event.get("opcode", -1)) == ProtocolType.OP_ROOM_ENDED \
				and str(event.get("payload", {}).get("reason", "")) == "kicked_by_host":
			saw_kicked_reason = true
	test.assert_true(saw_kicked_reason, "kicked client receives a clear terminal reason")
	test.assert_false(guest.room_snapshot(code)["ok"], "kicked identity is no longer a room member")
	var banned_rejoin: Dictionary = guest.join_private_room(code, "Guest")
	test.assert_false(banned_rejoin["ok"], "kicked identity cannot immediately rejoin with the retained invite")
	test.assert_equal(_error_code(banned_rejoin), "kicked_from_room", "kicked-room ban refusal code")
	var race_fixture := _ready_race("kick-lock-host", "kick-lock-guest")
	var locked: Dictionary = race_fixture["host"].kick_member(race_fixture["code"], "kick-lock-guest")
	test.assert_false(locked["ok"], "kick is unavailable after countdown")
	test.assert_equal(_error_code(locked), "room_locked", "post-countdown kick refusal code")


func _ready_race(host_id: String = "rate-host", guest_id: String = "rate-guest") -> Dictionary:
	var server := FakeServerType.new()
	var host := TransportType.new(server, host_id)
	var guest := TransportType.new(server, guest_id)
	var created: Dictionary = host.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	guest.join_private_room(code, "Guest")
	var manifest := _compiled_manifest()
	host.submit_track_manifest(code, manifest)
	var report := _matching_generation_report(manifest)
	host.submit_generation_report(code, report)
	guest.submit_generation_report(code, report)
	host.set_ready(code, true)
	guest.set_ready(code, true)
	var epoch := int(host.room_snapshot(code)["value"]["room_epoch"])
	host.set_room_lock(code, true)
	host.start_countdown(code)
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000)
	return {"server": server, "host": host, "guest": guest, "code": code, "epoch": epoch}


func _compiled_manifest() -> Dictionary:
	# Build independently of persisted golden fixtures so this suite exercises
	# the released schema API without coupling to fixture migration work.
	var definition := TrackDefinitionType.create(PackedVector2Array([
		Vector2(0.20, 0.35), Vector2(0.35, 0.20),
		Vector2(0.65, 0.20), Vector2(0.80, 0.35),
		Vector2(0.80, 0.65), Vector2(0.65, 0.80),
		Vector2(0.35, 0.80), Vector2(0.20, 0.65),
	]), Vector2(1920.0, 1080.0), 72.0, "Network Stadium", "network-stadium", 42)
	definition.generator_version = TrackCompilerType.COMPILER_VERSION
	definition.refresh_content_hash()
	var compiled_result := TrackCompilerType.compile(definition)
	if compiled_result.track == null:
		return {}
	return ManifestType.build(definition, compiled_result.track)


func _matching_generation_report(manifest: Dictionary) -> Dictionary:
	return {
		"success": true,
		"source_hash": manifest["source_hash"],
		"generator_version": manifest["generator_version"],
		"compiled_fingerprint": manifest["compiled_fingerprint"],
	}


func _car_state(slot: int, x_q: int, y_q: int) -> Dictionary:
	return {
		"slot": slot,
		"x_q": x_q,
		"y_q": y_q,
		"rotation_q": 0,
		"velocity_x_q": 0,
		"velocity_y_q": 0,
		"lap": 0,
		"checkpoint": 0,
		"collision_layer": 1,
		"collision_mask": 1,
		"flags": 0,
		"gear": 4,
		"engine_rpm_q": 102_000,
		"shift_ticks": 2,
		"steering_q": 2500,
		"slip_angle_q": -740,
		"wheel_slip_q": 800,
		"lateral_accel_q": 245_000,
	}


func _events_have_opcode(events: Array, opcode: int) -> bool:
	for event in events:
		if int(event.get("opcode", -1)) == opcode:
			return true
	return false


func _events_preserve_formula_dynamics(events: Array) -> bool:
	for event in events:
		if int(event.get("opcode", -1)) != ProtocolType.OP_STATE_SNAPSHOT:
			continue
		var cars: Array = event.get("payload", {}).get("cars", [])
		if cars.is_empty() or not cars[0] is Dictionary:
			continue
		var car: Dictionary = cars[0]
		return int(car.get("gear", -99)) == 4 \
			and int(car.get("engine_rpm_q", -1)) == 102_000 \
			and int(car.get("steering_q", -99_999)) == 2500 \
			and int(car.get("slip_angle_q", 99_999)) == -740
	return false


func _error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))
