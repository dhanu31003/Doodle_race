extends Control

signal navigate_requested(route: String, payload: Dictionary)

var leaving := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var services := get_node_or_null("/root/GameServices")
	var settings: GameSettings = services.call("settings") if services != null else GameSettings.new()
	var animate := animations_enabled(settings)
	_build(animate)
	_play_intro(animate)

static func animations_enabled(settings: GameSettings) -> bool:
	return settings == null or not settings.reduced_motion


func _build(animate: bool) -> void:
	var artwork := TextureRect.new()
	artwork.texture = load("res://assets/final/brand/raceglyph_splash.webp")
	artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	artwork.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(artwork)

	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.025, 0.06, 0.18)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var safe := DesignSystem.make_margin(68, 54, 68, 48)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(safe)
	var layout := VBoxContainer.new()
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	layout.custom_minimum_size.x = 460.0
	layout.add_theme_constant_override("separation", 12)
	safe.add_child(layout)
	var mark := TextureRect.new()
	mark.texture = load("res://assets/final/brand/raceglyph_mark.svg")
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.custom_minimum_size = Vector2(92.0, 92.0)
	mark.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	layout.add_child(mark)
	var eyebrow := DesignSystem.label("YOUR LINE. YOUR CIRCUIT.", 15, DesignSystem.MINT)
	layout.add_child(eyebrow)
	var title := DesignSystem.title("RACEGLYPH", 62)
	layout.add_child(title)
	var tagline := DesignSystem.label("Draw it. Generate it. Race it.", 21, DesignSystem.MUTED)
	layout.add_child(tagline)
	var loading := ProgressBar.new()
	loading.custom_minimum_size = Vector2(330.0, 5.0)
	loading.show_percentage = false
	loading.value = 0.0 if animate else 100.0
	loading.add_theme_stylebox_override("background", DesignSystem.panel_style(Color(0.1, 0.2, 0.3, 0.55), 3))
	loading.add_theme_stylebox_override("fill", DesignSystem.panel_style(DesignSystem.MINT, 3))
	layout.add_child(loading)
	if animate:
		var tween := create_tween()
		tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(loading, "value", 100.0, 1.9)
	var hint := DesignSystem.label("TAP TO CONTINUE", 12, Color(0.72, 0.79, 0.86, 0.72))
	layout.add_child(hint)

func _play_intro(animate: bool) -> void:
	modulate.a = 0.0 if animate else 1.0
	if animate:
		var tween := create_tween()
		tween.tween_property(self, "modulate:a", 1.0, 0.32)
	# Reduced motion also removes the otherwise decorative hold; the screen is
	# immediately legible and remains manually skippable in either mode.
	await get_tree().create_timer(2.35 if animate else 0.35).timeout
	_leave()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_leave()
	elif event is InputEventScreenTouch and event.pressed:
		_leave()
	elif event.is_pressed():
		_leave()

func _leave() -> void:
	if leaving:
		return
	leaving = true
	navigate_requested.emit("home", {})
