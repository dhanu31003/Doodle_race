extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const StableRngType := preload("res://game/core/stable_rng.gd")
const QuantizationType := preload("res://game/core/quantization.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_golden_sequence(test)
	_test_string_seed_and_shuffle(test)
	_test_quantization_and_canonical_json(test)
	return test.result("stable_rng_and_fixed_math")


func _test_golden_sequence(test: RefCounted) -> void:
	var rng := StableRngType.new(1)
	var expected := [270369, 67634689, 2647435461, 307599695, 2398689233]
	for value in expected:
		test.assert_equal(rng.next_u32(), value, "xorshift32 sequence must stay stable")
	var first := StableRngType.new(999)
	var second := StableRngType.new(999)
	for index in 100:
		test.assert_equal(first.next_u32(), second.next_u32(), "equal seeds must remain identical at %d" % index)


func _test_string_seed_and_shuffle(test: RefCounted) -> void:
	var first := StableRngType.from_string("fixture-track")
	var second := StableRngType.from_string("fixture-track")
	var values_a := [0, 1, 2, 3, 4, 5]
	var values_b := values_a.duplicate()
	first.shuffle(values_a)
	second.shuffle(values_b)
	test.assert_equal(values_a, values_b, "string-seeded shuffle must be reproducible")
	test.assert_true(first.range_f(-2.0, 3.0) >= -2.0, "range_f must respect lower bound")
	var decorations_a := first.fork(&"decorations")
	var decorations_b := first.fork(&"decorations")
	var opponents := first.fork(&"opponents")
	test.assert_equal(decorations_a.next_u32(), decorations_b.next_u32(), "named stream forks must reproduce")
	test.assert_true(decorations_a.next_u32() != opponents.next_u32(), "different stream names must decorrelate sequences")
	var wide_rng := StableRngType.new(123456)
	var reached_upper_half := false
	for index in 100:
		if wide_rng.range_i(0, 1 << 33) >= 1 << 32:
			reached_upper_half = true
			break
	test.assert_true(reached_upper_half, "ranges wider than u32 must reach their upper half")


func _test_quantization_and_canonical_json(test: RefCounted) -> void:
	test.assert_near(QuantizationType.scalar(1.23456, 0.001), 1.235, 0.0000001, "scalar quantization")
	test.assert_equal(QuantizationType.scalar(0.000001, 0.000001), 0.000001, "normalized quantum must not collapse to zero")
	test.assert_equal(QuantizationType.scalar(-0.0, 0.000001), 0.0, "negative zero must canonicalize")
	var first := {"z": 2, "a": [1.25, true]}
	var second := {"a": [1.25, true], "z": 2}
	test.assert_equal(CanonicalJsonType.stringify(first), CanonicalJsonType.stringify(second), "dictionary insertion order must not affect canonical JSON")
	test.assert_equal(CanonicalJsonType.stringify(first), "{\"a\":[1.25,true],\"z\":2}", "canonical JSON golden text")
	var assertion_probe := TestCaseType.new()
	assertion_probe.assert_near(NAN, 0.0, 1.0, "NaN probe")
	test.assert_false(assertion_probe.result("probe")["passed"], "assert_near must never accept NaN")
