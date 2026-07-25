class_name StableRng
extends RefCounted
## Version-independent xorshift32 RNG for reproducible authored content.

const MASK_32: int = 0xffffffff
const UINT32_MODULUS: int = 0x100000000
const UINT32_RANGE: float = 4294967296.0
const INT63_MAX: int = 0x7fffffffffffffff
const ZERO_SEED_REPLACEMENT: int = 0x6d2b79f5

var _state: int = ZERO_SEED_REPLACEMENT


func _init(seed_value: int = ZERO_SEED_REPLACEMENT) -> void:
	set_state(seed_value)


func seed(seed_value: int) -> void:
	set_state(seed_value)


func state() -> int:
	return _state


func set_state(state_value: int) -> void:
	_state = state_value & MASK_32
	if _state == 0:
		_state = ZERO_SEED_REPLACEMENT


func next_u32() -> int:
	var value := _state
	value = value ^ ((value << 13) & MASK_32)
	value = value ^ (value >> 17)
	value = value ^ ((value << 5) & MASK_32)
	_state = value & MASK_32
	return _state


func next_float() -> float:
	return float(next_u32()) / UINT32_RANGE


func range_i(minimum: int, maximum_exclusive: int) -> int:
	if maximum_exclusive <= minimum:
		return minimum
	var span: int = maximum_exclusive - minimum
	if span >= UINT32_MODULUS:
		# Compose 63 uniform bits so ranges wider than u32 remain reachable.
		var threshold: int = ((INT63_MAX % span) + 1) % span
		var wide_value := _next_u63()
		while wide_value < threshold:
			wide_value = _next_u63()
		return minimum + int(wide_value % span)
	# Rejection sampling avoids modulo bias while remaining fully deterministic.
	var accepted_limit: int = (UINT32_MODULUS / span) * span
	var value := next_u32()
	while value >= accepted_limit:
		value = next_u32()
	return minimum + int(value % span)


func range_f(minimum: float, maximum: float) -> float:
	if maximum <= minimum:
		return minimum
	return minimum + (maximum - minimum) * next_float()


func chance(probability: float) -> bool:
	return next_float() < clampf(probability, 0.0, 1.0)


func choose(values: Array, fallback: Variant = null) -> Variant:
	if values.is_empty():
		return fallback
	return values[range_i(0, values.size())]


func shuffle(values: Array) -> void:
	for index in range(values.size() - 1, 0, -1):
		var other := range_i(0, index + 1)
		var temporary: Variant = values[index]
		values[index] = values[other]
		values[other] = temporary


func fork(stream_name: StringName) -> StableRng:
	# Forks do not consume the parent stream, so adding a new subsystem cannot
	# perturb existing decoration, AI, or gameplay sequences.
	return StableRng.from_string("%08x:%s" % [_state, str(stream_name)])


func _next_u63() -> int:
	var high_31 := next_u32() & 0x7fffffff
	var low_32 := next_u32()
	return (high_31 << 32) | low_32


static func seed_from_string(value: String) -> int:
	# FNV-1a over UTF-8 is simple, specified, and stable on every target.
	var hash_value: int = 2166136261
	for byte in value.to_utf8_buffer():
		hash_value = hash_value ^ int(byte)
		hash_value = (hash_value * 16777619) & MASK_32
	return ZERO_SEED_REPLACEMENT if hash_value == 0 else hash_value


static func from_string(value: String) -> StableRng:
	return StableRng.new(seed_from_string(value))
