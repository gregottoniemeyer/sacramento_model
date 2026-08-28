#!/usr/bin/env python3
"""Generate the chair-sensor enclosure STLs and a rendered assembly preview.

Run with Blender 4.x:
  blender --background --python generate_case_blender.py

The dimensions at the top are deliberately easy to edit after a test fit.
"""

from __future__ import annotations

import math
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector


OUT = Path(__file__).resolve().parent

# --- Print and enclosure parameters (millimetres) --------------------------
WALL = 2.4
FLOOR = 2.4
BASE_H = 34.0
LID_T = 2.4
LIP_H = 3.2
LIP_T = 1.6
FIT = 0.35
CORNER_R = 4.5

BODY_W = 64.0
BODY_L = 98.4

# LILYGO T-Energy S3: official DXF envelope is about 29.0 x 91.2 mm.
BOARD_W = 29.1
BOARD_L = 91.2
BOARD_X = 3.5
BOARD_Y = 3.6
BOARD_Z = 24.0  # PCB underside; allows the 18650 holder below.
BOARD_HOLE_X = (2.1, 26.95)
BOARD_HOLE_Y = (2.0, 89.05)

# USB-C position measured from the official DXF/product orthographic image.
USB_Y = BOARD_Y + 12.5
USB_Z = BOARD_Z + 1.8
USB_OPEN_Y = 14.0
USB_OPEN_Z = 9.0
USB_FRAME_Y = 18.5
USB_FRAME_Z = 13.0
USB_FRAME_DEPTH = 3.2

# Adafruit MPU-6050: exact outline 25.4 x 17.78 mm, four 2.5 mm holes.
# Rotated so its 25.4 mm axis follows enclosure Y.
GYRO_W = 17.78
GYRO_L = 25.4
GYRO_X = 40.0
GYRO_Y = 30.0
GYRO_Z = 7.2
GYRO_HOLE_X = (2.54, 15.24)
GYRO_HOLE_Y = (2.54, 22.86)

BOARD_POST_R = 3.0
GYRO_POST_R = 2.8
M2_PILOT_R = 0.95

# Four lid screws live in the side bay, clear of both electronics boards.
CLOSURE_POINTS = ((37.3, 7.0), (59.0, 7.0), (37.3, 91.4), (59.0, 91.4))
CLOSURE_POST_R = 3.8
M3_PILOT_R = 1.35
M3_CLEAR_R = 1.75

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.curves, bpy.data.materials, bpy.data.cameras, bpy.data.lights):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def rounded_prism(name, width, length, height, z0, radius, center=(BODY_W / 2, BODY_L / 2), segments=8):
    radius = max(0.0, min(radius, width / 2, length / 2))
    cx, cy = center
    loop = []
    corners = (
        (cx + width / 2 - radius, cy + length / 2 - radius, 0),
        (cx - width / 2 + radius, cy + length / 2 - radius, 90),
        (cx - width / 2 + radius, cy - length / 2 + radius, 180),
        (cx + width / 2 - radius, cy - length / 2 + radius, 270),
    )
    for corner_x, corner_y, start in corners:
        for index in range(segments + 1):
            angle = math.radians(start + index * 90 / segments)
            loop.append((corner_x + radius * math.cos(angle), corner_y + radius * math.sin(angle)))

    vertices = [(x, y, z0) for x, y in loop] + [(x, y, z0 + height) for x, y in loop]
    count = len(loop)
    faces = [tuple(reversed(range(count))), tuple(range(count, count * 2))]
    for index in range(count):
        nxt = (index + 1) % count
        faces.append((index, nxt, count + nxt, count + index))
    mesh = bpy.data.meshes.new(f"{name}_mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def cube(name, size, location):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return obj


def cylinder(name, radius, depth, location, vertices=48):
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius, depth=depth, location=location)
    obj = bpy.context.object
    obj.name = name
    return obj


def active(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def boolean(target, tool, operation):
    active(target)
    modifier = target.modifiers.new(name=f"{operation}_{tool.name}", type="BOOLEAN")
    modifier.operation = operation
    modifier.solver = "EXACT"
    modifier.object = tool
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    bpy.data.objects.remove(tool, do_unlink=True)
    return target


def union(target, tool):
    return boolean(target, tool, "UNION")


def difference(target, tool):
    return boolean(target, tool, "DIFFERENCE")


def add_post(body, x, y, top_z, radius, pilot_radius, pilot_depth):
    post = cylinder("post", radius, top_z - FLOOR, (x, y, (top_z + FLOOR) / 2))
    union(body, post)
    hole = cylinder("pilot", pilot_radius, pilot_depth + 1.0, (x, y, top_z - pilot_depth / 2 + 0.5))
    difference(body, hole)


def make_base(name="chair_sensor_base"):
    base = rounded_prism(name, BODY_W, BODY_L, BASE_H, 0, CORNER_R)
    cavity = rounded_prism(
        "main_cavity",
        BODY_W - 2 * WALL,
        BODY_L - 2 * WALL,
        BASE_H - FLOOR + 2,
        FLOOR,
        max(1.2, CORNER_R - WALL),
    )
    difference(base, cavity)

    # A recessed frame lets the plastic case, rather than the PCB connector,
    # take sideways loads from a plugged-in USB cable.
    frame = cube(
        "usb_guard",
        (USB_FRAME_DEPTH, USB_FRAME_Y, USB_FRAME_Z),
        (-USB_FRAME_DEPTH / 2 + 0.3, USB_Y, USB_Z),
    )
    union(base, frame)
    usb_cut = cube(
        "usb_opening",
        (WALL + USB_FRAME_DEPTH + 4, USB_OPEN_Y, USB_OPEN_Z),
        ((WALL - USB_FRAME_DEPTH) / 2 - 0.5, USB_Y, USB_Z),
    )
    difference(base, usb_cut)

    # Four tall supports reach around the integrated battery holder.
    for dx in BOARD_HOLE_X:
        for dy in BOARD_HOLE_Y:
            add_post(base, BOARD_X + dx, BOARD_Y + dy, BOARD_Z, BOARD_POST_R, M2_PILOT_R, 7.0)

    # Side-bay gyro supports.
    for dx in GYRO_HOLE_X:
        for dy in GYRO_HOLE_Y:
            add_post(base, GYRO_X + dx, GYRO_Y + dy, GYRO_Z, GYRO_POST_R, M2_PILOT_R, 4.0)

    # Low divider leaves a generous cable pass-through around y=24..36 mm.
    for start_y, end_y in ((WALL, 24.0), (36.0, BODY_L - WALL)):
        rib = cube("divider", (1.8, end_y - start_y, 10.0), (36.0, (start_y + end_y) / 2, FLOOR + 5.0))
        union(base, rib)

    for x, y in CLOSURE_POINTS:
        add_post(base, x, y, BASE_H - 0.4, CLOSURE_POST_R, M3_PILOT_R, 9.0)

    return base


def make_lid(name="chair_sensor_lid", installed=False, explode=0.0):
    if installed:
        plate_z = BASE_H + explode
        lip_z = BASE_H - LIP_H + explode
    else:
        plate_z = 0.0
        lip_z = LID_T

    lid = rounded_prism(name, BODY_W, BODY_L, LID_T, plate_z, CORNER_R)
    cavity_w = BODY_W - 2 * WALL
    cavity_l = BODY_L - 2 * WALL
    lip_outer = rounded_prism(
        "lid_lip_outer",
        cavity_w - 2 * FIT,
        cavity_l - 2 * FIT,
        LIP_H,
        lip_z,
        max(1.0, CORNER_R - WALL - FIT),
    )
    lip_inner = rounded_prism(
        "lid_lip_inner",
        cavity_w - 2 * FIT - 2 * LIP_T,
        cavity_l - 2 * FIT - 2 * LIP_T,
        LIP_H + 1,
        lip_z - 0.5,
        max(0.5, CORNER_R - WALL - FIT - LIP_T),
    )
    difference(lip_outer, lip_inner)
    union(lid, lip_outer)

    hole_z = plate_z + LID_T / 2
    for x, y in CLOSURE_POINTS:
        hole = cylinder("lid_screw_clearance", M3_CLEAR_R, LID_T + 2, (x, y, hole_z))
        difference(lid, hole)
    return lid


def make_usb_gauge():
    gauge = rounded_prism("usb_c_fit_gauge", USB_FRAME_Y, USB_FRAME_Z, 3.0, 0, 2.0, center=(0, 0))
    opening = cube("gauge_opening", (USB_OPEN_Y, USB_OPEN_Z, 5.0), (0, 0, 1.5))
    difference(gauge, opening)
    return gauge


def export_stl(obj, filename):
    obj.data.validate(verbose=True)
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    non_manifold = sum(1 for edge in mesh.edges if not edge.is_manifold)
    volume = abs(mesh.calc_volume(signed=True))
    triangles = sum(max(1, len(face.verts) - 2) for face in mesh.faces)
    mesh.free()
    if non_manifold:
        raise RuntimeError(f"{filename}: {non_manifold} non-manifold edges")
    if volume <= 0:
        raise RuntimeError(f"{filename}: mesh has no enclosed volume")
    print(
        f"Validated {filename}: {triangles} triangles, "
        f"{volume:.1f} mm^3, size "
        f"{obj.dimensions.x:.1f} x {obj.dimensions.y:.1f} x {obj.dimensions.z:.1f} mm"
    )
    active(obj)
    bpy.ops.wm.stl_export(filepath=str(OUT / filename), export_selected_objects=True, ascii_format=False)


def material(name, rgba, metallic=0.0, roughness=0.45):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = rgba
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if rgba[3] < 1:
        bsdf.inputs["Alpha"].default_value = rgba[3]
        mat.surface_render_method = "DITHERED"
    return mat


def assign(obj, mat):
    obj.data.materials.append(mat)


def add_curve(name, points, radius, mat):
    curve = bpy.data.curves.new(name, type="CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 4
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for point, coordinate in zip(spline.bezier_points, points):
        point.co = coordinate
        point.handle_left_type = "AUTO"
        point.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    assign(obj, mat)
    return obj


def look_at(camera, target):
    camera.rotation_euler = (Vector(target) - camera.location).to_track_quat("-Z", "Y").to_euler()


def build_preview(base):
    # Render a cutaway copy; keep the exported base untouched and hidden.
    base.hide_render = True
    preview_base = make_base("cutaway_preview_base")
    cutaway = cube(
        "preview_cutaway",
        (BODY_W - WALL + 8, 42.0, BASE_H - 8.0),
        ((BODY_W + WALL) / 2 + 2, 14.0, BASE_H / 2 + 4),
    )
    difference(preview_base, cutaway)

    case_mat = material("PETG case", (0.12, 0.48, 0.78, 1.0), roughness=0.34)
    lid_mat = material("PETG lid", (0.30, 0.67, 0.91, 0.82), roughness=0.34)
    pcb_mat = material("PCB", (0.025, 0.38, 0.15, 1.0), roughness=0.30)
    gyro_mat = material("gyro PCB", (0.68, 0.23, 0.08, 1.0), roughness=0.30)
    battery_mat = material("18650", (0.08, 0.12, 0.18, 1.0), metallic=0.25)
    metal_mat = material("USB metal", (0.55, 0.59, 0.64, 1.0), metallic=0.8, roughness=0.23)
    cable_mat = material("STEMMA cable", (0.95, 0.48, 0.08, 1.0), roughness=0.35)
    assign(preview_base, case_mat)

    lid = make_lid("exploded_lid", installed=True, explode=16.0)
    assign(lid, lid_mat)

    board = rounded_prism(
        "T-Energy S3 proxy", BOARD_W, BOARD_L, 1.6, BOARD_Z, 2.0,
        center=(BOARD_X + BOARD_W / 2, BOARD_Y + BOARD_L / 2),
    )
    assign(board, pcb_mat)
    usb = cube("USB-C connector", (3.0, 9.0, 3.4), (BOARD_X - 0.7, USB_Y, BOARD_Z + 1.7))
    assign(usb, metal_mat)

    bpy.ops.mesh.primitive_cylinder_add(
        vertices=64,
        radius=9.2,
        depth=65.0,
        location=(BOARD_X + BOARD_W / 2, BOARD_Y + 49.0, BOARD_Z - 10.8),
        rotation=(math.pi / 2, 0, 0),
    )
    battery = bpy.context.object
    battery.name = "18650 proxy"
    assign(battery, battery_mat)

    gyro = rounded_prism(
        "MPU-6050 proxy", GYRO_W, GYRO_L, 1.6, GYRO_Z, 2.0,
        center=(GYRO_X + GYRO_W / 2, GYRO_Y + GYRO_L / 2),
    )
    assign(gyro, gyro_mat)
    add_curve(
        "STEMMA QT cable",
        (
            (BOARD_X + BOARD_W - 1, BOARD_Y + 18, BOARD_Z + 2.2),
            (35.0, 29.0, 17.0),
            (38.0, 32.0, 10.5),
            (GYRO_X + GYRO_W / 2, GYRO_Y + 1.0, GYRO_Z + 2.0),
        ),
        0.75,
        cable_mat,
    )

    ground_mat = material("ground", (0.91, 0.92, 0.94, 1.0), roughness=0.8)
    ground = cube("ground", (170, 170, 1.0), (BODY_W / 2, BODY_L / 2, -1.0))
    assign(ground, ground_mat)

    bpy.ops.object.camera_add(location=(-115, -135, 118))
    camera = bpy.context.object
    camera.data.lens = 56
    look_at(camera, (BODY_W / 2, BODY_L / 2, 21))
    bpy.context.scene.camera = camera

    for location, energy, size in (((-70, -40, 145), 1050, 70), ((120, 120, 115), 850, 55)):
        bpy.ops.object.light_add(type="AREA", location=location)
        light = bpy.context.object
        light.data.energy = energy
        light.data.shape = "DISK"
        light.data.size = size
        look_at(light, (BODY_W / 2, BODY_L / 2, 18))

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.resolution_x = 1100
    scene.render.resolution_y = 780
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(OUT / "chair_sensor_case_preview.png")
    scene.render.film_transparent = False
    scene.world.color = (0.92, 0.94, 0.97)
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (0.92, 0.95, 1.0, 1.0)
    background.inputs["Strength"].default_value = 0.75
    scene.view_settings.look = "AgX - Medium High Contrast"
    bpy.ops.render.render(write_still=True)

    # A second, lid-off top view makes both electronics bays and cable routing
    # unambiguous even before the physical parts arrive.
    lid.hide_render = True
    camera.data.type = "ORTHO"
    camera.data.ortho_scale = 120
    camera.location = (BODY_W / 2, BODY_L / 2, 175)
    look_at(camera, (BODY_W / 2, BODY_L / 2, 0))
    scene.render.filepath = str(OUT / "chair_sensor_case_layout.png")
    scene.render.resolution_x = 800
    scene.render.resolution_y = 1000
    bpy.ops.render.render(write_still=True)
    lid.hide_render = False


def main():
    clear_scene()
    base = make_base()
    export_stl(base, "chair_sensor_case_base.stl")

    lid = make_lid()
    export_stl(lid, "chair_sensor_case_lid.stl")
    bpy.data.objects.remove(lid, do_unlink=True)

    gauge = make_usb_gauge()
    export_stl(gauge, "usb_c_fit_gauge.stl")
    bpy.data.objects.remove(gauge, do_unlink=True)

    build_preview(base)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "chair_sensor_case_preview.blend"))
    backup = OUT / "chair_sensor_case_preview.blend1"
    if backup.exists():
        backup.unlink()
    print(f"Generated enclosure files in {OUT}")


if __name__ == "__main__":
    main()
