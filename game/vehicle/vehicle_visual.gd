class_name VehicleVisual
extends Node2D

var body_color := DesignSystem.MINT
var accent_color := DesignSystem.WHITE
var car_number := 1
var boost_glow := 0.0
var car_sprite: Sprite2D

const CAR_TEXTURES := [
	"res://assets/final/vehicles/car_prime.svg",
	"res://assets/final/vehicles/car_aurora.svg",
	"res://assets/final/vehicles/car_cinder.svg",
	"res://assets/final/vehicles/car_jade.svg",
	"res://assets/final/vehicles/car_solar.svg",
	"res://assets/final/vehicles/car_violet.svg",
	"res://assets/final/vehicles/car_tide.svg",
	"res://assets/final/vehicles/car_rose.svg"
]

func _ready() -> void:
	_ensure_sprite()

func configure(color: Color, number: int, accent: Color = DesignSystem.WHITE) -> void:
	body_color = color
	car_number = number
	accent_color = accent
	_ensure_sprite()
	queue_redraw()

func _ensure_sprite() -> void:
	if car_sprite == null:
		car_sprite = Sprite2D.new()
		car_sprite.rotation = PI * 0.5
		# V2 uses a 160x240 authored canvas; this preserves the original on-track
		# footprint while keeping the higher-detail wing and tire geometry crisp.
		car_sprite.scale = Vector2.ONE * 0.17
		car_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		add_child(car_sprite)
	car_sprite.texture = load(CAR_TEXTURES[(car_number - 1) % CAR_TEXTURES.size()])

func set_boosting(active: bool) -> void:
	boost_glow = 1.0 if active else 0.0
	queue_redraw()

func _draw() -> void:
	_draw_shadow_ellipse(Vector2(4.0, 5.0), Vector2(18.0, 8.0), Color(0.0, 0.0, 0.0, 0.36))
	if boost_glow > 0.0:
		draw_circle(Vector2(-19.0, 0.0), 10.0, Color(0.31, 0.78, 1.0, 0.20))
		draw_colored_polygon(PackedVector2Array([Vector2(-13.0, -3.0), Vector2(-30.0, 0.0), Vector2(-13.0, 3.0)]), DesignSystem.CYAN)
	if car_sprite != null and car_sprite.texture != null:
		return
	draw_colored_polygon(PackedVector2Array([
		Vector2(20.0, 0.0), Vector2(10.0, -7.0), Vector2(-6.0, -8.0),
		Vector2(-15.0, -5.0), Vector2(-18.0, 0.0), Vector2(-15.0, 5.0),
		Vector2(-6.0, 8.0), Vector2(10.0, 7.0)
	]), body_color)
	draw_colored_polygon(PackedVector2Array([Vector2(11.0, 0.0), Vector2(2.0, -4.5), Vector2(-7.0, -4.0), Vector2(-7.0, 4.0), Vector2(2.0, 4.5)]), accent_color)
	draw_rect(Rect2(-14.0, -12.0, 5.0, 8.0), Color("101725"), true)
	draw_rect(Rect2(7.0, -11.0, 5.0, 7.0), Color("101725"), true)
	draw_rect(Rect2(-14.0, 4.0, 5.0, 8.0), Color("101725"), true)
	draw_rect(Rect2(7.0, 4.0, 5.0, 7.0), Color("101725"), true)
	draw_line(Vector2(-13.0, -10.0), Vector2(-13.0, 10.0), accent_color, 2.0)
	draw_circle(Vector2(1.0, 0.0), 2.4, DesignSystem.INK)

func _draw_shadow_ellipse(center: Vector2, radii: Vector2, color: Color) -> void:
	var polygon := PackedVector2Array()
	for i in range(20):
		var angle := TAU * float(i) / 20.0
		polygon.append(center + Vector2(cos(angle) * radii.x, sin(angle) * radii.y))
	draw_colored_polygon(polygon, color)
