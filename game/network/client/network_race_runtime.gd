class_name NetworkRaceRuntime
extends RefCounted
## Client-host race bridge for protocol v1. The room host runs the only full
## RaceDirector; guests predict their own conventional-control car, reconcile
## against host snapshots, and interpolate every remote car.

signal outbound_envelope(envelope: Dictionary)
signal terminal(reason: String)

const Limits := preload("res://game/network/network_limits.gd")
const Protocol := preload("res://game/network/network_protocol.gd")
const Codec := preload("res://game/network/client/network_race_codec.gd")
const Scheduler := preload("res://game/network/client/network_send_scheduler.gd")
const Reconciler := preload("res://game/network/client/prediction_reconciler.gd")
const Interpolator := preload("res://game/network/client/snapshot_interpolator.gd")
const DirectorType := preload("res://game/race/race_director.gd")
const TrackQueryType := preload("res://game/race/track_query.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const VehicleCatalogType := preload("res://game/content/vehicle_catalog.gd")

const MAX_REMOTE_INPUT_HOLD_TICKS := 12
const FIXED_DT := 1.0 / float(Limits.SIMULATION_HZ)
const MAX_FRAME_DELTA := 0.25
const MAX_STEPS_PER_FRAME := 16

var director: RaceDirector
var track: RaceTrackQuery
var entries: Array[RaceEntry] = []
var local_entry: RaceEntry
var local_player_id: String = ""
var host_player_id: String = ""
var room_code: String = ""
var room_epoch: int = 0
var start_tick: int = 0
var global_tick: int = 0
var latest_authoritative_tick: int = 0
var running := false
var suspended := false
var finished := false
var terminal_reason := ""
var is_host := false
var last_reconcile_error_q := Vector2i.ZERO
var last_hard_reconcile := false
var authoritative_results: Array[Dictionary] = []

var _session: Variant
var _roster: Array[Dictionary] = []
var _slot_by_player: Dictionary = {}
var _player_by_slot: Dictionary = {}
var _remote_inputs: Dictionary = {}
var _last_remote_input_active: Dictionary = {}
var _sequence_by_opcode: Dictionary = {}
var _scheduler := Scheduler.new()
var _reconciler := Reconciler.new()
var _interpolator := Interpolator.new()
var _accumulator := 0.0
var _prediction_sequence := 0
var _last_command := RaceInputType.new()
var _awaiting_host_snapshot := false
var _completion_sent := false
var _recovery_parity_by_slot: Dictionary = {}


func configure(
		compiled_track: CompiledTrack,
		roster: Array,
		local_id: String,
		host_id: String,
		code: String,
		epoch: int,
		scheduled_start_tick: int,
		session_value: Variant = null,
		lap_count: int = 3,
		vehicle_collisions: bool = true
	) -> Dictionary:
	if compiled_track == null or local_id.is_empty() or host_id.is_empty() or code.is_empty() or epoch <= 0:
		return {"ok": false, "error": {"code": "network_race_configuration_invalid", "message": "Network race configuration is incomplete."}}
	track = TrackQueryType.from_compiled(compiled_track)
	if not track.is_valid():
		return {"ok": false, "error": {"code": "network_race_track_invalid", "message": "Network circuit is not valid for simulation."}}
	_roster = _sanitize_roster(roster)
	if _roster.is_empty() or _roster.size() > Limits.MAX_PLAYERS:
		return {"ok": false, "error": {"code": "network_race_roster_invalid", "message": "Network starting grid is invalid."}}
	local_player_id = local_id
	host_player_id = host_id
	room_code = code
	room_epoch = epoch
	start_tick = maxi(0, scheduled_start_tick)
	global_tick = start_tick
	latest_authoritative_tick = start_tick
	is_host = local_player_id == host_player_id
	_session = session_value
	# At a 60 Hz fixed simulation, a nominal 15 Hz scheduler gate yields a
	# deterministic every-five-tick publication after integer millisecond
	# quantization: exactly 12 bounded snapshots per second.
	_scheduler.configure(20, 15)
	_scheduler.reset()
	_reconciler.clear()
	_interpolator.clear()
	_sequence_by_opcode.clear()
	_remote_inputs.clear()
	_last_remote_input_active.clear()
	_recovery_parity_by_slot.clear()
	_slot_by_player.clear()
	_player_by_slot.clear()
	for member in _roster:
		_slot_by_player[str(member["player_id"])] = int(member["slot"])
		_player_by_slot[int(member["slot"])] = str(member["player_id"])
	director = DirectorType.new()
	if not director.configure(track, clampi(lap_count, 1, 8), int(compiled_track.deterministic_seed), 8, vehicle_collisions):
		return {"ok": false, "error": {"code": "network_race_director_failed", "message": "Network race authority could not initialize."}}
	director.countdown_duration = 0.0
	for member in _roster:
		var entry := director.add_entry(
			StringName(str(member["player_id"])),
			str(member["display_name"]),
			true
		)
		if entry == null:
			return {"ok": false, "error": {"code": "network_race_roster_invalid", "message": "A starting-grid slot could not be created."}}
	entries = director.entries
	local_entry = director.entry(StringName(local_player_id))
	if local_entry == null or director.entry(StringName(host_player_id)) == null:
		return {"ok": false, "error": {"code": "network_race_roster_invalid", "message": "Local driver or host is absent from the starting grid."}}
	return {"ok": true, "value": {"host": is_host, "cars": entries.size(), "start_tick": start_tick}}


func begin(authoritative_start_tick: int = -1) -> bool:
	if running or director == null:
		return false
	if authoritative_start_tick >= 0:
		start_tick = authoritative_start_tick
	global_tick = start_tick
	latest_authoritative_tick = maxi(latest_authoritative_tick, start_tick)
	running = director.start()
	suspended = false
	finished = false
	terminal_reason = ""
	_accumulator = 0.0
	return running


func advance_frame(delta: float, command: RaceInput) -> int:
	if not running or suspended or finished or director == null:
		return 0
	if is_nan(delta) or is_inf(delta) or delta <= 0.0:
		return 0
	_last_command = _conventional_command(command)
	_accumulator += minf(delta, MAX_FRAME_DELTA)
	var steps := 0
	while _accumulator + 0.000000001 >= FIXED_DT and steps < MAX_STEPS_PER_FRAME:
		_accumulator -= FIXED_DT
		if is_host:
			_host_tick()
		else:
			_guest_tick()
		steps += 1
	_sample_remote_presentation()
	if is_host and director.phase == DirectorType.PHASE_RESULTS and not _completion_sent:
		_publish_completion()
	return steps


func handle_event(event: Dictionary) -> Dictionary:
	var opcode := int(event.get("opcode", -1))
	if opcode == Protocol.OP_INPUT_FRAME and is_host:
		var sender := str(event.get("sender_id", ""))
		if sender == local_player_id or not _slot_by_player.has(sender):
			return {"ok": false, "error": {"code": "input_sender_invalid"}}
		var decoded := Codec.command_from_payload(event.get("payload", {}))
		if not decoded["ok"]:
			return decoded
		_remote_inputs[sender] = {
			"command": decoded["value"],
			"tick": int(event.get("tick", global_tick)),
		}
		latest_authoritative_tick = maxi(latest_authoritative_tick, int(event.get("payload", {}).get("ack_host_tick", 0)))
		return {"ok": true}
	if opcode == Protocol.OP_STATE_SNAPSHOT and not is_host:
		return _handle_snapshot(event)
	if opcode == Protocol.OP_RESUME:
		var resume_snapshot: Variant = event.get("payload", {}).get("authoritative_snapshot")
		if not is_host and resume_snapshot is Dictionary and not resume_snapshot.is_empty():
			var resumed := _handle_snapshot(resume_snapshot)
			if not resumed.get("ok", false):
				return resumed
		suspended = false
		_awaiting_host_snapshot = false
		return {"ok": true}
	if opcode == Protocol.OP_RACE_EVENT:
		var event_type := str(event.get("payload", {}).get("type", ""))
		if event_type == "race_started" and not running:
			begin(int(event.get("payload", {}).get("tick", start_tick)))
		elif event_type == "peer_disconnected" and str(event.get("payload", {}).get("player_id", "")) == host_player_id and not is_host:
			suspended = true
			_awaiting_host_snapshot = true
		elif event_type == "peer_resumed" and str(event.get("payload", {}).get("player_id", "")) == host_player_id and not is_host:
			# Do not resume guest prediction on presence alone. The next full host
			# snapshot is the authoritative restart boundary.
			suspended = true
			_awaiting_host_snapshot = true
		elif event_type == "peer_departed":
			var departed := str(event.get("payload", {}).get("player_id", ""))
			if departed == host_player_id:
				finish("simulation_host_departed")
			elif is_host and director != null:
				director.mark_dnf(StringName(departed), &"peer_departed")
		elif event_type == "race_complete":
			return _apply_authoritative_results(event.get("payload", {}).get("results", []))
		return {"ok": true}
	if opcode == Protocol.OP_ROOM_ENDED:
		finish(str(event.get("payload", {}).get("reason", "room_ended")))
		return {"ok": true}
	return {"ok": false, "error": {"code": "event_not_consumed"}}


func presentation_alpha() -> float:
	return clampf(_accumulator / FIXED_DT, 0.0, 1.0) if running else 0.0


func last_command() -> RaceInput:
	return _last_command


func results() -> Array[Dictionary]:
	return authoritative_results.duplicate(true) if not authoritative_results.is_empty() \
		else (director.results() if director != null else [])


func finish(reason: String) -> void:
	if finished:
		return
	finished = true
	running = false
	terminal_reason = reason
	terminal.emit(reason)


func set_suspended(value: bool) -> void:
	if finished:
		return
	suspended = value


static func remote_input_within_hold(authority_tick: int, received_tick: int) -> bool:
	return received_tick >= 0 and authority_tick >= received_tick \
		and authority_tick - received_tick <= MAX_REMOTE_INPUT_HOLD_TICKS


func remote_input_active(player_id: String) -> bool:
	return bool(_last_remote_input_active.get(player_id, false))


func _host_tick() -> void:
	var commands: Dictionary = {}
	commands[StringName(local_player_id)] = _last_command
	for member in _roster:
		var player_id := str(member["player_id"])
		if player_id == local_player_id:
			continue
		var remote: Dictionary = _remote_inputs.get(player_id, {})
		var received_tick := int(remote.get("tick", -1))
		var remote_command: RaceInput = remote.get("command")
		var active := remote_command != null and remote_input_within_hold(global_tick, received_tick)
		_last_remote_input_active[player_id] = active
		commands[StringName(player_id)] = remote_command if active else RaceInputType.new()
	director.tick_fixed(commands)
	global_tick = start_tick + director.fixed_tick
	latest_authoritative_tick = global_tick
	# Five fixed ticks at 60 Hz is an exact 12 Hz wire cadence. Keep the shared
	# scheduler marked for lifecycle/reset accounting, but gate on simulation
	# ticks so integer wall-clock rounding cannot drift to 10 or 14 Hz.
	if director.fixed_tick == 1 or director.fixed_tick % 5 == 0:
		_scheduler.mark_snapshot_sent(global_tick * 1000 / Limits.SIMULATION_HZ)
		_publish_snapshot()


func _guest_tick() -> void:
	global_tick += 1
	local_entry.previous_state = local_entry.state.duplicate_state()
	local_entry.vehicle_model.step_fixed(local_entry.state, _last_command, track)
	if local_entry.lap_tracker != null:
		local_entry.lap_tracker.update(
			local_entry.state.position,
			local_entry.state.velocity,
			FIXED_DT,
			global_tick,
			float(global_tick - start_tick) * FIXED_DT,
			local_entry.state.track_collision_layer,
			local_entry.state.track_collision_mask
		)
	_prediction_sequence += 1
	var prediction_input := {
		"seq": _prediction_sequence,
		"payload": Codec.input_payload(_last_command, latest_authoritative_tick),
	}
	_reconciler.record_local_step(
		global_tick,
		prediction_input,
		Codec.prediction_state_from_vehicle(local_entry.state)
	)
	var now_ms := global_tick * 1000 / Limits.SIMULATION_HZ
	if _scheduler.input_due(now_ms):
		_scheduler.mark_input_sent(now_ms)
		_emit_network_envelope(Protocol.OP_INPUT_FRAME, prediction_input["payload"], global_tick)


func _publish_snapshot() -> void:
	var cars: Array[Dictionary] = []
	for member in _roster:
		var player_id := str(member["player_id"])
		var entry := director.entry(StringName(player_id))
		var car := Codec.car_from_entry(entry, int(member["slot"]))
		if not car.is_empty():
			cars.append(car)
	_emit_network_envelope(Protocol.OP_STATE_SNAPSHOT, {"cars": cars}, global_tick)


func _publish_completion() -> void:
	_completion_sent = true
	_publish_snapshot()
	authoritative_results = []
	for result in director.results():
		var player_id := str(result["participant_id"])
		authoritative_results.append({
			"player_id": player_id,
			"slot": int(_slot_by_player.get(player_id, -1)),
			"position": int(result["position"]),
			"status": str(result["status"]),
			"laps": int(result["laps_completed"]),
			"finish_time_ms": maxi(0, roundi(float(result["finish_time"]) * 1000.0)),
			"dnf_reason": str(result["dnf_reason"]).left(40),
		})
	_emit_network_envelope(Protocol.OP_RACE_EVENT, {
		"type": "race_complete",
		"results": authoritative_results,
	}, global_tick)
	finish("race_complete")


func _apply_authoritative_results(results_value: Variant) -> Dictionary:
	if not results_value is Array or results_value.size() != entries.size():
		return {"ok": false, "error": {"code": "race_results_invalid"}}
	var envelope := Protocol.make_envelope(
		Protocol.OP_RACE_EVENT, "server", 0, room_epoch,
		{"type": "race_complete", "results": results_value}, latest_authoritative_tick
	)
	var validation := Protocol.validate_race_event(envelope)
	if not validation["ok"]:
		return validation
	var normalized_results: Array[Dictionary] = []
	for result_value in results_value:
		var result: Dictionary = result_value.duplicate(true)
		var entry := director.entry(StringName(str(result["player_id"])))
		if entry == null or int(_slot_by_player.get(str(result["player_id"]), -1)) != int(result["slot"]):
			return {"ok": false, "error": {"code": "race_results_roster_mismatch"}}
		entry.status = StringName(str(result["status"]))
		entry.race_position = int(result["position"])
		entry.finish_order = int(result["position"]) if entry.status == &"finished" else 0
		entry.finish_time = float(result["finish_time_ms"]) / 1000.0
		entry.dnf_reason = StringName(str(result["dnf_reason"]))
		if entry.lap_tracker != null:
			entry.lap_tracker.laps_completed = int(result["laps"])
		normalized_results.append(result)
	authoritative_results = normalized_results
	director.phase = DirectorType.PHASE_RESULTS
	finish("race_complete")
	return {"ok": true}


func _handle_snapshot(event: Dictionary) -> Dictionary:
	var tick := int(event.get("tick", -1))
	var cars: Array = event.get("payload", {}).get("cars", [])
	var recovery_changes := _detect_recovery_parity_changes(cars)
	if not recovery_changes.is_empty():
		# A recovery is an authority discontinuity, not latency drift. Purge both
		# histories so presentation cannot interpolate through the circuit and
		# local prediction cannot replay inputs from the abandoned position.
		_reconciler.clear()
		_interpolator.clear()
	var pushed := _interpolator.push_snapshot({"tick": tick, "cars": cars})
	if not pushed["ok"]:
		return pushed
	latest_authoritative_tick = maxi(latest_authoritative_tick, tick)
	var local_slot := int(_slot_by_player.get(local_player_id, -1))
	var local_car := Codec.car_for_slot(cars, local_slot)
	if not local_car.is_empty():
		var local_recovered := recovery_changes.has(local_slot)
		var authoritative_state := {
			"x_q": int(local_car["x_q"]),
			"y_q": int(local_car["y_q"]),
			"rotation_q": int(local_car["rotation_q"]),
			"velocity_x_q": int(local_car["velocity_x_q"]),
			"velocity_y_q": int(local_car["velocity_y_q"]),
			"collision_layer": int(local_car["collision_layer"]),
			"collision_mask": int(local_car["collision_mask"]),
		}
		for field in Codec.DYNAMICS_FIELDS:
			if local_car.has(field):
				authoritative_state[field] = int(local_car[field])
		for field in Codec.AIRBORNE_FIELDS:
			if local_car.has(field):
				authoritative_state[field] = int(local_car[field])
		for field in Codec.CONTACT_FIELDS:
			if local_car.has(field):
				authoritative_state[field] = int(local_car[field])
		if local_recovered:
			last_reconcile_error_q = Vector2i(
				int(local_car["x_q"]) - roundi(local_entry.state.position.x * Codec.POSITION_SCALE),
				int(local_car["y_q"]) - roundi(local_entry.state.position.y * Codec.POSITION_SCALE)
			)
			last_hard_reconcile = true
			Codec.apply_car_to_entry(local_car, local_entry, track)
		else:
			var reconciled := _reconciler.reconcile(tick, authoritative_state, _simulate_prediction_step)
			if not reconciled["ok"]:
				return reconciled
			var value: Dictionary = reconciled["value"]
			last_reconcile_error_q = Vector2i(int(value["error_q"][0]), int(value["error_q"][1]))
			last_hard_reconcile = bool(value["hard_snap"])
			_apply_prediction_state(value["state"], local_entry)
	for changed_slot in recovery_changes.keys():
		var slot := int(changed_slot)
		if slot == local_slot:
			continue
		var player_id := str(_player_by_slot.get(slot, ""))
		var recovered_entry := director.entry(StringName(player_id)) if not player_id.is_empty() else null
		var recovered_car := Codec.car_for_slot(cars, slot)
		if recovered_entry != null and not recovered_car.is_empty():
			Codec.apply_car_to_entry(recovered_car, recovered_entry, track)
	if _awaiting_host_snapshot:
		_awaiting_host_snapshot = false
		suspended = false
	return {"ok": true, "value": {"tick": tick, "cars": cars.size()}}


func _detect_recovery_parity_changes(cars: Array) -> Dictionary:
	var changed: Dictionary = {}
	for car_value in cars:
		if not car_value is Dictionary:
			continue
		var slot := int(car_value.get("slot", -1))
		if slot < 0:
			continue
		var parity := Codec.recovery_parity(car_value)
		if _recovery_parity_by_slot.has(slot):
			if int(_recovery_parity_by_slot[slot]) != parity:
				changed[slot] = true
		else:
			# First sight establishes baseline parity without inventing a recovery.
			var player_id := str(_player_by_slot.get(slot, ""))
			var entry := director.entry(StringName(player_id)) if not player_id.is_empty() else null
			if entry != null and (entry.state.recovery_hard_snap_serial & 1) != parity:
				entry.state.recovery_hard_snap_serial = parity
		_recovery_parity_by_slot[slot] = parity
	return changed


func _sample_remote_presentation() -> void:
	if is_host or _interpolator.buffered_count() == 0:
		return
	var sampled := _interpolator.sample_delayed(latest_authoritative_tick)
	if sampled.is_empty():
		return
	for car_value in sampled.get("cars", []):
		var slot := int(car_value.get("slot", -1))
		var player_id := str(_player_by_slot.get(slot, ""))
		if player_id.is_empty() or player_id == local_player_id:
			continue
		var entry := director.entry(StringName(player_id))
		Codec.apply_car_to_entry(car_value, entry, track)


func _simulate_prediction_step(state: Dictionary, input_frame: Dictionary, tick: int) -> Dictionary:
	var temporary := local_entry.state.duplicate_state()
	temporary.position = Vector2(float(state["x_q"]) / Codec.POSITION_SCALE, float(state["y_q"]) / Codec.POSITION_SCALE)
	temporary.velocity = Vector2(float(state["velocity_x_q"]) / Codec.VELOCITY_SCALE, float(state["velocity_y_q"]) / Codec.VELOCITY_SCALE)
	temporary.heading = float(state["rotation_q"]) / Codec.ROTATION_SCALE
	temporary.track_collision_layer = int(state.get("collision_layer", temporary.track_collision_layer))
	temporary.track_collision_mask = int(state.get("collision_mask", temporary.track_collision_mask))
	Codec.apply_dynamics_to_state(state, temporary)
	Codec.apply_airborne_to_state(state, temporary)
	Codec.apply_contact_to_state(state, temporary)
	var projection := track.nearest_continuous(temporary.position, temporary.track_distance, temporary.track_collision_layer, maxf(track.track_width * 4.0, 96.0))
	if not projection.is_empty():
		temporary.track_distance = float(projection["distance_along"])
		temporary.lateral_offset = float(projection["signed_lateral"])
	var decoded := Codec.command_from_payload(input_frame.get("payload", {}))
	var command: RaceInput = decoded["value"] if decoded["ok"] else RaceInputType.new()
	local_entry.vehicle_model.step_fixed(temporary, command, track)
	temporary.simulation_tick = tick
	return Codec.prediction_state_from_vehicle(temporary)


func _apply_prediction_state(state: Dictionary, entry: RaceEntry) -> void:
	entry.previous_state = entry.state.duplicate_state()
	entry.state.position = Vector2(float(state["x_q"]) / Codec.POSITION_SCALE, float(state["y_q"]) / Codec.POSITION_SCALE)
	entry.state.velocity = Vector2(float(state["velocity_x_q"]) / Codec.VELOCITY_SCALE, float(state["velocity_y_q"]) / Codec.VELOCITY_SCALE)
	entry.state.heading = float(state["rotation_q"]) / Codec.ROTATION_SCALE
	entry.state.track_collision_layer = int(state.get("collision_layer", entry.state.track_collision_layer))
	entry.state.track_collision_mask = int(state.get("collision_mask", entry.state.track_collision_mask))
	Codec.apply_dynamics_to_state(state, entry.state)
	Codec.apply_airborne_to_state(state, entry.state)
	Codec.apply_contact_to_state(state, entry.state)
	var projection := track.nearest_continuous(entry.state.position, entry.state.track_distance, entry.state.track_collision_layer, maxf(track.track_width * 4.0, 96.0))
	if not projection.is_empty():
		entry.state.track_distance = float(projection["distance_along"])
		entry.state.lateral_offset = float(projection["signed_lateral"])
		var surface := track.surface_context_at_distance(entry.state.track_distance)
		entry.state.track_elevation = float(surface.get("elevation_level", 0.0))
		entry.state.bridge_id = str(surface.get("bridge_id", ""))


func _emit_network_envelope(opcode: int, payload: Dictionary, tick: int) -> void:
	var sequence := int(_sequence_by_opcode.get(opcode, 0)) + 1
	_sequence_by_opcode[opcode] = sequence
	var envelope := Protocol.make_envelope(opcode, local_player_id, sequence, room_epoch, payload, tick)
	var validation := Protocol.validate_envelope(envelope, local_player_id, room_epoch)
	if not validation["ok"]:
		return
	outbound_envelope.emit(envelope.duplicate(true))
	if _session != null and _session.has_method("send_race_envelope"):
		_session.call("send_race_envelope", envelope)


func _conventional_command(command: RaceInput) -> RaceInput:
	var safe := command.duplicate_input() if command != null else RaceInputType.new()
	safe.sanitize()
	safe.nitro = false
	return safe


func _sanitize_roster(source: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var ids: Dictionary = {}
	var slots: Dictionary = {}
	for value in source:
		if not value is Dictionary:
			return []
		var player_id := str(value.get("player_id", ""))
		var slot := int(value.get("slot", -1))
		var car_id := str(value.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID))
		var team_id := str(value.get("team_id", VehicleCatalogType.DEFAULT_TEAM_ID))
		if player_id.is_empty() or ids.has(player_id) or slot < 0 or slot >= Limits.MAX_PLAYERS or slots.has(slot):
			return []
		if not VehicleCatalogType.is_valid_pair(car_id, team_id):
			return []
		ids[player_id] = true
		slots[slot] = true
		output.append({
			"player_id": player_id,
			"display_name": str(value.get("display_name", "Driver")).strip_edges().left(Limits.MAX_DISPLAY_NAME_LENGTH),
			"car_id": car_id,
			"team_id": team_id,
			"slot": slot,
		})
	output.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))
	return output
