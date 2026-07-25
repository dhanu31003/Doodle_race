extends SceneTree
## Mobile pause/focus notifications can arrive in pairs and can reverse while a
## socket leave/join is still awaiting the platform. This fixture gates each
## transport operation so those orderings are deterministic and regression-safe.

const TestCaseType := preload("res://tests/support/test_case.gd")
const SessionType := preload("res://game/network/client/private_multiplayer_session.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")


class GatedLifecycleTransport:
	extends MultiplayerTransport

	signal release_suspend
	signal release_reconnect
	signal release_leave

	const ResultType := preload("res://game/network/network_result.gd")

	var suspend_calls := 0
	var reconnect_calls := 0
	var leave_calls := 0
	var close_calls := 0
	var room_view: Dictionary = {}


	func suspend_connection(_room_code: String) -> Dictionary:
		suspend_calls += 1
		await release_suspend
		return ResultType.success({"reconnect_token": "token-0"})


	func reconnect(_room_code: String, reconnect_token: String) -> Dictionary:
		reconnect_calls += 1
		await release_reconnect
		if reconnect_token != "token-0":
			return ResultType.failure(&"reconnect_token_invalid", "Unexpected fixture token.")
		var resumed_room := room_view.duplicate(true)
		for member in resumed_room.get("members", []):
			if member is Dictionary and str(member.get("player_id", "")) == "mobile-player":
				member["connected"] = true
		return ResultType.success({
			"room": resumed_room,
			"reconnect_token": "token-1",
			"resume": {
				"type": "peer_resumed",
				"player_id": "mobile-player",
				"reconnect_token": "token-1",
				"authoritative_snapshot": {},
			},
		})


	func leave_room(_room_code: String) -> Dictionary:
		leave_calls += 1
		await release_leave
		return ResultType.success({"left": true})


	func room_snapshot(_room_code: String) -> Dictionary:
		return ResultType.success(room_view.duplicate(true))


	func close() -> void:
		close_calls += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var test := TestCaseType.new()
	await _pause_resume_pair_is_single_flight(test)
	await _stale_suspend_cannot_resurrect(test)
	await _stale_reconnect_cannot_resurrect(test)
	await _socket_loss_uses_one_resume(test)
	await _leave_is_local_first(test)
	await _shutdown_audio()
	var result: Dictionary = test.result("mobile_private_room_lifecycle")
	if result.passed:
		print("PASS %s (%d assertions)" % [result.suite, result.assertions])
	else:
		print("FAIL %s" % result.suite)
		for failure in result.failures:
			print("  - %s" % failure)
	call_deferred("quit", 0 if result.passed else 1)


func _pause_resume_pair_is_single_flight(test: RefCounted) -> void:
	var fixture := _session_fixture()
	var session: PrivateMultiplayerSession = fixture["session"]
	var transport: GatedLifecycleTransport = fixture["transport"]
	var errors: Array[Dictionary] = []
	session.session_error.connect(func(error: Dictionary) -> void: errors.append(error))

	session.on_application_paused()
	session.on_application_paused()
	await process_frame
	var first_anchor := int(session.get("_background_suspend_ms"))
	test.assert_equal(transport.suspend_calls, 1, "pause plus focus-out starts exactly one suspend")
	test.assert_equal(str(session.connection_state), "reconnecting", "pause marks reconnecting before socket leave acknowledges")
	test.assert_true(first_anchor > 0, "first pause anchors one bounded reconnect window")

	session.on_application_resumed()
	session.on_application_resumed()
	await process_frame
	test.assert_equal(transport.reconnect_calls, 0, "resume waits for the pending suspend acknowledgement")
	test.assert_equal(int(session.get("_background_suspend_ms")), first_anchor, "duplicate lifecycle notifications cannot extend reconnect grace")
	transport.release_suspend.emit()
	await _frames(2)
	test.assert_equal(transport.reconnect_calls, 1, "pending resume starts one reconnect after suspend completes")
	transport.release_reconnect.emit()
	await _frames(3)
	test.assert_equal(str(session.connection_state), "online", "paired mobile notifications finish online")
	test.assert_equal(str(session.get("_reconnect_token")), "token-1", "one successful resume rotates the token exactly once")
	test.assert_equal(errors.size(), 0, "valid paired lifecycle notifications emit no session error")
	session.reset_session(true)
	test.assert_equal(transport.close_calls, 1, "completed lifecycle transport closes exactly once on reset")
	session.queue_free()
	await process_frame


func _stale_suspend_cannot_resurrect(test: RefCounted) -> void:
	var fixture := _session_fixture()
	var session: PrivateMultiplayerSession = fixture["session"]
	var transport: GatedLifecycleTransport = fixture["transport"]
	var errors: Array[Dictionary] = []
	session.session_error.connect(func(error: Dictionary) -> void: errors.append(error))
	session.on_application_paused()
	await process_frame
	test.assert_equal(transport.suspend_calls, 1, "stale-suspend fixture reaches its gated transport")
	session.reset_session(true)
	transport.release_suspend.emit()
	await _frames(3)
	test.assert_equal(str(session.connection_state), "offline", "late suspend completion cannot resurrect an offline session")
	test.assert_true(session.room_code.is_empty() and str(session.get("_reconnect_token")).is_empty(), "late suspend cannot restore room identity or token")
	test.assert_equal(errors.size(), 0, "stale suspend completion emits no user-facing error")
	test.assert_equal(transport.close_calls, 1, "reset closes a gated suspend transport once")
	session.queue_free()
	await process_frame


func _stale_reconnect_cannot_resurrect(test: RefCounted) -> void:
	var fixture := _session_fixture()
	var session: PrivateMultiplayerSession = fixture["session"]
	var transport: GatedLifecycleTransport = fixture["transport"]
	var events: Array[Dictionary] = []
	session.event_received.connect(func(event: Dictionary) -> void: events.append(event))
	session.connection_state = SessionType.CONNECTION_RECONNECTING
	session.reconnect_async()
	await process_frame
	test.assert_equal(transport.reconnect_calls, 1, "stale-reconnect fixture reaches its gated transport")
	session.reset_session(true)
	transport.release_reconnect.emit()
	await _frames(3)
	test.assert_equal(str(session.connection_state), "offline", "late reconnect completion cannot restore online state")
	test.assert_true(session.room_code.is_empty() and str(session.get("_reconnect_token")).is_empty(), "late reconnect cannot rotate a cleared token")
	test.assert_equal(events.size(), 0, "stale reconnect emits no synthetic resume event")
	test.assert_equal(transport.close_calls, 1, "reset closes a gated reconnect transport once")
	session.queue_free()
	await process_frame


func _socket_loss_uses_one_resume(test: RefCounted) -> void:
	var fixture := _session_fixture()
	var session: PrivateMultiplayerSession = fixture["session"]
	var transport: GatedLifecycleTransport = fixture["transport"]
	var loss := ProtocolType.make_envelope(
		ProtocolType.OP_ERROR, "nakama", 0, 1, {"code": "nakama_socket_closed"}
	)
	session.call("_handle_event", loss)
	session.on_application_paused()
	session.on_application_paused()
	await process_frame
	test.assert_equal(transport.suspend_calls, 0, "already-lost socket is not suspended a second time")
	session.on_application_resumed()
	session.on_application_resumed()
	await process_frame
	test.assert_equal(transport.reconnect_calls, 1, "duplicate resume notifications start one reconnect after socket loss")
	transport.release_reconnect.emit()
	await _frames(3)
	test.assert_equal(str(session.connection_state), "online", "socket-loss lifecycle returns online once")
	session.reset_session(true)
	session.queue_free()
	await process_frame


func _leave_is_local_first(test: RefCounted) -> void:
	var fixture := _session_fixture()
	var session: PrivateMultiplayerSession = fixture["session"]
	var transport: GatedLifecycleTransport = fixture["transport"]
	var result: Dictionary = await session.leave_async()
	test.assert_true(result.get("ok", false), "explicit leave acknowledges the local transition immediately")
	test.assert_equal(transport.leave_calls, 1, "explicit leave starts one best-effort authority departure")
	test.assert_equal(str(session.connection_state), "offline", "local membership clears before a delayed server acknowledgement")
	test.assert_true(session.room_code.is_empty() and str(session.get("_reconnect_token")).is_empty(), "local-first leave immediately clears room and reconnect token")
	test.assert_equal(transport.close_calls, 0, "detached transport remains available only for its pending departure")
	transport.release_leave.emit()
	await _frames(3)
	test.assert_equal(transport.close_calls, 1, "detached transport closes exactly once after best-effort leave")
	session.queue_free()
	await process_frame


func _session_fixture() -> Dictionary:
	var transport := GatedLifecycleTransport.new()
	transport.room_view = {
		"room_code": "ABCDEF",
		"room_epoch": 1,
		"state": "READY",
		"host_id": "mobile-player",
		"member_count": 1,
		"members": [{
			"player_id": "mobile-player",
			"connected": true,
			"generation_verified": true,
			"ready": true,
		}],
		"track_identity": {},
		"race_config": {"laps": 3, "collisions": true},
		"join_locked": true,
		"countdown": {},
	}
	var session := SessionType.new()
	root.add_child(session)
	session.configure_test_transport(transport, "mobile-player")
	session.room_code = "ABCDEF"
	session.room_epoch = 1
	session.set("_room", transport.room_view.duplicate(true))
	session.set("_reconnect_token", "token-0")
	return {"session": session, "transport": transport}


func _frames(count: int) -> void:
	for _index in count:
		await process_frame


func _shutdown_audio() -> void:
	var audio := root.get_node_or_null("Audio")
	if audio != null:
		audio.call("shutdown")
	await create_timer(0.14, true, false, true).timeout

