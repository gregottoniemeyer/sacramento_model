# Sacramento Model

An interactive art installation (Niemeyer Lab, UC Berkeley): 7 chairs, each
wired with an occupancy sensor (see `chair-occupancy-sensor/`), map to 7
historical "regimes" of the Sacramento River — Yurok Kinship, Hydraulic
Mining, Reclamation & Levees, Dams and Pumps, Environmental Reg, Climate
Stress, AI Extraction (see `REGIMES` in `controller.py`). Sitting in a chair
selects its regime as dominant; how many chairs are occupied drives a
speed/intensity value. `controller.py` is the central hub: it reads chair
occupancy (keyboard 1-7 as a placeholder today, real ESP32 sensor data via
the hub described in `chair-occupancy-sensor/` eventually) and broadcasts a
UDP JSON packet (`chairs`, `speed`, `ring_alpha`, `regime`/`regime_name`) that
drives the audiovisual display — a model of the Sacramento river. This
top-level directory holds that display's rendering pieces (chevron flow
animation, rings, water-flow visuals in `water_pipeline/`); the sensor
hardware/firmware/occupancy-detection subsystem lives entirely under
`chair-occupancy-sensor/` (see that directory's own `START_HERE.md` /
`NOTES.md` for the sensor side).

## Chevron Frames

Python renderer for looping chevron flow-rate animation frames.

## Requirements

- Python 3
- Pillow

Install Pillow if needed:

```bash
python3 -m pip install Pillow
```

## Usage

Render landscape frames:

```bash
python3 flow_chevrons.py --count 4 --speed 180 --orientation h --outdir img_h
```

Render portrait frames:

```bash
python3 flow_chevrons.py --count 4 --speed 180 --orientation v --outdir img_v
```

Defaults:

- `--orientation h`: `1920x1080`
- `--orientation v`: `1080x1920`
- `--color #ffffff`
- `--altcolor #000000`
- 30 fps loop timing
- at least 30 frames
- rendered motion calibrated to half the nominal `--speed`

The output files are named:

```text
{count}_{speed}_{orientation}_{frame:04d}.jpg
```

## Ring Frames

Render 256 transparent PNG frames of emanating black/white rings:

```bash
python3 render_rings.py
```

Defaults:

- `1024x1024`
- `--ring 128`
- `--frames 256`
- `--color #ffffff`
- `--altcolor #000000`
- `--outdir img/rings`
- transparent outside the inscribed circle, so rings stop at the image edge and vanish inward

The output files are named:

```text
ring_0001.png
```
