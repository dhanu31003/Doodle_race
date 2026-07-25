class_name ValidationReport
extends RefCounted
## Structured validation result suitable for UI, tests, and telemetry.

const ValidationIssueType := preload("res://game/track/validation/validation_issue.gd")

var issues: Array[ValidationIssue] = []


func add_issue(issue: ValidationIssue) -> ValidationIssue:
	issues.append(issue)
	return issue


func add_error(
		code: StringName,
		message: String,
		path: String = "",
		details: Dictionary = {}
	) -> ValidationIssue:
	return add_issue(ValidationIssueType.new(
		code, ValidationIssueType.Severity.ERROR, message, path, details
	))


func add_warning(
		code: StringName,
		message: String,
		path: String = "",
		details: Dictionary = {}
	) -> ValidationIssue:
	return add_issue(ValidationIssueType.new(
		code, ValidationIssueType.Severity.WARNING, message, path, details
	))


func add_info(
		code: StringName,
		message: String,
		path: String = "",
		details: Dictionary = {}
	) -> ValidationIssue:
	return add_issue(ValidationIssueType.new(
		code, ValidationIssueType.Severity.INFO, message, path, details
	))


func merge(other: ValidationReport) -> void:
	if other == null:
		return
	for issue in other.issues:
		issues.append(issue)


func is_valid() -> bool:
	return error_count() == 0


func error_count() -> int:
	var count := 0
	for issue in issues:
		if issue.severity == ValidationIssueType.Severity.ERROR:
			count += 1
	return count


func warning_count() -> int:
	var count := 0
	for issue in issues:
		if issue.severity == ValidationIssueType.Severity.WARNING:
			count += 1
	return count


func has_code(code: StringName) -> bool:
	for issue in issues:
		if issue.code == code:
			return true
	return false


func to_dictionary() -> Dictionary:
	var serialized_issues: Array[Dictionary] = []
	for issue in issues:
		serialized_issues.append(issue.to_dictionary())
	return {
		"valid": is_valid(),
		"error_count": error_count(),
		"warning_count": warning_count(),
		"issues": serialized_issues,
	}

