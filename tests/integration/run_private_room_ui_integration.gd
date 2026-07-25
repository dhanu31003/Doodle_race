extends SceneTree
## Headless product-flow proof for the Private Room screen. The transport and
## authority are the same deterministic adapters used by protocol tests; this
## suite verifies that the actual buttons, fields, lobby state and navigation
## are wired to that authority rather than only testing the services directly.

const TestCaseType := preload("res://tests/support/test_case.gd")
const MultiplayerScreenType := preload("res://game/ui/screens/multiplayer_screen.gd")
const FakeRoomServerType := preload("res://game/network/fake_room_server.gd")
const InMemoryTransportType := preload("res://game/network/in_memory_transport.gd")

const WAIT_TIMEOUT_MS := 5000


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test := TestCaseType.new()
	var session: PrivateMultiplayerSession = root.get_node_or_null("NetworkSession")
	test.assert_true(session != null, "private-room session autoload is available to the product screen")
	if session == null:
		_finish(test)
		return

	await _prove_host_product_flow(test, session)
	await _prove_guest_code_join_and_leave(test, session)
	session.reset_session(true)
	await process_frame
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
	await create_timer(0.12).timeout
	_finish(test)


func _prove_host_product_flow(test: RefCounted, session: PrivateMultiplayerSession) -> void:
	session.reset_session(true)
	var server := FakeRoomServerType.new()
	var host_transport := InMemoryTransportType.new(server, "ui-host")
	session.configure_test_transport(host_transport, "ui-host")
	var screen := MultiplayerScreenType.new()
	var navigations: Array[Dictionary] = []
	screen.navigate_requested.connect(func(route: String, payload: Dictionary) -> void:
		navigations.append({"route": route, "payload": payload.duplicate(true)})
	)
	root.add_child(screen)
	screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	test.assert_true(screen._create_button != null and screen._join_button != null, "entry screen exposes create and code-join actions")
	test.assert_true(screen._name_edit != null and screen._code_edit != null, "entry screen exposes bounded driver-name and room-code fields")
	screen._name_edit.text = "UI Host"
	screen._create_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool: return session.is_joined()), "Create Private Room joins the host through the screen")
	test.assert_true(await _wait_until(func() -> bool: return not screen._busy), "host create action always clears its busy state")
	var created := session.public_snapshot()
	test.assert_equal(str(created.get("room_code", "")).length(), 6, "created lobby exposes one six-character invite code")
	test.assert_equal(str(created.get("host_id", "")), "ui-host", "created lobby assigns the local screen user as host")
	test.assert_equal(int(created.get("member_count", 0)), 1, "created lobby begins with exactly the host")
	test.assert_true(screen._room_code_label != null and screen._room_code_label.text == created["room_code"], "lobby renders the authoritative invite code")
	test.assert_true(screen._select_track_button.visible and screen._lock_button.visible and screen._start_button.visible, "host-only circuit, lock and start controls are visible to the host")
	test.assert_true(screen._selected_definition != null, "host lobby selects a valid release circuit by default")

	screen._select_track_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool:
		return bool(session.public_snapshot().get("has_local_track", false))
	), "host circuit action compiles and stores the exact local track")
	test.assert_true(await _wait_until(func() -> bool:
		return bool(session.local_member().get("generation_verified", false))
	), "host receives its generation-verification acknowledgement")
	test.assert_true(not screen._ready_button.disabled, "verified circuit enables the Ready action")

	screen._lock_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool:
		return bool(session.public_snapshot().get("join_locked", false))
	), "host Lock Grid action closes authoritative admission")
	screen._ready_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool:
		return bool(session.local_member().get("ready", false))
	), "host Ready action reaches authoritative member state")
	test.assert_true(await _wait_until(func() -> bool: return session.can_start()), "locked verified one-host grid reaches the authoritative start gate")

	screen._start_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool: return not navigations.is_empty()), "Start Race navigates only after authority publishes countdown")
	if not navigations.is_empty():
		var navigation := navigations[0]
		var race_payload: Dictionary = navigation["payload"]
		test.assert_equal(navigation["route"], "network_race", "private lobby launches the dedicated network race screen")
		test.assert_true(bool(race_payload.get("network_mode", false)), "private race payload remains explicitly network-authoritative")
		test.assert_equal(str(race_payload.get("room_code", "")), str(created["room_code"]), "private race payload preserves the exact invite room")
		test.assert_equal(race_payload.get("roster", []).size(), 1, "private race payload carries the authoritative roster")
		test.assert_true(not str(race_payload.get("track_definition_json", "")).is_empty(), "private race payload carries the verified canonical circuit")
		test.assert_true(int(race_payload.get("laps", 0)) in [1, 3, 5], "private race payload carries an allowed authoritative lap count")
	screen.queue_free()
	await process_frame
	session.reset_session(true)
	await process_frame


func _prove_guest_code_join_and_leave(test: RefCounted, session: PrivateMultiplayerSession) -> void:
	var server := FakeRoomServerType.new()
	var direct_host := InMemoryTransportType.new(server, "direct-host")
	var created: Dictionary = direct_host.create_private_room("Direct Host")
	test.assert_true(bool(created.get("ok", false)), "guest UI fixture begins from a real authoritative room")
	if not created.get("ok", false):
		return
	var room_code := str(created["value"].get("room_code", ""))
	var guest_transport := InMemoryTransportType.new(server, "ui-guest")
	session.configure_test_transport(guest_transport, "ui-guest")
	var screen := MultiplayerScreenType.new()
	var navigations: Array[Dictionary] = []
	screen.navigate_requested.connect(func(route: String, payload: Dictionary) -> void:
		navigations.append({"route": route, "payload": payload.duplicate(true)})
	)
	root.add_child(screen)
	screen.size = Vector2(1280.0, 720.0)
	await process_frame
	await process_frame
	screen._code_edit.text = "O0I1--"
	screen._code_edit.text_changed.emit(screen._code_edit.text)
	await process_frame
	test.assert_equal(screen._code_edit.text, "", "room-code field removes ambiguous unsupported characters on entry")
	screen._name_edit.text = "UI Guest"
	screen._code_edit.text = room_code.to_lower()
	screen._code_edit.text_changed.emit(screen._code_edit.text)
	await process_frame
	test.assert_equal(screen._code_edit.text, room_code, "room-code field normalizes lowercase invites before joining")
	screen._join_button.pressed.emit()
	test.assert_true(await _wait_until(func() -> bool: return session.is_joined()), "Join Room button joins the authoritative code room")
	test.assert_true(await _wait_until(func() -> bool: return not screen._busy), "guest join action always clears its busy state")
	var joined := session.public_snapshot()
	test.assert_equal(str(joined.get("room_code", "")), room_code, "guest session preserves the normalized room code")
	test.assert_equal(int(joined.get("member_count", 0)), 2, "guest lobby shows both admitted drivers")
	test.assert_true(not session.is_host(), "code-joined player cannot gain host authority")
	test.assert_true(not screen._select_track_button.visible and not screen._lock_button.visible and not screen._start_button.visible, "guest UI hides every host-only mutation control")
	test.assert_true(screen._ready_button.disabled, "guest Ready remains blocked until a host circuit is verified")
	var system_back := InputEventAction.new()
	system_back.action = "ui_cancel"
	system_back.pressed = true
	screen._unhandled_input(system_back)
	test.assert_true(await _wait_until(func() -> bool: return not session.is_joined()), "mobile system Back leaves the authoritative room instead of abandoning membership")
	test.assert_true(await _wait_until(func() -> bool: return not navigations.is_empty()), "completed leave returns the player to the paddock")
	if not navigations.is_empty():
		test.assert_equal(navigations[0]["route"], "home", "system Back returns private-room players to the home route")
	screen.queue_free()
	await process_frame


func _wait_until(predicate: Callable, timeout_ms: int = WAIT_TIMEOUT_MS) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() <= deadline:
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _finish(test: RefCounted) -> void:
	var result: Dictionary = test.result("private_room_ui_integration")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
	else:
		print("FAIL %s" % result.suite)
		for failure in result.failures:
			print("  - %s" % failure)
	call_deferred("quit", 0 if result.passed else 1)
