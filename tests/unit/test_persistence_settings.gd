extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")
const TrackDefinitionType := preload("res://game/track/definition/track_definition.gd")
const GameSettingsType := preload("res://game/settings/game_settings.gd")
const SettingsRuntimeType := preload("res://game/settings/settings_runtime.gd")
const AtomicSaveStoreType := preload("res://game/persistence/atomic_save_store.gd")
const LocalSaveDataType := preload("res://game/persistence/local_save_data.gd")
const LocalProfileRepositoryType := preload("res://game/persistence/local_profile_repository.gd")
const SaveLimitsType := preload("res://game/persistence/save_limits.gd")
const DesignSystemType := preload("res://game/ui/design_system.gd")
const PerspectiveType := preload("res://game/ui/components/race_perspective_view.gd")
const MinimapType := preload("res://game/ui/components/race_minimap.gd")
const NetworkRaceScreenType := preload("res://game/ui/screens/network_race_screen.gd")
const RaceScreenType := preload("res://game/ui/screens/race_screen.gd")
const SplashScreenType := preload("res://game/ui/screens/splash_screen.gd")
const VehicleStateType := preload("res://game/race/vehicle_state.gd")
const RaceInputType := preload("res://game/race/race_input.gd")
const InstallIdentityStoreType := preload("res://game/network/client/install_identity_store.gd")

const TRACK_FIXTURE := "res://tests/fixtures/tracks/stadium_v1.json"
const TEST_ROOT := "user://raceglyph_test_persistence"

var _clock_value: int = 1_700_000_000


func run() -> Dictionary:
	var test := TestCaseType.new()
	_test_settings_schema(test)
	_test_accessibility_runtime_contracts(test)
	_test_atomic_write_and_corruption_recovery(test)
	_test_install_identity_deletion(test)
	_test_repository_crud_and_progress(test)
	_test_legacy_migration(test)
	_cleanup_path(TEST_ROOT + "/atomic.json")
	_cleanup_path(TEST_ROOT + "/profile.json")
	_cleanup_path(TEST_ROOT + "/legacy.json")
	_cleanup_path(TEST_ROOT + "/install_identity.v1")
	_cleanup_path(TEST_ROOT + "/install_identity.v1.tmp")
	_cleanup_path(TEST_ROOT + "/install_identity.v1.delete")
	return test.result("persistence_settings")


func _test_install_identity_deletion(test: RefCounted) -> void:
	var path := TEST_ROOT + "/install_identity.v1"
	_cleanup_path(path)
	_cleanup_path(path + ".tmp")
	_cleanup_path(path + ".delete")
	var store := InstallIdentityStoreType.new(path)
	var created := store.load_or_create()
	test.assert_true(created.get("ok", false) and created.get("created", false), "temporary-path anonymous identity is created")
	test.assert_true(InstallIdentityStoreType.is_valid(str(created.get("install_id", ""))), "anonymous identity has the bounded random format")
	var stale := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if stale != null:
		stale.store_string("stale")
		stale.close()
	var deleted := store.delete_identity()
	test.assert_true(deleted.get("ok", false) and deleted.get("deleted", false), "anonymous identity deletion reports the removed live identity")
	test.assert_false(FileAccess.file_exists(path) or FileAccess.file_exists(path + ".tmp") or FileAccess.file_exists(path + ".delete"), "identity deletion removes live and transient copies")
	var repeated := store.delete_identity()
	test.assert_true(repeated.get("ok", false) and not repeated.get("deleted", true), "anonymous identity deletion is safely idempotent")


func _test_accessibility_runtime_contracts(test: RefCounted) -> void:
	var root := Control.new()
	DesignSystemType.configure_ui_scale(1.0)
	var label := DesignSystemType.label("SCALE PROBE", 20)
	root.add_child(label)
	DesignSystemType.apply_ui_scale(root, GameSettingsType.MAX_UI_SCALE)
	test.assert_equal(label.get_theme_font_size("font_size"), 26, "maximum UI scale enlarges authored text exactly once")
	DesignSystemType.apply_ui_scale(root, GameSettingsType.MIN_UI_SCALE)
	test.assert_equal(label.get_theme_font_size("font_size"), 17, "UI scaling reuses the authored baseline instead of compounding")
	root.free()
	DesignSystemType.configure_ui_scale(1.0)

	test.assert_near(PerspectiveType.chase_sway_offset(1.0, 0.0, false), 0.0, 0.0001, "zero screen shake disables chase-camera sway")
	test.assert_near(PerspectiveType.chase_sway_offset(1.0, 1.0, true), 0.0, 0.0001, "reduced motion overrides maximum screen shake")
	test.assert_true(PerspectiveType.chase_sway_offset(0.5, 0.35, false) > 0.0, "enabled screen shake retains bounded steering feedback")
	test.assert_near(PerspectiveType.shift_settle_offset(5, true), 0.0, 0.0001, "reduced motion removes drivetrain shift settle")
	test.assert_near(PerspectiveType.shift_settle_offset(120, false), 3.0, 0.0001, "shift settle remains bounded to three pixels")
	test.assert_near(PerspectiveType.dashboard_rpm_ratio(8500.0, 4500.0, 12500.0), 0.5, 0.0001, "cockpit RPM LEDs use authoritative normalized engine speed")
	test.assert_near(PerspectiveType.dashboard_rpm_ratio(INF, 4500.0, 12500.0), 0.0, 0.0001, "non-finite RPM cannot corrupt cockpit presentation")
	test.assert_equal(PerspectiveType.dashboard_gear_segment_mask(1), 6, "cockpit gear one has a stable seven-segment shape")
	test.assert_equal(PerspectiveType.dashboard_gear_segment_mask(-1), 80, "cockpit reverse has a stable non-numeric seven-segment cue")

	var previous := VehicleStateType.new()
	var state := VehicleStateType.new()
	state.heading = 0.0
	state.velocity = Vector2(18.0, 12.0)
	state.is_offtrack = true
	state.wall_contacts = 1
	var brake := RaceInputType.new(0.0, 0.0, 1.0)
	var full_cues := PerspectiveType.cosmetic_cue_state(state, previous, brake, false, false)
	test.assert_true(full_cues["brake_lights"], "braking exposes a functional rear-light cue")
	test.assert_true(full_cues["dust"] and full_cues["slip_smoke"] and full_cues["sparks"], "full graphics exposes deterministic surface feedback")
	test.assert_true(full_cues["debris"] and not full_cues["skid_marks"], "contact exposes debris while off-track slip does not paint asphalt")
	state.is_offtrack = false
	var asphalt_cues := PerspectiveType.cosmetic_cue_state(state, previous, brake, false, false)
	test.assert_true(asphalt_cues["skid_marks"], "high lateral asphalt slip exposes bounded persistent skid marks")
	state.is_offtrack = true
	var reduced_cues := PerspectiveType.cosmetic_cue_state(state, previous, brake, false, true)
	test.assert_true(reduced_cues["brake_lights"], "reduced motion preserves the functional brake-light cue")
	test.assert_false(reduced_cues["dust"] or reduced_cues["slip_smoke"] or reduced_cues["sparks"] or reduced_cues["debris"] or reduced_cues["skid_marks"], "reduced motion removes particulate, debris, and trail motion")
	var low_cues := PerspectiveType.cosmetic_cue_state(state, previous, brake, true, false)
	test.assert_false(low_cues["dust"] or low_cues["slip_smoke"] or low_cues["sparks"], "low graphics removes expensive surface particles")

	test.assert_equal(MinimapType.marker_shape(&"racing", true, true), &"diamond", "player minimap identity has a non-color shape")
	test.assert_equal(MinimapType.marker_shape(&"finished", false, true), &"square", "finished cars have a non-color square cue")
	test.assert_equal(MinimapType.marker_shape(&"dnf", false, true), &"x", "DNF cars have a non-color X cue")
	test.assert_equal(MinimapType.marker_shape(&"dnf", false, false), &"circle", "disabled non-color differentiation returns the color-only marker")
	test.assert_equal(NetworkRaceScreenType.steering_surface_for_scheme(GameSettingsType.CONTROL_BUTTONS), &"buttons", "multiplayer button scheme renders left/right controls")
	test.assert_equal(NetworkRaceScreenType.steering_surface_for_scheme(GameSettingsType.CONTROL_WHEEL), &"wheel", "multiplayer wheel scheme renders a steering wheel")
	test.assert_equal(NetworkRaceScreenType.steering_surface_for_scheme(GameSettingsType.CONTROL_TILT), &"tilt", "multiplayer tilt scheme renders calibration feedback")
	test.assert_equal(SettingsRuntimeType.speed_to_kmh(123.45), 133, "shared offline/network speed-display conversion is stable")
	test.assert_equal(SettingsRuntimeType.drivetrain_hud_text(5, 10_850.0, false), "G5  10850 RPM", "offline/network HUD shares authoritative gear and RPM formatting")
	test.assert_equal(SettingsRuntimeType.drivetrain_hud_text(-1, 6000.0, true), "R  06000 RPM  SHIFT", "HUD exposes reverse and the deterministic shift phase")
	test.assert_equal(SettingsRuntimeType.drivetrain_hud_text(1, INF, false), "G1  00000 RPM", "non-finite drivetrain telemetry fails safe in the HUD")
	for cue in [&"start", &"contact", &"lap", &"recovery", &"finish"]:
		var pattern := NetworkRaceScreenType.haptic_pattern(cue)
		test.assert_true(int(pattern.get("duration_ms", 0)) > 0 and float(pattern.get("amplitude", 0.0)) > 0.0, "network cue %s has a restrained haptic pattern" % cue)
	var reduced_settings := GameSettingsType.new()
	reduced_settings.reduced_motion = true
	test.assert_false(SplashScreenType.animations_enabled(reduced_settings), "reduced motion makes splash progress and fade static")
	var custom_json := "{\"track_id\":\"custom\"}"
	test.assert_equal(RaceScreenType.studio_return_payload({"source": "saved", "track_definition_json": custom_json}), {"editing_track_json": custom_json}, "custom race results reopen the exact editable circuit")
	test.assert_true(RaceScreenType.studio_return_payload({"source": "predefined", "track_definition_json": custom_json}).is_empty(), "predefined race results open a fresh Track Studio")
	var classification_fixture: Array = []
	for position in range(1, 13):
		classification_fixture.append({"position": position, "display_name": "DRIVER %02d" % position, "status": "finished", "finish_time_ms": position * 1000})
	var classification := RaceScreenType.classification_rows(classification_fixture)
	test.assert_equal(classification.size(), 12, "offline results retain the complete 12-driver classification")
	test.assert_equal(classification.back()["position"], 12, "offline classification preserves final-place ordering")

	var local_record := NetworkRaceScreenType.local_history_record([
		{"player_id": "private-peer-a", "position": 1, "status": "finished", "finish_time_ms": 91_234},
		{"player_id": "private-peer-b", "position": 2, "status": "dnf", "finish_time_ms": 0},
	], "private-peer-a", "builtin-evergreen-oval", "car-prime")
	test.assert_equal(local_record.get("position"), 1, "authoritative multiplayer result maps to local history")
	test.assert_equal(local_record.get("racer_count"), 2, "local history retains only aggregate grid size")
	test.assert_false(local_record.has("player_id") or local_record.has("room_code") or local_record.has("members"), "local race history excludes room and peer identifiers")


func _test_settings_schema(test: RefCounted) -> void:
	var settings := GameSettingsType.from_dictionary({
		"schema_version": 1,
		"audio": {"master": 4.0, "music": -2.0, "sfx": 0.25, "engine": 0.65, "ambience": 0.4, "ui": 0.9, "muted": true},
		"controls": {
			"scheme": "invalid-scheme",
			"size": 9.0,
			"opacity": 0.01,
			"vertical_offset": 4.0,
			"tilt_calibration": [3.0, -4.0],
			"tilt_sensitivity": 99.0,
			"tilt_dead_zone": -1.0,
			"vibration": false,
		},
		"graphics": {"low_graphics": true, "battery_saver": true, "camera_view": "cockpit"},
		"accessibility": {
			"reduced_motion": true,
			"high_contrast": true,
			"color_safe_differentiation": true,
			"ui_scale": 4.0,
			"screen_shake": 1.5,
		},
	})
	test.assert_near(settings.master_volume, 1.0, 0.0001, "master volume must clamp")
	test.assert_near(settings.music_volume, 0.0, 0.0001, "music volume must clamp")
	test.assert_near(settings.sfx_volume, 0.25, 0.0001, "SFX volume must round-trip")
	test.assert_near(settings.engine_volume, 0.65, 0.0001, "engine volume must round-trip")
	test.assert_near(settings.ambience_volume, 0.4, 0.0001, "ambience volume must round-trip")
	test.assert_near(settings.ui_volume, 0.9, 0.0001, "UI volume must round-trip")
	test.assert_equal(settings.touch_control_scheme, GameSettingsType.CONTROL_BUTTONS, "unknown touch scheme must fall back safely")
	test.assert_near(settings.touch_control_size, 1.5, 0.0001, "touch control size must clamp")
	test.assert_near(settings.touch_control_opacity, 0.35, 0.0001, "touch opacity must retain a visible minimum")
	test.assert_near(settings.touch_control_vertical_offset, 1.0, 0.0001, "touch reach-height offset must clamp")
	test.assert_equal(settings.tilt_calibration, Vector2(1.0, -1.0), "tilt calibration must clamp to normalized range")
	test.assert_near(settings.tilt_sensitivity, 2.5, 0.0001, "tilt sensitivity must clamp")
	test.assert_near(settings.tilt_dead_zone, 0.0, 0.0001, "tilt dead zone must clamp")
	test.assert_false(settings.vibration_enabled, "vibration toggle must load")
	test.assert_true(settings.low_graphics, "low graphics toggle must load")
	test.assert_true(settings.battery_saver, "battery saver toggle must load")
	test.assert_equal(SettingsRuntimeType.target_fps(settings), 30, "battery saver selects a bounded 30 FPS target")
	test.assert_equal(SettingsRuntimeType.target_fps(GameSettingsType.new()), 60, "performance mode selects a bounded 60 FPS target")
	test.assert_equal(settings.camera_view, GameSettingsType.CAMERA_COCKPIT, "race camera preference must load")
	test.assert_true(settings.reduced_motion, "reduced motion must load")
	test.assert_true(settings.high_contrast, "high contrast must load")
	test.assert_true(SettingsRuntimeType.requires_non_color_cues(settings), "color-safe differentiation must expose non-color cue requirement")
	test.assert_near(SettingsRuntimeType.motion_multiplier(settings), 0.0, 0.0001, "reduced motion must disable cosmetic motion")
	test.assert_near(SettingsRuntimeType.screen_shake_strength(settings), 0.0, 0.0001, "reduced motion must override screen shake")
	var round_trip := GameSettingsType.from_dictionary(settings.to_dictionary())
	test.assert_equal(
		CanonicalJsonType.stringify(round_trip.to_dictionary()),
		CanonicalJsonType.stringify(settings.to_dictionary()),
		"sanitized settings must round-trip canonically"
	)
	var future := GameSettingsType.from_dictionary({"schema_version": 999, "audio": {"master": 0.0}})
	test.assert_near(future.master_volume, 0.85, 0.0001, "future settings schema must use safe defaults")


func _test_atomic_write_and_corruption_recovery(test: RefCounted) -> void:
	var path := TEST_ROOT + "/atomic.json"
	_cleanup_path(path)
	var store := AtomicSaveStoreType.new(path)
	var first := store.write_payload({"schema_version": 1, "marker": "first"}, 1, 100)
	test.assert_true(first.get("ok", false), "first atomic write must succeed")
	var loaded := store.load_payload()
	test.assert_equal(loaded.get("source"), "primary", "healthy load must use primary")
	test.assert_equal(loaded.get("revision"), 1, "healthy load must retain envelope revision")
	test.assert_equal(loaded.get("payload", {}).get("marker"), "first", "healthy load must retain payload")
	var second := store.write_payload({"schema_version": 1, "marker": "second"}, 2, 200)
	test.assert_true(second.get("ok", false), "second atomic write must succeed")
	test.assert_true(FileAccess.file_exists(store.backup_path()), "replacing a valid primary must create a backup")
	_write_raw(path, "{ definitely not valid JSON")
	var recovered := store.load_payload()
	test.assert_true(recovered.get("ok", false), "valid backup must recover a corrupt primary")
	test.assert_true(recovered.get("recovered", false), "recovery must be explicit in the result")
	test.assert_equal(recovered.get("source"), "backup", "corruption recovery must identify backup source")
	test.assert_equal(recovered.get("revision"), 1, "backup must contain the previous committed revision")
	test.assert_equal(recovered.get("payload", {}).get("marker"), "first", "backup payload must be restored")
	test.assert_true(FileAccess.file_exists(store.corrupt_path()), "corrupt primary must be preserved for diagnosis")
	var repaired := store.load_payload()
	test.assert_equal(repaired.get("source"), "primary", "backup recovery must repair the primary copy")
	test.assert_equal(repaired.get("payload", {}).get("marker"), "first", "repaired primary must verify")
	test.assert_true(store.write_payload({"schema_version": 1, "marker": "third"}, 3, 300).get("ok", false), "post-recovery write must succeed")
	var rollback_path := path + ".rollback"
	var move_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(rollback_path)
	)
	test.assert_equal(move_error, OK, "interrupted-replacement fixture must move primary to rollback")
	var rollback_recovered := store.load_payload()
	test.assert_equal(rollback_recovered.get("payload", {}).get("marker"), "third", "startup must recover an interrupted rollback rename")
	test.assert_false(FileAccess.file_exists(rollback_path), "successful interrupted-write recovery must consume rollback")
	var oversized := {"blob": "x".repeat(SaveLimitsType.MAX_SAVE_BYTES)}
	test.assert_equal(store.write_payload(oversized, 4, 400).get("error_code"), "save_too_large", "oversized saves must fail before replacement")


func _test_repository_crud_and_progress(test: RefCounted) -> void:
	var path := TEST_ROOT + "/profile.json"
	_cleanup_path(path)
	var repository := LocalProfileRepositoryType.new(path, Callable(self, "_clock_tick"))
	var load_result := repository.load()
	test.assert_true(load_result.get("ok", false), "new repository must load defaults")
	test.assert_equal(load_result.get("source"), "defaults", "new repository must report defaults")

	var settings := repository.settings_snapshot()
	settings.master_volume = 0.42
	settings.music_volume = 0.31
	settings.sfx_volume = 0.73
	settings.muted = true
	settings.touch_control_scheme = GameSettingsType.CONTROL_TILT
	settings.touch_control_size = 1.2
	settings.touch_control_opacity = 0.65
	settings.touch_control_vertical_offset = 0.4
	settings.tilt_calibration = Vector2(0.15, -0.10)
	settings.vibration_enabled = false
	settings.low_graphics = true
	settings.battery_saver = true
	settings.reduced_motion = true
	settings.high_contrast = true
	settings.color_safe_differentiation = true
	test.assert_true(repository.update_settings(settings).get("ok", false), "settings update must persist")

	var definition := TrackDefinitionType.from_json(FileAccess.get_file_as_string(TRACK_FIXTURE))
	definition.track_id = "track-local-stadium"
	definition.content_hash = ""
	definition.refresh_content_hash()
	var noisy_name := "\u0001  Aurora   Run  " + "Z".repeat(120)
	var upsert := repository.upsert_track(definition, {
		"display_name": noisy_name,
		"favorite": true,
		"source": "custom",
		"thumbnail_path": "user://track_thumbnails/track-local-stadium.webp",
		"tags": ["Night", "night", "Forest", "Sprint"],
	})
	test.assert_true(upsert.get("ok", false), "valid TrackDefinition must save")
	test.assert_true(upsert.get("created", false), "first upsert must create")
	var metadata := repository.list_track_metadata()
	test.assert_equal(metadata.size(), 1, "saved track must appear in metadata list")
	test.assert_true(str(metadata[0]["display_name"]).length() <= 80, "track display name must be bounded")
	test.assert_false(str(metadata[0]["display_name"]).contains("\u0001"), "track display name must strip control characters")
	test.assert_equal(metadata[0]["tags"], ["forest", "night", "sprint"], "track tags must sanitize, deduplicate, and sort")
	test.assert_true(repository.get_track("track-local-stadium") != null, "saved track must deserialize")
	test.assert_false(repository.rename_track("track-local-stadium", "").get("ok", false), "empty rename must be rejected")
	var renamed := repository.rename_track("track-local-stadium", "Moonlit Apex")
	test.assert_true(renamed.get("ok", false), "saved track rename must persist")
	test.assert_equal(repository.get_track("track-local-stadium").track_name, "Moonlit Apex", "rename must update TrackDefinition")

	test.assert_true(repository.record_best_lap("track-local-stadium", 90_000, "car.cyan", -1, false).get("improved", false), "first best lap must record")
	test.assert_false(repository.record_best_lap("track-local-stadium", 95_000, "car.cyan", -1, false).get("improved", true), "slower lap must not replace best")
	test.assert_true(repository.record_best_lap("track-local-stadium", 88_000, "car.coral", -1, false).get("improved", false), "faster lap must replace best")
	test.assert_true(repository.unlock_content("car.coral", false).get("created", false), "new unlock must record")
	test.assert_false(repository.unlock_content("car.coral", false).get("created", true), "duplicate unlock must be idempotent")
	test.assert_true(repository.set_selected_cosmetics("car.coral", "team.aurora", false).get("ok", false), "selected cosmetics must update")
	for index in SaveLimitsType.MAX_RACE_RESULTS + 5:
		var race := repository.record_race_result({
			"track_id": "track-local-stadium",
			"position": 1 + (index % 12),
			"racer_count": 12,
			"total_time_ms": 100_000 + index,
			"finished": true,
			"vehicle_id": "car.coral",
		}, false)
		test.assert_true(race.get("ok", false), "bounded race result must be accepted")
	test.assert_equal(repository.snapshot().race_results.size(), SaveLimitsType.MAX_RACE_RESULTS, "race history must retain only its bounded tail")
	test.assert_true(repository.save_now().get("ok", false), "batched progression must persist")

	var reloaded := LocalProfileRepositoryType.new(path, Callable(self, "_clock_tick"))
	test.assert_true(reloaded.load().get("ok", false), "persisted profile must reload")
	test.assert_near(reloaded.settings_snapshot().master_volume, 0.42, 0.0001, "audio settings must survive reload")
	test.assert_near(reloaded.settings_snapshot().touch_control_vertical_offset, 0.4, 0.0001, "touch reach-height offset must survive reload")
	test.assert_true(reloaded.settings_snapshot().high_contrast, "accessibility settings must survive reload")
	test.assert_true(reloaded.settings_snapshot().battery_saver, "battery target must survive reload")
	test.assert_equal(reloaded.snapshot().best_laps["track-local-stadium"]["time_ms"], 88_000, "best lap must survive reload")
	test.assert_equal(reloaded.snapshot().race_results.size(), SaveLimitsType.MAX_RACE_RESULTS, "bounded results must survive reload")
	test.assert_equal(reloaded.snapshot().unlocks, ["car.coral"], "unlocks must survive reload")
	var reset := reloaded.reset_progress()
	test.assert_true(reset.get("ok", false), "explicit reset-progress API must persist")
	var reset_snapshot := reloaded.snapshot()
	test.assert_equal(reset_snapshot.best_laps.size(), 0, "progress reset must clear best laps")
	test.assert_equal(reset_snapshot.race_results.size(), 0, "progress reset must clear results")
	test.assert_equal(reset_snapshot.unlocks.size(), 0, "progress reset must clear unlocks")
	test.assert_equal(reset_snapshot.saved_tracks.size(), 1, "progress reset must preserve custom tracks")
	test.assert_true(reset_snapshot.settings.high_contrast, "progress reset must preserve user settings")
	test.assert_true(reloaded.delete_track("track-local-stadium").get("ok", false), "saved track delete must persist")
	test.assert_equal(reloaded.list_track_metadata().size(), 0, "deleted track must leave the catalog")


func _test_legacy_migration(test: RefCounted) -> void:
	var path := TEST_ROOT + "/legacy.json"
	_cleanup_path(path)
	var store := AtomicSaveStoreType.new(path)
	var legacy_payload := {
		"schema_version": 0,
		"revision": 7,
		"created_at_timestamp": 100,
		"updated_at_timestamp": 200,
		"settings": {"master_volume": 0.25, "muted": true},
		"tracks": [],
		"best_times_ms": {"predefined.stadium": 72_500},
		"results": [],
		"unlocked": ["car.cyan", "car.cyan"],
		"selected_car": "car.cyan",
		"selected_team": "team.comet",
	}
	test.assert_true(store.write_payload(legacy_payload, 7, 200).get("ok", false), "legacy fixture envelope must write")
	var repository := LocalProfileRepositoryType.new(path, Callable(self, "_clock_tick"))
	var loaded := repository.load()
	test.assert_true(loaded.get("ok", false), "supported legacy save must load")
	test.assert_true(loaded.get("migrated", false), "legacy load must report migration")
	test.assert_true(FileAccess.file_exists(store.backup_path()), "migration write must back up the previous schema")
	var state := repository.snapshot()
	test.assert_equal(state.schema_version, 1, "legacy save must migrate to current schema")
	test.assert_equal(state.best_laps["predefined.stadium"]["time_ms"], 72_500, "legacy best time must migrate")
	test.assert_equal(state.unlocks, ["car.cyan"], "legacy unlocks must deduplicate")
	test.assert_near(state.settings.master_volume, 0.25, 0.0001, "legacy flat audio setting must migrate")
	test.assert_true(state.settings.muted, "legacy mute setting must migrate")
	test.assert_equal(state.selected_car_id, "car.cyan", "legacy selected car must migrate")
	test.assert_equal(state.selected_team_id, "team.comet", "legacy selected team must migrate")
	test.assert_equal(state.revision, 8, "migration must commit a new revision")


func _clock_tick() -> int:
	_clock_value += 1
	return _clock_value


func _cleanup_path(path: String) -> void:
	AtomicSaveStoreType.new(path).delete_all_copies()


func _write_raw(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.flush()
		file.close()
