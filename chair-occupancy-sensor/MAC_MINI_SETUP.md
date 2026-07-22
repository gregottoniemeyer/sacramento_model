# Installation Host Setup (Mac Mini)

Exact steps to set up a fresh Mac (currently: the lab Mac Mini) to
permanently run this subsystem — receiver board plugged in, dashboard
running, and automatically staying in sync with GitHub with **zero manual
steps** after a push. Follow in order.

## 1. Install Homebrew

In Terminal:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 2. Install the Arduino IDE

```bash
brew install --cask arduino-ide
```
(Skip if it says an app already exists at `/Applications/Arduino IDE.app` —
that just means it's already installed.)

Open the Arduino IDE once, then add ESP32 board support:
- **Arduino IDE → Settings** (or Preferences) → **Additional boards manager URLs** → add:
  `https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json`
- **Tools → Board → Boards Manager** → search "esp32" → install the
  Espressif package.
- Every board in this project uses board profile **"ESP32 Dev Module."**

## 3. Install USB-serial drivers

The chair-node boards use one of two different USB chips — install **both**
drivers now so either kind works immediately when plugged in:

**CP2102 (Silicon Labs):**
```bash
brew install --cask silicon-labs-vcp-driver
```

**CH340 (WCH)** — do not use the Homebrew cask for this one, it's an
outdated build that stalls. Instead:
```bash
curl -L -o ~/Downloads/CH34xVCPDriver.pkg https://raw.githubusercontent.com/WCHSoftGroup/ch34xser_macos/main/CH34xVCPDriver.pkg
open ~/Downloads/CH34xVCPDriver.pkg
```
Run through the installer, **then also separately open
`/Applications/CH34xVCPDriver.app` and click its own "Install" button** —
the `.pkg` alone does not finish registering the driver.

**For both drivers**, macOS will likely show a **System Settings → General
→ Login Items & Extensions → Driver Extensions** approval prompt — go there
and toggle the new driver ON if it isn't already.

## 4. Clone the repo

The repo is public, so this needs no login/authentication at all:
```bash
cd ~
git clone https://github.com/gregottoniemeyer/sacramento_model.git
```

## 5. Set up the Python environment

```bash
cd ~/sacramento_model/chair-occupancy-sensor
python3 -m venv venv
venv/bin/pip install -r requirements.txt
```

## 6. Plug in the receiver board and find its port

```bash
ls /dev/cu.*
```
Look for a new entry that wasn't there before plugging in — `/dev/cu.wch...`
(CH340) or `/dev/cu.usbserial-...` / `/dev/cu.SLAB_USBtoUART` (CP2102). If
nothing new appears, a driver-approval prompt (see step 3) may be waiting
for you, or the driver needs a reboot to fully register.

## 7. Flash the receiver firmware

In Arduino IDE: open `firmware/receiver_esp_now.ino`, set **Tools → Board**
to "ESP32 Dev Module," set **Tools → Port** to the port found in step 6,
click **Upload**.

## 8. Set up automatic sync + auto-restart

This is the key step that makes everything hands-off: a background job
that pulls new code every 2 minutes, and restarts the live dashboard
automatically **only if something actually changed** (or if it isn't
running yet — e.g. right after a reboot).

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.sacramentomodel.autopull.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sacramentomodel.autopull</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>REPLACE_WITH_HOME/sacramento_model/chair-occupancy-sensor/tools/pull_and_refresh.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>120</integer>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>REPLACE_WITH_HOME/sacramento_model/autopull.log</string>
    <key>StandardErrorPath</key>
    <string>REPLACE_WITH_HOME/sacramento_model/autopull.log</string>
</dict>
</plist>
EOF
```
**Do not skip `AbandonProcessGroup`.** Without it, launchd kills the entire
process group when `pull_and_refresh.sh` finishes running — including the
dashboard process it just launched in the background — even though the
script uses `nohup`/`disown`. The dashboard will appear to start (the log
says so) but the process is already dead a moment later. This key tells
launchd to leave background children alone once the wrapper script exits.

**Before running the next command**, replace every `REPLACE_WITH_HOME` in
that file with the actual home directory path (e.g. `/Users/yourusername`
— run `echo $HOME` to get the exact value, then edit the plist file, e.g.
with `nano ~/Library/LaunchAgents/com.sacramentomodel.autopull.plist`).

Then load it:
```bash
launchctl load ~/Library/LaunchAgents/com.sacramentomodel.autopull.plist
```

Verify it's registered:
```bash
launchctl list | grep sacramentomodel
```
You should see `com.sacramentomodel.autopull` in the output.

Trigger it once immediately (don't wait 2 minutes) to confirm it works and
to get the dashboard running for the first time:
```bash
launchctl start com.sacramentomodel.autopull
sleep 3
cat ~/sacramento_model/autopull.log
```
A dashboard window should appear on screen, and the log should mention
restarting the dashboard.

## 9. Start the serial capture pipeline

This one does **not** currently auto-start on its own (only the
pull-and-restart job does) — it needs to be run once per session, and
again any time the receiver board is unplugged and replugged:
```bash
exec 3<>/dev/cu.YOUR_PORT_HERE
stty -f /dev/fd/3 921600 raw
cat <&3 > ~/motion_log.txt &
disown
```
**921600 must match `Serial.begin()` in `firmware/receiver_esp_now.ino`.**
Auto-pull updates this machine's *code*, but it cannot reflash the receiver
board — so if the receiver here was flashed with older firmware, reflash it
(step 7) rather than lowering this number.

## Done — what happens automatically from here on

- Anyone pushes a change to GitHub (normally from the development
  MacBook) → within 2 minutes, this machine pulls it automatically.
- If the change affects the dashboard, it restarts itself automatically,
  picking up the new code with no visible flicker on the runs where
  nothing changed.
- If this machine reboots, the auto-pull/restart job comes back on its own
  (launchd jobs in `~/Library/LaunchAgents` persist across reboots).

## What still needs a human after a physical reboot

- **Step 9 (serial capture)** — this is not currently automated. If you
  want it to also survive a reboot untouched, that would be a second
  `launchd` job (not yet set up — ask for it if/when this becomes
  annoying enough to be worth doing).
