extends RefCounted

const TestCaseType := preload("res://tests/support/test_case.gd")
const ProfileExchangeType := preload("res://game/persistence/profile_exchange.gd")
const CanonicalJsonType := preload("res://game/core/canonical_json.gd")


func run() -> Dictionary:
	var test := TestCaseType.new()
	var profile := {
		"schema_version": 1,
		"settings": {"controls": {"vibration": true}},
		"saved_tracks": [],
		"best_laps": {"builtin-evergreen-oval": {"time_ms": 65432}},
		"race_results": [{"track_id": "builtin-evergreen-oval", "position": 2}],
	}
	var encoded: Dictionary = ProfileExchangeType.encode(profile, 123456)
	test.assert_true(encoded.get("ok", false), "bounded local profile encodes")
	test.assert_equal(encoded["envelope"]["format"], ProfileExchangeType.FORMAT, "export format is explicit")
	test.assert_equal(encoded["envelope"]["format_version"], 1, "export format version is pinned")
	test.assert_equal(encoded["envelope"]["exported_at_timestamp"], 123456, "export timestamp is retained")
	var decoded: Dictionary = ProfileExchangeType.decode(str(encoded["json"]))
	test.assert_true(decoded.get("ok", false), "encoded profile verifies and decodes")
	test.assert_equal(
		CanonicalJsonType.stringify(decoded.get("profile", {})),
		CanonicalJsonType.stringify(profile),
		"portable profile round-trips exactly across JSON numeric decoding"
	)
	var private_fields := profile.duplicate(true)
	private_fields["install_id"] = "rg_install_should-never-export"
	private_fields["nested"] = {"reconnect_token": "secret", "access_token": "bearer", "safe": "kept"}
	var sanitized: Dictionary = ProfileExchangeType.encode(private_fields, 123456)
	var sanitized_text := str(sanitized.get("json", ""))
	test.assert_false("install_id" in sanitized_text or "reconnect_token" in sanitized_text or "access_token" in sanitized_text, "profile export strips anonymous identity and runtime tokens recursively")
	var sanitized_decoded: Dictionary = ProfileExchangeType.decode(sanitized_text)
	test.assert_equal(sanitized_decoded.get("profile", {}).get("nested", {}).get("safe"), "kept", "privacy filtering preserves ordinary local profile fields")

	var tampered: Dictionary = JSON.parse_string(str(encoded["json"]))
	tampered["profile"]["race_results"][0]["position"] = 1
	var rejected := ProfileExchangeType.decode(JSON.stringify(tampered))
	test.assert_false(rejected.get("ok", true), "tampered profile fails closed")
	test.assert_equal(rejected.get("error_code"), "profile_export_checksum_mismatch", "tamper failure is stable")
	test.assert_false(ProfileExchangeType.decode("not-json").get("ok", true), "malformed export is rejected")

	var relative_directory := "user://tests/profile-exchange"
	var absolute_directory := ProjectSettings.globalize_path(relative_directory)
	_cleanup(absolute_directory)
	var first := ProfileExchangeType.export_to_file(profile, 123456, relative_directory)
	test.assert_true(first.get("ok", false), "verified profile installs atomically")
	test.assert_true(FileAccess.file_exists(str(first.get("path", ""))), "installed export exists")
	test.assert_true(ProfileExchangeType.decode(FileAccess.get_file_as_string(str(first["path"]))).get("ok", false), "installed file passes read-back decoder")
	var second := ProfileExchangeType.export_to_file(profile, 123457, relative_directory)
	test.assert_true(second.get("ok", false), "existing export can be replaced atomically")
	test.assert_true(second.get("replaced", false), "replacement is reported explicitly")
	test.assert_false(FileAccess.file_exists(str(second["path"]) + ".tmp"), "temporary export is removed")
	test.assert_false(FileAccess.file_exists(str(second["path"]) + ".bak"), "backup export is removed after success")
	_cleanup(absolute_directory)
	return test.result("profile_exchange")


func _cleanup(absolute_directory: String) -> void:
	for filename in [
		ProfileExchangeType.DEFAULT_FILENAME,
		ProfileExchangeType.DEFAULT_FILENAME + ".tmp",
		ProfileExchangeType.DEFAULT_FILENAME + ".bak",
	]:
		var path := absolute_directory.path_join(filename)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if DirAccess.dir_exists_absolute(absolute_directory):
		DirAccess.remove_absolute(absolute_directory)
