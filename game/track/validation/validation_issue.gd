class_name ValidationIssue
extends RefCounted
## One machine-readable validation finding.

enum Severity {
	INFO,
	WARNING,
	ERROR,
}

var code: StringName
var severity: Severity
var message: String
var path: String
var details: Dictionary


func _init(
		issue_code: StringName,
		issue_severity: Severity,
		issue_message: String,
		issue_path: String = "",
		issue_details: Dictionary = {}
	) -> void:
	code = issue_code
	severity = issue_severity
	message = issue_message
	path = issue_path
	details = issue_details.duplicate(true)


func severity_name() -> String:
	match severity:
		Severity.ERROR:
			return "error"
		Severity.WARNING:
			return "warning"
		_:
			return "info"


func to_dictionary() -> Dictionary:
	return {
		"code": str(code),
		"severity": severity_name(),
		"message": message,
		"path": path,
		"details": details.duplicate(true),
	}

