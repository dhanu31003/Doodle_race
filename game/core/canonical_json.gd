class_name CanonicalJson
extends RefCounted
## Canonical JSON serializer: sorted object keys, deterministic numeric text,
## no whitespace. TrackDefinition quantizes coordinates before reaching here.

const QuantizationType := preload("res://game/core/quantization.gd")


static func stringify(value: Variant) -> String:
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_BOOL:
			return "true" if value else "false"
		TYPE_INT:
			return str(value)
		TYPE_FLOAT:
			return _float_to_string(value)
		TYPE_STRING, TYPE_STRING_NAME:
			return JSON.stringify(str(value))
		TYPE_VECTOR2:
			return "[%s,%s]" % [_float_to_string(value.x), _float_to_string(value.y)]
		TYPE_VECTOR2I:
			return "[%d,%d]" % [value.x, value.y]
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, \
				TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, \
				TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
				TYPE_PACKED_VECTOR2_ARRAY:
			return _array_to_string(value)
		TYPE_DICTIONARY:
			return _dictionary_to_string(value)
		_:
			push_error("CanonicalJson cannot serialize Variant type %d" % typeof(value))
			return "null"


static func sha256(value: Variant) -> String:
	return stringify(value).sha256_text()


static func _array_to_string(values: Variant) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(stringify(value))
	return "[" + ",".join(parts) + "]"


static func _dictionary_to_string(values: Dictionary) -> String:
	var keys := PackedStringArray()
	for key in values.keys():
		if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
			push_error("CanonicalJson dictionaries require string keys")
		keys.append(str(key))
	keys.sort()
	var parts := PackedStringArray()
	for key in keys:
		parts.append(JSON.stringify(key) + ":" + stringify(values[key]))
	return "{" + ",".join(parts) + "}"


static func _float_to_string(value: float) -> String:
	if is_nan(value):
		return JSON.stringify("NaN")
	if is_inf(value):
		return JSON.stringify("-Infinity" if value < 0.0 else "Infinity")
	# Values must be quantized by their owning schema. Nine fixed decimals are
	# enough for all v1 scales and avoid platform-specific exponent formatting.
	var formatted := "%.9f" % value
	while formatted.contains(".") and formatted.ends_with("0"):
		formatted = formatted.left(formatted.length() - 1)
	if formatted.ends_with("."):
		formatted = formatted.left(formatted.length() - 1)
	return "0" if formatted == "-0" else formatted
