class_name TestCase
extends RefCounted
## Minimal assertion collector for executable headless GDScript test suites.

var _failures := PackedStringArray()
var _assertion_count: int = 0


func assert_true(condition: bool, message: String) -> void:
	_assertion_count += 1
	if not condition:
		_failures.append(message)


func assert_false(condition: bool, message: String) -> void:
	assert_true(not condition, message)


func assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assertion_count += 1
	if actual != expected:
		_failures.append("%s (actual=%s expected=%s)" % [message, str(actual), str(expected)])


func assert_near(actual: float, expected: float, tolerance: float, message: String) -> void:
	_assertion_count += 1
	if actual == expected:
		return
	if is_nan(actual) or is_nan(expected) or is_inf(actual) or is_inf(expected) \
			or absf(actual - expected) > tolerance:
		_failures.append("%s (actual=%f expected=%f tolerance=%f)" % [message, actual, expected, tolerance])


func result(suite_name: String) -> Dictionary:
	return {
		"suite": suite_name,
		"passed": _failures.is_empty(),
		"assertions": _assertion_count,
		"failures": Array(_failures),
	}
