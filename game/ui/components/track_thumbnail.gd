class_name TrackThumbnail
extends Control
## Small deterministic circuit portrait derived from compiled geometry.
## No rendered image is persisted, so a saved track preview can never drift
## from the exact bytes that will be raced.

const PREVIEW_PADDING := 11.0

var _centerline := PackedVector2Array()
var _bridge_positions := PackedVector2Array()
var _accent := DesignSystem.MINT


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = Vector2(164.0, 92.0)
	resized.connect(queue_redraw)


func configure(compiled: CompiledTrack, accent: Color = DesignSystem.MINT) -> void:
	_centerline.clear()
	_bridge_positions.clear()
	_accent = accent
	if compiled != null:
		_centerline = compiled.centerline.duplicate()
		for declaration_variant in compiled.bridge_crossings:
			if not declaration_variant is Dictionary:
				continue
			var declaration: Dictionary = declaration_variant
			_bridge_positions.append(_sample_polyline(
				compiled.centerline,
				compiled.arc_distances,
				float(declaration.get("distance_a", 0.0)),
				compiled.total_length
			))
	tooltip_text = "Validated circuit preview"
	queue_redraw()


static func fit_points(points: PackedVector2Array, target_size: Vector2, padding: float = PREVIEW_PADDING) -> PackedVector2Array:
	var output := PackedVector2Array()
	if points.is_empty() or not is_finite(target_size.x) or not is_finite(target_size.y):
		return output
	var minimum := points[0]
	var maximum := points[0]
	for point in points:
		if not is_finite(point.x) or not is_finite(point.y):
			return PackedVector2Array()
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	var available := Vector2(
		maxf(target_size.x - padding * 2.0, 1.0),
		maxf(target_size.y - padding * 2.0, 1.0)
	)
	var extent := maximum - minimum
	var scale := minf(
		available.x / maxf(extent.x, 0.000001),
		available.y / maxf(extent.y, 0.000001)
	)
	var fitted_extent := extent * scale
	var offset := (target_size - fitted_extent) * 0.5 - minimum * scale
	output.resize(points.size())
	for index in points.size():
		output[index] = points[index] * scale + offset
	return output


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	draw_style_box(
		DesignSystem.panel_style(Color(0.025, 0.055, 0.10, 0.98), 14, Color(_accent, 0.22), 1),
		bounds
	)
	for x in range(18, int(size.x), 18):
		draw_line(Vector2(float(x), 0.0), Vector2(float(x), size.y), Color(0.35, 0.72, 0.86, 0.035), 1.0)
	for y in range(18, int(size.y), 18):
		draw_line(Vector2(0.0, float(y)), Vector2(size.x, float(y)), Color(0.35, 0.72, 0.86, 0.035), 1.0)
	if _centerline.size() < 3:
		var center := size * 0.5
		draw_arc(center, 21.0, 0.0, TAU, 32, Color(_accent, 0.16), 2.0, true)
		return
	var fitted := fit_points(_centerline, size)
	var closed := fitted.duplicate()
	closed.append(fitted[0])
	draw_polyline(closed, Color(0.0, 0.0, 0.0, 0.58), 10.0, true)
	draw_polyline(closed, Color(0.15, 0.22, 0.31, 1.0), 7.0, true)
	draw_polyline(closed, Color(_accent, 0.82), 2.2, true)
	var start := fitted[0]
	draw_circle(start, 5.0, Color(0.02, 0.06, 0.10, 1.0), true)
	draw_arc(start, 5.0, 0.0, TAU, 20, DesignSystem.WHITE, 2.0, true)
	for bridge_position in _bridge_positions:
		var bridge_fitted := _fit_single(bridge_position, _centerline, size)
		draw_circle(bridge_fitted, 4.0, DesignSystem.GOLD, true)


static func _fit_single(point: Vector2, source: PackedVector2Array, target_size: Vector2) -> Vector2:
	var with_point := source.duplicate()
	with_point.append(point)
	var fitted := fit_points(with_point, target_size)
	return fitted[-1] if not fitted.is_empty() else target_size * 0.5


static func _sample_polyline(
		points: PackedVector2Array,
		arc_distances: PackedFloat64Array,
		distance: float,
		total_length: float
	) -> Vector2:
	if points.is_empty() or arc_distances.size() != points.size() or total_length <= 0.0:
		return Vector2.ZERO
	var wrapped := fposmod(distance, total_length)
	for index in points.size():
		var next := (index + 1) % points.size()
		var start_distance := float(arc_distances[index])
		var end_distance := total_length if next == 0 else float(arc_distances[next])
		if wrapped <= end_distance or next == 0:
			var amount := inverse_lerp(start_distance, end_distance, wrapped)
			return points[index].lerp(points[next], clampf(amount, 0.0, 1.0))
	return points[0]
