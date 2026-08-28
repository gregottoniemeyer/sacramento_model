# Chair sensor enclosure

This is a two-piece, 3D-printable enclosure for one chair sensor:

- LILYGO T-Energy S3 with its integrated 18650 holder
- one protected 18650 cell
- Adafruit MPU-6050 breakout (PID 3886)
- one 100 mm STEMMA QT / Qwiic cable

The VEML7700 lux sensor is for the separate light project and is intentionally
not included in this enclosure.

## Design

The LILYGO board and battery occupy the long left bay. Four tall screw posts
support the PCB around the battery holder. The gyro has its own low right bay,
so it is rigidly coupled to the case rather than hanging from its cable. A low
divider protects the cable while leaving a 12 mm routing gap.

The USB-C opening is 14 x 9 mm. A 3.2 mm-deep external collar surrounds it so
side loads from a moulded USB plug bear on the printed case before they reach
the PCB connector. The exterior underside is completely flat for adhesive
hook-and-loop (Velcro) mounting.

- Main body: 64 x 98.4 x 36.4 mm including the lid
- Overall width at the USB-C reinforcement: about 66.9 mm
- Wall and floor: 2.4 mm
- Lid: four M3 screws plus a locating lip
- Nominal printed fit allowance: 0.35 mm per side

## Files

- `chair_sensor_case_base.stl` — print floor-down
- `chair_sensor_case_lid.stl` — print smooth exterior face-down
- `usb_c_fit_gauge.stl` — tiny, fast test for the moulded cable-plug opening
- `chair_sensor_case.scad` — editable OpenSCAD source
- `generate_case_blender.py` — canonical generator used for the supplied STLs
- `chair_sensor_case_preview.blend` — editable rendered assembly
- `chair_sensor_case_preview.png` — exploded cutaway view
- `chair_sensor_case_layout.png` — lid-off electronics layout
- `analyze_dxf.py` — dependency-free check of the manufacturer DXF bounds

## Print settings

PETG is recommended because it is tougher and more temperature tolerant than
PLA. Suggested starting settings:

- 0.20 mm layer height
- 0.4 mm nozzle
- four walls/perimeters
- five bottom and top layers
- 25% gyroid or cubic infill
- no supports; enable bridging for the USB opening

Print the USB gauge first. The plug body should slide through without force but
should not have more than roughly 0.5 mm of movement on each side. Change
`USB_OPEN_Y` / `USB_OPEN_Z` in the Blender generator or `usb_open_y` /
`usb_open_z` in the OpenSCAD file if needed.

## Hardware

- 8 x M2 x 6–8 mm pan-head screws for the two PCBs
- 4 x M3 x 10 mm pan-head screws for the lid

The M2 and M3 holes are sized as pilot holes for screws threading directly into
PETG. Do not use screws longer than specified near the battery. Do not
overtighten them.

## Assembly

1. Print and test the USB gauge with the actual cable.
2. Place the MPU-6050 in the side bay and secure it with four M2 screws.
3. Connect the STEMMA QT cable and route it through the divider gap.
4. Insert the protected 18650 cell into the LILYGO holder, observing polarity.
5. Lower the LILYGO assembly battery-side down and secure its four corners with
   M2 screws. Confirm the holder and cell are not being compressed by the base.
6. Verify the USB-C plug enters freely and does not lever the PCB connector.
7. Fit the lid lip into the base and install the four M3 screws.
8. Clean the flat base with isopropyl alcohol and apply industrial adhesive
   hook-and-loop after the print has fully cooled.

## Required test fit before printing ten

The manufacturer geometry is good enough for a first prototype, but product
and printer tolerances still matter. When the parts arrive, check these three
measurements against the model:

1. LILYGO PCB envelope: nominally 29.1 x 91.2 mm.
2. USB-C centre: nominally 12.5 mm from the PCB's lower end, with the connector
   centred about 1.8 mm above the PCB underside.
3. Total depth below the PCB from the populated 18650 holder and chosen cell:
   the model allows 21.6 mm between the floor and PCB underside.

Print one complete base and lid before producing the remaining nine. If the
battery holder just touches the floor, a thin (no more than 1 mm) closed-cell
foam pad can suppress rattling; it must not bow the PCB or squeeze the cell.

## Source dimensions

- LILYGO's official T-Energy S3 repository and mechanical DXF:
  <https://github.com/Xinyuan-LilyGO/T-Energy-S3>
- Adafruit's official MPU-6050 PCB source (25.4 x 17.78 mm outline, four
  2.5 mm mounting holes):
  <https://github.com/adafruit/Adafruit-MPU6050-PCB>

## Battery safety

Use a protected, undamaged 18650 from a reputable supplier. Keep plastic and
screw tips clear of the cell wrapper and contacts. Never charge an unattended
or damaged cell, and discontinue use if the enclosure becomes hot, deformed,
or mechanically damaged.

## Regenerating the artifacts

With Blender installed on macOS:

```sh
/Applications/Blender.app/Contents/MacOS/Blender \
  --background \
  --python generate_case_blender.py
```

The generator overwrites the three STL files, both PNG previews, and the `.blend`
preview in this directory.
