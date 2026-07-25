class_name NetworkSendScheduler
extends RefCounted
## Client cadence gate. Inputs are selectable only within 10-20 Hz and host
## snapshots within 10-15 Hz; simulation itself remains fixed at 60 Hz.

const Limits := preload("res://game/network/network_limits.gd")

var input_hz: int = Limits.INPUT_SUBMISSION_MAX_HZ
var snapshot_hz: int = 12
var _last_input_ms: int = -1_000_000
var _last_snapshot_ms: int = -1_000_000


func configure(requested_input_hz: int = 20, requested_snapshot_hz: int = 12) -> void:
	input_hz = clampi(
		requested_input_hz,
		Limits.INPUT_SUBMISSION_MIN_HZ,
		Limits.INPUT_SUBMISSION_MAX_HZ
	)
	snapshot_hz = clampi(
		requested_snapshot_hz,
		Limits.AUTHORITATIVE_SNAPSHOT_MIN_HZ,
		Limits.AUTHORITATIVE_SNAPSHOT_MAX_HZ
	)


func input_due(now_ms: int) -> bool:
	return now_ms >= _last_input_ms + _ceil_interval_ms(input_hz)


func snapshot_due(now_ms: int) -> bool:
	return now_ms >= _last_snapshot_ms + _ceil_interval_ms(snapshot_hz)


func mark_input_sent(now_ms: int) -> void:
	_last_input_ms = now_ms


func mark_snapshot_sent(now_ms: int) -> void:
	_last_snapshot_ms = now_ms


func reset() -> void:
	_last_input_ms = -1_000_000
	_last_snapshot_ms = -1_000_000


func _ceil_interval_ms(rate_hz: int) -> int:
	return ceili(1000.0 / float(maxi(1, rate_hz)))

