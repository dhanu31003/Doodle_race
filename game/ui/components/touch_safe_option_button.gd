class_name TouchSafeOptionButton
extends Button
## A release-to-select mobile option sheet. Rows live in a ScrollContainer, so
## a finger drag scrolls and cancels the pending row press; only a stationary
## tap released on the same row commits a value.

signal item_selected(index: int)

const ROW_HEIGHT := 52.0
const POPUP_MARGIN := 18.0
const TOUCH_SCROLL_DEADZONE := 18

var selected := -1
var item_count: int:
	get:
		return _items.size()

var _items: Array[Dictionary] = []
var _popup: PopupPanel
var _list: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	focus_mode = Control.FOCUS_ALL
	accessibility_name = "Tap and release to choose an option. Drag the open list to scroll."
	pressed.connect(_open_options)
	_build_popup()
	_refresh_label()


func add_item(label: String, item_id: int = -1) -> void:
	var resolved_id := item_id if item_id >= 0 else _items.size()
	_items.append({"label": label, "id": resolved_id})
	if selected < 0:
		selected = 0
	_refresh_label()


func clear() -> void:
	_items.clear()
	selected = -1
	_refresh_label()


func select(index: int) -> void:
	if _items.is_empty():
		selected = -1
	else:
		selected = clampi(index, 0, _items.size() - 1)
	_refresh_label()


func get_item_id(index: int) -> int:
	if index < 0 or index >= _items.size():
		return -1
	return int(_items[index]["id"])


func get_item_text(index: int) -> String:
	if index < 0 or index >= _items.size():
		return ""
	return str(_items[index]["label"])


func get_selected_id() -> int:
	return get_item_id(selected)


func _gui_input(event: InputEvent) -> void:
	# Never let a desktop wheel or touchpad gesture mutate the current option.
	# Scrolling is available only inside the deliberately opened option sheet.
	if event is InputEventMouseButton and event.button_index in [
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
		MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT,
	]:
		accept_event()


func _build_popup() -> void:
	if _popup != null:
		return
	_popup = PopupPanel.new()
	_popup.name = "TouchOptionSheet"
	var popup_style := StyleBoxFlat.new()
	popup_style.bg_color = Color(0.018, 0.043, 0.078, 0.995)
	popup_style.border_color = Color(0.37, 1.0, 0.82, 0.42)
	popup_style.set_border_width_all(2)
	popup_style.set_corner_radius_all(16)
	popup_style.content_margin_left = 10.0
	popup_style.content_margin_top = 10.0
	popup_style.content_margin_right = 10.0
	popup_style.content_margin_bottom = 10.0
	popup_style.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	popup_style.shadow_size = 12
	popup_style.shadow_offset = Vector2(0.0, 6.0)
	_popup.add_theme_stylebox_override("panel", popup_style)
	add_child(_popup)
	_scroll = ScrollContainer.new()
	_scroll.name = "OptionScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.scroll_deadzone = TOUCH_SCROLL_DEADZONE
	_scroll.follow_focus = false
	_popup.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)


func _open_options() -> void:
	if disabled or _items.is_empty():
		return
	_rebuild_rows()
	var viewport_size := get_viewport_rect().size
	var popup_width := clampf(maxf(size.x, 236.0), 220.0, viewport_size.x - POPUP_MARGIN * 2.0)
	var content_height := float(_items.size()) * (ROW_HEIGHT + 4.0) + 12.0
	var popup_height := minf(content_height, viewport_size.y - POPUP_MARGIN * 2.0)
	var origin := get_screen_position()
	var popup_y := origin.y + size.y + 4.0
	if popup_y + popup_height > viewport_size.y - POPUP_MARGIN:
		popup_y = maxf(POPUP_MARGIN, origin.y - popup_height - 4.0)
	var popup_x := clampf(origin.x, POPUP_MARGIN, viewport_size.x - popup_width - POPUP_MARGIN)
	_popup.popup(Rect2i(
		Vector2i(roundi(popup_x), roundi(popup_y)),
		Vector2i(roundi(popup_width), roundi(popup_height))
	))


func _rebuild_rows() -> void:
	for child in _list.get_children():
		child.queue_free()
	for index in _items.size():
		var row := Button.new()
		row.name = "OptionRow%d" % index
		row.text = str(_items[index]["label"])
		row.custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
		row.focus_mode = Control.FOCUS_NONE
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_font_size_override("font_size", 16)
		row.add_theme_color_override(
			"font_color", Color("5fffd1") if index == selected else Color("eef6f5")
		)
		row.add_theme_stylebox_override(
			"normal", _row_style(
				Color(0.045, 0.09, 0.14, 1.0) if index == selected
				else Color(0.025, 0.057, 0.095, 1.0),
				Color(0.37, 1.0, 0.82, 0.34) if index == selected
				else Color(1.0, 1.0, 1.0, 0.08)
			)
		)
		row.add_theme_stylebox_override(
			"hover", _row_style(Color(0.06, 0.13, 0.19, 1.0), Color(0.37, 1.0, 0.82, 0.52))
		)
		row.add_theme_stylebox_override(
			"pressed", _row_style(Color(0.07, 0.19, 0.23, 1.0), Color(0.37, 1.0, 0.82, 0.86))
		)
		row.pressed.connect(func() -> void: _commit(index))
		_list.add_child(row)


func _row_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	return style


func _commit(index: int) -> void:
	if index < 0 or index >= _items.size():
		return
	selected = index
	_refresh_label()
	_popup.hide()
	item_selected.emit(index)


func _refresh_label() -> void:
	text = "%s   ▾" % get_item_text(selected) if selected >= 0 else "SELECT   ▾"


func debug_touch_contract() -> Dictionary:
	_build_popup()
	return {
		"selection_action_mode": action_mode,
		"scroll_deadzone": _scroll.scroll_deadzone,
		"horizontal_scroll_disabled": _scroll.horizontal_scroll_mode \
				== ScrollContainer.SCROLL_MODE_DISABLED,
		"item_count": item_count,
		"selected": selected,
	}
