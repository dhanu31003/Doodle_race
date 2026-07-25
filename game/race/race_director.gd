class_name RaceDirector
extends RefCounted
## Pause-safe fixed-step race lifecycle, simulation, contacts, and classification.

const RaceInputType := preload("res://game/race/race_input.gd")
const VehicleConfigType := preload("res://game/race/vehicle_config.gd")
const VehicleModelType := preload("res://game/race/arcade_vehicle_model.gd")
const LapTrackerType := preload("res://game/race/lap_tracker.gd")
const RaceEntryType := preload("res://game/race/race_entry.gd")

const PHASE_SETUP: StringName = &"setup"
const PHASE_COUNTDOWN: StringName = &"countdown"
const PHASE_RACING: StringName = &"racing"
const PHASE_RESULTS: StringName = &"results"
const MAX_ENTRIES: int = 12
const FIXED_DT: float = VehicleModelType.FIXED_DT
const MAX_FRAME_DELTA: float = 0.25
const MAX_TICKS_PER_FRAME: int = 16
const VEHICLE_CONTACT_SOLVER_ITERATIONS: int = 32
const VEHICLE_CONTACT_FINAL_ITERATIONS: int = 8
# A staggered Formula grid alternates lanes, so nine authority units per slot
# gives every same-lane pair 18 units—two units beyond the 16-unit capsule
# length. The former paired 12.5-unit row pitch placed same-lane cars only 12.5
# apart and spawned a pile-up. Nine-unit staggering also keeps all twelve slots
# inside the catalog's validated start straight instead of curling the rear rows
# into the preceding corner.
const GRID_FIRST_SLOT_OFFSET: float = 8.0
const GRID_SLOT_SPACING: float = 9.0
const AUTOMATIC_RECOVERY_DELAY_TICKS: int = 5 * VehicleModelType.FIXED_HZ
const AUTOMATIC_RECOVERY_COOLDOWN_TICKS: int = 8 * VehicleModelType.FIXED_HZ
# A single resolved barrier impact is enough to establish a blocked-contact
# episode. Keep that evidence for the same five-second interval required by the
# recovery counter; a shorter grace can never satisfy the delay after one hit.
const AUTOMATIC_RECOVERY_CONTACT_GRACE_TICKS: int = AUTOMATIC_RECOVERY_DELAY_TICKS
const AUTOMATIC_RECOVERY_MAX_BLOCKED_SPEED: float = 36.0
const AUTOMATIC_RECOVERY_PROGRESS_EPSILON: float = 1.0
const MAX_AUTOMATIC_RECOVERIES: int = 24

var phase: StringName = PHASE_SETUP
var paused: bool = false
var countdown_duration: float = 3.0
var countdown_remaining: float = 3.0
var race_time: float = 0.0
var race_time_limit: float = 600.0
var fixed_tick: int = 0
var race_seed: int = 1
var total_laps: int = 3
var checkpoint_count: int = 8
var vehicle_collisions_enabled: bool = true
var entries: Array[RaceEntry] = []
# Read-only-after-tick diagnostics for performance regression tests. They do not
# participate in authority, replay snapshots or network serialization.
var contact_solver_passes_last_tick: int = 0
var contact_pair_checks_last_tick: int = 0
var contact_resolutions_last_tick: int = 0

var _track: RaceTrackQuery
var _accumulator: float = 0.0
var _finish_count: int = 0


func configure(
		track: RaceTrackQuery,
		lap_count: int = 3,
		seed_value: int = 1,
		requested_checkpoints: int = 8,
		enable_vehicle_collisions: bool = true
	) -> bool:
	if track == null or not track.is_valid() or not entries.is_empty():
		return false
	_track = track
	total_laps = clampi(lap_count, 1, 99)
	race_seed = seed_value
	checkpoint_count = clampi(requested_checkpoints, 4, 32)
	vehicle_collisions_enabled = enable_vehicle_collisions
	return true


func add_entry(
		participant_id: StringName,
		display_name: String,
		is_human: bool,
		controller: Variant = null,
		vehicle_config: VehicleConfig = null
	) -> RaceEntry:
	if phase != PHASE_SETUP or _track == null or not _track.is_valid():
		return null
	if entries.size() >= MAX_ENTRIES or participant_id == &"" or _entry_for(participant_id) != null:
		return null
	var entry := RaceEntryType.new()
	entry.participant_id = participant_id
	entry.display_name = display_name.strip_edges().substr(0, 40)
	if entry.display_name.is_empty():
		entry.display_name = str(participant_id)
	entry.is_human = is_human
	entry.controller = controller
	entry.grid_position = entries.size() + 1
	entry.vehicle_model = VehicleModelType.new(
		vehicle_config if vehicle_config != null else VehicleConfigType.new()
	)
	if entry.controller != null and entry.controller.has_method("configure_vehicle_dynamics"):
		entry.controller.configure_vehicle_dynamics(entry.vehicle_model.config)
	var row := entry.grid_position - 1
	var grid_distance := -GRID_FIRST_SLOT_OFFSET - float(row) * GRID_SLOT_SPACING
	var lane_side := -1.0 if row % 2 == 0 else 1.0
	var lateral := lane_side * minf(_track.track_width * 0.22, 7.0)
	entry.state = entry.vehicle_model.create_state(participant_id, _track, grid_distance, lateral)
	entry.previous_state = entry.state.duplicate_state()
	entry.lap_tracker = LapTrackerType.new()
	if not entry.lap_tracker.configure(_track, total_laps, checkpoint_count):
		return null
	entry.lap_tracker.prime(
		entry.state.position,
		entry.state.track_distance,
		entry.state.track_collision_layer
	)
	_reset_recovery_monitor(entry)
	entries.append(entry)
	return entry


func start() -> bool:
	if phase != PHASE_SETUP or entries.is_empty() or _track == null or not _track.is_valid():
		return false
	phase = PHASE_COUNTDOWN
	paused = false
	countdown_remaining = maxf(0.0, countdown_duration)
	race_time = 0.0
	fixed_tick = 0
	_accumulator = 0.0
	_finish_count = 0
	if countdown_remaining <= 0.0:
		_begin_racing()
	return true


func set_paused(value: bool) -> void:
	if phase == PHASE_COUNTDOWN or phase == PHASE_RACING:
		paused = value


func advance_frame(frame_delta: float, human_commands: Dictionary = {}) -> int:
	if paused or phase == PHASE_SETUP or phase == PHASE_RESULTS:
		return 0
	if is_nan(frame_delta) or is_inf(frame_delta) or frame_delta <= 0.0:
		return 0
	_accumulator += minf(frame_delta, MAX_FRAME_DELTA)
	var executed := 0
	while _accumulator + 0.000000001 >= FIXED_DT and executed < MAX_TICKS_PER_FRAME:
		_accumulator -= FIXED_DT
		if absf(_accumulator) < 0.000000001:
			_accumulator = 0.0
		tick_fixed(human_commands)
		executed += 1
	return executed


func tick_fixed(human_commands: Dictionary = {}) -> void:
	if paused or phase == PHASE_SETUP or phase == PHASE_RESULTS:
		return
	fixed_tick += 1
	if phase == PHASE_COUNTDOWN:
		countdown_remaining = maxf(0.0, countdown_remaining - FIXED_DT)
		if countdown_remaining <= 0.000001:
			_begin_racing()
		return
	if phase != PHASE_RACING:
		return
	race_time += FIXED_DT
	var active := _active_entries_sorted()
	var decision_states: Array = []
	for entry in active:
		decision_states.append(entry.state.duplicate_state())
	var commands: Dictionary = {}
	for entry in active:
		var command := RaceInputType.new()
		if entry.is_human:
			var supplied: Variant = human_commands.get(
				entry.participant_id, human_commands.get(str(entry.participant_id), null)
			)
			if supplied is RaceInput:
				command = supplied.duplicate_input()
		elif entry.controller != null and entry.controller.has_method("command"):
			var generated: Variant = entry.controller.command(
				entry.state, _track, decision_states, entry.state.simulation_tick
			)
			if generated is RaceInput:
				command = generated
		# Boost is not part of the shipped race-control contract. The dormant bit
		# remains on RaceInput only so legacy replays can still be decoded directly
		# by the vehicle model; authoritative offline/network races always clear it.
		command.nitro = false
		commands[entry.participant_id] = command
	for entry in active:
		entry.previous_state = entry.state.duplicate_state()
		entry.vehicle_model.step_fixed(entry.state, commands[entry.participant_id], _track)
	if vehicle_collisions_enabled:
		_resolve_vehicle_contacts(active)
	for entry in active:
		var lap_event := entry.lap_tracker.update(
			entry.state.position,
			entry.state.velocity,
			FIXED_DT,
			fixed_tick,
			race_time,
			entry.state.track_collision_layer,
			entry.state.track_collision_mask
		)
		if bool(lap_event.get("finished", false)):
			_finish_count += 1
			entry.finish_order = _finish_count
			entry.finish_time = entry.lap_tracker.finish_time
			entry.status = RaceEntryType.STATUS_FINISHED
		elif _update_automatic_recovery(entry):
			# Recovery re-primes only the projection baseline. Ordered checkpoint and
			# lap authority are intentionally retained, so recovery cannot grant race
			# progress or cross a gate on the entrant's behalf.
			entry.lap_tracker.prime(
				entry.state.position,
				entry.state.track_distance,
				entry.state.track_collision_layer
			)
			entry.previous_state = entry.state.duplicate_state()
	if race_time >= race_time_limit:
		for entry in entries:
			if entry.status == RaceEntryType.STATUS_RACING:
				mark_dnf(entry.participant_id, &"time_limit")
	_update_positions()
	if _racing_entry_count() == 0:
		phase = PHASE_RESULTS
		paused = false
		_accumulator = 0.0


func _resolve_vehicle_contacts(active: Array[RaceEntry]) -> void:
	contact_solver_passes_last_tick = 0
	contact_pair_checks_last_tick = 0
	contact_resolutions_last_tick = 0
	if active.size() < 2:
		return
	# Stable participant-id sorting in _active_entries_sorted plus fixed pass
	# counts makes this Gauss-Seidel capsule solver replay/network deterministic.
	# Rechecking walls between passes prevents a pile-up from separating a car
	# through the outer barrier. A short contact-only tail removes any remaining
	# sub-quantization penetration introduced by the last wall clamp.
	for _iteration in VEHICLE_CONTACT_SOLVER_ITERATIONS:
		var pass_contact := _resolve_vehicle_contact_pass(active)
		if not pass_contact:
			return
		for entry in active:
			entry.vehicle_model.refresh_track_context_after_contact(entry.state, _track)
	for _iteration in VEHICLE_CONTACT_FINAL_ITERATIONS:
		if not _resolve_vehicle_contact_pass(active):
			break


func _resolve_vehicle_contact_pass(active: Array[RaceEntry]) -> bool:
	contact_solver_passes_last_tick += 1
	var pass_contact := false
	for first_index in active.size():
		for second_index in range(first_index + 1, active.size()):
			contact_pair_checks_last_tick += 1
			var first := active[first_index]
			var second := active[second_index]
			var contacted := first.vehicle_model.resolve_vehicle_contact(
				first.state,
				second.state,
				second.vehicle_model.config,
				true
			)
			if contacted:
				contact_resolutions_last_tick += 1
				pass_contact = true
				first.recovery_last_contact_tick = fixed_tick
				second.recovery_last_contact_tick = fixed_tick
	return pass_contact


func mark_dnf(participant_id: StringName, reason: StringName = &"retired") -> bool:
	var entry := _entry_for(participant_id)
	if entry == null or entry.status != RaceEntryType.STATUS_RACING:
		return false
	entry.status = RaceEntryType.STATUS_DNF
	entry.dnf_reason = reason
	entry.finish_time = race_time
	_update_positions()
	if _racing_entry_count() == 0:
		phase = PHASE_RESULTS
	return true


func standings() -> Array[RaceEntry]:
	var ordered := entries.duplicate()
	ordered.sort_custom(_classifies_before)
	for index in ordered.size():
		ordered[index].race_position = index + 1
	return ordered


func results() -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for entry in standings():
		output.append(entry.result_dictionary())
	return output


func entry(participant_id: StringName) -> RaceEntry:
	return _entry_for(participant_id)


func track() -> RaceTrackQuery:
	return _track


func interpolation_alpha() -> float:
	if paused or phase == PHASE_SETUP or phase == PHASE_RESULTS:
		return 0.0
	return clampf(_accumulator / FIXED_DT, 0.0, 1.0)


func _begin_racing() -> void:
	phase = PHASE_RACING
	countdown_remaining = 0.0
	for entry in entries:
		entry.status = RaceEntryType.STATUS_RACING
		_reset_recovery_monitor(entry)
	_update_positions()


func _update_automatic_recovery(entry: RaceEntry) -> bool:
	if entry == null or entry.status != RaceEntryType.STATUS_RACING:
		return false
	var progress := entry.classification_progress()
	var checkpoint := entry.lap_tracker.next_checkpoint
	var progressed := progress >= entry.recovery_progress_anchor \
		+ AUTOMATIC_RECOVERY_PROGRESS_EPSILON
	var checkpoint_advanced := checkpoint != entry.recovery_checkpoint_anchor
	if progressed or checkpoint_advanced:
		entry.recovery_progress_anchor = progress
		entry.recovery_checkpoint_anchor = checkpoint
		entry.recovery_stagnant_ticks = 0
	if entry.state.wall_contacts > entry.recovery_last_wall_contacts:
		entry.recovery_last_contact_tick = fixed_tick
	entry.recovery_last_wall_contacts = entry.state.wall_contacts
	if progressed or checkpoint_advanced:
		return false
	var recently_contacted := fixed_tick - entry.recovery_last_contact_tick \
		<= AUTOMATIC_RECOVERY_CONTACT_GRACE_TICKS
	var blocked := entry.state.is_offtrack or recently_contacted
	var recovery_reason: StringName = &"blocked_offtrack" \
		if entry.state.is_offtrack else &"blocked_contact"
	var slow := entry.state.speed() <= AUTOMATIC_RECOVERY_MAX_BLOCKED_SPEED
	var cooling_down := fixed_tick < entry.recovery_cooldown_until_tick
	if not blocked or not slow or cooling_down:
		entry.recovery_stagnant_ticks = 0
		return false
	entry.recovery_stagnant_ticks += 1
	if entry.recovery_stagnant_ticks < AUTOMATIC_RECOVERY_DELAY_TICKS \
			or entry.automatic_recovery_count >= MAX_AUTOMATIC_RECOVERIES:
		return false
	var laps_before := entry.lap_tracker.laps_completed
	var checkpoint_before := entry.lap_tracker.next_checkpoint
	if not entry.vehicle_model.recover_to_track(entry.state, _track):
		return false
	# The vehicle recovery API cannot mutate lap authority. Keep this guard close
	# to the call so a future refactor fails closed instead of awarding progress.
	if entry.lap_tracker.laps_completed != laps_before \
			or entry.lap_tracker.next_checkpoint != checkpoint_before:
		return false
	entry.automatic_recovery_count += 1
	entry.recovery_last_tick = fixed_tick
	entry.recovery_last_reason = recovery_reason
	if recovery_reason == &"blocked_offtrack":
		entry.recovery_offtrack_count += 1
	else:
		entry.recovery_contact_count += 1
	entry.state.recovery_hard_snap_serial = entry.automatic_recovery_count
	entry.state.last_recovery_tick = fixed_tick
	entry.state.last_recovery_reason = recovery_reason
	entry.state.quantize_authority()
	entry.recovery_events.append({
		"tick": fixed_tick,
		"reason": str(recovery_reason),
		"track_distance": entry.state.track_distance,
		"lateral_offset": entry.state.lateral_offset,
		"collision_layer": entry.state.track_collision_layer,
		"bridge_id": entry.state.bridge_id,
	})
	entry.recovery_cooldown_until_tick = fixed_tick + AUTOMATIC_RECOVERY_COOLDOWN_TICKS
	entry.recovery_stagnant_ticks = 0
	entry.recovery_progress_anchor = entry.classification_progress()
	entry.recovery_checkpoint_anchor = entry.lap_tracker.next_checkpoint
	entry.recovery_last_wall_contacts = entry.state.wall_contacts
	entry.recovery_last_contact_tick = -1_000_000
	return true


func _reset_recovery_monitor(entry: RaceEntry) -> void:
	if entry == null:
		return
	entry.recovery_stagnant_ticks = 0
	entry.recovery_progress_anchor = entry.classification_progress()
	entry.recovery_checkpoint_anchor = entry.lap_tracker.next_checkpoint
	entry.recovery_last_wall_contacts = entry.state.wall_contacts
	entry.recovery_last_contact_tick = -1_000_000
	entry.recovery_cooldown_until_tick = 0
	entry.recovery_last_tick = -1
	entry.recovery_last_reason = &""


func _active_entries_sorted() -> Array[RaceEntry]:
	var active: Array[RaceEntry] = []
	for entry in entries:
		if entry.status == RaceEntryType.STATUS_RACING:
			active.append(entry)
	active.sort_custom(func(first: RaceEntry, second: RaceEntry) -> bool:
		return str(first.participant_id) < str(second.participant_id)
	)
	return active


func _update_positions() -> void:
	standings()


func _classifies_before(first: RaceEntry, second: RaceEntry) -> bool:
	var first_priority := _status_priority(first.status)
	var second_priority := _status_priority(second.status)
	if first_priority != second_priority:
		return first_priority < second_priority
	if first.status == RaceEntryType.STATUS_FINISHED:
		return first.finish_order < second.finish_order
	if first.status == RaceEntryType.STATUS_RACING:
		var first_progress := first.classification_progress()
		var second_progress := second.classification_progress()
		if not is_equal_approx(first_progress, second_progress):
			return first_progress > second_progress
	return first.grid_position < second.grid_position


func _status_priority(status: StringName) -> int:
	if status == RaceEntryType.STATUS_FINISHED:
		return 0
	if status == RaceEntryType.STATUS_RACING:
		return 1
	if status == RaceEntryType.STATUS_GRID:
		return 2
	return 3


func _racing_entry_count() -> int:
	var count := 0
	for entry in entries:
		if entry.status == RaceEntryType.STATUS_RACING:
			count += 1
	return count


func _entry_for(participant_id: StringName) -> RaceEntry:
	for entry in entries:
		if entry.participant_id == participant_id:
			return entry
	return null
