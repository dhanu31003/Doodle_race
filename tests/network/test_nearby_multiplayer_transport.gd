extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const HubType := preload("res://tests/network/support/fake_nearby_hub.gd")
const BridgeType := preload("res://tests/network/support/fake_nearby_bridge.gd")
const TransportType := preload("res://game/network/nearby/nearby_multiplayer_transport.gd")
const ProtocolType := preload("res://game/network/network_protocol.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	var hub := HubType.new()
	var host_bridge := BridgeType.new(hub, "phone-host")
	var guest_bridge := BridgeType.new(hub, "tablet-guest")
	var host_transport := TransportType.new()
	var guest_transport := TransportType.new()
	host_transport.configure_test_bridge(host_bridge)
	guest_transport.configure_test_bridge(guest_bridge)
	var tree := Engine.get_main_loop() as SceneTree
	var wait_host := Node.new()
	var wait_guest := Node.new()
	tree.root.add_child(wait_host)
	tree.root.add_child(wait_guest)

	var host_auth: Dictionary = await host_transport.authenticate_device_async(
		wait_host, "host-device-identity", "Host"
	)
	var guest_auth: Dictionary = await guest_transport.authenticate_device_async(
		wait_guest, "guest-device-identity", "Guest"
	)
	test.assert_true(host_auth.get("ok", false), "nearby host authenticates locally without a cloud account")
	test.assert_true(guest_auth.get("ok", false), "nearby guest authenticates locally without a cloud account")

	var created: Dictionary = await host_transport.create_private_room("Host")
	test.assert_true(created.get("ok", false), "nearby phone advertises a private room")
	var code := str(created.get("value", {}).get("room_code", ""))
	test.assert_equal(code.length(), 6, "nearby room uses the bounded six-character join code")
	test.assert_true(str(hub.advertisements.get("phone-host", "")).begins_with("RG4|%s|" % code), "nearby advertisement preserves its protocol and room-code delimiters")

	var joined: Dictionary = await guest_transport.join_private_room(code, "Guest")
	test.assert_true(joined.get("ok", false), "nearby tablet discovers and joins the requested host")
	test.assert_equal(str(joined.get("value", {}).get("room_code", "")), code, "nearby guest joins the advertised room only")
	var host_room: Dictionary = host_transport.room_snapshot(code)
	test.assert_equal(host_room.get("value", {}).get("members", []).size(), 2, "peer-host lobby contains both nearby devices")

	var ready: Dictionary = await guest_transport.set_ready(code, true)
	test.assert_false(ready.get("ok", false), "nearby guest lobby commands round-trip through the phone host")
	test.assert_equal(str(ready.get("error", {}).get("code", "")), "ready_unavailable", "peer host applies the authoritative lobby readiness gate")
	var guest_events: Array[Dictionary] = guest_transport.drain_events()
	test.assert_true(_contains_opcode(guest_events, ProtocolType.OP_ROOM_CONFIG), "nearby guest receives authoritative lobby updates")
	test.assert_equal(host_transport.authority_mode(), "peer_host", "nearby transport explicitly selects phone-host authority")
	test.assert_true(host_transport.transport_label().contains("NO INTERNET"), "nearby UI declares its offline operating mode")

	await host_transport.leave_room(code)
	guest_events = guest_transport.drain_events()
	test.assert_true(_contains_opcode(guest_events, ProtocolType.OP_ROOM_ENDED), "host departure terminates the nearby room on the guest")
	guest_transport.close()
	host_transport.configure_test_bridge(null)
	guest_transport.configure_test_bridge(null)
	hub.bridges.clear()
	hub.advertisements.clear()
	host_bridge.hub = null
	guest_bridge.hub = null
	wait_host.free()
	wait_guest.free()
	return test.result("nearby_multiplayer_transport")


func _contains_opcode(events: Array[Dictionary], opcode: int) -> bool:
	for event in events:
		if int(event.get("opcode", -1)) == opcode:
			return true
	return false
