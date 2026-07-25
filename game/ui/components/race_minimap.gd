class_name RaceMinimap
extends Control
## Lightweight authoritative 12-car overview; never participates in simulation.

var _track: RaceTrackQuery
var _entries: Array[RaceEntry] = []
var _player_id: StringName = &"player"
var _bounds := Rect2()
var _non_color_cues := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(150.0, 76.0)


func configure(track: RaceTrackQuery, player_id: StringName = &"player") -> void:
	_track = track
	_player_id = player_id
	_bounds = Rect2()
	if _track != null and _track.is_valid():
		for point in _track.centerline:
			if _bounds.size == Vector2.ZERO:
				_bounds = Rect2(point, Vector2(0.001, 0.001))
			else:
				_bounds = _bounds.expand(point)
	queue_redraw()


func configure_accessibility(non_color_cues: bool) -> void:
	_non_color_cues = non_color_cues
	queue_redraw()


static func marker_shape(status: StringName, is_player: bool, non_color_cues: bool) -> StringName:
	if not non_color_cues:
		return &"circle"
	if status == RaceEntry.STATUS_DNF:
		return &"x"
	if status == RaceEntry.STATUS_FINISHED:
		return &"square"
	return &"diamond" if is_player else &"circle"


func update_entries(entries: Array[RaceEntry]) -> void:
	_entries = entries.duplicate()
	queue_redraw()


func clear_race_authority() -> void:
	_track = null
	_entries.clear()
	_bounds = Rect2()
	queue_redraw()


func _draw() -> void:
	if _track == null or not _track.is_valid() or _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0:
		return
	var route := PackedVector2Array()
	for point in _track.centerline:
		route.append(_map_point(point))
	if not route.is_empty():
		route.append(route[0])
	draw_polyline(route, Color(0.02, 0.04, 0.07, 0.82), 7.0, true)
	draw_polyline(route, Color(0.72, 0.79, 0.84, 0.82), 3.0, true)
	var start := _map_point(_track.centerline[0])
	draw_circle(start, 3.5, DesignSystem.WHITE)
	for entry in _entries:
		if entry == null or entry.state == null:
			continue
		var position := _map_point(entry.state.position)
		var is_player := entry.participant_id == _player_id
		var color := DesignSystem.GOLD if is_player else DesignSystem.CYAN
		if entry.status == RaceEntry.STATUS_DNF:
			color = DesignSystem.MUTED
		elif entry.status == RaceEntry.STATUS_FINISHED:
			color = DesignSystem.MINT
		_draw_marker(position, marker_shape(entry.status, is_player, _non_color_cues), color, is_player)


func _draw_marker(position: Vector2, shape: StringName, color: Color, is_player: bool) -> void:
	var radius := 4.5 if is_player else 3.2
	match shape:
		&"diamond":
			draw_colored_polygon(PackedVector2Array([
				position + Vector2(0.0, -radius - 1.0), position + Vector2(radius + 1.0, 0.0),
				position + Vector2(0.0, radius + 1.0), position + Vector2(-radius - 1.0, 0.0),
			]), Color(0.01, 0.02, 0.04, 0.92))
			draw_colored_polygon(PackedVector2Array([
				position + Vector2(0.0, -radius), position + Vector2(radius, 0.0),
				position + Vector2(0.0, radius), position + Vector2(-radius, 0.0),
			]), color)
		&"square":
			draw_rect(Rect2(position - Vector2.ONE * (radius + 1.0), Vector2.ONE * (radius + 1.0) * 2.0), Color(0.01, 0.02, 0.04, 0.92), true)
			draw_rect(Rect2(position - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), color, true)
		&"x":
			draw_line(position + Vector2(-radius, -radius), position + Vector2(radius, radius), Color(0.01, 0.02, 0.04, 0.92), 5.0, true)
			draw_line(position + Vector2(-radius, radius), position + Vector2(radius, -radius), Color(0.01, 0.02, 0.04, 0.92), 5.0, true)
			draw_line(position + Vector2(-radius, -radius), position + Vector2(radius, radius), color, 2.2, true)
			draw_line(position + Vector2(-radius, radius), position + Vector2(radius, -radius), color, 2.2, true)
		_:
			draw_circle(position, radius + 1.2, Color(0.01, 0.02, 0.04, 0.92))
			draw_circle(position, radius, color)


func _map_point(point: Vector2) -> Vector2:
	var padding := Vector2(10.0, 9.0)
	var available := size - padding * 2.0
	var scale_factor := minf(
		available.x / maxf(_bounds.size.x, 0.001),
		available.y / maxf(_bounds.size.y, 0.001)
	)
	var content_size := _bounds.size * scale_factor
	var offset := padding + (available - content_size) * 0.5
	return offset + (point - _bounds.position) * scale_factor
