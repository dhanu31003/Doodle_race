class_name Quantization
extends RefCounted
## Deterministic conversion between world-space floats and fixed-point ints.

const GameLimitsType := preload("res://game/config/game_limits.gd")


static func scalar(value: float, quantum: float = GameLimitsType.COORDINATE_QUANTUM) -> float:
	if not is_finite_scalar(value) or not is_finite_scalar(quantum) or quantum <= 0.0:
		return value
	var quantized: float = round(value / quantum) * quantum
	# Do not use is_zero_approx here: its epsilon is larger than the normalized
	# 1e-6 grid and would collapse several valid fixed-point values to zero.
	return 0.0 if quantized == 0.0 else quantized


static func vector2(value: Vector2, quantum: float = GameLimitsType.COORDINATE_QUANTUM) -> Vector2:
	return Vector2(scalar(value.x, quantum), scalar(value.y, quantum))


static func packed_vector2(
		values: PackedVector2Array,
		quantum: float = GameLimitsType.COORDINATE_QUANTUM
	) -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(values.size())
	for index in values.size():
		output[index] = vector2(values[index], quantum)
	return output


static func to_fixed(value: float, scale: int = GameLimitsType.COORDINATE_SCALE) -> int:
	if not is_finite_scalar(value) or scale <= 0:
		return 0
	return int(round(value * float(scale)))


static func from_fixed(value: int, scale: int = GameLimitsType.COORDINATE_SCALE) -> float:
	if scale <= 0:
		return 0.0
	return float(value) / float(scale)


static func vector2_to_fixed(
		value: Vector2,
		scale: int = GameLimitsType.COORDINATE_SCALE
	) -> Vector2i:
	return Vector2i(to_fixed(value.x, scale), to_fixed(value.y, scale))


static func vector2_from_fixed(
		value: Vector2i,
		scale: int = GameLimitsType.COORDINATE_SCALE
	) -> Vector2:
	return Vector2(from_fixed(value.x, scale), from_fixed(value.y, scale))


static func is_finite_scalar(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)


static func is_finite_vector2(value: Vector2) -> bool:
	return is_finite_scalar(value.x) and is_finite_scalar(value.y)
