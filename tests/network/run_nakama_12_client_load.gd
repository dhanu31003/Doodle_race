extends Node
## Real local-only 12-client Nakama cloud-authority/load smoke.
## The shell runner owns an isolated disposable Compose stack.

const TestCaseType := preload("res://tests/support/test_case.gd")
const AdapterType := preload("res://tests/network/support/local_nakama_load_peer.gd")
const Limits := preload("res://game/network/network_limits.gd")

const CLIENT_COUNT := 12
const PROTOCOL := Limits.PROTOCOL_VERSION
const OVERFLOW_CLIENT_INDEX := 12
const INPUTS_PER_GUEST := 5
const SNAPSHOT_BROADCASTS := 3
const LOCAL_SERVER_KEY := "CHANGE_ME_LOCAL_SERVER_KEY_32_CHARS"
const OP_ROOM_CONFIG := 2
const OP_TRACK_MANIFEST := 3
const OP_START_AT_TICK := 7
const OP_INPUT_FRAME := 8
const OP_STATE_SNAPSHOT := 9
const OP_RACE_EVENT := 10
const OP_ERROR := 15

var _test: RefCounted
var _clients: Array[RefCounted] = []
var _client_roots: Array[Node] = []
var _started_at_ms := 0
var _authentication_count := 0
var _admission_count := 0
var _overflow_refusal_count := 0
var _input_submission_count := 0
var _snapshot_delivery_count := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_started_at_ms = Time.get_ticks_msec()
	_test = TestCaseType.new()
	var port := _local_port()
	_test.assert_true(port > 0, "local Nakama test port must be explicitly provided")
	if port <= 0:
		await _finish()
		return

	for client_index in range(CLIENT_COUNT + 1):
		var client_root := Node.new()
		client_root.name = "LoadClient%02d" % client_index
		add_child(client_root)
		_client_roots.append(client_root)
		var client := AdapterType.new()
		_clients.append(client)
		var authenticated: Dictionary = await client.authenticate_device_async(
			client_root,
			"rg-load-%02d-device-unique-00000000" % client_index,
			"Load Driver %02d" % (client_index + 1),
			"127.0.0.1",
			port,
			LOCAL_SERVER_KEY
		)
		_test.assert_true(authenticated["ok"], "client %d must device-authenticate" % client_index)
		if not authenticated["ok"]:
			await _finish()
			return
		_authentication_count += 1

	var host: RefCounted = _clients[0]
	var created: Dictionary = await host.create_private_room("Load Driver 01")
	_test.assert_true(created["ok"], "host must create the authoritative load room")
	if not created["ok"]:
		await _finish()
		return
	_admission_count += 1
	var room_code := str(created["value"].get("room_code", ""))
	_test.assert_equal(room_code.length(), 6, "load room code length")

	for client_index in range(1, CLIENT_COUNT):
		var joined: Dictionary = await _clients[client_index].join_private_room(
			room_code, "Load Driver %02d" % (client_index + 1)
		)
		_test.assert_true(joined["ok"], "client %d must join the 12-seat room" % client_index)
		if not joined["ok"]:
			await _finish()
			return
		_admission_count += 1

	var full_room: Dictionary = await _wait_for_room_count(host, CLIENT_COUNT, 8000)
	_test.assert_true(full_room["ok"], "host must observe all 12 admitted clients")
	if full_room["ok"]:
		var members: Array = full_room["value"]["payload"].get("members", [])
		_test.assert_equal(members.size(), CLIENT_COUNT, "authoritative roster must contain 12 members")
		_test.assert_equal(_unique_roster_slots(members), CLIENT_COUNT, "all 12 roster slots must be unique")

	var overflow: Dictionary = await _clients[OVERFLOW_CLIENT_INDEX].join_private_room(
		room_code, "Overflow Driver"
	)
	_test.assert_false(overflow["ok"], "a thirteenth authenticated client must be refused")
	if not overflow["ok"]:
		_overflow_refusal_count += 1
		_test.assert_equal(_error_code(overflow), "room_full", "full-room refusal code must be stable")

	var manifest := _compiled_manifest()
	var report := _generation_report(manifest)
	var manifest_send: Dictionary = await host.submit_track_manifest(room_code, manifest)
	_test.assert_true(manifest_send["ok"], "host must submit the canonical load track")
	for client_index in range(CLIENT_COUNT):
		var manifest_event: Dictionary = await _clients[client_index].wait_for_opcode_async(
			OP_TRACK_MANIFEST, 6000
		)
		_test.assert_true(manifest_event["ok"], "client %d must receive the verified track" % client_index)

	for client_index in range(CLIENT_COUNT):
		var generated: Dictionary = await _clients[client_index].submit_generation_report(room_code, report)
		_test.assert_true(generated["ok"], "client %d generation report must be queued" % client_index)
	var generated_ready: Dictionary = await _wait_for_room_state(host, "READY", 8000)
	_test.assert_true(generated_ready["ok"], "all 12 generation reports must move the room to READY")
	_test.assert_true((await host.set_room_lock(room_code, true))["ok"], "host lock request must reach authoritative grid")

	for client_index in range(CLIENT_COUNT - 1):
		var ready_send: Dictionary = await _clients[client_index].set_ready(room_code, true)
		_test.assert_true(ready_send["ok"], "client %d ready state must be queued" % client_index)
	var early_start: Dictionary = await host.start_countdown(room_code)
	_test.assert_true(early_start["ok"], "premature start request must reach server-side gating")
	var early_refusal: Dictionary = await _wait_for_error_code(host, "players_not_ready", 5000)
	_test.assert_true(early_refusal["ok"], "authority must refuse start while one of 12 clients is not ready")

	var final_ready: Dictionary = await _clients[CLIENT_COUNT - 1].set_ready(room_code, true)
	_test.assert_true(final_ready["ok"], "twelfth ready state must be queued")
	var all_ready: Dictionary = await _wait_for_all_ready(host, CLIENT_COUNT, 8000)
	_test.assert_true(all_ready["ok"], "authoritative roster must show all 12 clients ready")
	if not all_ready["ok"]:
		await _finish()
		return

	var start_send: Dictionary = await host.start_countdown(room_code)
	_test.assert_true(start_send["ok"], "fully ready host start request must be queued")
	var start_tick := -1
	for client_index in range(CLIENT_COUNT):
		var countdown: Dictionary = await _clients[client_index].wait_for_opcode_async(
			OP_START_AT_TICK, 6000
		)
		_test.assert_true(countdown["ok"], "client %d must receive synchronized countdown" % client_index)
		if countdown["ok"]:
			var peer_start_tick := int(countdown["value"]["payload"].get("start_tick", -1))
			if start_tick < 0:
				start_tick = peer_start_tick
			_test.assert_equal(peer_start_tick, start_tick, "all countdowns must share one simulation tick")
	_test.assert_true(start_tick >= 0, "countdown must contain a non-negative start tick")

	await get_tree().create_timer(3.2).timeout
	var race_tick := -1
	for client_index in range(CLIENT_COUNT):
		var race_started: Dictionary = await _wait_for_race_event_type(
			_clients[client_index], "race_started", 6000
		)
		_test.assert_true(race_started["ok"], "client %d must observe authoritative race start" % client_index)
		if race_started["ok"]:
			var peer_race_tick := int(race_started["value"]["payload"].get("tick", -1))
			if race_tick < 0:
				race_tick = peer_race_tick
			_test.assert_equal(peer_race_tick, race_tick, "all clients must observe one race-start tick")
	if race_tick < 0:
		await _finish()
		return
	# Discard countdown-era snapshots so measured deliveries are definitely
	# produced after the input burst below.
	for client_index in range(CLIENT_COUNT):
		for event in _clients[client_index].drain_events():
			_test.assert_false(
				int(event.get("opcode", -1)) == OP_ERROR,
				"client %d must enter cloud simulation without an authority error" % client_index
			)

	for client_index in range(1, CLIENT_COUNT):
		var guest: RefCounted = _clients[client_index]
		for sequence in range(INPUTS_PER_GUEST):
			var input_tick := maxi(race_tick, guest.last_server_tick())
			var input := _make_envelope(
				OP_INPUT_FRAME,
				guest.session_user_id(),
				sequence + 1,
				guest.room_epoch(),
				{
					"steering": (client_index * 137 + sequence * 41) % 2001 - 1000,
					"throttle": 700 + sequence * 50,
					"brake": 0,
					"boost": false,
					"ack_host_tick": input_tick,
				},
				input_tick
			)
			var queued: Dictionary = await guest.send_envelope(room_code, input)
			_test.assert_true(queued["ok"], "guest %d input %d must queue" % [client_index, sequence])
			if queued["ok"]:
				_input_submission_count += 1

	var expected_inputs := (CLIENT_COUNT - 1) * INPUTS_PER_GUEST
	_test.assert_equal(_input_submission_count, expected_inputs, "all bounded mobile inputs must reach cloud authority")
	await get_tree().create_timer(0.10).timeout
	# Measure only snapshots emitted after Nakama has consumed the complete input
	# burst; earlier queued zero-speed start frames are not load evidence.
	for client_index in range(CLIENT_COUNT):
		for event in _clients[client_index].drain_events():
			_test.assert_false(
				int(event.get("opcode", -1)) == OP_ERROR,
				"client %d input burst must produce no cloud authority error" % client_index
			)

	var observed_motion := false
	for client_index in range(CLIENT_COUNT):
		for sequence in range(SNAPSHOT_BROADCASTS):
			var delivered: Dictionary = await _clients[client_index].wait_for_opcode_async(
				OP_STATE_SNAPSHOT, 6000
			)
			_test.assert_true(delivered["ok"], "client %d must receive cloud snapshot %d" % [client_index, sequence])
			if delivered["ok"]:
				_snapshot_delivery_count += 1
				_test.assert_equal(str(delivered["value"].get("sender_id", "")), "server", "snapshot authority must be the cloud")
				_test.assert_equal(
					delivered["value"]["payload"].get("cars", []).size(),
					CLIENT_COUNT,
					"each snapshot must preserve all 12 car states"
				)
				for car in delivered["value"]["payload"].get("cars", []):
					if int(car.get("slot", -1)) > 0 \
							and (absi(int(car.get("velocity_x_q", 0))) > 0 or absi(int(car.get("velocity_y_q", 0))) > 0):
						observed_motion = true
	var expected_snapshot_deliveries := CLIENT_COUNT * SNAPSHOT_BROADCASTS
	_test.assert_equal(
		_snapshot_delivery_count,
		expected_snapshot_deliveries,
		"all cloud snapshot fan-out deliveries must arrive"
	)
	_test.assert_true(observed_motion, "cloud simulation must apply submitted throttle to the mobile field")

	for client_index in range(CLIENT_COUNT):
		for event in _clients[client_index].drain_events():
			_test.assert_false(
				int(event.get("opcode", -1)) == OP_ERROR,
				"admitted client %d must have no unconsumed authority error" % client_index
			)
	await _finish()


func _local_port() -> int:
	var raw := OS.get_environment("RACEGLYPH_TEST_NAKAMA_PORT").strip_edges()
	if raw.is_empty() or not raw.is_valid_int():
		return -1
	var port := int(raw)
	return port if port >= 1024 and port <= 65535 else -1


func _wait_for_room_count(transport: RefCounted, count: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(OP_ROOM_CONFIG, 500)
		if event["ok"] and int(event["value"]["payload"].get("member_count", -1)) == count:
			return event
	return {"ok": false, "error": {"code": "room_count_timeout"}}


func _wait_for_room_state(transport: RefCounted, state: String, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(OP_ROOM_CONFIG, 500)
		if event["ok"] and str(event["value"]["payload"].get("state", "")) == state:
			return event
	return {"ok": false, "error": {"code": "room_state_timeout"}}


func _wait_for_all_ready(transport: RefCounted, count: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(OP_ROOM_CONFIG, 500)
		if not event["ok"]:
			continue
		var members: Array = event["value"]["payload"].get("members", [])
		if members.size() != count:
			continue
		var ready_count := 0
		for member in members:
			if bool(member.get("connected", false)) and bool(member.get("generation_verified", false)) \
					and bool(member.get("ready", false)):
				ready_count += 1
		if ready_count == count:
			return event
	return {"ok": false, "error": {"code": "all_ready_timeout"}}


func _wait_for_error_code(transport: RefCounted, code: String, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(OP_ERROR, 500)
		if event["ok"] and str(event["value"]["payload"].get("code", "")) == code:
			return event
	return {"ok": false, "error": {"code": "error_code_timeout", "expected": code}}


func _wait_for_race_event_type(transport: RefCounted, event_type: String, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		var event: Dictionary = await transport.wait_for_opcode_async(OP_RACE_EVENT, 500)
		if event["ok"] and str(event["value"]["payload"].get("type", "")) == event_type:
			return event
	return {"ok": false, "error": {"code": "race_event_timeout", "expected": event_type}}


func _unique_roster_slots(members: Array) -> int:
	var slots: Dictionary = {}
	for member in members:
		slots[int(member.get("slot", -1))] = true
	return slots.size()


func _error_code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))


func _make_envelope(
		opcode: int,
		sender_id: String,
		sequence: int,
		room_epoch: int,
		payload: Dictionary,
		tick: int
	) -> Dictionary:
	return {
		"protocol": PROTOCOL,
		"opcode": opcode,
		"room_epoch": room_epoch,
		"sender_id": sender_id,
		"seq": sequence,
		"tick": tick,
		"payload": payload,
	}


func _compiled_manifest() -> Dictionary:
	var source_hash := "f04a1a8b52de6714af5c29ac9be02656c9cb8944be730e107655ca4f5f5e110a"
	return {
		"track_definition": {
			"schema_version": 2,
			"generator_version": 3,
			"track_id": "nakama-stadium",
			"track_name": "Nakama Stadium",
			"author_id": "",
			"canvas_size": [1920, 1080],
			"control_points": [
				[0.20000000298023224, 0.3499999940395355],
				[0.3499999940395355, 0.20000000298023224],
				[0.6499999761581421, 0.20000000298023224],
				[0.800000011920929, 0.3499999940395355],
				[0.800000011920929, 0.6499999761581421],
				[0.6499999761581421, 0.800000011920929],
				[0.3499999940395355, 0.800000011920929],
				[0.20000000298023224, 0.6499999761581421],
			],
			"direction": "clockwise",
			"target_length": 1200,
			"track_width": 72,
			"theme": "classic",
			"road_surface": "smooth_asphalt",
			"pit_side": "none",
			"decoration_density": 0.5,
			"deterministic_seed": "42",
			"bridge_crossings": [],
			"start_finish_distance": 0,
			"content_hash": source_hash,
			"created_at_timestamp": 0,
			"updated_at_timestamp": 0,
		},
		"source_hash": source_hash,
		"generator_version": 3,
		"compiled_fingerprint": "e90dedcf44ba60445ad6bc75fe210d6ec4d3e7431d960ff1241b805f7a6448f6",
		"authority_path": {
			"scale": 1000,
			"centerline_q": [
				[0, 0], [220000, -180000], [620000, -180000], [840000, 0],
				[840000, 420000], [620000, 600000], [220000, 600000], [0, 420000],
			],
			"elevation_q": [0, 0, 0, 0, 0, 0, 0, 0],
			"track_width_q": 72000,
			"total_length_q": 2400000,
			"start_finish_distance_q": 0,
			"road_surface": "smooth_asphalt",
			"deterministic_seed": "42",
			"path_hash": "bb0b8ea0a437a948a596c650364ac96370f664e76a0268af0edcae207329a3f8",
		},
	}


func _generation_report(manifest: Dictionary) -> Dictionary:
	return {
		"success": true,
		"source_hash": manifest["source_hash"],
		"generator_version": manifest["generator_version"],
		"compiled_fingerprint": manifest["compiled_fingerprint"],
	}


func _car_states(count: int) -> Array:
	var cars: Array = []
	for slot in range(count):
		cars.append({
			"slot": slot,
			"x_q": slot * 1000,
			"y_q": -slot * 200,
			"rotation_q": 0,
			"velocity_x_q": 12500,
			"velocity_y_q": 0,
			"lap": 0,
			"checkpoint": 0,
			"collision_layer": 1,
			"collision_mask": 1,
			"flags": 0,
		})
	return cars


func _finish() -> void:
	var elapsed_ms := Time.get_ticks_msec() - _started_at_ms
	var result: Dictionary = _test.result("nakama_real_12_client_load")
	if result["passed"]:
		print("PASS %s (%d assertions)" % [result["suite"], result["assertions"]])
	else:
		print("FAIL %s" % result["suite"])
		for failure in result["failures"]:
			print("  - %s" % failure)
	print(
		"LOAD_METRICS protocol=%d clients=%d authentications=%d admissions=%d overflow_refusals=%d inputs_submitted=%d snapshot_deliveries=%d elapsed_ms=%d" % [
			PROTOCOL,
			CLIENT_COUNT,
			_authentication_count,
			_admission_count,
			_overflow_refusal_count,
			_input_submission_count,
			_snapshot_delivery_count,
			elapsed_ms,
		]
	)
	var exit_code := 0 if result["passed"] else 1
	for client in _clients:
		client.close()
	_clients.clear()
	for client_root in _client_roots:
		if is_instance_valid(client_root):
			client_root.queue_free()
	_client_roots.clear()
	_test = null
	for _frame in range(12):
		await get_tree().process_frame
	get_tree().quit(exit_code)
