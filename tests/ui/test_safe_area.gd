extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const SafeMarginType := preload("res://game/ui/components/safe_margin_container.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	var insets := SafeMarginType.safe_insets_for_test(
		Rect2i(120, 0, 2160, 1080), Vector2i(2400, 1080), Vector2(1280.0, 720.0)
	)
	test.assert_near(insets.x, 64.0, 0.001, "left landscape cutout must scale into viewport units")
	test.assert_near(insets.z, 64.0, 0.001, "right landscape inset must scale into viewport units")
	test.assert_near(insets.y, 0.0, 0.001, "full-height safe rect has no top inset")
	var full := SafeMarginType.safe_insets_for_test(
		Rect2i(0, 0, 1920, 1080), Vector2i(1920, 1080), Vector2(1280.0, 720.0)
	)
	test.assert_equal(full, Vector4.ZERO, "full-screen safe area adds no margin")
	var broken := SafeMarginType.safe_insets_for_test(
		Rect2i(900, 0, 100, 1080), Vector2i(1920, 1080), Vector2(1280.0, 720.0)
	)
	test.assert_equal(broken, Vector4.ZERO, "implausible platform insets must fail closed")
	return test.result("safe_area")
