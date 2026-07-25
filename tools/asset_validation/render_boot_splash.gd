extends SceneTree
## Deterministically rasterize the project SVG mark with Godot's own SVG parser.

const SOURCE := "res://assets/final/brand/raceglyph_mark.svg"
const OUTPUT := "res://assets/final/brand/raceglyph_boot_splash.png"

func _initialize() -> void:
	var source_text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(SOURCE))
	var image := Image.new()
	var load_error := image.load_svg_from_string(source_text, 4.0)
	if load_error != OK:
		push_error("Unable to rasterize %s: error %d" % [SOURCE, load_error])
		quit(1)
		return
	var save_error := image.save_png(ProjectSettings.globalize_path(OUTPUT))
	if save_error != OK:
		push_error("Unable to save %s: error %d" % [OUTPUT, save_error])
		quit(1)
		return
	print("Rendered %s (%dx%d)" % [OUTPUT, image.get_width(), image.get_height()])
	quit(0)
