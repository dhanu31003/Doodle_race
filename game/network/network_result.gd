class_name NetworkResult
extends RefCounted
## Small transport-neutral result envelope. Error codes are stable API surface.


static func success(value: Dictionary = {}) -> Dictionary:
	return {
		"ok": true,
		"value": value,
	}


static func failure(code: StringName, message: String, details: Dictionary = {}) -> Dictionary:
	return {
		"ok": false,
		"error": {
			"code": str(code),
			"message": message,
			"details": details,
		},
	}


static func code(result: Dictionary) -> String:
	return str(result.get("error", {}).get("code", ""))

