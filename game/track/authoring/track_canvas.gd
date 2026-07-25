class_name TrackCanvas
extends Control

signal track_changed(point_count: int, is_closed: bool)
signal status_requested(message: String, is_error: bool)

const MIN_SAMPLE_DISTANCE := 7.0
const MIN_POINT_COUNT := 18
const CLOSURE_RADIUS := 58.0
const GameLimitsType := preload("res://game/config/game_limits.gd")
const MAX_CAPTURE_POINTS := mini(
	GameLimitsType.MAX_INPUT_STROKE_POINTS,
	GameLimitsType.MAX_CONTROL_POINTS * 8
)

# Points are stored normalized so an orientation or safe-area resize cannot
# silently reshape an authored circuit.
var points := PackedVector2Array()
var undo_stack: Array[PackedVector2Array] = []
var redo_stack: Array[PackedVector2Array] = []
var drawing := false
var pointer_id := -1
var accent := DesignSystem.MINT
var input_limit_reached := false
var _start_fix_current := Vector2(-1.0, -1.0)
var _start_fix_proposed := Vector2(-1.0, -1.0)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	resized.connect(queue_redraw)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_stroke(event.position, -1)
		else:
			_end_stroke(-1)
		accept_event()
	elif event is InputEventMouseMotion and drawing and pointer_id == -1:
		_append_point(event.position)
		accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed:
			_begin_stroke(event.position, event.index)
		elif event.index == pointer_id:
			_end_stroke(event.index)
		accept_event()
	elif event is InputEventScreenDrag and drawing and event.index == pointer_id:
		_append_point(event.position)
		accept_event()

func _begin_stroke(position: Vector2, id: int) -> void:
	if drawing:
		return
	_push_undo()
	points.clear()
	redo_stack.clear()
	drawing = true
	pointer_id = id
	input_limit_reached = false
	_append_point(position, true)
	status_requested.emit("Keep the line flowing and return to the glowing start gate.", false)

func _append_point(position: Vector2, force: bool = false) -> void:
	if points.size() >= MAX_CAPTURE_POINTS:
		if not input_limit_reached:
			input_limit_reached = true
			status_requested.emit("Input limit reached. Lift your finger to validate this circuit.", true)
		return
	var inset := Rect2(Vector2(18.0, 18.0), size - Vector2(36.0, 36.0))
	var clamped := Vector2(
		clampf(position.x, inset.position.x, inset.end.x),
		clampf(position.y, inset.position.y, inset.end.y)
	)
	var normalized := _position_to_normalized(clamped)
	if force or points.is_empty() or _pixel_distance(points[-1], normalized) >= MIN_SAMPLE_DISTANCE:
		points.append(normalized)
		track_changed.emit(points.size(), is_loop_closed())
		queue_redraw()

func _end_stroke(id: int) -> void:
	if not drawing or id != pointer_id:
		return
	drawing = false
	pointer_id = -1
	if points.size() < MIN_POINT_COUNT:
		status_requested.emit("The circuit is too short. Draw one confident closed loop.", true)
	elif will_snap_close():
		status_requested.emit("Small gap detected. Review the highlighted seam, then choose SNAP GAP CLOSED. You can undo it.", false)
	elif is_loop_closed():
		status_requested.emit("Loop captured. Confirm to validate and build the circuit.", false)
	else:
		status_requested.emit("Bring the finish inside the glowing start gate, then redraw the final section.", true)
	queue_redraw()

func clear_track() -> void:
	if points.is_empty():
		return
	_push_undo()
	points.clear()
	redo_stack.clear()
	track_changed.emit(0, false)
	status_requested.emit("Canvas cleared. Draw a new circuit.", false)
	queue_redraw()

func undo() -> void:
	if undo_stack.is_empty():
		return
	redo_stack.append(points.duplicate())
	points = undo_stack.pop_back()
	track_changed.emit(points.size(), is_loop_closed())
	status_requested.emit("Last drawing change undone.", false)
	queue_redraw()

func redo() -> void:
	if redo_stack.is_empty():
		return
	undo_stack.append(points.duplicate())
	points = redo_stack.pop_back()
	track_changed.emit(points.size(), is_loop_closed())
	status_requested.emit("Drawing change restored.", false)
	queue_redraw()

func can_undo() -> bool:
	return not undo_stack.is_empty()

func can_redo() -> bool:
	return not redo_stack.is_empty()

func is_loop_closed() -> bool:
	return points.size() >= MIN_POINT_COUNT and _pixel_distance(points[0], points[-1]) <= CLOSURE_RADIUS

func will_snap_close() -> bool:
	return is_loop_closed() and _pixel_distance(points[0], points[-1]) > 1.0

func accept_auto_close() -> bool:
	if not will_snap_close():
		return false
	_push_undo()
	redo_stack.clear()
	points.append(points[0])
	track_changed.emit(points.size(), true)
	status_requested.emit("Gap closed exactly. Review the seam, or Undo to restore the original stroke.", false)
	queue_redraw()
	return true

func build_normalized_loop(
		allow_auto_close: bool = true,
		authority_canvas_size: Vector2 = Vector2.ZERO
	) -> PackedVector2Array:
	var output := PackedVector2Array()
	if points.size() < MIN_POINT_COUNT or size.x <= 0.0 or size.y <= 0.0:
		return output
	if not is_loop_closed():
		return output
	if not allow_auto_close and will_snap_close():
		return output
	# Visual pixels are device-dependent. When an authority canvas is supplied,
	# simplify against that fixed logical space so the same normalized stroke on
	# a phone and a desktop produces byte-identical control points.
	var measurement_size := authority_canvas_size
	if not _finite_vector(measurement_size) \
			or measurement_size.x <= 0.0 or measurement_size.y <= 0.0:
		measurement_size = size
	var reduced := _cap_control_points(
		_reduce_points(points, 11.0, measurement_size),
		GameLimitsType.MAX_CONTROL_POINTS - 1
	)
	if reduced.size() < 8:
		return output
	for point in reduced:
		output.append(Vector2(clampf(point.x, 0.0, 1.0), clampf(point.y, 0.0, 1.0)))
	if output[0] != output[-1]:
		output.append(output[0])
	return output

func estimated_length_pixels() -> float:
	if points.size() < 2:
		return 0.0
	var length := 0.0
	for index in range(1, points.size()):
		length += _pixel_distance(points[index - 1], points[index])
	if is_loop_closed():
		length += _pixel_distance(points[-1], points[0])
	return length

func load_demo_loop() -> void:
	_push_undo()
	points.clear()
	# A hand-drawn-looking stadium with genuine straight sections. It starts at
	# the middle of the top straight so compiler-v1 can place a safe 12-car grid.
	for index in 10:
		points.append(Vector2(0.50 + 0.22 * float(index) / 9.0, 0.22))
	for index in range(1, 19):
		var angle := -PI * 0.5 + PI * float(index) / 18.0
		points.append(Vector2(0.72 + cos(angle) * 0.14, 0.50 + sin(angle) * 0.28))
	for index in range(1, 19):
		points.append(Vector2(0.72 - 0.44 * float(index) / 18.0, 0.78))
	for index in range(1, 19):
		var angle := PI * 0.5 + PI * float(index) / 18.0
		points.append(Vector2(0.28 + cos(angle) * 0.14, 0.50 + sin(angle) * 0.28))
	for index in range(1, 10):
		points.append(Vector2(0.28 + 0.22 * float(index) / 9.0, 0.22))
	redo_stack.clear()
	track_changed.emit(points.size(), true)
	status_requested.emit("Demo loop loaded. Edit it by drawing your own line, or confirm to race.", false)
	queue_redraw()

func load_normalized_loop(source: PackedVector2Array) -> void:
	_push_undo()
	points.clear()
	var bounded_count := mini(source.size(), GameLimitsType.MAX_CONTROL_POINTS)
	for index in bounded_count:
		var point := source[index]
		if is_finite(point.x) and is_finite(point.y):
			points.append(point.clamp(Vector2.ZERO, Vector2.ONE))
	redo_stack.clear()
	track_changed.emit(points.size(), is_loop_closed())
	status_requested.emit("Saved circuit loaded. Redraw to replace it, or build to validate it again.", false)
	queue_redraw()


func show_start_fix_preview(current_position: Vector2, proposed_position: Vector2) -> void:
	if not _finite_vector(current_position) or not _finite_vector(proposed_position):
		clear_start_fix_preview()
		return
	_start_fix_current = current_position
	_start_fix_proposed = proposed_position
	queue_redraw()


func clear_start_fix_preview() -> void:
	_start_fix_current = Vector2(-1.0, -1.0)
	_start_fix_proposed = Vector2(-1.0, -1.0)
	queue_redraw()


func has_start_fix_preview() -> bool:
	return _finite_vector(_start_fix_current) and _finite_vector(_start_fix_proposed) \
		and _start_fix_current.x >= 0.0 and _start_fix_proposed.x >= 0.0

func _push_undo() -> void:
	undo_stack.append(points.duplicate())
	if undo_stack.size() > 20:
		undo_stack.pop_front()

func _reduce_points(
		source: PackedVector2Array,
		spacing: float,
		measurement_size: Vector2 = Vector2.ZERO
	) -> PackedVector2Array:
	var reduced := PackedVector2Array()
	var resolved_size := measurement_size
	if not _finite_vector(resolved_size) or resolved_size.x <= 0.0 or resolved_size.y <= 0.0:
		resolved_size = size
	for point in source:
		if reduced.is_empty() \
				or ((reduced[-1] - point) * resolved_size).length() >= spacing:
			reduced.append(point)
	return reduced

func _cap_control_points(source: PackedVector2Array, maximum: int) -> PackedVector2Array:
	if source.size() <= maximum:
		return source
	var capped := PackedVector2Array()
	capped.resize(maximum)
	for index in maximum:
		var source_index := roundi(float(index) * float(source.size() - 1) / float(maximum - 1))
		capped[index] = source[source_index]
	return capped

func _position_to_normalized(position: Vector2) -> Vector2:
	return Vector2(
		clampf(position.x / maxf(size.x, 1.0), 0.0, 1.0),
		clampf(position.y / maxf(size.y, 1.0), 0.0, 1.0)
	)

func _normalized_to_position(point: Vector2) -> Vector2:
	return point * size

func _pixel_distance(first: Vector2, second: Vector2) -> float:
	return ((first - second) * size).length()


func _finite_vector(value: Vector2) -> bool:
	return is_finite(value.x) and is_finite(value.y)

func _pixel_points(source: PackedVector2Array) -> PackedVector2Array:
	var output := PackedVector2Array()
	output.resize(source.size())
	for index in source.size():
		output[index] = _normalized_to_position(source[index])
	return output

func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_style_box(DesignSystem.panel_style(Color(0.035, 0.075, 0.13, 0.97), 26, Color(0.37, 1.0, 0.82, 0.18), 1), rect)
	var grid_color := Color(0.42, 0.73, 0.88, 0.055)
	for x in range(36, int(size.x), 36):
		draw_line(Vector2(float(x), 0.0), Vector2(float(x), size.y), grid_color, 1.0)
	for y in range(36, int(size.y), 36):
		draw_line(Vector2(0.0, float(y)), Vector2(size.x, float(y)), grid_color, 1.0)
	if points.is_empty():
		var c := size * 0.5
		draw_arc(c, 86.0, 0.0, TAU, 64, Color(0.37, 1.0, 0.82, 0.12), 2.0, true)
		draw_arc(c, 126.0, 0.0, TAU, 64, Color(0.31, 0.78, 1.0, 0.07), 2.0, true)
		return
	var draw_points := _pixel_points(points)
	if points.size() >= 2:
		draw_polyline(draw_points, Color(0.0, 0.0, 0.0, 0.42), 20.0, true)
		draw_polyline(draw_points, Color(0.31, 0.78, 1.0, 0.20), 12.0, true)
		draw_polyline(draw_points, accent, 4.0, true)
	var gate_color := DesignSystem.CORAL if has_start_fix_preview() else (DesignSystem.MINT if is_loop_closed() else DesignSystem.GOLD)
	draw_circle(draw_points[0], CLOSURE_RADIUS, Color(gate_color, 0.08), true)
	draw_arc(draw_points[0], CLOSURE_RADIUS, 0.0, TAU, 48, Color(gate_color, 0.8), 3.0, true)
	draw_circle(draw_points[0], 7.0, gate_color, true)
	if points.size() > 1:
		draw_circle(draw_points[-1], 6.0, DesignSystem.WHITE, true)
	if will_snap_close():
		var seam_start := draw_points[-1]
		var seam_end := draw_points[0]
		var seam_length := seam_start.distance_to(seam_end)
		var dash_count := maxi(2, ceili(seam_length / 12.0))
		for dash_index in dash_count:
			if dash_index % 2 == 0:
				var from_weight := float(dash_index) / float(dash_count)
				var to_weight := float(dash_index + 1) / float(dash_count)
				draw_line(
					seam_start.lerp(seam_end, from_weight),
					seam_start.lerp(seam_end, to_weight),
					DesignSystem.CYAN,
					4.0,
					true
				)
	if has_start_fix_preview():
		_draw_start_fix_preview()


func _draw_start_fix_preview() -> void:
	var current := _start_fix_current.clamp(Vector2.ZERO, size)
	var proposed := _start_fix_proposed.clamp(Vector2.ZERO, size)
	var distance := current.distance_to(proposed)
	var dash_count := maxi(2, ceili(distance / 16.0))
	for dash_index in dash_count:
		if dash_index % 2 == 0:
			var from_weight := float(dash_index) / float(dash_count)
			var to_weight := float(dash_index + 1) / float(dash_count)
			draw_line(
				current.lerp(proposed, from_weight),
				current.lerp(proposed, to_weight),
				DesignSystem.GOLD,
				3.0,
				true
			)
	# Coral is the authored/current grid gate; mint is the compiler's proposed
	# safe straight. Nothing is changed until the adjacent review is accepted.
	draw_circle(current, 15.0, Color(DesignSystem.CORAL, 0.18), true)
	draw_arc(current, 15.0, 0.0, TAU, 32, DesignSystem.CORAL, 3.0, true)
	draw_line(current + Vector2(-9.0, -9.0), current + Vector2(9.0, 9.0), DesignSystem.CORAL, 3.0, true)
	draw_line(current + Vector2(9.0, -9.0), current + Vector2(-9.0, 9.0), DesignSystem.CORAL, 3.0, true)
	draw_circle(proposed, 19.0, Color(DesignSystem.MINT, 0.16), true)
	draw_arc(proposed, 19.0, 0.0, TAU, 40, DesignSystem.MINT, 4.0, true)
	draw_line(proposed + Vector2(0.0, -24.0), proposed + Vector2(0.0, 24.0), DesignSystem.WHITE, 3.0, true)
