class_name TrackCompileResult
extends RefCounted
## Compilation returns previewable output and all validation findings together.

const ValidationReportType := preload("res://game/track/validation/validation_report.gd")

var track: CompiledTrack
var report: ValidationReport = ValidationReportType.new()


func succeeded() -> bool:
	return track != null and report.is_valid()

