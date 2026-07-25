class_name RaceTelemetryCluster
extends Control
## One-canvas race instrument designed for mobile. The cluster intentionally
## draws its own chrome and glyphs so it costs one Control and no per-frame
## layout work while the authoritative telemetry changes at 60 Hz.

const BASE_SIZE := Vector2(346.0, 138.0)
const REV_SEGMENTS := 16
const MAX_RPM := 20_000.0

var _speed_kmh := 0
var _gear := 1
var _rpm := 4500
var _redline_rpm := 12_500
var _shifting := false
var _lap := 1
var _total_laps := 3
var _sector := 1
var _race_seconds := 0.0
var _sector_seconds := 0.0
var _offtrack := false
var _high_contrast := false
var _reduced_motion := false
var _shift_flash_until_ms := 0
var _spoken_speed_bucket := -1
var _spoken_gear := -99
var _spoken_rpm_bucket := -1
var _spoken_lap := -1
var _spoken_total_laps := -1
var _spoken_sector := -1
var _spoken_offtrack := false
var _paint_update_count := 0
var _panel_style: StyleBoxFlat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	custom_minimum_size = BASE_SIZE
	_panel_style = _make_panel_style()
	_refresh_accessibility_name()
	queue_redraw()


func configure_accessibility(reduced_motion: bool, high_contrast: bool) -> void:
	_reduced_motion = reduced_motion
	_high_contrast = high_contrast
	_panel_style = _make_panel_style()
	queue_redraw()


func update_telemetry(
	speed_kmh: int,
	gear: int,
	engine_rpm: float,
	redline_rpm: float,
	shifting: bool,
	current_lap: int,
	total_laps: int,
	sector: int,
	race_seconds: float,
	sector_seconds: float,
	offtrack: bool = false
	) -> void:
	var next_speed := clampi(speed_kmh, 0, 999)
	var next_gear := clampi(gear, -1, 8)
	var next_rpm := clampi(roundi(_finite_or(engine_rpm, 0.0)), 0, int(MAX_RPM))
	var next_redline := clampi(roundi(_finite_or(redline_rpm, 12_500.0)), 1, int(MAX_RPM))
	var next_laps := clampi(total_laps, 1, 99)
	var next_lap := clampi(current_lap, 1, next_laps)
	var next_sector := clampi(sector, 1, 3)
	var next_race_seconds := maxf(_finite_or(race_seconds, 0.0), 0.0)
	var next_sector_seconds := maxf(_finite_or(sector_seconds, 0.0), 0.0)
	var next_race_ms := roundi(next_race_seconds * 1000.0)
	var next_sector_ms := roundi(next_sector_seconds * 1000.0)
	var visual_changed := next_speed != _speed_kmh \
		or next_gear != _gear \
		or next_rpm != _rpm \
		or next_redline != _redline_rpm \
		or shifting != _shifting \
		or next_lap != _lap \
		or next_laps != _total_laps \
		or next_sector != _sector \
		or next_race_ms != roundi(_race_seconds * 1000.0) \
		or next_sector_ms != roundi(_sector_seconds * 1000.0) \
		or offtrack != _offtrack
	if shifting and not _shifting and not _reduced_motion:
		_shift_flash_until_ms = Time.get_ticks_msec() + 180
	_speed_kmh = next_speed
	_gear = next_gear
	_rpm = next_rpm
	_redline_rpm = next_redline
	_shifting = shifting
	_lap = next_lap
	_total_laps = next_laps
	_sector = next_sector
	_race_seconds = next_race_seconds
	_sector_seconds = next_sector_seconds
	_offtrack = offtrack
	# Spoken telemetry is intentionally coarser than the visual instrument. This
	# avoids rebuilding a long accessibility string at frame rate while keeping
	# gear/lap changes immediate and speed/RPM useful.
	var speed_bucket := next_speed / 5
	var rpm_bucket := next_rpm / 250
	var spoken_changed := speed_bucket != _spoken_speed_bucket \
		or next_gear != _spoken_gear \
		or rpm_bucket != _spoken_rpm_bucket \
		or next_lap != _spoken_lap \
		or next_laps != _spoken_total_laps \
		or next_sector != _spoken_sector \
		or offtrack != _spoken_offtrack
	if spoken_changed:
		_spoken_speed_bucket = speed_bucket
		_spoken_gear = next_gear
		_spoken_rpm_bucket = rpm_bucket
		_spoken_lap = next_lap
		_spoken_total_laps = next_laps
		_spoken_sector = next_sector
		_spoken_offtrack = offtrack
		_refresh_accessibility_name()
	if not visual_changed:
		return
	_paint_update_count += 1
	queue_redraw()


func debug_snapshot() -> Dictionary:
	return {
		"speed_kmh": _speed_kmh,
		"gear": _gear_text(_gear),
		"rpm": _rpm,
		"redline_rpm": _redline_rpm,
		"rev_ratio": normalized_rev(_rpm, _redline_rpm),
		"shifting": _shifting,
		"lap": _lap,
		"total_laps": _total_laps,
		"sector": _sector,
		"race_time": _format_time(_race_seconds),
		"sector_time": _format_time(_sector_seconds),
		"offtrack": _offtrack,
		"node_count": _descendant_count(self),
		"paint_updates": _paint_update_count,
	}


static func normalized_rev(engine_rpm: Variant, redline_rpm: Variant) -> float:
	var rpm := _safe_number(engine_rpm, 0.0)
	var redline := maxf(_safe_number(redline_rpm, 12_500.0), 1.0)
	return clampf(rpm / redline, 0.0, 1.0)


static func _safe_number(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	var number := float(value)
	return fallback if is_nan(number) or is_inf(number) else number


static func _finite_or(value: float, fallback: float) -> float:
	return fallback if is_nan(value) or is_inf(value) else value


func _draw() -> void:
	if _panel_style == null:
		_panel_style = _make_panel_style()
	var panel_rect := Rect2(Vector2.ZERO, size)
	draw_style_box(_panel_style, panel_rect)
	var scale := DesignSystem.current_ui_scale()
	var font := ThemeDB.fallback_font
	_draw_rev_band(scale)

	var label_size := _font_size(9, scale)
	var speed_size := _font_size(39, scale)
	var gear_size := _font_size(43, scale)
	var rpm_size := _font_size(14, scale)
	var baseline := minf(78.0, size.y * 0.59)

	_draw_text(font, Vector2(15.0, 37.0), "SPEED", label_size, DesignSystem.MUTED)
	_draw_text(font, Vector2(14.0, baseline), "%03d" % _speed_kmh, speed_size, DesignSystem.WHITE)
	_draw_text(font, Vector2(115.0, baseline - 2.0), "KM/H", label_size, DesignSystem.CYAN)

	var gear_color := DesignSystem.GOLD if _shifting else DesignSystem.MINT
	if not _reduced_motion and Time.get_ticks_msec() < _shift_flash_until_ms:
		gear_color = DesignSystem.WHITE
	_draw_text(font, Vector2(164.0, 37.0), "GEAR", label_size, DesignSystem.MUTED)
	_draw_text(font, Vector2(164.0, baseline), _gear_text(_gear), gear_size, gear_color)

	_draw_text(font, Vector2(231.0, 37.0), "ENGINE", label_size, DesignSystem.MUTED)
	_draw_text(font, Vector2(231.0, 59.0), "%05d" % _rpm, rpm_size, DesignSystem.WHITE)
	_draw_text(font, Vector2(231.0, 76.0), "RPM", label_size, DesignSystem.MINT)
	if _offtrack:
		_draw_text(font, Vector2(281.0, 76.0), "OFF", label_size, DesignSystem.CORAL)

	var divider_y := size.y - 42.0
	draw_line(Vector2(14.0, divider_y), Vector2(size.x - 14.0, divider_y), Color(1.0, 1.0, 1.0, 0.10), 1.0)
	var detail_y := size.y - 18.0
	var detail_size := _font_size(10, scale)
	_draw_text(font, Vector2(15.0, detail_y), "LAP %d/%d" % [_lap, _total_laps], detail_size, DesignSystem.WHITE)
	_draw_text(font, Vector2(92.0, detail_y), "S%d %s" % [_sector, _format_time(_sector_seconds, false)], detail_size, DesignSystem.CYAN)
	_draw_text(font, Vector2(221.0, detail_y), "T %s" % _format_time(_race_seconds), detail_size, DesignSystem.MUTED)


func _draw_rev_band(scale: float) -> void:
	var left := 14.0
	var right := size.x - 14.0
	var gap := 3.0
	var segment_width := (right - left - gap * float(REV_SEGMENTS - 1)) / float(REV_SEGMENTS)
	var active_segments := ceili(normalized_rev(_rpm, _redline_rpm) * float(REV_SEGMENTS))
	var height := 8.0 if scale < 1.15 else 9.0
	for index in REV_SEGMENTS:
		var rect := Rect2(Vector2(left + float(index) * (segment_width + gap), 12.0), Vector2(segment_width, height))
		var color := Color(0.32, 0.40, 0.50, 0.20)
		if index < active_segments:
			color = DesignSystem.MINT
			if index >= 10:
				color = DesignSystem.GOLD
			if index >= 14:
				color = DesignSystem.CORAL
			if _shifting and index >= 12:
				color = DesignSystem.WHITE
		draw_rect(rect, color, true)


func _draw_text(font: Font, position: Vector2, text: String, font_size: int, color: Color) -> void:
	draw_string(font, position + Vector2(1.0, 2.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, 0.68))
	draw_string(font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


func _make_panel_style() -> StyleBoxFlat:
	var border := DesignSystem.WHITE if _high_contrast else Color(1.0, 1.0, 1.0, 0.13)
	var style := DesignSystem.panel_style(Color(0.018, 0.038, 0.070, 0.94), 19, border, 1)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0.0, 4.0)
	return style


func _refresh_accessibility_name() -> void:
	accessibility_name = "Speed %d kilometres per hour; gear %s; engine %d RPM; lap %d of %d; sector %d; race time %s%s" % [
		_speed_kmh, _gear_text(_gear), _rpm, _lap, _total_laps, _sector,
		_format_time(_race_seconds), "; off track" if _offtrack else "",
	]


static func _gear_text(value: int) -> String:
	if value < 0:
		return "R"
	if value == 0:
		return "N"
	return str(value)


static func _format_time(seconds: float, include_minutes: bool = true) -> String:
	var total_ms := maxi(0, roundi(seconds * 1000.0))
	var minutes := total_ms / 60_000
	var whole_seconds := (total_ms / 1000) % 60
	var millis := total_ms % 1000
	if not include_minutes and minutes == 0:
		return "%02d.%03d" % [whole_seconds, millis]
	return "%02d:%02d.%03d" % [minutes, whole_seconds, millis]


static func _font_size(base: int, scale: float) -> int:
	return maxi(8, roundi(float(base) * clampf(scale, DesignSystem.MIN_UI_SCALE, DesignSystem.MAX_UI_SCALE)))


static func _descendant_count(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _descendant_count(child)
	return count
