"""Build the APEX VELOCITY circuit venue kit with Blender's Python API (headless).

Run:
  ~/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/build_venue_kit.py

Outputs GLB files into assets/venues/ plus venue_manifest.json.

Authoring convention: metres, Blender Z-up, asset front = +Y (Godot -Z),
origin at ground centre. Materials are named Venue<Role> for runtime re-tint.
"""
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_common as C  # noqa: E402

OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "assets", "venues"))
os.makedirs(OUT_DIR, exist_ok=True)

MANIFEST = {}


def metres(v):
    return float(v)


# ---------------------------------------------------------------------------
# 1. start gantry (spans the track, 24 m)
# ---------------------------------------------------------------------------

def build_gantry():
    prefix = "gantry_"
    concrete = C.mat_concrete()
    metal = C.mat_metal()
    dark = C.mat_dark()
    accent = C.mat_accent()

    for sx in (-1.0, 1.0):
        C.truss_column(prefix + "column", sx * 11.5, 0.0, 8.4, metal, width=0.7, spacing=1.0)
        C.box(prefix + "foot", (1.4, 1.4, 0.35), (sx * 11.5, 0.0, 0.17), concrete)
    C.truss_beam(prefix + "beam", 23.0, (0.0, 0.0, 8.4), metal, width=0.85, spacing=1.1)
    # banner
    C.box(prefix + "banner", (21.0, 0.28, 1.5), (0.0, 0.0, 7.2), dark)
    C.box(prefix + "banner_trim", (21.0, 0.12, 0.16), (0.0, 0.2, 6.5), accent)
    C.box(prefix + "banner_trim2", (21.0, 0.12, 0.16), (0.0, 0.2, 7.9), accent)
    C.text_mesh(prefix + "banner_text", "APEX VELOCITY", size=1.05,
                loc=(0.0, 0.18, 7.2), mat=C.material("VenueText", (0.95, 0.96, 1.0)),
                rot=(math.pi * 0.5, 0.0, math.pi), extrude=0.02)

    # start light pods (emissive) under the banner
    emissive = C.mat_emissive((1.0, 0.18, 0.1), 8.0)
    for i in range(5):
        x = (i - 2) * 1.1
        C.box(prefix + "light_housing", (0.62, 0.4, 0.62), (x, -0.28, 6.2), dark)
        C.box(prefix + "light_lamp", (0.46, 0.06, 0.46), (x, -0.5, 6.2), emissive)

    # sponsor boards on the columns
    for sx in (-1.0, 1.0):
        C.box(prefix + "sponsor", (1.6, 0.12, 2.2), (sx * 11.5, -0.85, 4.2), accent)
        C.box(prefix + "sponsor2", (1.6, 0.12, 2.2), (sx * 11.5, -0.85, 1.6), dark)

    C.export_objects(prefix, OUT_DIR, "gantry")
    C.delete_objects(prefix)
    MANIFEST["gantry"] = {"file": "gantry.glb", "span_m": 24.0, "height_m": 8.4,
                          "anchor": "start_line", "front": "+Y"}


# ---------------------------------------------------------------------------
# 2. main grandstand (60 m long, 8 rows)
# ---------------------------------------------------------------------------

def build_grandstand():
    prefix = "grand_"
    concrete = C.mat_concrete()
    metal = C.mat_metal()
    dark = C.mat_dark()
    seat = C.mat_seat()
    accent = C.mat_accent()

    C.box(prefix + "slab", (60.0, 17.0, 0.5), (0.0, 0.0, 0.25), concrete)
    # 8 stepped rows rising towards the back (-Y)
    for i in range(8):
        y = 8.0 - 1.5 * i
        z = 0.55 + 0.62 * i
        C.box(prefix + "step", (60.0, 1.5, 0.62), (0.0, y, z), concrete)
        # seats
        if i < 7:
            seat_count = 52
            for s in range(seat_count):
                x = -29.0 + s * 1.14
                C.box(prefix + "seat", (0.5, 0.42, 0.5),
                      (x, y + 0.1, z + 0.55), seat)
        # front edge accent stripe
        C.box(prefix + "stripe", (60.0, 0.08, 0.1), (0.0, y + 0.75, z + 0.36), accent)

    C.box(prefix + "backwall", (60.0, 0.55, 12.0), (0.0, -8.2, 6.0), concrete)
    C.box(prefix + "backwall_trim", (60.0, 0.1, 0.5), (0.0, -7.9, 10.5), accent)
    for sx in (-1.0, 1.0):
        C.box(prefix + "sidewall", (0.5, 17.0, 12.0), (sx * 30.0, 0.0, 6.0), concrete)

    # roof
    C.box(prefix + "roof", (61.0, 15.0, 0.4), (0.0, -0.5, 13.0), metal)
    C.box(prefix + "roof_trim", (61.0, 0.3, 0.5), (0.0, 6.7, 12.9), accent)
    for i in range(5):
        x = -24.0 + i * 12.0
        C.box(prefix + "roof_beam", (0.35, 15.0, 0.5), (x, -0.5, 12.6), dark)
        for sy in (5.6, -6.4):
            C.box(prefix + "column", (0.55, 0.55, 12.5), (x, sy, 6.25), metal)
            C.box(prefix + "col_foot", (1.0, 1.0, 0.4), (x, sy, 0.2), concrete)

    # railing along the front
    for z in (1.2, 1.85):
        C.box(prefix + "rail", (60.0, 0.07, 0.07), (0.0, 8.9, z), metal)
    for i in range(31):
        x = -30.0 + i * 2.0
        C.box(prefix + "railpost", (0.06, 0.06, 1.9), (x, 8.9, 0.95), metal)
    # front barrier wall
    C.box(prefix + "frontwall", (60.0, 0.35, 1.0), (0.0, 9.2, 0.5), concrete)

    # stairs at both ends
    for sx in (-1.0, 1.0):
        for i in range(8):
            C.box(prefix + "stair", (1.6, 1.2, 0.62),
                  (sx * 30.9, 7.2 - i * 1.5, 0.31 + i * 0.62), concrete)

    # back wall windows / VIP boxes
    for i in range(8):
        x = -26.0 + i * 7.4
        C.box(prefix + "vip_glass", (5.6, 0.12, 2.2), (x, -7.9, 9.3), C.mat_glass())
        C.box(prefix + "vip_frame", (5.9, 0.15, 0.18), (x, -7.85, 10.45), dark)

    C.export_objects(prefix, OUT_DIR, "grandstand")
    C.delete_objects(prefix)
    MANIFEST["grandstand"] = {"file": "grandstand.glb", "length_m": 61.0, "depth_m": 17.0,
                              "height_m": 13.4, "anchor": "main_straight", "front": "+Y"}


# ---------------------------------------------------------------------------
# 3. pit building (80 m long, 2 floors, 10 garages)
# ---------------------------------------------------------------------------

def build_pit_building():
    prefix = "pit_"
    concrete = C.mat_concrete()
    dark = C.mat_dark()
    glass = C.mat_glass()
    metal = C.mat_metal()
    accent = C.mat_accent()
    white = C.material("VenuePanel", (0.9, 0.9, 0.88))

    L = 84.0
    # shell
    C.box(prefix + "slab", (L, 15.0, 0.4), (0.0, 0.0, 0.2), concrete)
    C.box(prefix + "backwall", (L, 0.5, 11.0), (0.0, -7.2, 5.5), concrete)
    for sx in (-1.0, 1.0):
        C.box(prefix + "sidewall", (0.5, 15.0, 11.0), (sx * L * 0.5, 0.0, 5.5), concrete)
    # roof with overhang towards the pit lane
    C.box(prefix + "roof", (L + 1.2, 16.6, 0.5), (0.0, 0.8, 11.3), concrete)
    C.box(prefix + "roof_trim", (L + 1.4, 0.22, 0.3), (0.0, 9.0, 11.55), accent)
    C.box(prefix + "parapet_b", (L + 1.2, 0.3, 0.9), (0.0, -7.4, 11.95), concrete)
    # roof railing
    for sy in (8.6, -7.3):
        C.box(prefix + "roof_rail", (L, 0.06, 0.06), (0.0, sy, 12.45), metal)
        for i in range(43):
            x = -42.0 + i * 2.0
            C.box(prefix + "roof_rail_post", (0.05, 0.05, 1.0), (x, sy, 12.0), metal)
    # roof HVAC + ducting + antennas
    for i in range(6):
        x = -32.0 + i * 12.8
        C.box(prefix + "hvac", (3.2, 2.4, 1.3), (x, -2.4, 12.2), metal)
        C.box(prefix + "hvac_dark", (3.4, 0.2, 0.1), (x, -2.4, 12.9), dark)
    C.box(prefix + "duct", (52.0, 0.7, 0.7), (0.0, 2.8, 12.1), metal)
    for x in (-34.0, 8.0):
        C.box(prefix + "antenna", (0.1, 0.1, 5.0), (x, -5.0, 14.5), metal)

    # pit lane canopy: slab over the garages, supported by slim columns
    C.box(prefix + "canopy", (L, 6.2, 0.28), (0.0, 11.4, 6.4), white)
    C.box(prefix + "canopy_trim", (L, 0.18, 0.22), (0.0, 14.4, 6.35), accent)
    for i in range(11):
        x = -40.0 + i * 8.0
        C.box(prefix + "canopy_col", (0.35, 0.35, 6.3), (x, 14.2, 3.2), metal)
        C.box(prefix + "canopy_brace", (0.2, 5.6, 0.2), (x, 11.6, 6.1), metal)

    # ground floor garages: 10 doors with numbers + frames
    for i in range(10):
        x = -37.8 + i * 8.4
        C.box(prefix + "garage_inner", (7.0, 0.12, 3.6), (x, 7.15, 1.8),
              C.material("VenueGarage", (0.02, 0.02, 0.025)))
        C.box(prefix + "garage_door", (7.2, 0.2, 3.7), (x, 6.95, 1.85), dark)
        C.box(prefix + "garage_roll", (7.2, 0.28, 0.45), (x, 6.92, 3.6), metal)
        C.box(prefix + "garage_frame_top", (7.6, 0.35, 0.28), (x, 6.85, 3.9), accent)
        for sx in (-1.0, 1.0):
            C.box(prefix + "garage_frame", (0.35, 0.35, 3.9), (x + sx * 3.7, 6.9, 1.95), metal)
        C.box(prefix + "garage_lamp", (1.4, 0.1, 0.1), (x, 6.75, 3.75),
              C.mat_emissive((1.0, 0.95, 0.8), 3.5))
        C.text_mesh(prefix + "garage_num", "%02d" % (i + 1), size=0.55,
                    loc=(x, 6.65, 4.35), mat=C.material("VenueText", (0.95, 0.96, 1.0)),
                    rot=(math.pi * 0.5, 0.0, math.pi), extrude=0.01)

    # upper floor window band with mullions
    for i in range(26):
        x = -38.0 + i * 3.0
        C.box(prefix + "win_glass", (2.5, 0.14, 2.2), (x, 7.05, 9.10), glass)
        C.box(prefix + "win_frame_top", (2.9, 0.2, 0.2), (x, 7.0, 10.3), metal)
        C.box(prefix + "win_sill", (2.9, 0.26, 0.18), (x, 7.05, 7.9), metal)
        C.box(prefix + "win_mullion", (0.08, 0.16, 2.2), (x, 7.0, 9.1), metal)
    # balcony under the windows + railing
    C.box(prefix + "balcony", (L + 1.2, 1.9, 0.32), (0.0, 7.9, 7.35), concrete)
    for z in (7.9, 8.55):
        C.box(prefix + "bal_rail", (L + 1.2, 0.08, 0.08), (0.0, 8.85, z), metal)
    for i in range(43):
        x = -42.0 + i * 2.0
        C.box(prefix + "bal_post", (0.06, 0.06, 1.3), (x, 8.85, 8.0), metal)

    # team signage + sponsor bands
    C.box(prefix + "accent_band", (L + 1.2, 0.14, 0.45), (0.0, 7.25, 7.55), accent)
    C.box(prefix + "sign_board", (30.0, 0.3, 2.6), (0.0, 7.6, 12.8), dark)
    C.text_mesh(prefix + "sign_text", "APEX RACING", size=1.6,
                loc=(0.0, 7.82, 12.8), mat=C.material("VenueText", (0.95, 0.96, 1.0)),
                rot=(math.pi * 0.5, 0.0, math.pi), extrude=0.03)
    for i in range(6):
        x = -35.0 + i * 14.0
        C.box(prefix + "sponsor", (8.0, 0.12, 1.0), (x, 7.3, 10.7), white)
        C.box(prefix + "sponsor_stripe", (8.0, 0.06, 0.16), (x, 7.38, 10.7), accent)

    # side stairs
    for sx in (-1.0, 1.0):
        for i in range(10):
            C.box(prefix + "stair", (1.6, 1.4, 0.55),
                  (sx * (L * 0.5 + 1.2), 6.5 - i * 1.4, 0.27 + i * 0.55), concrete)

    C.export_objects(prefix, OUT_DIR, "pit_building")
    C.delete_objects(prefix)
    MANIFEST["pit_building"] = {"file": "pit_building.glb", "length_m": 84.0, "depth_m": 15.0,
                                "height_m": 13.5, "anchor": "main_straight_opposite", "front": "+Y"}


# ---------------------------------------------------------------------------
# 4. pit wall + timing screens
# ---------------------------------------------------------------------------

def build_pit_wall():
    prefix = "pitwall_"
    concrete = C.mat_concrete()
    dark = C.mat_dark()
    accent = C.mat_accent()
    L = 24.0
    C.box(prefix + "wall", (L, 0.45, 1.15), (0.0, 0.0, 0.575), concrete)
    C.box(prefix + "cap", (L, 0.6, 0.12), (0.0, 0.0, 1.2), dark)
    for i in range(6):
        x = -10.0 + i * 4.0
        C.box(prefix + "panel", (3.0, 0.06, 0.6), (x, 0.26, 0.62), accent)
    for i, x in enumerate((-6.0, 2.0)):
        C.box(prefix + "screen_frame", (2.2, 0.35, 1.1), (x, 0.3, 1.75), dark)
        C.box(prefix + "screen", (1.9, 0.08, 0.85), (x, 0.5, 1.75),
              C.mat_emissive((0.3, 0.8, 1.0), 2.0))
    C.export_objects(prefix, OUT_DIR, "pit_wall")
    C.delete_objects(prefix)
    MANIFEST["pit_wall"] = {"file": "pit_wall.glb", "length_m": 24.0, "height_m": 2.3,
                            "anchor": "main_straight_inner", "front": "+Y"}


# ---------------------------------------------------------------------------
# 5. floodlight tower
# ---------------------------------------------------------------------------

def build_light_tower():
    prefix = "light_"
    metal = C.mat_metal()
    concrete = C.mat_concrete()
    emissive = C.mat_emissive((1.0, 0.96, 0.85), 10.0)
    height = 26.0
    C.box(prefix + "base", (2.4, 2.4, 0.5), (0.0, 0.0, 0.25), concrete)
    C.truss_column(prefix + "mast", 0.0, 0.0, height, metal, width=1.3, spacing=1.6)
    C.box(prefix + "head_frame", (3.6, 0.5, 0.5), (0.0, 0.0, height + 0.3), metal)
    for row in range(3):
        for col in range(4):
            x = (col - 1.5) * 0.9
            z = height - 0.2 + row * 0.55
            C.box(prefix + "lamp_box", (0.85, 0.45, 0.5), (x, 0.35, z), metal)
            C.box(prefix + "lamp", (0.78, 0.06, 0.42), (x, 0.6, z), emissive)
    C.export_objects(prefix, OUT_DIR, "light_tower")
    C.delete_objects(prefix)
    MANIFEST["light_tower"] = {"file": "light_tower.glb", "height_m": 28.5,
                               "anchor": "track_side", "front": "+Y"}


# ---------------------------------------------------------------------------
# 6. advertising board
# ---------------------------------------------------------------------------

def build_ad_board():
    prefix = "ad_"
    metal = C.mat_metal_dark()
    dark = C.mat_dark()
    accent = C.mat_accent()
    C.box(prefix + "frame", (6.2, 0.28, 2.7), (0.0, 0.0, 3.1), metal)
    C.box(prefix + "panel", (6.0, 0.16, 2.5), (0.0, 0.18, 3.1), C.material("VenuePanel", (0.92, 0.92, 0.9)))
    for i, z in enumerate((2.1, 3.1, 4.1)):
        C.box(prefix + "stripe", (6.0, 0.06, 0.42), (0.0, 0.28, z), accent if i != 1 else dark)
    for sx in (-1.0, 1.0):
        C.box(prefix + "leg", (0.28, 0.28, 1.8), (sx * 2.6, 0.0, 0.9), metal)
        C.box(prefix + "foot", (0.7, 0.7, 0.16), (sx * 2.6, 0.0, 0.08), dark)
    C.export_objects(prefix, OUT_DIR, "ad_board")
    C.delete_objects(prefix)
    MANIFEST["ad_board"] = {"file": "ad_board.glb", "width_m": 6.2, "height_m": 4.5,
                            "anchor": "track_side", "front": "+Y"}


# ---------------------------------------------------------------------------
# 7. catch fence section (10 m)
# ---------------------------------------------------------------------------

def build_catch_fence():
    prefix = "fence_"
    metal = C.mat_metal_dark()
    concrete = C.mat_concrete()
    L = 10.0
    for sx in (-1.0, 1.0):
        C.box(prefix + "post", (0.16, 0.16, 4.2), (sx * L * 0.5, 0.0, 2.1), metal)
        C.box(prefix + "foot", (0.6, 0.6, 0.3), (sx * L * 0.5, 0.0, 0.15), concrete)
    for z in (1.0, 2.1, 3.2, 4.0):
        C.box(prefix + "rail", (L, 0.08, 0.08), (0.0, 0.0, z), metal)
    for i in range(21):
        x = -L * 0.5 + i * 0.5
        C.box(prefix + "bar", (0.05, 0.05, 3.9), (x, 0.0, 2.0), metal)
    C.export_objects(prefix, OUT_DIR, "catch_fence")
    C.delete_objects(prefix)
    MANIFEST["catch_fence"] = {"file": "catch_fence.glb", "width_m": 10.0, "height_m": 4.2,
                               "anchor": "track_side", "front": "+Y"}


# ---------------------------------------------------------------------------
# 8. marshal post
# ---------------------------------------------------------------------------

def build_marshal_post():
    prefix = "marshal_"
    concrete = C.mat_concrete()
    dark = C.mat_dark()
    glass = C.mat_glass()
    accent = C.mat_accent()
    C.box(prefix + "base", (3.2, 3.2, 0.3), (0.0, 0.0, 0.15), concrete)
    for sx in (-1.0, 1.0):
        C.box(prefix + "wall_side", (0.2, 3.0, 2.6), (sx * 1.5, 0.0, 1.45), concrete)
    C.box(prefix + "wall_back", (3.0, 0.2, 2.6), (0.0, -1.5, 1.45), concrete)
    C.box(prefix + "wall_front_low", (3.0, 0.2, 1.0), (0.0, 1.5, 0.65), concrete)
    C.box(prefix + "window", (2.6, 0.12, 1.4), (0.0, 1.55, 1.9), glass)
    C.box(prefix + "roof", (3.6, 3.6, 0.2), (0.0, 0.0, 2.85), dark)
    C.box(prefix + "roof_trim", (3.7, 0.2, 0.16), (0.0, 1.7, 2.7), accent)
    C.box(prefix + "desk", (2.2, 0.6, 0.8), (0.0, 0.9, 1.05), dark)
    C.box(prefix + "flag_pole", (0.08, 0.08, 3.0), (1.5, -1.2, 3.9), C.mat_metal())
    C.box(prefix + "flag", (1.1, 0.06, 0.7), (2.0, -1.2, 5.1), accent)
    C.export_objects(prefix, OUT_DIR, "marshal_post")
    C.delete_objects(prefix)
    MANIFEST["marshal_post"] = {"file": "marshal_post.glb", "size_m": [3.6, 3.6, 3.0],
                                "anchor": "track_side", "front": "+Y"}


# ---------------------------------------------------------------------------
# 9. big screen
# ---------------------------------------------------------------------------

def build_big_screen():
    prefix = "screen_"
    metal = C.mat_metal_dark()
    dark = C.mat_dark()
    accent = C.mat_accent()
    C.box(prefix + "foot", (4.0, 3.0, 0.6), (0.0, 0.0, 0.3), C.mat_concrete())
    for sx in (-1.0, 1.0):
        C.box(prefix + "leg", (0.4, 0.4, 8.6), (sx * 4.6, 0.0, 4.9), metal)
        C.box(prefix + "brace", (0.2, 2.6, 0.2), (sx * 4.6, 1.3, 3.4), metal)
    C.box(prefix + "frame", (10.6, 0.6, 5.4), (0.0, -0.1, 10.2), metal)
    C.box(prefix + "screen", (10.0, 0.14, 4.8), (0.0, 0.25, 10.2), dark)
    C.box(prefix + "screen_glow", (10.0, 0.06, 0.16), (0.0, 0.34, 12.55),
          C.mat_emissive((0.35, 0.85, 1.0), 2.5))
    C.box(prefix + "speaker", (1.2, 1.0, 0.8), (0.0, -0.4, 7.3), dark)
    C.export_objects(prefix, OUT_DIR, "big_screen")
    C.delete_objects(prefix)
    MANIFEST["big_screen"] = {"file": "big_screen.glb", "width_m": 10.6, "height_m": 12.9,
                              "anchor": "start_area", "front": "+Y"}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    C.reset_scene()
    build_gantry()
    build_grandstand()
    build_pit_building()
    build_pit_wall()
    build_light_tower()
    build_ad_board()
    build_catch_fence()
    build_marshal_post()
    build_big_screen()
    C.save_manifest(OUT_DIR, MANIFEST)
    print("[VENUE] built %d assets into %s" % (len(MANIFEST), OUT_DIR))


main()
