extends Control

const AmbientBackdropScript := preload("res://game/ui/components/ambient_backdrop.gd")
const SplashScreenScript := preload("res://game/ui/screens/splash_screen.gd")
const MainMenuScript := preload("res://game/ui/screens/main_menu.gd")
const TrackStudioScript := preload("res://game/ui/screens/track_studio.gd")
const OfflineRaceConfigScreenScript := preload("res://game/ui/screens/offline_race_config_screen.gd")
const RaceScreenScript := preload("res://game/ui/screens/race_screen.gd")
const NetworkRaceScreenScript := preload("res://game/ui/screens/network_race_screen.gd")
const SavedTracksScript := preload("res://game/ui/screens/saved_tracks_screen.gd")
const SettingsScreenScript := preload("res://game/ui/screens/settings_screen.gd")
const GarageScreenScript := preload("res://game/ui/screens/garage_screen.gd")
const CreditsScreenScript := preload("res://game/ui/screens/credits_screen.gd")
const TrackSelectScreenScript := preload("res://game/ui/screens/track_select_screen.gd")
const TrackTourScreenScript := preload("res://game/ui/screens/track_tour_screen.gd")
const MultiplayerScreenScript := preload("res://game/ui/screens/multiplayer_screen.gd")
const SimpleScreenScript := preload("res://game/ui/screens/simple_screen.gd")

var screen_host: Control
var current_screen: Control
var transition_layer: ColorRect
var route_payload: Dictionary = {}
var _quitting := false
var _background_paused_audio := false
var _application_backgrounded := false

func _ready() -> void:
	set_process_unhandled_input(true)
	DesignSystem.configure_ui_scale(_startup_ui_scale())
	if not GameServices.settings_changed.is_connected(_on_settings_changed):
		GameServices.settings_changed.connect(_on_settings_changed)
	_build_shell()
	var startup := _startup_route()
	navigate(startup, _startup_payload(startup))
	var smoke_frames := _smoke_frame_count()
	if smoke_frames > 0:
		_run_smoke_and_quit(smoke_frames)

func _startup_route() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--route="):
			var requested := argument.trim_prefix("--route=")
			if requested in ["splash", "home", "studio", "tracks", "tour", "race_config", "race", "network_race", "multiplayer", "saved", "settings", "garage", "credits"]:
				return requested
	return "splash"

func _smoke_frame_count() -> int:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--smoke-frames="):
			return clampi(int(argument.trim_prefix("--smoke-frames=")), 1, 600)
	return 0


func _startup_ui_scale() -> float:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ui-scale="):
			var parsed := argument.trim_prefix("--ui-scale=").to_float()
			return clampf(parsed, GameSettings.MIN_UI_SCALE, GameSettings.MAX_UI_SCALE)
	return GameServices.settings().ui_scale


func _startup_payload(route: String) -> Dictionary:
	if route == "splash":
		return {}
	var output := {"visual_fixture": true}
	for argument in OS.get_cmdline_user_args():
		if argument == "--camera=cockpit":
			output["camera_view"] = "cockpit"
		elif argument == "--camera=chase":
			output["camera_view"] = "chase"
	return output

func _build_shell() -> void:
	var backdrop := AmbientBackdropScript.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	screen_host = Control.new()
	screen_host.name = "ScreenHost"
	screen_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(screen_host)

	transition_layer = ColorRect.new()
	transition_layer.name = "Transition"
	transition_layer.color = DesignSystem.INK
	transition_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	transition_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	transition_layer.modulate.a = 0.0
	add_child(transition_layer)

func navigate(route: String, payload: Dictionary = {}) -> void:
	route_payload = payload.duplicate(true)
	var next_screen: Control
	match route:
		"splash":
			next_screen = SplashScreenScript.new()
		"home":
			next_screen = MainMenuScript.new()
		"studio":
			next_screen = TrackStudioScript.new()
		"tracks":
			next_screen = TrackSelectScreenScript.new()
		"tour":
			next_screen = TrackTourScreenScript.new()
		"race_config":
			next_screen = OfflineRaceConfigScreenScript.new()
		"race":
			next_screen = RaceScreenScript.new()
		"network_race":
			next_screen = NetworkRaceScreenScript.new()
		"multiplayer":
			next_screen = MultiplayerScreenScript.new()
		"saved":
			next_screen = SavedTracksScript.new()
		"settings":
			next_screen = SettingsScreenScript.new()
		"garage":
			next_screen = GarageScreenScript.new()
		"credits":
			next_screen = CreditsScreenScript.new()
		_:
			next_screen = SimpleScreenScript.new()
			next_screen.configure(route)
	next_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if next_screen.has_method("set_payload"):
		next_screen.call("set_payload", route_payload)
	if next_screen.has_signal("navigate_requested"):
		next_screen.connect("navigate_requested", navigate)
	if current_screen != null:
		current_screen.queue_free()
	current_screen = next_screen
	screen_host.add_child(current_screen)
	DesignSystem.apply_ui_scale(current_screen, DesignSystem.current_ui_scale())
	_apply_route_audio(route)
	_play_enter_transition()


func _on_settings_changed(value: GameSettings) -> void:
	DesignSystem.apply_ui_scale(current_screen, value.ui_scale)

func _apply_route_audio(route: String) -> void:
	if route == "splash":
		Audio.stop_music()
	elif route == "race" or route == "network_race":
		Audio.play_music(&"race_loop")
		Audio.play_ambience()
		Audio.start_engine()
	else:
		Audio.set_gameplay_paused(false)
		Audio.stop_engine()
		Audio.stop_ambience()
		Audio.play_music(&"menu_loop")

func _play_enter_transition() -> void:
	if GameServices.settings().reduced_motion:
		transition_layer.modulate.a = 0.0
		return
	transition_layer.modulate.a = 0.72
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(transition_layer, "modulate:a", 0.0, 0.28)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and current_screen != null and not current_screen is MainMenuScreen:
		if current_screen.has_method("handle_back_request"):
			current_screen.call("handle_back_request")
		elif current_screen.get_script() == TrackStudioScript and bool(route_payload.get("multiplayer_return", false)):
			navigate("multiplayer", {"return_room_code": str(route_payload.get("return_room_code", ""))})
		else:
			navigate("home")
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			_begin_clean_quit()
		NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT:
			if _application_backgrounded:
				return
			_application_backgrounded = true
			_background_paused_audio = true
			Audio.set_gameplay_paused(true)
			if current_screen != null and current_screen.has_method("on_application_paused"):
				current_screen.call("on_application_paused")
		NOTIFICATION_APPLICATION_RESUMED, NOTIFICATION_APPLICATION_FOCUS_IN:
			if not _application_backgrounded:
				return
			_application_backgrounded = false
			if _background_paused_audio:
				_background_paused_audio = false
				Audio.set_gameplay_paused(false)
			if current_screen != null and current_screen.has_method("on_application_resumed"):
				current_screen.call("on_application_resumed")

func _begin_clean_quit() -> void:
	if _quitting:
		return
	_quitting = true
	# Stop route-level process callbacks before draining audio. Otherwise an
	# active race can restart its engine stream in the short asynchronous
	# AudioServer shutdown window and leave playback resources behind.
	if current_screen != null:
		current_screen.set_process(false)
		current_screen.set_process_unhandled_input(false)
	Audio.shutdown()
	_finish_clean_quit()

func _finish_clean_quit() -> void:
	# WAV playback is released asynchronously by AudioServer. Give it a bounded
	# drain window before freeing the owner; this also keeps test and desktop
	# shutdown logs free of false-positive resource leaks.
	await get_tree().create_timer(0.14, true, false, true).timeout
	if is_instance_valid(Audio):
		Audio.free()
	await get_tree().process_frame
	get_tree().quit()

func _run_smoke_and_quit(frame_count: int) -> void:
	for _frame in frame_count:
		await get_tree().process_frame
	_begin_clean_quit()
