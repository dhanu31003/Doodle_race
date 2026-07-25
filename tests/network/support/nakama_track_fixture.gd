extends RefCounted
## Runtime-scoped canonical track fixture for the Nakama process test. Keeping
## this graph out of the SDK runner lets Godot release its script resources
## after the fixture objects are explicitly dropped.

const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const ManifestType := preload("res://game/network/network_track_manifest.gd")
const CatalogType := preload("res://game/content/predefined_track_catalog.gd")


static func build() -> Dictionary:
	var definition: TrackDefinition = CatalogType.all()[0]["definition"]
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	if not compiled.succeeded() or compiled.track == null:
		return {"ok": false}
	return {
		"ok": true,
		"manifest": ManifestType.build(definition, compiled.track),
		"definition": definition,
		"compiled_track": compiled.track,
	}
