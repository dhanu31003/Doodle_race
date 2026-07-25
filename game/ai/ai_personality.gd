class_name AiPersonality
extends RefCounted
## Bounded deterministic traits; no runtime entropy is consumed after creation.

const StableRngType := preload("res://game/core/stable_rng.gd")
const QuantizationType := preload("res://game/core/quantization.gd")

var skill: float = 0.85
var aggression: float = 0.5
var risk: float = 0.5
var braking_precision: float = 0.95
var line_bias: float = 0.0
var overtake_commitment: float = 0.5
var top_speed_factor: float = 0.97
var reaction_ticks: int = 2
var preferred_pass_side: int = 1


static func generate(race_seed: int, driver_id: StringName, difficulty: float = 0.75) -> AiPersonality:
	var output := AiPersonality.new()
	var bounded_difficulty := clampf(difficulty, 0.0, 1.0)
	var rng := StableRngType.from_string("race-ai-v1:%d:%s" % [race_seed, str(driver_id)])
	output.skill = _quantize(clampf(0.66 + bounded_difficulty * 0.25 + rng.range_f(-0.045, 0.045), 0.62, 0.98))
	output.aggression = _quantize(rng.range_f(0.22, 0.92))
	output.risk = _quantize(rng.range_f(0.18, 0.84))
	output.braking_precision = _quantize(clampf(0.82 + bounded_difficulty * 0.24 + rng.range_f(-0.08, 0.08), 0.76, 1.10))
	output.line_bias = _quantize(rng.range_f(-0.58, 0.58))
	output.overtake_commitment = _quantize(rng.range_f(0.28, 0.94))
	output.top_speed_factor = _quantize(clampf(0.88 + bounded_difficulty * 0.13 + rng.range_f(-0.025, 0.025), 0.86, 1.03))
	# Formula drivers still react at a deterministic 15-30 Hz control cadence;
	# vehicle authority continues at 60 Hz and holds the bounded rack/pedal command.
	output.reaction_ticks = rng.range_i(2, 5)
	output.preferred_pass_side = -1 if rng.chance(0.5) else 1
	return output


func to_dictionary() -> Dictionary:
	return {
		"skill_q": QuantizationType.to_fixed(skill, 10_000),
		"aggression_q": QuantizationType.to_fixed(aggression, 10_000),
		"risk_q": QuantizationType.to_fixed(risk, 10_000),
		"braking_precision_q": QuantizationType.to_fixed(braking_precision, 10_000),
		"line_bias_q": QuantizationType.to_fixed(line_bias, 10_000),
		"overtake_commitment_q": QuantizationType.to_fixed(overtake_commitment, 10_000),
		"top_speed_factor_q": QuantizationType.to_fixed(top_speed_factor, 10_000),
		"reaction_ticks": reaction_ticks,
		"preferred_pass_side": preferred_pass_side,
	}


static func _quantize(value: float) -> float:
	return QuantizationType.scalar(value, 0.0001)
