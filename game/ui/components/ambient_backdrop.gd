class_name AmbientBackdrop
extends Control

var phase := 0.0
var high_contrast := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	GameServices.settings_changed.connect(_apply_settings)
	_apply_settings(GameServices.settings())

func _apply_settings(settings: GameSettings) -> void:
	high_contrast = settings.high_contrast
	set_process(not settings.reduced_motion and not settings.low_graphics)
	queue_redraw()

func _process(delta: float) -> void:
	phase = fmod(phase + delta * 0.08, 1.0)
	queue_redraw()

func _draw() -> void:
	var size := get_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), DesignSystem.INK)
	for i in range(9):
		var radius := 110.0 + float(i) * 58.0
		var center := Vector2(size.x * (0.78 + sin(phase * TAU + i) * 0.015), size.y * 0.48)
		var alpha := 0.035 - float(i) * 0.0025
		draw_circle(center, radius, Color(0.32, 0.92, 0.77, maxf(alpha * (1.45 if high_contrast else 1.0), 0.008)), false, 2.0, true)
	var path := PackedVector2Array()
	var origin := Vector2(size.x * 0.66, size.y * 0.50)
	for i in range(97):
		var angle := TAU * float(i) / 96.0
		var ripple := sin(angle * 3.0 + phase * TAU) * 34.0 + cos(angle * 5.0) * 16.0
		path.append(origin + Vector2(cos(angle) * (300.0 + ripple), sin(angle) * (190.0 + ripple * 0.5)))
	draw_polyline(path, Color(0.31, 0.78, 1.0, 0.10 if high_contrast else 0.07), 46.0, true)
	draw_polyline(path, Color(0.37, 1.0, 0.82, 0.20 if high_contrast else 0.12), 2.0, true)
	var vignette := Color(0.0, 0.0, 0.0, 0.18)
	draw_rect(Rect2(0.0, 0.0, size.x, 72.0), vignette)
	draw_rect(Rect2(0.0, size.y - 94.0, size.x, 94.0), vignette)
