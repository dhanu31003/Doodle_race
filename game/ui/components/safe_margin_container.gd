class_name SafeMarginContainer
extends MarginContainer
## Base design margin plus platform cutout/home-indicator insets in viewport units.

var _base := Vector4.ZERO # left, top, right, bottom


func configure(left: int, top: int, right: int, bottom: int) -> void:
	_base = Vector4(left, top, right, bottom)
	if is_inside_tree():
		_apply_insets()
	else:
		_apply_margins(Vector4.ZERO)


func _ready() -> void:
	get_viewport().size_changed.connect(_apply_insets)
	_apply_insets()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_apply_insets()


func _apply_insets() -> void:
	var extra := _safe_insets_for_viewport(
		DisplayServer.get_display_safe_area(),
		DisplayServer.screen_get_size(),
		get_viewport_rect().size
	)
	_apply_margins(extra)


func _apply_margins(extra: Vector4) -> void:
	add_theme_constant_override("margin_left", roundi(_base.x + extra.x))
	add_theme_constant_override("margin_top", roundi(_base.y + extra.y))
	add_theme_constant_override("margin_right", roundi(_base.z + extra.z))
	add_theme_constant_override("margin_bottom", roundi(_base.w + extra.w))


static func safe_insets_for_test(safe_rect: Rect2i, screen_size: Vector2i, viewport_size: Vector2) -> Vector4:
	return _safe_insets_for_viewport(safe_rect, screen_size, viewport_size)


static func _safe_insets_for_viewport(safe_rect: Rect2i, screen_size: Vector2i, viewport_size: Vector2) -> Vector4:
	if screen_size.x <= 0 or screen_size.y <= 0 or viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return Vector4.ZERO
	if safe_rect.size.x <= 0 or safe_rect.size.y <= 0:
		return Vector4.ZERO
	var left_px := clampi(safe_rect.position.x, 0, screen_size.x)
	var top_px := clampi(safe_rect.position.y, 0, screen_size.y)
	var right_px := clampi(screen_size.x - safe_rect.end.x, 0, screen_size.x)
	var bottom_px := clampi(screen_size.y - safe_rect.end.y, 0, screen_size.y)
	var output := Vector4(
		float(left_px) / float(screen_size.x) * viewport_size.x,
		float(top_px) / float(screen_size.y) * viewport_size.y,
		float(right_px) / float(screen_size.x) * viewport_size.x,
		float(bottom_px) / float(screen_size.y) * viewport_size.y
	)
	# Fail closed against desktop window coordinates or a broken platform report.
	if output.x > viewport_size.x * 0.20 or output.z > viewport_size.x * 0.20 \
			or output.y > viewport_size.y * 0.20 or output.w > viewport_size.y * 0.20:
		return Vector4.ZERO
	return output
