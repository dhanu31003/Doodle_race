class_name RaceStandingsPanel
extends Control
## Compact authoritative classification for a full 12-car mobile grid. Rows are
## painted in one CanvasItem to avoid a dozen panels/labels rebuilding every
## frame when gaps change.

const BASE_SIZE := Vector2(246.0, 292.0)
const MAX_VISIBLE_ROWS := 12

var _rows: Array[Dictionary] = []
var _lap := 1
var _total_laps := 3
var _race_seconds := 0.0
var _player_position := 0
var _position_flash_until_ms := 0
var _high_contrast := false
var _reduced_motion := false
var _last_order_hash := 0
var _last_authority_tick := -1_000_000
var _last_rows_paint_hash := 0
var _last_painted_lap := -1
var _last_painted_total_laps := -1
var _last_painted_second := -1
var _last_painted_flash := false
var _spoken_order_hash := 0
var _spoken_player_position := -1
var _spoken_lap := -1
var _spoken_total_laps := -1
var _spoken_second := -1
var _authority_update_calls := 0
var _row_rebuild_count := 0
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


func update_standings(
	ordered_entries: Array,
	player_id: StringName,
	track_length: float,
	current_lap: int,
	total_laps: int,
	race_seconds: float,
	authority_tick: int = -1
	) -> void:
	# Classification rows are a human-readable instrument, not simulation input.
	# Refresh intervals at 10 Hz on the 60 Hz authority clock, but repaint an
	# overtake/status change immediately. This bounds text shaping on mid-range
	# mobile CPUs without making race order feel delayed.
	_authority_update_calls += 1
	var order_hash := 17
	for entry in ordered_entries:
		if entry == null:
			continue
		order_hash = (int(hash(entry.participant_id)) ^ (order_hash * 31)) & 0x7fff_ffff
		order_hash = (int(hash(entry.status)) ^ (order_hash * 31)) & 0x7fff_ffff
	if authority_tick >= 0 and authority_tick - _last_authority_tick < 6 \
			and order_hash == _last_order_hash:
		return
	_last_authority_tick = authority_tick
	_last_order_hash = order_hash
	_row_rebuild_count += 1
	var next_rows := rows_from_authority(ordered_entries, player_id, track_length)
	var next_total_laps := clampi(total_laps, 1, 99)
	var next_lap := clampi(current_lap, 1, next_total_laps)
	var next_race_seconds := maxf(_finite_or(race_seconds, 0.0), 0.0)
	var next_player_position := 0
	for row in next_rows:
		if bool(row.get("is_player", false)):
			next_player_position = int(row.get("position", 0))
			break
	if _player_position > 0 and next_player_position > 0 and next_player_position != _player_position and not _reduced_motion:
		_position_flash_until_ms = Time.get_ticks_msec() + 280
	_player_position = next_player_position
	_rows = next_rows
	_lap = next_lap
	_total_laps = next_total_laps
	_race_seconds = next_race_seconds
	var flash_active := not _reduced_motion and Time.get_ticks_msec() < _position_flash_until_ms
	var current_second := int(_race_seconds)
	var rows_paint_hash := _rows_hash(_rows)
	var spoken_changed := order_hash != _spoken_order_hash \
		or _player_position != _spoken_player_position \
		or _lap != _spoken_lap \
		or _total_laps != _spoken_total_laps \
		or current_second != _spoken_second
	if spoken_changed:
		_spoken_order_hash = order_hash
		_spoken_player_position = _player_position
		_spoken_lap = _lap
		_spoken_total_laps = _total_laps
		_spoken_second = current_second
		_refresh_accessibility_name()
	var paint_changed := rows_paint_hash != _last_rows_paint_hash \
		or _lap != _last_painted_lap \
		or _total_laps != _last_painted_total_laps \
		or current_second != _last_painted_second \
		or flash_active != _last_painted_flash
	if not paint_changed:
		return
	_last_rows_paint_hash = rows_paint_hash
	_last_painted_lap = _lap
	_last_painted_total_laps = _total_laps
	_last_painted_second = current_second
	_last_painted_flash = flash_active
	_paint_update_count += 1
	queue_redraw()


func debug_snapshot() -> Dictionary:
	return {
		"row_count": _rows.size(),
		"rows": _rows.duplicate(true),
		"player_position": _player_position,
		"lap": _lap,
		"total_laps": _total_laps,
		"race_time": _format_clock(_race_seconds),
		"node_count": _descendant_count(self),
		"authority_update_calls": _authority_update_calls,
		"row_rebuilds": _row_rebuild_count,
		"paint_updates": _paint_update_count,
	}


static func rows_from_authority(ordered_entries: Array, player_id: StringName, track_length: float) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var safe_track_length := maxf(_finite_or(track_length, 1.0), 1.0)
	var leader_progress := 0.0
	if not ordered_entries.is_empty() and ordered_entries[0] != null:
		leader_progress = maxf(_entry_progress(ordered_entries[0]), 0.0)
	for index in mini(ordered_entries.size(), MAX_VISIBLE_ROWS):
		var entry: Variant = ordered_entries[index]
		if entry == null:
			continue
		var status := StringName(str(entry.status))
		var progress := maxf(_entry_progress(entry), 0.0)
		var gap := maxf(leader_progress - progress, 0.0)
		var interval := "LEAD" if index == 0 else _gap_text(gap, safe_track_length)
		if status == RaceEntry.STATUS_FINISHED:
			interval = "FIN"
		elif status == RaceEntry.STATUS_DNF:
			interval = "OUT"
		elif status == RaceEntry.STATUS_GRID:
			interval = "GRID"
		var is_player := StringName(entry.participant_id) == player_id
		var display_name := _compact_name(str(entry.display_name))
		rows.append({
			"position": index + 1,
			"participant_id": str(entry.participant_id),
			"display_name": display_name,
			"is_player": is_player,
			"status": str(status),
			"interval": interval,
			"progress": snappedf(progress, 0.1),
		})
	return rows


static func _entry_progress(entry: Variant) -> float:
	if entry == null or not entry.has_method("classification_progress"):
		return 0.0
	var value := float(entry.classification_progress())
	return 0.0 if is_nan(value) or is_inf(value) else value


static func _gap_text(gap: float, track_length: float) -> String:
	if gap >= track_length * 0.92:
		return "+%dL" % maxi(1, floori(gap / track_length))
	return "+%dm" % maxi(0, roundi(gap / 5.0) * 5)


static func _compact_name(value: String) -> String:
	var clean := value.strip_edges().to_upper()
	if clean.is_empty():
		clean = "DRIVER"
	return clean.left(12)


static func _rows_hash(rows: Array[Dictionary]) -> int:
	var output := 23
	for row in rows:
		output = _mix_hash(output, int(row.get("position", 0)))
		output = _mix_hash(output, int(hash(row.get("participant_id", ""))))
		output = _mix_hash(output, int(hash(row.get("status", ""))))
		output = _mix_hash(output, int(hash(row.get("interval", ""))))
		output = _mix_hash(output, roundi(float(row.get("progress", 0.0)) * 10.0))
		output = _mix_hash(output, 1 if bool(row.get("is_player", false)) else 0)
	return output


static func _mix_hash(current: int, value: int) -> int:
	return (value ^ (current * 31)) & 0x7fff_ffff


func _draw() -> void:
	if _panel_style == null:
		_panel_style = _make_panel_style()
	draw_style_box(_panel_style, Rect2(Vector2.ZERO, size))
	var font := ThemeDB.fallback_font
	var scale := DesignSystem.current_ui_scale()
	var heading_size := _font_size(11, scale)
	var meta_size := _font_size(10, scale)
	_draw_text(font, Vector2(14.0, 21.0), "LIVE ORDER", heading_size, DesignSystem.WHITE)
	var context := "L%d/%d  %s" % [_lap, _total_laps, _format_clock(_race_seconds)]
	draw_string(font, Vector2(14.0, 40.0), context, HORIZONTAL_ALIGNMENT_LEFT, -1.0, meta_size, DesignSystem.CYAN)
	draw_line(Vector2(13.0, 49.0), Vector2(size.x - 13.0, 49.0), Color(1.0, 1.0, 1.0, 0.11), 1.0)

	var row_top := 55.0
	var row_height := (size.y - row_top - 8.0) / float(MAX_VISIBLE_ROWS)
	var row_font := _font_size(10, scale)
	var interval_font := _font_size(9, scale)
	for index in _rows.size():
		var row: Dictionary = _rows[index]
		var y := row_top + float(index) * row_height
		var is_player := bool(row.get("is_player", false))
		if is_player:
			var alpha := 0.20
			if not _reduced_motion and Time.get_ticks_msec() < _position_flash_until_ms:
				alpha = 0.34
			draw_rect(Rect2(Vector2(7.0, y), Vector2(size.x - 14.0, row_height - 1.0)), Color(DesignSystem.MINT, alpha), true)
			draw_rect(Rect2(Vector2(7.0, y), Vector2(3.0, row_height - 1.0)), DesignSystem.MINT, true)
		elif index % 2 == 1:
			draw_rect(Rect2(Vector2(7.0, y), Vector2(size.x - 14.0, row_height - 1.0)), Color(1.0, 1.0, 1.0, 0.025), true)
		var baseline := y + row_height * 0.72
		var place_color := DesignSystem.GOLD if index == 0 else (DesignSystem.WHITE if index < 3 else DesignSystem.MUTED)
		_draw_text(font, Vector2(14.0, baseline), "%02d" % int(row.get("position", index + 1)), row_font, place_color)
		var marker_color := DesignSystem.MINT if is_player else (DesignSystem.GOLD if index == 0 else DesignSystem.CYAN)
		draw_circle(Vector2(42.0, y + row_height * 0.48), 2.6 if is_player else 2.1, marker_color)
		var name := str(row.get("display_name", "DRIVER"))
		if is_player and name != "YOU":
			name = name.left(8) + "  YOU"
		_draw_text(font, Vector2(51.0, baseline), name, row_font, DesignSystem.WHITE if is_player else Color("d3dce8"))
		var interval_color := DesignSystem.CORAL if str(row.get("status", "")) == str(RaceEntry.STATUS_DNF) else DesignSystem.MUTED
		draw_string(font, Vector2(151.0, baseline), str(row.get("interval", "")), HORIZONTAL_ALIGNMENT_RIGHT, size.x - 165.0, interval_font, interval_color)


func _draw_text(font: Font, position: Vector2, text: String, font_size: int, color: Color) -> void:
	draw_string(font, position + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, 0.60))
	draw_string(font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)


func _make_panel_style() -> StyleBoxFlat:
	var border := DesignSystem.WHITE if _high_contrast else Color(1.0, 1.0, 1.0, 0.12)
	var style := DesignSystem.panel_style(Color(0.018, 0.038, 0.070, 0.92), 18, border, 1)
	style.shadow_size = 6
	style.shadow_offset = Vector2(0.0, 4.0)
	return style


func _refresh_accessibility_name() -> void:
	var parts := PackedStringArray()
	for row in _rows:
		parts.append("position %d, %s%s, %s" % [
			int(row.get("position", 0)), str(row.get("display_name", "DRIVER")),
			", you" if bool(row.get("is_player", false)) else "",
			str(row.get("interval", "")),
		])
	accessibility_name = "Live race order; " + "; ".join(parts)


static func _format_clock(seconds: float) -> String:
	var safe := maxi(0, floori(seconds))
	return "%02d:%02d" % [safe / 60, safe % 60]


static func _finite_or(value: float, fallback: float) -> float:
	return fallback if is_nan(value) or is_inf(value) else value


static func _font_size(base: int, scale: float) -> int:
	return maxi(8, roundi(float(base) * clampf(scale, DesignSystem.MIN_UI_SCALE, DesignSystem.MAX_UI_SCALE)))


static func _descendant_count(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _descendant_count(child)
	return count
