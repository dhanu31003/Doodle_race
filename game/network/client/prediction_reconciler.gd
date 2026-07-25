class_name PredictionReconciler
extends RefCounted
## Stores unacknowledged local inputs and replays them from an authoritative
## state. The vehicle layer supplies the deterministic simulation Callable.

const Limits := preload("res://game/network/network_limits.gd")
const Result := preload("res://game/network/network_result.gd")

var _pending_inputs: Array[Dictionary] = []
var _predicted_states: Dictionary = {}
var _last_recorded_tick: int = -1
var _last_recorded_sequence: int = -1


func record_local_step(tick: int, input_frame: Dictionary, predicted_state: Dictionary) -> Dictionary:
	if tick < 0 or not _valid_state(predicted_state):
		return Result.failure(&"prediction_state_invalid", "Predicted state is malformed.")
	if not input_frame.has("seq") or typeof(input_frame["seq"]) != TYPE_INT:
		return Result.failure(&"prediction_input_invalid", "Predicted input requires an integer sequence.")
	if tick <= _last_recorded_tick or int(input_frame["seq"]) <= _last_recorded_sequence:
		return Result.failure(&"prediction_input_stale", "Predicted inputs must advance by tick and sequence.")
	_pending_inputs.append({
		"tick": tick,
		"input": input_frame.duplicate(true),
	})
	_predicted_states[tick] = predicted_state.duplicate(true)
	_last_recorded_tick = tick
	_last_recorded_sequence = int(input_frame["seq"])
	_trim_history(tick)
	return Result.success({"pending_inputs": _pending_inputs.size()})


func reconcile(
		authoritative_tick: int,
		authoritative_state: Dictionary,
		simulate_step: Callable
	) -> Dictionary:
	if authoritative_tick < 0 or not _valid_state(authoritative_state):
		return Result.failure(&"authoritative_state_invalid", "Authoritative state is malformed.")
	if not simulate_step.is_valid():
		return Result.failure(&"prediction_model_missing", "Reconciliation requires a simulation step callable.")
	var previous: Dictionary = _predicted_states.get(authoritative_tick, authoritative_state)
	var error_x := int(authoritative_state["x_q"]) - int(previous["x_q"])
	var error_y := int(authoritative_state["y_q"]) - int(previous["y_q"])
	var corrected := authoritative_state.duplicate(true)
	var remaining: Array[Dictionary] = []
	var replayed_ticks: Array[int] = []
	for entry in _pending_inputs:
		if int(entry["tick"]) <= authoritative_tick:
			continue
		var replayed: Variant = simulate_step.call(
			corrected.duplicate(true),
			entry["input"].duplicate(true),
			int(entry["tick"])
		)
		if typeof(replayed) != TYPE_DICTIONARY or not _valid_state(replayed):
			return Result.failure(
				&"prediction_model_invalid", "Simulation step returned a malformed predicted state."
			)
		corrected = replayed.duplicate(true)
		_predicted_states[int(entry["tick"])] = corrected.duplicate(true)
		remaining.append(entry)
		replayed_ticks.append(int(entry["tick"]))
	_pending_inputs = remaining
	for stored_tick in _predicted_states.keys():
		if int(stored_tick) <= authoritative_tick:
			_predicted_states.erase(stored_tick)
	var hard_snap := absi(error_x) > Limits.HARD_RECONCILE_DISTANCE_Q \
			or absi(error_y) > Limits.HARD_RECONCILE_DISTANCE_Q
	return Result.success({
		"state": corrected,
		"authoritative_tick": authoritative_tick,
		"error_q": [error_x, error_y],
		"hard_snap": hard_snap,
		"replayed_ticks": replayed_ticks,
		"pending_inputs": _pending_inputs.size(),
	})


func pending_input_count() -> int:
	return _pending_inputs.size()


func predicted_state(tick: int) -> Dictionary:
	return _predicted_states.get(tick, {}).duplicate(true)


func clear() -> void:
	_pending_inputs.clear()
	_predicted_states.clear()
	_last_recorded_tick = -1
	_last_recorded_sequence = -1


func _trim_history(latest_tick: int) -> void:
	var minimum_tick := latest_tick - Limits.PREDICTION_HISTORY_TICKS
	while not _pending_inputs.is_empty() and int(_pending_inputs[0]["tick"]) < minimum_tick:
		_pending_inputs.pop_front()
	for stored_tick in _predicted_states.keys():
		if int(stored_tick) < minimum_tick:
			_predicted_states.erase(stored_tick)


func _valid_state(state: Dictionary) -> bool:
	for key in ["x_q", "y_q", "rotation_q", "velocity_x_q", "velocity_y_q"]:
		if not state.has(key) or typeof(state[key]) != TYPE_INT:
			return false
	if absi(int(state["x_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT \
			or absi(int(state["y_q"])) > Limits.WORLD_COORDINATE_Q_LIMIT:
		return false
	return absi(int(state["velocity_x_q"])) <= Limits.VELOCITY_Q_LIMIT \
			and absi(int(state["velocity_y_q"])) <= Limits.VELOCITY_Q_LIMIT \
			and absi(int(state["rotation_q"])) <= Limits.ROTATION_Q_LIMIT
