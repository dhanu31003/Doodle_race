class_name RaceEntry
extends RefCounted
## Runtime aggregate for one classified race participant.

const STATUS_GRID: StringName = &"grid"
const STATUS_RACING: StringName = &"racing"
const STATUS_FINISHED: StringName = &"finished"
const STATUS_DNF: StringName = &"dnf"

var participant_id: StringName = &""
var display_name: String = ""
var is_human: bool = false
var grid_position: int = 0
var status: StringName = STATUS_GRID
var state: VehicleState
var previous_state: VehicleState
var lap_tracker: LapTracker
var vehicle_model: ArcadeVehicleModel
var controller: Variant = null
var finish_order: int = 0
var finish_time: float = -1.0
var dnf_reason: StringName = &""
var race_position: int = 0
var automatic_recovery_count: int = 0
var recovery_stagnant_ticks: int = 0
var recovery_progress_anchor: float = 0.0
var recovery_checkpoint_anchor: int = 1
var recovery_last_wall_contacts: int = 0
var recovery_last_contact_tick: int = -1_000_000
var recovery_cooldown_until_tick: int = 0
var recovery_last_tick: int = -1
var recovery_last_reason: StringName = &""
var recovery_offtrack_count: int = 0
var recovery_contact_count: int = 0
var recovery_events: Array[Dictionary] = []


func classification_progress() -> float:
	if lap_tracker == null:
		return 0.0
	return lap_tracker.validated_progress()


func result_dictionary() -> Dictionary:
	return {
		"participant_id": str(participant_id),
		"display_name": display_name,
		"grid_position": grid_position,
		"position": race_position,
		"status": str(status),
		"laps_completed": lap_tracker.laps_completed if lap_tracker != null else 0,
		"finish_time": finish_time,
		"finish_order": finish_order,
		"dnf_reason": str(dnf_reason),
		"automatic_recoveries": automatic_recovery_count,
		"last_recovery_tick": recovery_last_tick,
		"last_recovery_reason": str(recovery_last_reason),
		"offtrack_recoveries": recovery_offtrack_count,
		"contact_recoveries": recovery_contact_count,
		"recovery_events": recovery_events.duplicate(true),
	}
