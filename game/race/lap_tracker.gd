class_name LapTracker
extends RefCounted
## Ordered spatial checkpoints and forward-only lap authority.
##
## A lap is awarded only after every gate is crossed in sequence, in the track
## direction, at a physically plausible per-tick displacement. Nearest-point
## progress alone is never trusted because it can jump across adjacent roads.

const MIN_CHECKPOINTS: int = 4
const MAX_CHECKPOINTS: int = 32
const SECTOR_COUNT: int = 3
const MIN_FORWARD_GATE_SPEED: float = 1.0
const MAX_LEGAL_SPEED: float = 700.0

var total_laps: int = 3
var laps_completed: int = 0
var checkpoint_count: int = 8
var next_checkpoint: int = 1
var finished: bool = false
var finish_tick: int = -1
var finish_time: float = -1.0
var invalid_motion_count: int = 0
var reverse_distance: float = 0.0
var current_track_distance: float = 0.0
var current_track_layer: int = RaceTrackQuery.COLLISION_LAYER_GROUND
var current_track_mask: int = RaceTrackQuery.COLLISION_LAYER_GROUND
var last_validated_progress: float = 0.0
var sector_splits: Array[Dictionary] = []

var _track: RaceTrackQuery
var _gate_distances: PackedFloat64Array = PackedFloat64Array()
var _gate_positions: PackedVector2Array = PackedVector2Array()
var _gate_tangents: PackedVector2Array = PackedVector2Array()
var _gate_normals: PackedVector2Array = PackedVector2Array()
var _gate_layers: PackedInt32Array = PackedInt32Array()
var _gate_masks: PackedInt32Array = PackedInt32Array()
var _primed: bool = false
var _previous_position: Vector2 = Vector2.ZERO
var _previous_track_distance: float = 0.0
var _previous_track_layer: int = RaceTrackQuery.COLLISION_LAYER_GROUND
var _previous_track_mask: int = RaceTrackQuery.COLLISION_LAYER_GROUND
var _sector_started_at: float = 0.0


func configure(track: RaceTrackQuery, lap_count: int = 3, requested_checkpoints: int = 8) -> bool:
	reset()
	if track == null or not track.is_valid():
		return false
	_track = track
	total_laps = clampi(lap_count, 1, 99)
	checkpoint_count = clampi(requested_checkpoints, MIN_CHECKPOINTS, MAX_CHECKPOINTS)
	_gate_distances.resize(checkpoint_count)
	_gate_positions.resize(checkpoint_count)
	_gate_tangents.resize(checkpoint_count)
	_gate_normals.resize(checkpoint_count)
	_gate_layers.resize(checkpoint_count)
	_gate_masks.resize(checkpoint_count)
	for index in checkpoint_count:
		var distance_along := track.total_length * float(index) / float(checkpoint_count)
		var sample := track.sample_at_distance(distance_along)
		_gate_distances[index] = distance_along
		_gate_positions[index] = sample["position"]
		_gate_tangents[index] = sample["tangent"]
		_gate_normals[index] = sample["normal"]
		_gate_layers[index] = int(sample.get("collision_layer", RaceTrackQuery.COLLISION_LAYER_GROUND))
		_gate_masks[index] = int(sample.get("collision_mask", _gate_layers[index]))
	return true


func reset() -> void:
	laps_completed = 0
	next_checkpoint = 1
	finished = false
	finish_tick = -1
	finish_time = -1.0
	invalid_motion_count = 0
	reverse_distance = 0.0
	current_track_distance = 0.0
	current_track_layer = RaceTrackQuery.COLLISION_LAYER_GROUND
	current_track_mask = RaceTrackQuery.COLLISION_LAYER_GROUND
	last_validated_progress = 0.0
	sector_splits.clear()
	_track = null
	_gate_distances = PackedFloat64Array()
	_gate_positions = PackedVector2Array()
	_gate_tangents = PackedVector2Array()
	_gate_normals = PackedVector2Array()
	_gate_layers = PackedInt32Array()
	_gate_masks = PackedInt32Array()
	_primed = false
	_previous_position = Vector2.ZERO
	_previous_track_distance = 0.0
	_previous_track_layer = RaceTrackQuery.COLLISION_LAYER_GROUND
	_previous_track_mask = RaceTrackQuery.COLLISION_LAYER_GROUND
	_sector_started_at = 0.0


func prime(
	position: Vector2,
	distance_hint: float = INF,
	collision_layer_hint: int = 0
	) -> bool:
	if _track == null or not _track.is_valid() or not _finite_vector(position):
		return false
	var projection := _track.nearest(position) if not _finite(distance_hint) else _track.nearest_continuous(
		position,
		distance_hint,
		collision_layer_hint,
		maxf(_track.track_width * 2.5, 48.0)
	)
	if projection.is_empty():
		return false
	_previous_position = position
	_previous_track_distance = float(projection["distance_along"])
	_previous_track_layer = int(projection.get("collision_layer", RaceTrackQuery.COLLISION_LAYER_GROUND))
	_previous_track_mask = int(projection.get("collision_mask", _previous_track_layer))
	current_track_distance = _previous_track_distance
	current_track_layer = _previous_track_layer
	current_track_mask = _previous_track_mask
	_primed = true
	_update_validated_progress()
	return true


func update(
		position: Vector2,
	velocity: Vector2,
	delta: float,
	simulation_tick: int,
	race_time: float,
	collision_layer_hint: int = 0,
	collision_mask_hint: int = 0
	) -> Dictionary:
	var event := {
		"checkpoint": false,
		"lap": false,
		"sector": false,
		"finished": false,
		"invalid": false,
	}
	if finished or _track == null or not _track.is_valid():
		return event
	if not _finite_vector(position) or not _finite_vector(velocity) \
			or not _finite(delta) or delta <= 0.0 or delta > 0.1 \
			or not _finite(race_time):
		invalid_motion_count += 1
		event["invalid"] = true
		return event
	if not _primed:
		prime(position)
		return event
	var displacement := position.distance_to(_previous_position)
	var maximum_displacement := MAX_LEGAL_SPEED * delta + 1.0
	var context_layer := collision_layer_hint \
		if collision_layer_hint == RaceTrackQuery.COLLISION_LAYER_GROUND \
			or collision_layer_hint == RaceTrackQuery.COLLISION_LAYER_ELEVATED \
		else _previous_track_layer
	var projection := _track.nearest_continuous(
		position,
		_previous_track_distance,
		context_layer,
		maxf(16.0, maximum_displacement * 2.0 + 8.0)
	)
	if projection.is_empty():
		invalid_motion_count += 1
		event["invalid"] = true
		return event
	var projected_distance := float(projection["distance_along"])
	var forward_delta := _track.forward_delta(_previous_track_distance, projected_distance)
	var projected_layer := int(projection.get("collision_layer", context_layer))
	var projected_mask := int(projection.get("collision_mask", projected_layer))
	if collision_mask_hint > 0 and collision_layer_hint == projected_layer:
		projected_mask = collision_mask_hint
	if displacement > maximum_displacement or absf(forward_delta) > maximum_displacement * 1.5:
		invalid_motion_count += 1
		event["invalid"] = true
		_previous_position = position
		_previous_track_distance = projected_distance
		_previous_track_layer = projected_layer
		_previous_track_mask = projected_mask
		current_track_distance = projected_distance
		current_track_layer = projected_layer
		current_track_mask = projected_mask
		return event
	if forward_delta < 0.0:
		reverse_distance += -forward_delta
	var gate_index := next_checkpoint if next_checkpoint < checkpoint_count else 0
	if _crossed_gate_forward(
		gate_index,
		_previous_position,
		position,
		velocity,
		_previous_track_layer,
		_previous_track_mask,
		projected_layer,
		projected_mask
	):
		if next_checkpoint < checkpoint_count:
			var crossed_checkpoint := next_checkpoint
			event["checkpoint"] = true
			event["checkpoint_index"] = crossed_checkpoint
			next_checkpoint += 1
			var boundaries := sector_boundary_checkpoints(checkpoint_count)
			if crossed_checkpoint == boundaries[0]:
				_record_sector(event, 1, race_time, laps_completed + 1, crossed_checkpoint)
			elif crossed_checkpoint == boundaries[1]:
				_record_sector(event, 2, race_time, laps_completed + 1, crossed_checkpoint)
		else:
			laps_completed += 1
			event["lap"] = true
			event["lap_number"] = laps_completed
			_record_sector(event, 3, race_time, laps_completed, checkpoint_count)
			next_checkpoint = 1
			if laps_completed >= total_laps:
				finished = true
				finish_tick = simulation_tick
				finish_time = maxf(0.0, race_time)
				event["finished"] = true
	_previous_position = position
	_previous_track_distance = projected_distance
	_previous_track_layer = projected_layer
	_previous_track_mask = projected_mask
	current_track_distance = projected_distance
	current_track_layer = projected_layer
	current_track_mask = projected_mask
	_update_validated_progress()
	return event


func validated_progress() -> float:
	return last_validated_progress


func checkpoint_fraction() -> float:
	if checkpoint_count <= 0:
		return 0.0
	return clampf(float(next_checkpoint - 1) / float(checkpoint_count), 0.0, 1.0)


static func sector_boundary_checkpoints(requested_checkpoint_count: int) -> PackedInt32Array:
	var count := clampi(requested_checkpoint_count, MIN_CHECKPOINTS, MAX_CHECKPOINTS)
	var first := clampi(roundi(float(count) / float(SECTOR_COUNT)), 1, count - 2)
	var second := clampi(roundi(float(count) * 2.0 / float(SECTOR_COUNT)), first + 1, count - 1)
	return PackedInt32Array([first, second, count])


func current_sector_index() -> int:
	var boundaries := sector_boundary_checkpoints(checkpoint_count)
	if next_checkpoint <= boundaries[0]:
		return 1
	if next_checkpoint <= boundaries[1]:
		return 2
	return 3


func current_sector_elapsed(race_time: float) -> float:
	if not _finite(race_time):
		return 0.0
	return maxf(0.0, race_time - _sector_started_at)


func sector_splits_snapshot() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for split in sector_splits:
		output.append(split.duplicate(true))
	return output


func gate_count() -> int:
	return _gate_distances.size()


func gate(index: int) -> Dictionary:
	if index < 0 or index >= _gate_distances.size():
		return {}
	return {
		"distance": _gate_distances[index],
		"position": _gate_positions[index],
		"tangent": _gate_tangents[index],
		"normal": _gate_normals[index],
		"collision_layer": _gate_layers[index],
		"collision_mask": _gate_masks[index],
	}


func _record_sector(
	event: Dictionary,
	sector_index: int,
	race_time: float,
	lap_number: int,
	checkpoint_boundary: int
	) -> void:
	var split_time := maxf(race_time, _sector_started_at)
	var duration := split_time - _sector_started_at
	var split := {
		"lap_number": lap_number,
		"sector_index": sector_index,
		"duration": duration,
		"race_time": split_time,
		"checkpoint_boundary": checkpoint_boundary,
	}
	sector_splits.append(split)
	_sector_started_at = split_time
	event["sector"] = true
	event["sector_index"] = sector_index
	event["sector_time"] = duration
	event["sector_race_time"] = split_time


func _crossed_gate_forward(
		gate_index: int,
	previous_position: Vector2,
	position: Vector2,
	velocity: Vector2,
	previous_layer: int,
	previous_mask: int,
	current_layer: int,
	current_mask: int
	) -> bool:
	if gate_index < 0 or gate_index >= _gate_positions.size():
		return false
	var center := _gate_positions[gate_index]
	var tangent := _gate_tangents[gate_index]
	var normal := _gate_normals[gate_index]
	var gate_layer := _gate_layers[gate_index]
	var gate_mask := _gate_masks[gate_index]
	if not _surfaces_compatible(previous_layer, previous_mask, gate_layer, gate_mask) \
			or not _surfaces_compatible(current_layer, current_mask, gate_layer, gate_mask):
		return false
	if velocity.dot(tangent) < MIN_FORWARD_GATE_SPEED:
		return false
	var previous_side := (previous_position - center).dot(tangent)
	var current_side := (position - center).dot(tangent)
	if previous_side > 0.0001 or current_side < -0.0001:
		return false
	var denominator := previous_side - current_side
	var crossing_amount := 0.5
	if absf(denominator) > 0.000001:
		crossing_amount = clampf(previous_side / denominator, 0.0, 1.0)
	var crossing_point := previous_position.lerp(position, crossing_amount)
	var gate_half_width := _track.track_width * 0.85
	return absf((crossing_point - center).dot(normal)) <= gate_half_width


static func _surfaces_compatible(
	first_layer: int,
	first_mask: int,
	second_layer: int,
	second_mask: int
	) -> bool:
	return (first_mask & second_layer) != 0 and (second_mask & first_layer) != 0


func _update_validated_progress() -> void:
	if _track == null or checkpoint_count <= 0:
		last_validated_progress = 0.0
		return
	if finished:
		last_validated_progress = float(total_laps) * _track.total_length
		return
	var sector_length := _track.total_length / float(checkpoint_count)
	var completed_in_lap := clampi(next_checkpoint - 1, 0, checkpoint_count - 1)
	var sector_start := sector_length * float(completed_in_lap)
	var local_distance := _track.wrap_distance(current_track_distance - sector_start)
	# Grid slots sit just before the start line and do not count as having driven
	# the whole first sector before the race begins.
	if laps_completed == 0 and completed_in_lap == 0 and current_track_distance > _track.total_length * 0.5:
		local_distance = 0.0
	local_distance = clampf(local_distance, 0.0, sector_length)
	last_validated_progress = float(laps_completed) * _track.total_length + sector_start + local_distance


static func _finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func _finite_vector(value: Vector2) -> bool:
	return _finite(value.x) and _finite(value.y)
