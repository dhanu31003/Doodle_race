extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const ServerType := preload("res://game/network/fake_room_server.gd")
const TransportType := preload("res://game/network/in_memory_transport.gd")
const RuntimeType := preload("res://game/network/client/network_race_runtime.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const ManifestType := preload("res://game/network/network_track_manifest.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const LimitsType := preload("res://game/network/network_limits.gd")
const CodecType := preload("res://game/network/client/network_race_codec.gd")
const NetworkRaceScreenType := preload("res://game/ui/screens/network_race_screen.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	test.assert_near(NetworkRaceScreenType.touch_control_lift_px(0.0), 0.0, 0.001, "network controls preserve baseline at zero reach offset")
	test.assert_near(NetworkRaceScreenType.touch_control_lift_px(1.0), 96.0, 0.001, "network controls honor full ninety-six-pixel reach lift")
	test.assert_near(NetworkRaceScreenType.touch_control_lift_px(INF), 0.0, 0.001, "network controls reject non-finite reach offset")
	test.assert_equal(NetworkRaceScreenType.sector_hud_text(2, 65.432, true), "S2  01:05.432", "network host sector timing is labeled as authoritative")
	test.assert_true(NetworkRaceScreenType.sector_hud_text(4, INF, false).contains("S3  00:00.000  LOCAL"), "network guest sector timing is bounded and explicitly local")
	var shared := NetworkRaceScreenType.classification_share_text([
		{"player_id": "internal-host-id", "position": 1, "status": "finished", "finish_time_ms": 90123},
		{"player_id": "internal-guest-id", "position": 2, "status": "dnf", "finish_time_ms": 0},
	], [
		{"player_id": "internal-host-id", "display_name": "NOVA"},
		{"player_id": "internal-guest-id", "display_name": "APEX"},
	])
	test.assert_true(shared.contains("NOVA") and shared.contains("APEX") and shared.contains("P1"), "local classification share includes display names and standings")
	test.assert_false(shared.contains("internal-host-id") or shared.contains("internal-guest-id") or shared.contains("ROOM"), "local classification share excludes room and peer identifiers")
	test.assert_true(NetworkRaceScreenType.history_persistence_failure_text({"ok": false, "message": "Disk is read-only"}).begins_with("LOCAL HISTORY NOT SAVED"), "results persistence failure is explicit in terminal UI")
	test.assert_equal(NetworkRaceScreenType.history_persistence_failure_text({"ok": true}), "", "successful results persistence emits no false warning")
	_test_formula_dynamics_snapshot_round_trip(test)
	_test_contact_event_survives_guest_paths(test)
	_test_two_client_authority_prediction_and_leave(test)
	_test_bridge_snapshot_reconciliation(test)
	_test_recovery_parity_forces_two_hard_snaps(test)
	_test_deterministic_loss_jitter_and_reordering(test)
	return test.result("network_race_runtime")


func _test_formula_dynamics_snapshot_round_trip(test: RefCounted) -> void:
	var item := CatalogType.all()[0]
	var compiled: TrackCompileResult = CompilerType.compile(item["definition"])
	var roster := [
		{"player_id": "formula-host", "display_name": "Host", "slot": 0},
		{"player_id": "formula-guest", "display_name": "Guest", "slot": 1},
	]
	var source := RuntimeType.new()
	var target := RuntimeType.new()
	test.assert_true(source.configure(
		compiled.track, roster, "formula-host", "formula-host", "FORMU1", 1, 10
	)["ok"], "Formula snapshot source configures")
	test.assert_true(target.configure(
		compiled.track, roster, "formula-guest", "formula-host", "FORMU1", 1, 10
	)["ok"], "Formula snapshot target configures")
	var source_state := source.local_entry.state
	source_state.gear = 6
	source_state.engine_rpm = 10_850.0
	source_state.shift_ticks_remaining = 3
	source_state.steering_input = -0.42
	source_state.slip_angle = 0.091
	source_state.wheel_slip = 0.125
	source_state.lateral_acceleration = -318.0
	source_state.vertical_offset_meters = 0.325
	source_state.vertical_velocity_mps = -1.2
	source_state.is_grounded = false
	source_state.vehicle_contact_serial = 17
	source_state.vehicle_contact_tick = 83
	source_state.vehicle_contact_speed = 74.125
	source_state.vehicle_contact_position = Vector2(321.25, -87.5)
	source_state.vehicle_contact_normal = Vector2(0.6, 0.8)
	source_state.vehicle_contact_other_id = &"formula-guest"
	var car := CodecType.car_from_entry(source.local_entry, 0)
	test.assert_true(
		CodecType.apply_car_to_entry(car, target.local_entry, target.track),
		"Formula snapshot applies to a remote entry"
	)
	var restored := target.local_entry.state
	test.assert_equal(restored.gear, 6, "network snapshot round-trips current gear")
	test.assert_near(restored.engine_rpm, 10_850.0, 0.1, "network snapshot round-trips engine RPM")
	test.assert_equal(restored.shift_ticks_remaining, 3, "network snapshot round-trips shift torque-cut state")
	test.assert_near(restored.steering_input, -0.42, 0.0001, "network snapshot round-trips physical rack position")
	test.assert_near(restored.slip_angle, 0.091, 0.0001, "network snapshot round-trips tyre slip angle")
	test.assert_near(restored.wheel_slip, 0.125, 0.0001, "network snapshot round-trips driven-wheel slip")
	test.assert_near(restored.lateral_acceleration, -318.0, 0.001, "network snapshot round-trips lateral load")
	test.assert_near(restored.vertical_offset_meters, 0.325, 0.0001, "network snapshot round-trips airborne height")
	test.assert_near(restored.vertical_velocity_mps, -1.2, 0.0001, "network snapshot round-trips vertical velocity")
	test.assert_false(restored.is_grounded, "network snapshot round-trips the airborne authority flag")
	test.assert_equal(restored.vehicle_contact_serial, 17, "network snapshot round-trips contact serial")
	test.assert_equal(restored.vehicle_contact_tick, 83, "network snapshot round-trips contact tick")
	test.assert_near(restored.vehicle_contact_speed, 74.125, 0.001, "network snapshot round-trips impact speed")
	test.assert_near(restored.vehicle_contact_position.distance_to(Vector2(321.25, -87.5)), 0.0, 0.0001, "network snapshot round-trips impact position")
	test.assert_near(restored.vehicle_contact_normal.distance_to(Vector2(0.6, 0.8)), 0.0, 0.0001, "network snapshot round-trips impact normal")
	test.assert_equal(restored.vehicle_contact_other_id, &"", "wire contact omits peer identity instead of trusting an unbound id")

	var legacy := car.duplicate(true)
	for field in CodecType.DYNAMICS_FIELDS:
		legacy.erase(field)
	for field in CodecType.AIRBORNE_FIELDS:
		legacy.erase(field)
	for field in CodecType.CONTACT_FIELDS:
		legacy.erase(field)
	restored.gear = 8
	restored.engine_rpm = 12_000.0
	restored.steering_input = 1.0
	restored.slip_angle = 0.5
	restored.wheel_slip = 1.0
	restored.lateral_acceleration = 500.0
	restored.vertical_offset_meters = 1.0
	restored.vertical_velocity_mps = -2.0
	restored.is_grounded = false
	restored.vehicle_contact_serial = 99
	restored.vehicle_contact_tick = 99
	restored.vehicle_contact_speed = 99.0
	restored.vehicle_contact_position = Vector2.ONE
	restored.vehicle_contact_normal = Vector2.UP
	test.assert_true(
		CodecType.apply_car_to_entry(legacy, target.local_entry, target.track),
		"legacy snapshot remains applicable"
	)
	test.assert_equal(restored.gear, 1, "legacy snapshot selects the explicit first-gear compatibility default")
	test.assert_near(restored.engine_rpm, 4500.0, 0.1, "legacy snapshot selects the explicit idle-RPM compatibility default")
	test.assert_near(restored.steering_input, 0.0, 0.0001, "legacy snapshot centers the rack by default")
	test.assert_near(restored.slip_angle, 0.0, 0.0001, "legacy snapshot clears unavailable slip telemetry")
	test.assert_near(restored.wheel_slip, 0.0, 0.0001, "legacy snapshot clears unavailable wheel-slip telemetry")
	test.assert_near(restored.lateral_acceleration, 0.0, 0.001, "legacy snapshot clears unavailable lateral-load telemetry")
	test.assert_near(restored.vertical_offset_meters, 0.0, 0.0001, "legacy snapshot clears unavailable airborne height")
	test.assert_near(restored.vertical_velocity_mps, 0.0, 0.0001, "legacy snapshot clears unavailable vertical velocity")
	test.assert_true(restored.is_grounded, "legacy snapshot selects the safe grounded compatibility default")
	test.assert_equal(restored.vehicle_contact_serial, 0, "legacy snapshot selects the explicit no-contact serial default")
	test.assert_equal(restored.vehicle_contact_tick, -1, "legacy snapshot selects the explicit no-contact tick default")
	test.assert_near(restored.vehicle_contact_speed, 0.0, 0.001, "legacy snapshot clears unavailable contact speed")
	test.assert_equal(restored.vehicle_contact_position, Vector2.ZERO, "legacy snapshot clears unavailable contact position")
	test.assert_equal(restored.vehicle_contact_normal, Vector2.RIGHT, "legacy snapshot selects a finite default contact normal")


func _test_contact_event_survives_guest_paths(test: RefCounted) -> void:
	var item := CatalogType.all()[0]
	var compiled: TrackCompileResult = CompilerType.compile(item["definition"])
	var roster := [
		{"player_id": "contact-host", "display_name": "Host", "slot": 0},
		{"player_id": "contact-guest", "display_name": "Guest", "slot": 1},
	]
	var runtime := RuntimeType.new()
	test.assert_true(runtime.configure(
		compiled.track, roster, "contact-guest", "contact-host", "IMPACT", 1, 10
	)["ok"], "contact guest runtime configures")
	test.assert_true(runtime.begin(10), "contact guest runtime begins")
	# Establish unacknowledged prediction history; the host event must survive
	# replay from its older authoritative tick instead of being overwritten by
	# the guest's collision-free local prediction.
	runtime.advance_frame(3.0 / 60.0, RaceInputType.new(0.0, 1.0, 0.0))
	var local_car := CodecType.car_from_entry(runtime.local_entry, 1)
	var remote_entry = runtime.director.entry(&"contact-host")
	var remote_car := CodecType.car_from_entry(remote_entry, 0)
	local_car.merge(_contact_bundle(4, 1, 82_500, 250_000, 125_000, 6000, 8000), true)
	remote_car.merge(_contact_bundle(7, 1, 45_250, 252_000, 126_000, -6000, -8000), true)
	var snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT,
		"contact-host",
		1,
		1,
		{"cars": [remote_car, local_car]},
		11
	)
	test.assert_true(runtime.handle_event(snapshot)["ok"], "guest accepts a complete bounded contact event bundle")
	test.assert_equal(runtime.local_entry.state.vehicle_contact_serial, 4, "local guest reconciliation retains the latest host contact serial through input replay")
	test.assert_near(runtime.local_entry.state.vehicle_contact_speed, 82.5, 0.001, "local guest reconciliation retains host impact speed")
	test.assert_equal(runtime.local_entry.previous_state.vehicle_contact_serial, 0, "local guest previous state preserves a presentation edge for the new contact")
	runtime.advance_frame(1.0 / 60.0, RaceInputType.new(0.0, 1.0, 0.0))
	test.assert_equal(runtime.local_entry.state.vehicle_contact_serial, 4, "continued guest prediction does not discard the latest host contact")
	test.assert_equal(remote_entry.state.vehicle_contact_serial, 7, "remote interpolation applies the latest host contact event")
	test.assert_near(remote_entry.state.vehicle_contact_position.distance_to(Vector2(25.2, 12.6)), 0.0, 0.0001, "remote interpolation preserves the impact position as one discrete bundle")
	test.assert_equal(remote_entry.previous_state.vehicle_contact_serial, 0, "remote interpolation preserves a presentation edge for the new contact")


func _contact_bundle(
		serial: int,
		tick: int,
		speed_q: int,
		x_q: int,
		y_q: int,
		normal_x_q: int,
		normal_y_q: int
	) -> Dictionary:
	return {
		"contact_serial": serial,
		"contact_tick": tick,
		"contact_speed_q": speed_q,
		"contact_x_q": x_q,
		"contact_y_q": y_q,
		"contact_normal_x_q": normal_x_q,
		"contact_normal_y_q": normal_y_q,
	}


func _test_bridge_snapshot_reconciliation(test: RefCounted) -> void:
	var item := CatalogType.by_id("builtin-nightfall-crossing")
	var definition: TrackDefinition = item["definition"]
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	test.assert_true(compiled.succeeded(), "bridge network fixture compiles")
	if not compiled.succeeded():
		return
	var roster := [
		{"player_id": "bridge-host", "display_name": "Host", "slot": 0},
		{"player_id": "bridge-guest", "display_name": "Guest", "slot": 1},
	]
	var runtime := RuntimeType.new()
	test.assert_true(runtime.configure(
		compiled.track, roster, "bridge-guest", "bridge-host", "BR1DGE", 1, 10
	)["ok"], "bridge guest runtime configures")
	if runtime.track == null or runtime.track.bridge_zones.is_empty():
		test.assert_true(false, "bridge guest runtime exposes the declared bridge zone")
		return
	test.assert_true(runtime.begin(10), "bridge guest runtime begins")
	var zone: Dictionary = runtime.track.bridge_zones[0]
	var overpass_distance := float(zone["overpass_distance"])
	var sample := runtime.track.sample_at_distance(overpass_distance)
	var surface := runtime.track.surface_context_at_distance(overpass_distance)
	runtime.local_entry.state.track_distance = overpass_distance
	runtime.local_entry.state.position = sample["position"]
	runtime.local_entry.state.track_collision_layer = int(surface["collision_layer"])
	runtime.local_entry.state.track_collision_mask = int(surface["collision_mask"])
	runtime.local_entry.previous_state = runtime.local_entry.state.duplicate_state()
	var car := {
		"slot": 1,
		"x_q": roundi(float(sample["position"].x) * CodecType.POSITION_SCALE),
		"y_q": roundi(float(sample["position"].y) * CodecType.POSITION_SCALE),
		"rotation_q": roundi(float(sample["tangent"].angle()) * CodecType.ROTATION_SCALE),
		"velocity_x_q": roundi(float(sample["tangent"].x) * 30.0 * CodecType.VELOCITY_SCALE),
		"velocity_y_q": roundi(float(sample["tangent"].y) * 30.0 * CodecType.VELOCITY_SCALE),
		"lap": 0,
		"checkpoint": 0,
		"collision_layer": int(surface["collision_layer"]),
		"collision_mask": int(surface["collision_mask"]),
		"flags": 0,
		"vertical_offset_q": 4000,
		"vertical_velocity_q": -10_000,
		"grounded": 0,
	}
	var snapshot := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "bridge-host", 1, 1, {"cars": [car]}, 11
	)
	test.assert_true(runtime.handle_event(snapshot)["ok"], "guest accepts elevated authoritative snapshot")
	test.assert_equal(runtime.local_entry.state.track_collision_layer, 2, "reconciliation preserves the elevated collision layer")
	test.assert_equal(runtime.local_entry.state.track_collision_mask, int(surface["collision_mask"]), "reconciliation preserves the authoritative bridge mask")
	test.assert_true(runtime.track.circular_distance(runtime.local_entry.state.track_distance, overpass_distance) < 0.5, "reconciliation remains on the contextual overpass branch")
	test.assert_true(runtime.local_entry.state.track_elevation > 0.0, "reconciliation restores deterministic bridge elevation")
	test.assert_false(runtime.local_entry.state.bridge_id.is_empty(), "reconciliation restores declared bridge identity")
	test.assert_near(runtime.local_entry.state.vertical_offset_meters, 0.4, 0.0001, "reconciliation restores authoritative airborne height")
	test.assert_near(runtime.local_entry.state.vertical_velocity_mps, -1.0, 0.0001, "reconciliation restores authoritative vertical velocity")
	test.assert_false(runtime.local_entry.state.is_grounded, "reconciliation preserves airborne state above the bridge deck")


func _test_recovery_parity_forces_two_hard_snaps(test: RefCounted) -> void:
	var item := CatalogType.all()[0]
	var compiled: TrackCompileResult = CompilerType.compile(item["definition"])
	var roster := [
		{"player_id": "recovery-host", "display_name": "Host", "slot": 0},
		{"player_id": "recovery-guest", "display_name": "Guest", "slot": 1},
	]
	var runtime := RuntimeType.new()
	test.assert_true(runtime.configure(
		compiled.track, roster, "recovery-guest", "recovery-host", "RCVRY2", 1, 10
	)["ok"], "recovery guest runtime configures")
	test.assert_true(runtime.begin(10), "recovery guest runtime begins")
	var initial := CodecType.car_from_entry(runtime.local_entry, 1)
	var first := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "recovery-host", 1, 1, {"cars": [initial]}, 11
	)
	test.assert_true(runtime.handle_event(first)["ok"], "initial recovery parity establishes a baseline")
	runtime.advance_frame(3.0 / 60.0, RaceInputType.new(0.0, 1.0, 0.0, false))
	var recovered := initial.duplicate(true)
	recovered["x_q"] = int(recovered["x_q"]) + 900_000
	recovered["flags"] = int(recovered["flags"]) | CodecType.FLAG_RECOVERY_PARITY
	var first_recovery := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "recovery-host", 2, 1, {"cars": [recovered]}, 16
	)
	test.assert_true(runtime.handle_event(first_recovery)["ok"], "first recovery parity toggle is accepted")
	test.assert_true(runtime.last_hard_reconcile, "first recovery toggle forces a hard snap independent of distance threshold")
	test.assert_near(runtime.local_entry.state.position.x, float(recovered["x_q"]) / CodecType.POSITION_SCALE, 0.0001, "first recovery hard-applies authority")
	test.assert_equal(runtime.local_entry.state.recovery_hard_snap_serial, 1, "guest recovery serial advances once")
	var repeated := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "recovery-host", 3, 1, {"cars": [recovered]}, 21
	)
	test.assert_true(runtime.handle_event(repeated)["ok"], "unchanged recovery parity accepts the next snapshot")
	test.assert_false(runtime.last_hard_reconcile, "persistent parity does not hard-snap every snapshot")
	var recovered_again := recovered.duplicate(true)
	recovered_again["x_q"] = int(recovered_again["x_q"]) - 500_000
	recovered_again["flags"] = int(recovered_again["flags"]) & ~CodecType.FLAG_RECOVERY_PARITY
	var second_recovery := ProtocolType.make_envelope(
		ProtocolType.OP_STATE_SNAPSHOT, "recovery-host", 4, 1, {"cars": [recovered_again]}, 26
	)
	test.assert_true(runtime.handle_event(second_recovery)["ok"], "second recovery parity toggle is accepted")
	test.assert_true(runtime.last_hard_reconcile, "second recovery toggle also forces a hard snap")
	test.assert_equal(runtime.local_entry.state.recovery_hard_snap_serial, 2, "two parity toggles produce exactly two recovery serial advances")


func _test_deterministic_loss_jitter_and_reordering(test: RefCounted) -> void:
	# This is a bounded deterministic process test, not a claim about real WAN,
	# radio, or physical-device behavior. It injects exact 10% packet loss and
	# 0–100 ms scheduling jitter into the same runtime/authority surfaces.
	var server := ServerType.new()
	var host_transport := TransportType.new(server, "impair-host")
	var guest_transport := TransportType.new(server, "impair-guest")
	var created: Dictionary = host_transport.create_private_room("Host")
	var code := str(created["value"]["room_code"])
	guest_transport.join_private_room(code, "Guest")
	var item := CatalogType.all()[0]
	var compiled: TrackCompileResult = CompilerType.compile(item["definition"])
	var manifest := ManifestType.build(item["definition"], compiled.track)
	host_transport.submit_track_manifest(code, manifest)
	var report := {
		"success": true,
		"source_hash": manifest["source_hash"],
		"generator_version": manifest["generator_version"],
		"compiled_fingerprint": manifest["compiled_fingerprint"],
	}
	host_transport.submit_generation_report(code, report)
	guest_transport.submit_generation_report(code, report)
	host_transport.set_ready(code, true)
	guest_transport.set_ready(code, true)
	var room: Dictionary = host_transport.room_snapshot(code)["value"]
	host_transport.set_room_lock(code, true)
	var countdown: Dictionary = host_transport.start_countdown(code)["value"]["countdown"]
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000)
	host_transport.drain_events()
	guest_transport.drain_events()
	var host_runtime := RuntimeType.new()
	var guest_runtime := RuntimeType.new()
	test.assert_true(host_runtime.configure(
		compiled.track, room["members"], "impair-host", "impair-host", code,
		int(room["room_epoch"]), int(countdown["start_tick"])
	)["ok"], "impaired host runtime configures")
	test.assert_true(guest_runtime.configure(
		compiled.track, room["members"], "impair-guest", "impair-host", code,
		int(room["room_epoch"]), int(countdown["start_tick"])
	)["ok"], "impaired guest runtime configures")
	var wire_queue: Array[Dictionary] = []
	var condition := {
		"now_ms": 0,
		"wire_serial": 0,
		"measure_loss": true,
		"blackout_inputs": false,
		"input_eligible": 0,
		"input_dropped": 0,
		"snapshot_eligible": 0,
		"snapshot_dropped": 0,
		"blackout_dropped": 0,
		"host_snapshots": 0,
		"guest_inputs": 0,
		"max_jitter_ms": 0,
		"server_rejections": [],
	}
	host_runtime.outbound_envelope.connect(func(envelope: Dictionary) -> void:
		_queue_impaired_outbound(wire_queue, condition, "host", envelope)
	)
	guest_runtime.outbound_envelope.connect(func(envelope: Dictionary) -> void:
		_queue_impaired_outbound(wire_queue, condition, "guest", envelope)
	)
	var start_tick := int(countdown["start_tick"])
	host_runtime.begin(start_tick)
	guest_runtime.begin(start_tick)
	var host_command := RaceInputType.new(-0.03, 0.84, 0.0, false)
	var guest_command := RaceInputType.new(0.06, 1.0, 0.0, false)
	for _frame in 360:
		_run_impaired_frame(
			server, host_transport, guest_transport, host_runtime, guest_runtime,
			wire_queue, condition, host_command, guest_command
		)
	test.assert_equal(int(condition["input_dropped"]), int(condition["input_eligible"]) / 10, "deterministic condition drops exactly 10% of input frames")
	test.assert_equal(int(condition["snapshot_dropped"]), int(condition["snapshot_eligible"]) / 10, "deterministic condition drops exactly 10% of snapshots")
	test.assert_true(int(condition["max_jitter_ms"]) >= 90 and int(condition["max_jitter_ms"]) <= 100, "deterministic jitter spans the bounded 0–100 ms window")
	test.assert_true(int(condition["guest_inputs"]) <= 6 * LimitsType.INPUT_SUBMISSION_MAX_HZ + 1, "impaired guest generation stays within 20 Hz cadence")
	test.assert_true(int(condition["host_snapshots"]) <= 6 * LimitsType.MAX_SNAPSHOTS_PER_SECOND + 1, "impaired host generation stays within snapshot cadence")
	var rejection_codes: Array = condition["server_rejections"]
	test.assert_true(
		"input_sequence_stale" in rejection_codes or "input_tick_out_of_order" in rejection_codes,
		"reordered input is rejected rather than applied backwards"
	)
	test.assert_true("snapshot_sequence_stale" in rejection_codes or "snapshot_tick_stale" in rejection_codes, "reordered snapshots are rejected rather than relayed backwards")
	test.assert_true(host_runtime.local_entry.state.is_finite(), "host authority remains finite under deterministic impairment")
	test.assert_true(guest_runtime.local_entry.state.is_finite(), "guest prediction remains finite under deterministic impairment")
	var authoritative_guest := host_runtime.director.entry(&"impair-guest")
	test.assert_true(authoritative_guest != null, "impaired host retains guest authority")
	if authoritative_guest != null:
		test.assert_true(guest_runtime.local_entry.state.position.distance_to(authoritative_guest.state.position) < 18.0, "guest prediction/reconciliation remains spatially bounded under impairment")

	test.assert_true(RuntimeType.remote_input_within_hold(112, 100), "host holds the latest remote command through the documented 12-tick grace")
	test.assert_false(RuntimeType.remote_input_within_hold(113, 100), "host switches to neutral immediately after the 12-tick grace")
	test.assert_true(host_runtime.remote_input_active("impair-guest"), "host is applying a recent guest command before the blackout")
	condition["measure_loss"] = false
	condition["blackout_inputs"] = true
	var speed_before_blackout := authoritative_guest.state.speed() if authoritative_guest != null else 0.0
	for _frame in 48:
		_run_impaired_frame(
			server, host_transport, guest_transport, host_runtime, guest_runtime,
			wire_queue, condition, host_command, guest_command
		)
	var speed_after_blackout := authoritative_guest.state.speed() if authoritative_guest != null else 0.0
	test.assert_true(int(condition["blackout_dropped"]) > 0, "bounded blackout actually withholds guest input")
	test.assert_false(host_runtime.remote_input_active("impair-guest"), "host applies neutral after the bounded input hold expires")
	test.assert_true(speed_after_blackout <= speed_before_blackout + 8.0, "neutral fallback prevents continued full-throttle acceleration")
	condition["blackout_inputs"] = false
	host_runtime.director.race_time_limit = host_runtime.director.race_time + 0.15
	for _frame in 120:
		_run_impaired_frame(
			server, host_transport, guest_transport, host_runtime, guest_runtime,
			wire_queue, condition, host_command, RaceInputType.new()
		)
		if host_runtime.finished and guest_runtime.finished:
			break
	test.assert_true(host_runtime.finished, "impaired host reaches a finite terminal classification")
	test.assert_true(guest_runtime.finished and guest_runtime.results().size() == 2, "reliable terminal results arrive after lossy sequenced traffic")


func _queue_impaired_outbound(
		queue: Array[Dictionary], condition: Dictionary, source: String, envelope: Dictionary
	) -> void:
	var opcode := int(envelope.get("opcode", -1))
	var is_input := opcode == ProtocolType.OP_INPUT_FRAME
	var is_snapshot := opcode == ProtocolType.OP_STATE_SNAPSHOT
	if is_input:
		condition["guest_inputs"] = int(condition["guest_inputs"]) + 1
	elif is_snapshot:
		condition["host_snapshots"] = int(condition["host_snapshots"]) + 1
	if is_input and bool(condition["blackout_inputs"]):
		condition["blackout_dropped"] = int(condition["blackout_dropped"]) + 1
		return
	if bool(condition["measure_loss"]) and (is_input or is_snapshot):
		var eligible_key := "input_eligible" if is_input else "snapshot_eligible"
		var dropped_key := "input_dropped" if is_input else "snapshot_dropped"
		condition[eligible_key] = int(condition[eligible_key]) + 1
		if int(condition[eligible_key]) % 10 == 0:
			condition[dropped_key] = int(condition[dropped_key]) + 1
			return
	var sequence := int(envelope.get("seq", 0))
	var forced_jitter := 100 if sequence % 4 == 2 else (0 if sequence % 4 == 3 else -1)
	_queue_impaired_packet(queue, condition, source, envelope, forced_jitter)


func _queue_impaired_packet(
		queue: Array[Dictionary], condition: Dictionary, target: String, envelope: Dictionary,
		jitter_override: int = -1
	) -> void:
	condition["wire_serial"] = int(condition["wire_serial"]) + 1
	var serial := int(condition["wire_serial"])
	var jitter_ms := jitter_override if jitter_override >= 0 else (serial * 37) % 101
	condition["max_jitter_ms"] = maxi(int(condition["max_jitter_ms"]), jitter_ms)
	queue.append({
		"due_ms": int(condition["now_ms"]) + jitter_ms,
		"wire_serial": serial,
		"target": target,
		"envelope": envelope.duplicate(true),
	})


func _run_impaired_frame(
		server: RefCounted,
		host_transport: RefCounted,
		guest_transport: RefCounted,
		host_runtime: RefCounted,
		guest_runtime: RefCounted,
		queue: Array[Dictionary],
		condition: Dictionary,
		host_command: RaceInput,
		guest_command: RaceInput
	) -> void:
	condition["now_ms"] = int(condition["now_ms"]) + 17
	server.advance_time(17)
	guest_runtime.advance_frame(1.0 / 60.0, guest_command)
	host_runtime.advance_frame(1.0 / 60.0, host_command)
	var ready: Array[Dictionary] = []
	var pending: Array[Dictionary] = []
	for packet in queue:
		if int(packet["due_ms"]) <= int(condition["now_ms"]):
			ready.append(packet)
		else:
			pending.append(packet)
	queue.clear()
	queue.append_array(pending)
	# Reverse same-frame deliveries to ensure the condition includes genuine
	# reorder pressure rather than delay alone.
	ready.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["wire_serial"]) > int(b["wire_serial"])
	)
	for packet in ready:
		var target := str(packet["target"])
		var envelope: Dictionary = packet["envelope"]
		if target == "host":
			var host_result: Dictionary = host_transport.send_envelope(host_runtime.room_code, envelope)
			if not host_result.get("ok", false):
				condition["server_rejections"].append(str(host_result.get("error", {}).get("code", "unknown")))
		elif target == "guest":
			var guest_result: Dictionary = guest_transport.send_envelope(guest_runtime.room_code, envelope)
			if not guest_result.get("ok", false):
				condition["server_rejections"].append(str(guest_result.get("error", {}).get("code", "unknown")))
		elif target == "deliver_host":
			host_runtime.handle_event(envelope)
		elif target == "deliver_guest":
			guest_runtime.handle_event(envelope)
	for event in host_transport.drain_events():
		_queue_impaired_packet(queue, condition, "deliver_host", event)
	for event in guest_transport.drain_events():
		_queue_impaired_packet(queue, condition, "deliver_guest", event)


func _test_two_client_authority_prediction_and_leave(test: RefCounted) -> void:
	var server := ServerType.new()
	var host_transport := TransportType.new(server, "race-host")
	var guest_transport := TransportType.new(server, "race-guest")
	var created: Dictionary = host_transport.create_private_room("Host Driver")
	test.assert_true(created["ok"], "race host creates room")
	if not created["ok"]:
		return
	var code := str(created["value"]["room_code"])
	test.assert_true(guest_transport.join_private_room(code, "Guest Driver")["ok"], "race guest joins room")
	var item := CatalogType.all()[0]
	var definition: TrackDefinition = item["definition"]
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	test.assert_true(compiled.succeeded(), "network race fixture compiles")
	if not compiled.succeeded():
		return
	var manifest := ManifestType.build(definition, compiled.track)
	test.assert_true(host_transport.submit_track_manifest(code, manifest)["ok"], "host selects network circuit")
	var report := {
		"success": true,
		"source_hash": manifest["source_hash"],
		"generator_version": manifest["generator_version"],
		"compiled_fingerprint": manifest["compiled_fingerprint"],
	}
	test.assert_true(host_transport.submit_generation_report(code, report)["ok"], "host compile verifies")
	test.assert_true(guest_transport.submit_generation_report(code, report)["ok"], "guest compile verifies")
	test.assert_true(host_transport.set_ready(code, true)["ok"], "host ready")
	test.assert_true(guest_transport.set_ready(code, true)["ok"], "guest ready")
	var lobby: Dictionary = host_transport.room_snapshot(code)["value"]
	var epoch := int(lobby["room_epoch"])
	test.assert_true(host_transport.set_room_lock(code, true)["ok"], "host locks network race grid")
	var countdown: Dictionary = host_transport.start_countdown(code)
	test.assert_true(countdown["ok"], "host starts synchronized countdown")
	var scheduled_tick := int(countdown["value"]["countdown"]["start_tick"])
	server.advance_time(LimitsType.COUNTDOWN_SECONDS * 1000)
	host_transport.drain_events()
	guest_transport.drain_events()

	var host_runtime := RuntimeType.new()
	var guest_runtime := RuntimeType.new()
	var roster: Array = lobby["members"]
	test.assert_true(host_runtime.configure(compiled.track, roster, "race-host", "race-host", code, epoch, scheduled_tick)["ok"], "host runtime configures")
	test.assert_true(guest_runtime.configure(compiled.track, roster, "race-guest", "race-host", code, epoch, scheduled_tick)["ok"], "guest runtime configures")
	var host_wire: Array[Dictionary] = []
	var guest_wire: Array[Dictionary] = []
	var send_failures: Array[String] = []
	host_runtime.outbound_envelope.connect(func(envelope: Dictionary) -> void:
		host_wire.append(envelope.duplicate(true))
		var result: Dictionary = host_transport.send_envelope(code, envelope)
		if not result["ok"]:
			send_failures.append(str(result.get("error", {}).get("code", "unknown")))
	)
	guest_runtime.outbound_envelope.connect(func(envelope: Dictionary) -> void:
		guest_wire.append(envelope.duplicate(true))
		var result: Dictionary = guest_transport.send_envelope(code, envelope)
		if not result["ok"]:
			send_failures.append(str(result.get("error", {}).get("code", "unknown")))
	)
	test.assert_true(host_runtime.begin(scheduled_tick), "host authority starts on scheduled tick")
	test.assert_true(guest_runtime.begin(scheduled_tick), "guest prediction starts on scheduled tick")
	var guest_command := RaceInputType.new(0.08, 1.0, 0.0, true)
	var host_command := RaceInputType.new(-0.04, 0.82, 0.0, true)
	var max_host_guest_speed := 0.0
	for _frame in 240:
		server.advance_time(17)
		guest_runtime.advance_frame(1.0 / 60.0, guest_command)
		for event in host_transport.drain_events():
			host_runtime.handle_event(event)
		host_runtime.advance_frame(1.0 / 60.0, host_command)
		var simulated_guest := host_runtime.director.entry(&"race-guest")
		if simulated_guest != null:
			max_host_guest_speed = maxf(max_host_guest_speed, simulated_guest.state.speed())
		for event in guest_transport.drain_events():
			guest_runtime.handle_event(event)
	test.assert_equal(send_failures.size(), 0, "bounded race cadence produces no server send failures")
	test.assert_true(host_wire.size() >= 44 and host_wire.size() <= 52, "host emits approximately 12 snapshots per second (actual %d)" % host_wire.size())
	test.assert_true(guest_wire.size() >= 76 and guest_wire.size() <= 81, "guest emits at most 20 input frames per second")
	for envelope in guest_wire:
		test.assert_false(bool(envelope["payload"].get("boost", true)), "guest wire always forces dormant boost false")
	test.assert_true(host_runtime.local_entry.state.position.is_finite(), "host authority remains finite")
	test.assert_true(guest_runtime.local_entry.state.position.is_finite(), "guest prediction remains finite")
	var host_guest := host_runtime.director.entry(&"race-guest")
	test.assert_true(host_guest != null, "host authority retains guest entry")
	if host_guest != null:
		test.assert_true(max_host_guest_speed > 10.0, "host simulates conventional guest throttle (peak %.3f)" % max_host_guest_speed)
		test.assert_true(
			guest_runtime.local_entry.state.position.distance_to(host_guest.state.position) < 4.0,
			"guest prediction reconciles close to host authority"
		)
	test.assert_true(guest_runtime.latest_authoritative_tick > scheduled_tick, "guest receives advancing authoritative ticks")
	var host_position_before_suspend := host_runtime.local_entry.state.position
	var guest_position_before_suspend := guest_runtime.local_entry.state.position
	var host_wire_before_suspend := host_wire.size()
	var guest_wire_before_suspend := guest_wire.size()
	host_runtime.set_suspended(true)
	test.assert_true(host_transport.suspend_connection(code)["ok"], "host background starts reconnect grace")
	for event in guest_transport.drain_events():
		guest_runtime.handle_event(event)
	test.assert_true(guest_runtime.suspended, "guest freezes when simulation host disconnects")
	for _frame in 30:
		server.advance_time(17)
		host_runtime.advance_frame(1.0 / 60.0, host_command)
		guest_runtime.advance_frame(1.0 / 60.0, guest_command)
	test.assert_equal(host_runtime.local_entry.state.position, host_position_before_suspend, "background host authority does not advance")
	test.assert_equal(guest_runtime.local_entry.state.position, guest_position_before_suspend, "guest prediction does not advance without host")
	test.assert_equal(host_wire.size(), host_wire_before_suspend, "suspended host emits no snapshots")
	test.assert_equal(guest_wire.size(), guest_wire_before_suspend, "suspended guest emits no inputs")
	var resumed_host: Dictionary = host_transport.reconnect(code, str(created["value"]["reconnect_token"]))
	test.assert_true(resumed_host["ok"], "host resumes inside grace window")
	host_runtime.set_suspended(false)
	for event in guest_transport.drain_events():
		guest_runtime.handle_event(event)
	test.assert_true(guest_runtime.suspended, "host presence alone does not resume stale guest prediction")
	for _frame in 6:
		server.advance_time(17)
		host_runtime.advance_frame(1.0 / 60.0, host_command)
		for event in guest_transport.drain_events():
			guest_runtime.handle_event(event)
	test.assert_false(guest_runtime.suspended, "fresh authoritative snapshot resumes guest after host reconnect")

	var departure_event := ProtocolType.make_envelope(
		ProtocolType.OP_RACE_EVENT, "server", 900, epoch,
		{"type": "peer_departed", "player_id": "race-guest"}, server.current_tick()
	)
	test.assert_true(host_runtime.handle_event(departure_event)["ok"], "host consumes authoritative guest departure")
	test.assert_equal(str(host_runtime.director.entry(&"race-guest").status), "dnf", "departed non-host is classified DNF")
	host_runtime.director.race_time_limit = host_runtime.director.race_time + 0.05
	for _frame in 12:
		server.advance_time(17)
		guest_runtime.advance_frame(1.0 / 60.0, guest_command)
		for event in host_transport.drain_events():
			host_runtime.handle_event(event)
		host_runtime.advance_frame(1.0 / 60.0, host_command)
		for event in guest_transport.drain_events():
			guest_runtime.handle_event(event)
	test.assert_true(host_runtime.finished, "host publishes terminal authoritative results")
	test.assert_true(guest_runtime.finished, "guest reaches results from host completion event")
	test.assert_equal(host_runtime.results().size(), 2, "host completion contains full classification")
	test.assert_equal(guest_runtime.results().size(), 2, "guest applies full authoritative classification")
	var guest_result_status := ""
	for result in guest_runtime.results():
		if str(result.get("player_id", "")) == "race-guest":
			guest_result_status = str(result.get("status", ""))
	test.assert_equal(guest_result_status, "dnf", "guest reflects host-authoritative departure DNF")

	var malicious := ProtocolType.make_envelope(
		ProtocolType.OP_INPUT_FRAME,
		"race-guest",
		999,
		epoch,
		{"steering": 0, "throttle": 1000, "brake": 0, "boost": true, "ack_host_tick": server.current_tick()},
		server.current_tick()
	)
	var malicious_result: Dictionary = guest_transport.send_envelope(code, malicious)
	test.assert_false(malicious_result["ok"], "server boundary rejects malicious multiplayer boost")
	test.assert_equal(str(malicious_result.get("error", {}).get("code", "")), "input_boost_disabled", "malicious boost refusal is explicit")

	var host_leave: Dictionary = host_transport.leave_room(code)
	test.assert_true(host_leave["ok"], "host may end results room")
	var saw_host_end := false
	for event in guest_transport.drain_events():
		if int(event.get("opcode", -1)) == ProtocolType.OP_ROOM_ENDED \
				and str(event.get("payload", {}).get("reason", "")) == "simulation_host_departed":
			saw_host_end = true
	test.assert_true(saw_host_end, "host departure publishes an explicit room terminal reason")
	var terminal_runtime := RuntimeType.new()
	test.assert_true(terminal_runtime.configure(compiled.track, roster, "race-guest", "race-host", code, epoch, scheduled_tick)["ok"], "terminal UI runtime configures")
	terminal_runtime.begin(scheduled_tick)
	terminal_runtime.handle_event(ProtocolType.make_envelope(
		ProtocolType.OP_ROOM_ENDED, "server", 901, epoch,
		{"reason": "simulation_host_departed"}, server.current_tick()
	))
	test.assert_true(terminal_runtime.finished, "host-loss event enters terminal UI state")
	test.assert_equal(terminal_runtime.terminal_reason, "simulation_host_departed", "host-loss terminal reason stays honest")
