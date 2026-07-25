"""Generate RaceGlyph's original, brandless modern Formula body as a GLB.

This clean-room model is built only from Blender primitives and authored vertex
profiles. It contains no third-party geometry, logos, liveries, or textures.
Run with Blender 4.5 LTS:

  blender --background --python generate_premium_formula_car.py -- OUTPUT.glb
"""

from __future__ import annotations

import math
import pathlib
import sys

import bpy


def output_path() -> pathlib.Path:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if arguments:
        return pathlib.Path(arguments[0]).expanduser().resolve()
    return pathlib.Path("formula_car_premium_original.glb").resolve()


def reset_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.curves, bpy.data.materials):
        for item in list(block):
            block.remove(item)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0


def material(name: str, color: tuple[float, float, float, float], metallic: float, roughness: float):
    result = bpy.data.materials.new(name)
    result.diffuse_color = color
    result.use_nodes = True
    principled = result.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = color
    principled.inputs["Metallic"].default_value = metallic
    principled.inputs["Roughness"].default_value = roughness
    return result


def mesh_object(name: str, vertices, faces, source_material, smooth_sides: bool = True):
    mesh = bpy.data.meshes.new(f"{name}Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.materials.append(source_material)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    if smooth_sides:
        for polygon in mesh.polygons:
            polygon.use_smooth = True
    return obj


def loft(name: str, sections, source_material, radial_segments: int = 24):
    """Create a smooth closed loft along +X using elliptical Y/Z sections.

    Section tuple: (x, center_y, center_z, half_width, upper_height,
    lower_height). Separate upper/lower height keeps the floor side taut while
    retaining the smooth shoulder curvature of modern carbon bodywork.
    """
    vertices = []
    for x, center_y, center_z, half_width, upper_height, lower_height in sections:
        for segment in range(radial_segments):
            angle = math.tau * segment / radial_segments
            sine = math.sin(angle)
            height = upper_height if sine >= 0.0 else lower_height
            vertices.append(
                (x, center_y + math.cos(angle) * half_width, center_z + sine * height)
            )
    faces = []
    for section_index in range(len(sections) - 1):
        current = section_index * radial_segments
        following = (section_index + 1) * radial_segments
        for segment in range(radial_segments):
            next_segment = (segment + 1) % radial_segments
            faces.append(
                (
                    current + segment,
                    current + next_segment,
                    following + next_segment,
                    following + segment,
                )
            )
    first_center = len(vertices)
    first = sections[0]
    vertices.append((first[0], first[1], first[2]))
    last_center = len(vertices)
    last = sections[-1]
    vertices.append((last[0], last[1], last[2]))
    for segment in range(radial_segments):
        next_segment = (segment + 1) % radial_segments
        faces.append((first_center, next_segment, segment))
        offset = (len(sections) - 1) * radial_segments
        faces.append((last_center, offset + segment, offset + next_segment))
    obj = mesh_object(name, vertices, faces, source_material)
    # End caps should remain crisp even though the longitudinal shell is smooth.
    for polygon in obj.data.polygons[-radial_segments * 2 :]:
        polygon.use_smooth = False
    return obj


def rounded_box(name: str, location, dimensions, source_material, bevel: float = 0.025, rotation=(0.0, 0.0, 0.0)):
    bpy.ops.mesh.primitive_cube_add(location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(source_material)
    if bevel > 0.0:
        modifier = obj.modifiers.new("EdgeSoftening", "BEVEL")
        modifier.width = min(bevel, min(dimensions) * 0.45)
        modifier.segments = 3
        modifier.limit_method = "ANGLE"
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def cylinder_between(name: str, start, finish, radius: float, source_material, vertices: int = 16):
    from mathutils import Vector

    start_vector = Vector(start)
    finish_vector = Vector(finish)
    direction = finish_vector - start_vector
    midpoint = (start_vector + finish_vector) * 0.5
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=direction.length,
        location=midpoint,
    )
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(source_material)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0.0, 0.0, 1.0)).rotation_difference(direction.normalized())
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def wedge(name: str, center, length: float, width: float, low: float, high: float, source_material):
    cx, cy, cz = center
    x0 = cx - length * 0.5
    x1 = cx + length * 0.5
    y0 = cy - width * 0.5
    y1 = cy + width * 0.5
    vertices = [
        (x0, y0, cz - low * 0.5),
        (x0, y1, cz - low * 0.5),
        (x0, y0, cz + high),
        (x0, y1, cz + high),
        (x1, y0, cz - low * 0.5),
        (x1, y1, cz - low * 0.5),
        (x1, y0, cz + low * 0.5),
        (x1, y1, cz + low * 0.5),
    ]
    faces = [
        (0, 4, 5, 1),
        (2, 3, 7, 6),
        (0, 2, 6, 4),
        (1, 5, 7, 3),
        (0, 1, 3, 2),
        (4, 6, 7, 5),
    ]
    return mesh_object(name, vertices, faces, source_material, False)


def join_prefix(prefix: str, final_name: str) -> None:
    objects = [obj for obj in bpy.context.scene.objects if obj.name.startswith(prefix)]
    if not objects:
        return
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    objects[0].name = final_name


def build_car() -> None:
    paint = material("PremiumTeamPaint", (0.025, 0.10, 0.17, 1.0), 0.55, 0.16)
    accent = material("PremiumAccent", (0.15, 0.90, 0.63, 1.0), 0.30, 0.18)
    carbon = material("PremiumCarbon", (0.008, 0.012, 0.018, 1.0), 0.18, 0.30)
    metal = material("PremiumMetal", (0.19, 0.22, 0.25, 1.0), 0.92, 0.20)

    # Ground-effect floor and a low, continuously curved survival cell.
    rounded_box("Carbon_Floor", (-0.05, 0.0, 0.135), (4.30, 1.42, 0.085), carbon, 0.035)
    rounded_box("Carbon_FloorTeaTray", (1.43, 0.0, 0.17), (1.25, 0.58, 0.055), carbon, 0.025)
    loft(
        "Paint_Monocoque",
        [
            (2.52, 0.0, 0.35, 0.075, 0.075, 0.055),
            (2.28, 0.0, 0.36, 0.115, 0.095, 0.070),
            (1.85, 0.0, 0.39, 0.185, 0.145, 0.095),
            (1.38, 0.0, 0.42, 0.270, 0.190, 0.120),
            (0.92, 0.0, 0.46, 0.345, 0.245, 0.155),
            (0.48, 0.0, 0.48, 0.405, 0.285, 0.170),
            (0.06, 0.0, 0.48, 0.455, 0.300, 0.180),
            (-0.42, 0.0, 0.47, 0.470, 0.285, 0.175),
            (-0.88, 0.0, 0.44, 0.405, 0.260, 0.160),
            (-1.38, 0.0, 0.39, 0.275, 0.205, 0.135),
            (-1.72, 0.0, 0.35, 0.150, 0.135, 0.095),
        ],
        paint,
        28,
    )

    # Sculpted sidepods: broad radiators, deep undercuts, and a tight coke-bottle exit.
    for side in (-1.0, 1.0):
        loft(
            "Paint_Sidepod",
            [
                (0.56, side * 0.50, 0.45, 0.105, 0.115, 0.075),
                (0.38, side * 0.55, 0.47, 0.255, 0.245, 0.115),
                (0.02, side * 0.56, 0.48, 0.315, 0.285, 0.135),
                (-0.48, side * 0.54, 0.48, 0.335, 0.285, 0.125),
                (-0.92, side * 0.48, 0.45, 0.275, 0.245, 0.105),
                (-1.32, side * 0.37, 0.40, 0.195, 0.180, 0.080),
                (-1.60, side * 0.26, 0.36, 0.090, 0.100, 0.060),
            ],
            paint,
            24,
        )
        rounded_box(
            "Carbon_SidepodInlet",
            (0.45, side * 0.665, 0.515),
            (0.12, 0.050, 0.275),
            carbon,
            0.022,
            (0.0, math.radians(8.0) * side, 0.0),
        )
        rounded_box(
            "Accent_FloorEdge",
            (-0.28, side * 0.727, 0.205),
            (2.95, 0.045, 0.035),
            accent,
            0.012,
        )
        wedge(
            "Carbon_FloorFence",
            (-0.75, side * 0.69, 0.25),
            0.72,
            0.028,
            0.03,
            0.19,
            carbon,
        )

    # Airbox and engine cover share the narrow, high centerline silhouette.
    loft(
        "Paint_EngineCover",
        [
            (-0.26, 0.0, 0.72, 0.115, 0.250, 0.115),
            (-0.48, 0.0, 0.73, 0.190, 0.335, 0.145),
            (-0.78, 0.0, 0.68, 0.235, 0.345, 0.155),
            (-1.10, 0.0, 0.60, 0.220, 0.310, 0.150),
            (-1.44, 0.0, 0.50, 0.170, 0.240, 0.125),
            (-1.70, 0.0, 0.41, 0.080, 0.130, 0.075),
        ],
        paint,
        24,
    )
    # Dark cockpit well reads as a real opening from chase angles while the
    # live steering wheel, hands, and driver are supplied by Godot.
    loft(
        "Carbon_CockpitWell",
        [
            (0.31, 0.0, 0.690, 0.285, 0.065, 0.045),
            (0.02, 0.0, 0.710, 0.340, 0.090, 0.050),
            (-0.36, 0.0, 0.700, 0.355, 0.095, 0.050),
            (-0.68, 0.0, 0.665, 0.280, 0.060, 0.040),
        ],
        carbon,
        24,
    )
    # A lofted dorsal stripe follows the nose crown instead of floating above
    # its taper. This remains visible at race distance without becoming a rail.
    loft(
        "Accent_NoseStripe",
        [
            (2.26, 0.0, 0.465, 0.030, 0.012, 0.008),
            (1.88, 0.0, 0.535, 0.036, 0.013, 0.009),
            (1.43, 0.0, 0.605, 0.042, 0.014, 0.010),
            (0.98, 0.0, 0.690, 0.046, 0.014, 0.010),
            (0.58, 0.0, 0.755, 0.050, 0.014, 0.010),
        ],
        accent,
        12,
    )
    wedge("Paint_EngineFin", (-1.02, 0.0, 0.84), 1.18, 0.030, 0.02, 0.28, paint)

    # Modern multi-element front wing with slim pylons and rolled endplates.
    rounded_box("Carbon_FrontWingMain", (2.48, 0.0, 0.175), (0.48, 2.02, 0.060), carbon, 0.028)
    rounded_box(
        "Paint_FrontWingFlap",
        (2.34, 0.0, 0.245),
        (0.36, 1.90, 0.045),
        paint,
        0.020,
        (0.0, math.radians(-8.0), 0.0),
    )
    rounded_box(
        "Accent_FrontWingFlap",
        (2.22, 0.0, 0.300),
        (0.28, 1.68, 0.036),
        accent,
        0.016,
        (0.0, math.radians(-11.0), 0.0),
    )
    for side in (-1.0, 1.0):
        rounded_box(
            "Carbon_FrontEndplate",
            (2.43, side * 1.015, 0.285),
            (0.48, 0.040, 0.310),
            carbon,
            0.025,
            (math.radians(4.0) * side, 0.0, 0.0),
        )
        cylinder_between(
            "Carbon_NosePylon",
            (1.82, side * 0.115, 0.39),
            (2.25, side * 0.18, 0.235),
            0.025,
            carbon,
        )

    # Rear wing, beam wing, diffuser and load-bearing pylons.
    rounded_box(
        "Carbon_RearWingMain",
        (-1.88, 0.0, 1.020),
        (0.31, 1.62, 0.060),
        carbon,
        0.026,
        (0.0, math.radians(7.0), 0.0),
    )
    rounded_box(
        "Paint_RearWingFlap",
        (-1.80, 0.0, 1.105),
        (0.24, 1.48, 0.040),
        accent,
        0.018,
        (0.0, math.radians(11.0), 0.0),
    )
    rounded_box("Carbon_BeamWing", (-1.66, 0.0, 0.765), (0.26, 1.20, 0.055), carbon, 0.022)
    for side in (-1.0, 1.0):
        rounded_box(
            "Carbon_RearEndplate",
            (-1.86, side * 0.82, 0.93),
            (0.36, 0.042, 0.55),
            carbon,
            0.028,
        )
        cylinder_between(
            "Carbon_RearPylon",
            (-1.52, side * 0.22, 0.48),
            (-1.80, side * 0.29, 1.00),
            0.030,
            carbon,
        )
    for side in (-0.48, -0.24, 0.0, 0.24, 0.48):
        wedge("Carbon_Diffuser", (-1.63, side, 0.22), 0.70, 0.028, 0.02, 0.24, carbon)

    # Mirrors and aero stalks add scale cues missing from the placeholder car.
    for side in (-1.0, 1.0):
        cylinder_between(
            "Metal_MirrorStalk",
            (0.16, side * 0.34, 0.70),
            (0.30, side * 0.61, 0.77),
            0.014,
            metal,
            12,
        )
        rounded_box(
            "Paint_MirrorHousing",
            (0.32, side * 0.66, 0.78),
            (0.16, 0.22, 0.095),
            paint,
            0.038,
            (math.radians(4.0) * side, 0.0, math.radians(4.0)),
        )

    # Collapse to four renderer-friendly meshes while retaining material lanes.
    join_prefix("Paint_", "Paint_PremiumFormulaBody")
    join_prefix("Accent_", "Accent_PremiumLivery")
    join_prefix("Carbon_", "Carbon_PremiumAero")
    join_prefix("Metal_", "Metal_PremiumDetails")

    for obj in bpy.context.scene.objects:
        if obj.type == "MESH":
            obj.data.set_sharp_from_angle(angle=math.radians(48.0))


def export_glb(destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=str(destination),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials="EXPORT",
        export_cameras=False,
        export_lights=False,
        export_animations=False,
        export_texcoords=True,
        export_normals=True,
        export_tangents=False,
    )
    print(f"EXPORTED_PREMIUM_FORMULA={destination}")


reset_scene()
build_car()
export_glb(output_path())
