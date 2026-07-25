extends SceneTree
## Requires the local backend stack. The shell wrapper owns clean startup and teardown.

const TestCaseType := preload("res://tests/support/test_case.gd")
const AdapterType := preload("res://game/network/nakama/nakama_multiplayer_transport.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")
const LimitsType := preload("res://game/network/network_limits.gd")
const SessionType := preload("res://game/network/client/private_multiplayer_session.gd")
const NetworkRaceScreenType := preload("res://game/ui/screens/network_race_screen.gd")

var _test: RefCounted


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test = TestCaseType.new()
	var host_root := Node.new()
	var guest_root := Node.new()
	get_root().add_child(host_root)
	get_root().add_child(guest_root)
	var host := AdapterType.new()
	var guest := AdapterType.new()
	var nakama_port := _nakama_port()

	var host_auth: Dictionary = await host.authenticate_device_async(
		host_root, "raceglyph-e2e-host-device-0001", "E2E Host", "127.0.0.1", nakama_port,
		"CHANGE_ME_LOCAL_SERVER_KEY_32_CHARS"
	)
	var guest_auth: Dictionary = await guest.authenticate_device_async(
		guest_root, "raceglyph-e2e-guest-device-0002", "E2E Guest", "127.0.0.1", nakama_port,
		"CHANGE_ME_LOCAL_SERVER_KEY_32_CHARS"
	)
	_test.assert_true(host_auth["ok"], "official SDK must device-authenticate host")
	_test.assert_true(guest_auth["ok"], "official SDK must device-authenticate guest")
	if not host_auth["ok"] or not guest_auth["ok"]:
		await _finish(host, guest, host_root, guest_root)
		return

	var created: Dictionary = await host.create_private_room(
		"E2E Host", {"car_id": "car-cinder", "team_id": "team-cinder"}
	)
	_test.assert_true(created["ok"], "host RPC must create and join authoritative private room")
	if not created["ok"]:
		await _finish(host, guest, host_root, guest_root)
		return
	var room_code := str(created["value"]["room_code"])
	_test.assert_equal(room_code.length(), 6, "real backend room code length")
	var host_config: Dictionary = await host.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG)
	_test.assert_true(host_config["ok"], "host must receive authoritative room config")

	var invalid_join: Dictionary = await guest.join_private_room("OOOOOO", "E2E Guest")
	_test.assert_false(invalid_join["ok"], "backend refuses a room code outside the private-code alphabet")
	if not invalid_join["ok"]:
		_test.assert_equal(
			str(invalid_join["error"]["code"]), "room_code_invalid", "invalid-room refusal code is stable"
		)
	var incompatible := LimitsType.compatibility_payload("linux")
	incompatible["protocol_version"] = 1
	var update_refusal: Dictionary = await guest.join_private_room(room_code, "E2E Guest", {}, incompatible)
	_test.assert_false(update_refusal["ok"], "real RPC rejects the superseded protocol-1 physics handshake")
	if not update_refusal["ok"]:
		_test.assert_equal(str(update_refusal["error"]["code"]), "update_required", "real handshake uses update-required refusal")
	var joined: Dictionary = await guest.join_private_room(
		room_code, "E2E Guest", {"car_id": "car-jade", "team_id": "team-jade"}
	)
	_test.assert_true(joined["ok"], "guest RPC must resolve room code and join match")
	if not joined["ok"]:
		await _finish(host, guest, host_root, guest_root)
		return
	var guest_config: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG)
	_test.assert_true(guest_config["ok"], "guest must receive authoritative room config")
	var host_two: Dictionary = await _wait_for_room_count(host, 2)
	_test.assert_true(host_two["ok"], "host must observe two admitted players")
	if host_two["ok"]:
		_test.assert_equal(host_two["value"]["payload"]["member_count"], 2, "authoritative member count")
		var members: Array = host_two["value"]["payload"]["members"]
		_test.assert_equal(str(members[0].get("car_id", "")), "car-cinder", "real roster preserves host fictional car")
		_test.assert_equal(str(members[1].get("car_id", "")), "car-jade", "real roster preserves guest fictional car")
	_test.assert_true((await host.set_ready(room_code, true))["ok"], "pre-track ready request reaches real authority")
	var premature_ready_error: Dictionary = await _wait_for_error_code(host, "ready_unavailable")
	_test.assert_true(premature_ready_error["ok"], "real authority rejects readiness before circuit synchronization")

	var fixture_builder := ResourceLoader.load(
		_track_fixture_builder_path(), "Script", ResourceLoader.CACHE_MODE_IGNORE
	) as Script
	var track_fixture: Dictionary = fixture_builder.call("build") if fixture_builder != null else {}
	fixture_builder = null
	var manifest: Dictionary = track_fixture.get("manifest", {})
	_test.assert_true(bool(track_fixture.get("ok", false)), "generator-v3 track must compile for real network test")
	if not bool(track_fixture.get("ok", false)):
		await _finish(host, guest, host_root, guest_root)
		return
	_test.assert_true((await host.submit_track_manifest(room_code, manifest))["ok"], "host must submit canonical track manifest")
	var transferred: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_TRACK_MANIFEST)
	_test.assert_true(transferred["ok"], "guest must receive server-verified track manifest")

	var matching := _generation_report(manifest)
	var mismatch := matching.duplicate(true)
	mismatch["compiled_fingerprint"] = "f".repeat(64)
	if mismatch["compiled_fingerprint"] == matching["compiled_fingerprint"]:
		mismatch["compiled_fingerprint"] = "e".repeat(64)
	_test.assert_true((await guest.submit_generation_report(room_code, mismatch))["ok"], "mismatch report must reach authority")
	var mismatch_error: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_ERROR)
	_test.assert_true(mismatch_error["ok"], "authority must answer mismatched generation")
	if mismatch_error["ok"]:
		_test.assert_equal(mismatch_error["value"]["payload"]["code"], "track_identity_mismatch", "real mismatch refusal code")

	_test.assert_true((await host.submit_generation_report(room_code, matching))["ok"], "host matching report send")
	_test.assert_true((await guest.submit_generation_report(room_code, matching))["ok"], "guest corrected report send")
	_test.assert_true((await host.set_ready(room_code, true))["ok"], "host ready send")
	_test.assert_true((await guest.set_ready(room_code, true))["ok"], "guest ready send")
	var ready_state: Dictionary = await _wait_for_room_state(host, "READY")
	_test.assert_true(ready_state["ok"], "real room must reach READY")
	_test.assert_true((await guest.set_race_config(room_code, {"laps": 5, "collisions": false}))["ok"], "guest race-rule request reaches authority")
	var guest_rules_error: Dictionary = await _wait_for_error_code(guest, "host_only")
	_test.assert_true(guest_rules_error["ok"], "real authority refuses non-host race-rule changes")
	_test.assert_true((await host.set_race_config(room_code, {"laps": 2, "collisions": true}))["ok"], "malformed host rule tuple reaches authority")
	var invalid_rules_error: Dictionary = await _wait_for_error_code(host, "race_config_invalid")
	_test.assert_true(invalid_rules_error["ok"], "real authority refuses lap counts outside 1, 3, or 5")
	_test.assert_true((await host.set_race_config(room_code, {"laps": 5, "collisions": false}))["ok"], "host race-rule request reaches authority")
	var synced_rules: Dictionary = await _wait_for_race_config(guest, 5, false)
	_test.assert_true(synced_rules["ok"], "guest receives authoritative lap and collision rules")
	if synced_rules["ok"]:
		for member in synced_rules["value"]["payload"]["members"]:
			_test.assert_false(bool(member["ready"]), "real rule change resets every ready flag")
	_test.assert_true((await host.set_ready(room_code, true))["ok"], "host re-readies after rule change")
	_test.assert_true((await guest.set_ready(room_code, true))["ok"], "guest re-readies after rule change")
	_test.assert_true((await _wait_for_room_state(host, "READY"))["ok"], "real room returns to READY after rule acknowledgement")
	_test.assert_true((await host.set_room_lock(room_code, true))["ok"], "host grid-lock request reaches authority")
	var locked_config: Dictionary = await _wait_for_room_lock(guest, true)
	_test.assert_true(locked_config["ok"], "guest observes explicit grid lock independently of countdown")

	var guest_token := guest.reconnect_token()
	_test.assert_true(guest.simulate_socket_drop()["ok"], "guest socket closes to simulate a real transport loss")
	var first_close: Dictionary = await _wait_for_error_code(guest, "nakama_socket_closed")
	_test.assert_true(first_close["ok"], "adapter surfaces the real socket-close lifecycle event")
	var resumed: Dictionary = await guest.reconnect(room_code, guest_token)
	_test.assert_true(resumed["ok"], "guest must open a new socket and rejoin with reconnect token")
	if resumed["ok"]:
		_test.assert_equal(
			str(resumed["value"]["resume"].get("type", "")),
			"peer_resumed",
			"authority sends an explicit resume payload"
		)
		_test.assert_true(
			not str(resumed["value"]["reconnect_token"]).is_empty()
					and str(resumed["value"]["reconnect_token"]) != guest_token,
			"authority rotates reconnect token after use"
		)
	var resume_config: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG)
	_test.assert_true(resume_config["ok"], "reconnected guest receives full room state")

	_test.assert_true((await host.start_countdown(room_code))["ok"], "host start request reaches authority")
	var countdown: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_START_AT_TICK)
	_test.assert_true(countdown["ok"], "guest receives synchronized authoritative countdown")
	if not countdown["ok"]:
		await _finish(host, guest, host_root, guest_root)
		return
	_test.assert_equal(countdown["value"]["payload"]["race_config"], {"laps": 5, "collisions": false}, "countdown locks the same authoritative race rules")
	var start_tick := int(countdown["value"]["payload"]["start_tick"])
	await create_timer(3.2).timeout
	var race_started: Dictionary = await _wait_for_race_event_type(guest, "race_started")
	_test.assert_true(race_started["ok"], "authoritative room reaches racing after countdown")
	if race_started["ok"]:
		_test.assert_equal(race_started["value"]["payload"]["type"], "race_started", "race-start event type")

	var input := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		guest.session_user_id(),
		1,
		guest.room_epoch(),
		{"steering": 125, "throttle": 900, "brake": 0, "boost": false, "ack_host_tick": start_tick},
		start_tick
	)
	_test.assert_true((await guest.send_envelope(room_code, input))["ok"], "guest input send through official socket")
	var relayed_input: Dictionary = await host.wait_for_opcode_async(ProtocolType.OP_INPUT_FRAME)
	_test.assert_true(relayed_input["ok"], "authoritative match relays bounded guest input to host")
	var future_input := input.duplicate(true)
	future_input["seq"] = 2
	future_input["tick"] = start_tick + 100_000
	_test.assert_true(
		(await guest.send_envelope(room_code, future_input))["ok"],
		"structurally valid future input reaches backend validation"
	)
	var future_input_error: Dictionary = await _wait_for_error_code(guest, "input_tick_future")
	_test.assert_true(future_input_error["ok"], "backend rejects input too far ahead of authority")

	var snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT,
		host.session_user_id(),
		1,
		host.room_epoch(),
		{"cars": [_car_state(0, 1000), _car_state(1, 900)]},
		start_tick
	)
	_test.assert_true((await host.send_envelope(room_code, snapshot))["ok"], "host authoritative snapshot send")
	var relayed_snapshot: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_STATE_SNAPSHOT)
	_test.assert_true(relayed_snapshot["ok"], "authoritative match relays host snapshot to guest")
	if relayed_snapshot["ok"]:
		var relayed_car: Dictionary = relayed_snapshot["value"]["payload"]["cars"][0]
		_test.assert_equal(relayed_car["gear"], 5, "real Nakama relay preserves Formula gear authority")
		_test.assert_equal(relayed_car["engine_rpm_q"], 108_500, "real Nakama relay preserves fixed-point engine RPM")
		_test.assert_equal(relayed_car["steering_q"], -4200, "real Nakama relay preserves physical steering state")
		_test.assert_equal(relayed_car["slip_angle_q"], 910, "real Nakama relay preserves tyre-slip telemetry")
		_test.assert_equal(relayed_car["contact_serial"], 3, "real Nakama relay preserves the car-contact event serial")
		_test.assert_equal(relayed_car["contact_speed_q"], 72_500, "real Nakama relay preserves fixed-point impact speed")
		_test.assert_equal(relayed_car["contact_normal_y_q"], 8000, "real Nakama relay preserves the impact normal as part of one bundle")
	var future_snapshot := snapshot.duplicate(true)
	future_snapshot["seq"] = 2
	future_snapshot["tick"] = start_tick + 100_000
	_test.assert_true(
		(await host.send_envelope(room_code, future_snapshot))["ok"],
		"structurally valid future snapshot reaches backend validation"
	)
	var future_snapshot_error: Dictionary = await _wait_for_error_code(host, "snapshot_tick_future")
	_test.assert_true(future_snapshot_error["ok"], "backend rejects snapshot too far ahead of authority")

	# Route the second forced loss through the production callback -> persistent
	# session -> NetworkRaceScreen path. This is deliberately not a direct
	# transport-only reconnect assertion.
	var network_session: PrivateMultiplayerSession = get_root().get_node_or_null("NetworkSession")
	_test.assert_true(network_session != null, "persistent NetworkSession autoload is available to real E2E")
	var authoritative_room: Dictionary = guest.room_snapshot(room_code)["value"]
	authoritative_room["state"] = "RACING"
	authoritative_room["countdown"] = countdown["value"]["payload"].duplicate(true)
	authoritative_room["race_config"] = {"laps": 5, "collisions": false}
	# Clear old peer-resume/manifest copies left by the earlier direct transport
	# reconnect; from this point the persistent session exclusively owns events.
	guest.drain_events()
	network_session.configure_test_transport(guest, guest.session_user_id())
	network_session.call("_apply_join_result", {
		"room_code": room_code,
		"room_epoch": guest.room_epoch(),
		"reconnect_token": guest.reconnect_token(),
		"room": authoritative_room,
	})
	var definition: Variant = track_fixture.get("definition")
	var compiled: Variant = track_fixture.get("compiled_track")
	_test.assert_true(definition != null and compiled != null, "real E2E track can seed the production race screen")
	if definition == null or compiled == null:
		await _finish(host, guest, host_root, guest_root)
		return
	network_session.set("_current_definition", definition)
	network_session.set("_current_compiled", compiled)
	network_session.call("_handle_event", race_started["value"])
	# Earlier protocol checks used input sequences 1 and 2. Continue above that
	# authenticated sequence boundary when the screen begins submitting input.
	network_session.set("_sequence_by_opcode", {ProtocolType.OP_INPUT_FRAME: 2})
	var race_screen := NetworkRaceScreenType.new()
	race_screen.set_payload(network_session.race_payload())
	race_screen.size = Vector2(1280.0, 720.0)
	guest_root.add_child(race_screen)
	await process_frame
	await process_frame
	_test.assert_true(race_screen.runtime != null and race_screen.runtime.running, "NetworkRaceScreen begins from the authoritative live session")

	var racing_token := guest.reconnect_token()
	_test.assert_true(guest.simulate_socket_drop()["ok"], "racing guest can lose its real socket through the SDK callback")
	var loss_deadline := Time.get_ticks_msec() + 3000
	while network_session.connection_state != SessionType.CONNECTION_RECONNECTING and Time.get_ticks_msec() <= loss_deadline:
		await process_frame
	_test.assert_equal(str(network_session.connection_state), str(SessionType.CONNECTION_RECONNECTING), "socket callback moves production session into reconnecting")
	_test.assert_true(network_session.reconnect_remaining_ms() > 0 and network_session.reconnect_remaining_ms() <= LimitsType.RECONNECT_WINDOW_MS, "session starts the bounded reconnect deadline")
	await process_frame
	_test.assert_true(race_screen.runtime.suspended, "NetworkRaceScreen suspends simulation while the session is reconnecting")
	var connection_panel: PanelContainer = race_screen.get("_connection_panel")
	_test.assert_true(connection_panel != null and connection_panel.visible, "NetworkRaceScreen shows its reconnect panel after the real socket callback")
	var racing_resume: Dictionary = await network_session.reconnect_async()
	_test.assert_true(racing_resume["ok"], "production session reconnects inside the live-race grace window")
	if racing_resume["ok"]:
		_test.assert_true(
			guest.reconnect_token() != racing_token,
			"racing reconnect consumes and rotates its token"
		)
	await process_frame
	await process_frame
	_test.assert_equal(str(network_session.connection_state), str(SessionType.CONNECTION_ONLINE), "production session returns online after resume")
	_test.assert_false(race_screen.runtime.suspended, "authoritative resume snapshot releases NetworkRaceScreen suspension")
	_test.assert_false(connection_panel.visible, "reconnect panel closes after the production session resumes")
	var complete := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT, host.session_user_id(), 1, host.room_epoch(),
		{"type": "race_complete", "results": [
			{"player_id": host.session_user_id(), "slot": 0, "position": 1, "status": "finished", "laps": 5, "finish_time_ms": 90000, "dnf_reason": ""},
			{"player_id": guest.session_user_id(), "slot": 1, "position": 2, "status": "finished", "laps": 5, "finish_time_ms": 91000, "dnf_reason": ""},
		]}, start_tick + 120
	)
	_test.assert_true((await host.send_envelope(room_code, complete))["ok"], "host publishes authoritative results for real rematch flow")
	var host_results := await _wait_for_race_event_type(host, "race_complete")
	_test.assert_true(host_results["ok"], "real authority accepts and broadcasts host classification")
	var session_results := await _wait_for_session_state(network_session, "RESULTS")
	_test.assert_true(session_results["ok"], "persistent guest session reaches authoritative RESULTS")
	await process_frame
	var terminal_panel: PanelContainer = race_screen.get("_terminal_panel")
	_test.assert_true(terminal_panel != null and terminal_panel.visible, "NetworkRaceScreen exposes rematch/share results controls")
	_test.assert_true((await network_session.request_rematch_async())["ok"], "guest submits bounded rematch request through production session")
	var requested := await _wait_for_race_event_type(host, "rematch_requested")
	_test.assert_true(requested["ok"], "real authority relays guest rematch intent to host")
	_test.assert_true((await host.request_rematch(room_code))["ok"], "host rematch restart reaches real authority")
	var session_ready := await _wait_for_session_state(network_session, "READY")
	_test.assert_true(session_ready["ok"], "real rematch returns persistent session to READY")
	if session_ready["ok"]:
		_test.assert_true(bool(session_ready["value"].get("join_locked", false)), "real rematch preserves explicit grid lock")
		for member in session_ready["value"].get("members", []):
			_test.assert_false(bool(member.get("ready", false)), "real rematch resets ready acknowledgement")
	race_screen.queue_free()
	await process_frame
	race_screen = null
	definition = null
	compiled = null
	track_fixture.clear()
	await process_frame

	var left: Dictionary = await guest.leave_room(room_code)
	_test.assert_true(left["ok"], "voluntary leave is acknowledged through authoritative RPC")
	var departed: Dictionary = await _wait_for_race_event_type(host, "peer_departed")
	_test.assert_true(departed["ok"], "remaining peer observes permanent departure")
	var host_alone: Dictionary = await _wait_for_room_count(host, 1)
	_test.assert_true(host_alone["ok"], "voluntary departure immediately releases the room slot")
	_test.assert_true((await host.leave_room(room_code))["ok"], "host can close the completed E2E room cleanly")

	var kick_created: Dictionary = await host.create_private_room("Kick Host")
	_test.assert_true(kick_created["ok"], "real kick fixture creates a fresh private room")
	if kick_created["ok"]:
		var kick_code := str(kick_created["value"].get("room_code", ""))
		await host.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG)
		var kick_joined: Dictionary = await guest.join_private_room(kick_code, "Kick Guest")
		_test.assert_true(kick_joined["ok"], "real kick fixture admits its guest before removal")
		if kick_joined["ok"]:
			await guest.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG)
			_test.assert_true(
				(await host.kick_member(kick_code, guest.session_user_id()))["ok"],
				"real host kick request reaches authoritative match"
			)
			var kicked_notice: Dictionary = await guest.wait_for_opcode_async(ProtocolType.OP_ROOM_ENDED)
			_test.assert_true(kicked_notice["ok"], "real kicked client receives a terminal room notice")
			if kicked_notice["ok"]:
				_test.assert_equal(
					str(kicked_notice["value"]["payload"].get("reason", "")),
					"kicked_by_host",
					"real kick terminal reason is explicit"
				)
			var kick_rejoin: Dictionary = await guest.join_private_room(kick_code, "Kick Guest")
			_test.assert_false(kick_rejoin["ok"], "real kicked identity cannot reuse the retained invite")
			if not kick_rejoin["ok"]:
				_test.assert_equal(
					str(kick_rejoin["error"].get("code", "")),
					"kicked_from_room",
					"real kicked-room ban returns a stable refusal code"
				)
		await host.leave_room(kick_code)

	await _finish(host, guest, host_root, guest_root)


func _wait_for_room_count(transport: RefCounted, count: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG, 500)
		if event["ok"] and int(event["value"]["payload"].get("member_count", -1)) == count:
			return event
	return {"ok": false, "error": {"code": "room_count_timeout"}}


func _wait_for_session_state(session: PrivateMultiplayerSession, state: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var snapshot := session.public_snapshot()
		if str(snapshot.get("state", "")) == state:
			return {"ok": true, "value": snapshot}
		await process_frame
	return {"ok": false, "error": {"code": "session_state_timeout", "expected": state}}


func _wait_for_room_state(transport: RefCounted, state: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG, 500)
		if event["ok"] and str(event["value"]["payload"].get("state", "")) == state:
			return event
	return {"ok": false, "error": {"code": "room_state_timeout"}}


func _wait_for_race_config(transport: RefCounted, laps: int, collisions: bool) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG, 500)
		var config: Variant = event.get("value", {}).get("payload", {}).get("race_config") if event.get("ok", false) else null
		if config is Dictionary and int(config.get("laps", -1)) == laps \
				and typeof(config.get("collisions")) == TYPE_BOOL and bool(config["collisions"]) == collisions:
			return event
	return {"ok": false, "error": {"code": "race_config_timeout"}}


func _wait_for_room_lock(transport: RefCounted, locked: bool) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_ROOM_CONFIG, 500)
		if event["ok"] and typeof(event["value"]["payload"].get("join_locked")) == TYPE_BOOL \
				and bool(event["value"]["payload"]["join_locked"]) == locked:
			return event
	return {"ok": false, "error": {"code": "room_lock_timeout"}}


func _wait_for_error_code(transport: RefCounted, code: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_ERROR, 500)
		if event["ok"] and str(event["value"]["payload"].get("code", "")) == code:
			return event
	return {"ok": false, "error": {"code": "error_code_timeout", "expected": code}}


func _wait_for_race_event_type(transport: RefCounted, event_type: String) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(ProtocolType.OP_RACE_EVENT, 500)
		if event["ok"] and str(event["value"]["payload"].get("type", "")) == event_type:
			return event
	return {"ok": false, "error": {"code": "race_event_timeout", "expected": event_type}}


func _track_fixture_builder_path() -> String:
	return "/".join(PackedStringArray([
		"res:", "", "tests", "network", "support", "nakama_track_fixture.gd",
	]))


func _generation_report(manifest: Dictionary) -> Dictionary:
	return {
		"success": true,
		"source_hash": manifest["source_hash"],
		"generator_version": manifest["generator_version"],
		"compiled_fingerprint": manifest["compiled_fingerprint"],
	}


func _car_state(slot: int, x_q: int) -> Dictionary:
	return {
		"slot": slot,
		"x_q": x_q,
		"y_q": 0,
		"rotation_q": 0,
		"velocity_x_q": 0,
		"velocity_y_q": 0,
		"lap": 0,
		"checkpoint": 0,
		"collision_layer": 1,
		"collision_mask": 1,
		"flags": 0,
		"gear": 5,
		"engine_rpm_q": 108_500,
		"shift_ticks": 3,
		"steering_q": -4200,
		"slip_angle_q": 910,
		"wheel_slip_q": 1250,
		"lateral_accel_q": -318_000,
		"contact_serial": 3,
		"contact_tick": 12,
		"contact_speed_q": 72_500,
		"contact_x_q": 250_000,
		"contact_y_q": -125_000,
		"contact_normal_x_q": 6000,
		"contact_normal_y_q": 8000,
	}


func _finish(host: RefCounted, guest: RefCounted, host_root: Node, guest_root: Node) -> void:
	var network_session: PrivateMultiplayerSession = get_root().get_node_or_null("NetworkSession")
	if network_session != null:
		network_session.reset_session(false)
		network_session.set("transport", null)
	host.close()
	guest.close()
	host_root.queue_free()
	guest_root.queue_free()
	var audio := get_root().get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
		await create_timer(0.16, true, false, true).timeout
		audio.free()
	# Let the official SDK's queued HTTP/WebSocket adapter teardown complete
	# before this one-shot SceneTree exits, otherwise Godot reports false leaks.
	await process_frame
	await process_frame
	var result: Dictionary = _test.result("nakama_real_backend_e2e")
	if result["passed"]:
		print("PASS %s (%d assertions)" % [result["suite"], result["assertions"]])
	else:
		print("FAIL %s" % result["suite"])
		for failure in result["failures"]:
			print("  - %s" % failure)
	print("Nakama E2E: %d assertions, %d failures" % [result["assertions"], result["failures"].size()])
	var exit_code := 0 if result["passed"] else 1
	_test = null
	call_deferred("_quit_after_cleanup", exit_code)


func _nakama_port() -> int:
	var raw := OS.get_environment("RACEGLYPH_TEST_NAKAMA_PORT").strip_edges()
	if raw.is_valid_int():
		var port := int(raw)
		if port >= 1024 and port <= 65535:
			return port
	return 7350


func _quit_after_cleanup(exit_code: int) -> void:
	quit(exit_code)
