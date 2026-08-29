@tool
extends EditorPlugin

var export_plugin: AndroidExportPlugin


func _enter_tree() -> void:
	export_plugin = AndroidExportPlugin.new()
	add_export_plugin(export_plugin)


func _exit_tree() -> void:
	remove_export_plugin(export_plugin)
	export_plugin = null


class AndroidExportPlugin extends EditorExportPlugin:
	const PLUGIN_NAME := "RaceGlyphNearby"
	const NEARBY_DEPENDENCY := "com.google.android.gms:play-services-nearby:19.4.0"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		var build := "debug" if debug else "release"
		return PackedStringArray([
			"%s/bin/%s/%s-%s.aar" % [PLUGIN_NAME, build, PLUGIN_NAME, build],
		])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		return PackedStringArray([NEARBY_DEPENDENCY])

	func _get_name() -> String:
		return PLUGIN_NAME
