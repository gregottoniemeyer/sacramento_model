# Sacramento Model Chevron Frames

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
