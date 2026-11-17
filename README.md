# MouseBattery

A small macOS menu bar app for Pulsar wireless mice on the Pulsar 1K dongle (`3710:5402`).
It shows the battery level next to a mouse icon and lets you change the mouse settings
without the vendor software.

Tested with the Pulsar Xlite v4. Other Pulsar mice on the same dongle and protocol
(e.g. the X3) should work too.

## Features

- Battery level in the menu bar, with a charging mark. The icon shows up only while the
  dongle is plugged in and the mouse is awake.
- Live signal quality in the menu (updates every second while the menu is open).
- Settings with read-back verification: DPI, polling rate, lift-off distance, motion sync,
  angle snapping, ripple control, debounce, sleep timer, power-saving threshold.
- Side LED: off / steady / breathing, brightness, and an optional mode where the LED colour
  shows the charge (red to green). The mouse resets LED brightness after every sleep; the
  app puts your brightness back as soon as the mouse wakes up.
- English and Russian. By default the app follows the system language (Russian when the
  system language is Russian, English otherwise); change it in the menu under Language.

## Install

Download `MouseBattery-<version>.zip` from
[Releases](../../releases), unzip it and move `MouseBattery.app` to `/Applications`.

The app is not notarized, so remove the quarantine flag once before the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/MouseBattery.app
```

To start it at login, add it in System Settings → General → Login Items.

On the first launch macOS asks for **Input Monitoring**: the dongle sends link and signal
events through its input interface. Battery and settings work without it; signal quality
and instant wake/sleep detection need it.

## Build from source

Needs the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh      # build.noindex/MouseBattery.app, universal arm64 + x86_64
./install.sh    # build, copy to ~/Applications, start at login via a LaunchAgent
```

The binary also has a small CLI for scripts and debugging:

```sh
MouseBattery.app/Contents/MacOS/MouseBattery --once            # battery level
MouseBattery.app/Contents/MacOS/MouseBattery --settings        # dump all settings
MouseBattery.app/Contents/MacOS/MouseBattery --set dpi=1600    # write and verify
```

Keys for `--set`: `dpi`, `polling`, `lod`, `angle_snap`, `ripple`, `motion_sync`,
`debounce`, `sleep`, `low_power`, `led`, `led_brightness`, `led_charge`.

## Releases

Pushing a tag `v*` runs the GitHub Actions workflow, which builds the app and attaches
the zip to a new release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

## Protocol

The dongle speaks the Fusion2/Sonix protocol: 64-byte feature reports without a report
ID on USB interface 3. The register map comes from
[pulsar-mouse-linux](https://github.com/packerlschupfer/pulsar-mouse-linux) and
[mousectl](https://github.com/D3m0nZOnFire/mousectl). Do not send other vendors' frames
to the dongle: the 17-byte X2 V2 protocol locks it up until it is replugged.

Not affiliated with Pulsar Gaming Gears.
