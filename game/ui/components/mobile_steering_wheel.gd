class_name MobileSteeringWheel
extends Control
## Mobile-first analog steering surface. Authority receives a continuous
## normalized axis while the drawn wheel provides immediate, allocation-free
## feedback. Releasing the pointer centers authority immediately and lets only
## the visual rim ease home.

signal steering_changed(value: float)

const MAX_VISUAL_ROTATION := deg_to_rad(78.0)
const VISUAL_RETURN_SPEED := 8.5

var steering_value := 0.0
var _visual_value := 0.0
var _touch_index := -1
var _mouse_held := false
var _control_opacity := 0.82


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	accessibility_name = "Analog steering wheel. Drag left or right and release to center."
	set_process(true)
	queue_redraw()


func configure(size_scale: float, opacity: float) -> void:
	var safe_scale := clampf(size_scale, 0.75, 1.50)
	_control_opacity = clampf(opacity, 0.35, 1.0)
	custom_minimum_size = Vector2(136.0, 136.0) * safe_scale
	modulate.a = _control_opacity
	queue_redraw()


func _exit_tree() -> void:
	_release_steering()


func _process(delta: float) -> void:
	if _touch_index >= 0 or _mouse_held:
		return
	var next_visual := move_toward(
		_visual_value, 0.0, maxf(delta, 0.0) * VISUAL_RETURN_SPEED
	)
	if is_equal_approx(next_visual, _visual_value):
		return
	_visual_value = next_visual
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and (_touch_index < 0 or _touch_index == event.index):
			_touch_index = event.index
			_set_axis_from_local(event.position)
			accept_event()
		elif not event.pressed and event.index == _touch_index:
			_touch_index = -1
			_release_steering()
			accept_event()
	elif event is InputEventScreenDrag and event.index == _touch_index:
		_set_axis_from_local(event.position)
		accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_mouse_held = event.pressed
		if event.pressed:
			_set_axis_from_local(event.position)
		else:
			_release_steering()
		accept_event()
	elif event is InputEventMouseMotion and _mouse_held:
		_set_axis_from_local(event.position)
		accept_event()


func _set_axis_from_local(local_position: Vector2) -> void:
	var center_x := size.x * 0.5
	var travel := maxf(minf(size.x, size.y) * 0.34, 1.0)
	var next_value := clampf((local_position.x - center_x) / travel, -1.0, 1.0)
	if is_equal_approx(next_value, steering_value) and is_equal_approx(
		_visual_value, next_value
	):
		return
	steering_value = next_value
	_visual_value = next_value
	steering_changed.emit(steering_value)
	queue_redraw()


func _release_steering() -> void:
	_touch_index = -1
	_mouse_held = false
	if not is_zero_approx(steering_value):
		steering_value = 0.0
		steering_changed.emit(0.0)


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.40
	if radius <= 1.0:
		return
	# A single restrained backing plate preserves contrast over every road surface.
	draw_circle(center, radius * 1.12, Color(0.018, 0.043, 0.078, 0.86))
	draw_arc(center, radius * 1.08, 0.0, TAU, 64, Color(0.37, 1.0, 0.82, 0.38), 2.0, true)
	draw_set_transform(center, _visual_value * MAX_VISUAL_ROTATION, Vector2.ONE)
	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 64, Color(0.82, 0.89, 0.91, 0.92), radius * 0.16, true)
	draw_arc(Vector2.ZERO, radius * 0.80, 0.0, TAU, 64, Color(0.06, 0.12, 0.19, 0.98), radius * 0.10, true)
	var spoke_color := Color(0.23, 0.31, 0.37, 1.0)
	for angle in [deg_to_rad(-28.0), deg_to_rad(28.0), deg_to_rad(152.0), deg_to_rad(208.0)]:
		var outer := Vector2(cos(angle), sin(angle)) * radius * 0.79
		var inner := Vector2(cos(angle), sin(angle)) * radius * 0.30
		draw_line(inner, outer, spoke_color, radius * 0.12, true)
	draw_circle(Vector2.ZERO, radius * 0.29, Color(0.025, 0.07, 0.11, 1.0))
	draw_arc(Vector2.ZERO, radius * 0.29, 0.0, TAU, 32, Color(0.37, 1.0, 0.82, 0.78), 2.0, true)
	# Mint top marker makes steering angle readable without text or animation nodes.
	draw_line(
		Vector2(0.0, -radius * 1.02), Vector2(0.0, -radius * 0.83),
		Color(0.37, 1.0, 0.82, 1.0), radius * 0.08, true
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
