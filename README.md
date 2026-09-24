# Tactile Hardware Accessibility Bridge for UAD Apollo using SSL UF8

**Creator:** S&D A11y Solutions ([snda11ysolutions@gmail.com](mailto:snda11ysolutions@gmail.com))  
**Release Date:** September 24, 2026  
**License:** [MIT with Audio Safety Rider](LICENSE)  
**Legal Terms:** [Terms of Service & EULA](TERMS_OF_SERVICE.md) | [User Manual](MANUAL.md)

---

> [!IMPORTANT]
> **Legal & Non-Affiliation Disclaimer:**  
> This project is an independent accessibility and workflow interoperability utility engineered by **S&D A11y Solutions**. It is **NOT** affiliated, authorized, maintained, sponsored, or endorsed by **Solid State Logic (SSL)**, **Audiotonix**, **Universal Audio, Inc. (UAD)**, or **LOUD Audio, LLC (Mackie)**. All product names, logos, and brands (including *SSL UF8*, *SSL 360°*, *Universal Audio*, *Apollo*, *UAD Console*, and *Mackie Control Universal*) are registered trademarks of their respective owners and are used strictly under **nominative fair use** for technical interoperability identification.

> [!CAUTION]
> **Acoustic Safety & Monitoring Warning:**  
> This software controls hardware gain parameters, cue sends, and master monitor levels. Always turn down external analog speaker volume controllers before launching or testing the bridge. S&D A11y Solutions accepts no liability for acoustic shock, hearing injury, or hardware loudspeaker/headphone damage.

---

## Accessibility & Interoperability Mission

**S&D A11y Solutions** developed this bridge to solve a critical accessibility and ergonomic barrier in modern music production and recording studios:

* **Tactile Motor Control for Blind & Low-Vision Creators:** Universal Audio’s Console application uses custom graphical rendering that lacks native screen reader support (VoiceOver, NVDA, JAWS), rendering it difficult or impossible for blind audio engineers to control with a mouse.
* **100% Physical Fader Parity:** By bridging the tactile 100mm motorized faders, color scribble strips, detented rotary pots, and tactile buttons of the Solid State Logic UF8 directly to the Universal Audio Apollo Console engine, this bridge restores complete, eyes-free physical control over preamps, tracking, monitoring, and cue mixes.
* **Open Interoperability:** Implemented in pure Python and native macOS Swift using standard CoreMIDI and local loopback TCP protocols without modifying proprietary binaries or circumventing copy protection.

---

## Overview

**Tactile Hardware Accessibility Bridge for UAD Apollo using SSL UF8** is a native, zero-dependency macOS bridge application connecting the **Solid State Logic (SSL) UF8** hardware control surface to **Universal Audio (UAD) Apollo Console / Volt / UA Mixer Engine** using the **Mackie Control Universal (MCU)** protocol.

It provides bidirectional motorized fader tracking, center-screen scribble strip LCD feedback with marquee scrolling, rotary pan controls with LED rings, dual-mode channel wheel navigation/monitor volume control, multi-bus sends-on-faders (Aux and Cue cycling), real-time 25 FPS VU audio metering, and an unobtrusive native macOS Menu Bar application.

---

## Key Features

* **8 Motorized Faders (14-Bit Precision):**
  * High-resolution bidirectional tracking between physical 100mm faders and UAD Console faders (`FaderLevelTapered`).
  * Smooth logarithmic/exponential dB curve matching Apollo hardware faders.
  * **Capacitive Touch Interlock:** Suppresses motor feedback fights while your hand is actively touching a fader cap.
* **Centered LCD Scribble Strips with Marquee Scrolling:**
  * **Screen Center Alignment:** Channel names are displayed prominently in the center of the UF8 LCD displays (SysEx offset `56`).
  * **dB / Status Readouts:** Precise dB readouts and status banners are displayed directly below channel names (SysEx offset `0`).
  * **Dual SysEx Broadcast:** Simultaneously transmits to both Logic Control (`0x10`) and MCU (`0x14`) formats.
  * **Smooth 4 Hz Marquee:** Long track names (> 7 characters) scroll smoothly with initial and trailing pause holds.
* **Channel Rotary Wheel (Dual Operating Modes):**
  * **Option 1 (Track Navigation):** Nudges fader banking by 1 track per click.
  * **Option 2 (Apollo Master Monitor Volume):** Commands Apollo Master Monitor level directly in clean 1.0 dB increments with an instant on-screen HUD readout.
  * Toggle modes by pressing the wheel down or using the menu bar icon.
* **Sends on Faders (`FLIP` Mode):**
  * Cycles through `AUX 1` $\rightarrow$ `AUX 2` $\rightarrow$ `CUE 1` $\rightarrow$ `CUE 2` $\rightarrow$ `CUE 3` $\rightarrow$ `CUE 4` $\rightarrow$ `MAIN MIX`.
  * Physical faders reposition immediately to show send levels; V-Pots adjust send pan; Mutes toggle send bypass.
* **Real-Time VU Level Metering:**
  * Dedicated 25 FPS background poller queries live Apollo input meters (`/devices/0/inputs/{ch}/meters/0`).
  * Streams MCU Channel Pressure (`0xD0`) to the physical 16-segment ladder meters on the UF8.
* **Native macOS Menu Bar App:**
  * Clean status indicator (Green = Running, Red = Stopped).
  * Instant port switching (Ports 1–12; default is Port 9).
  * Direct access to Live Terminal Monitor and log files.
* **Zero External Python Dependencies:**
  * Interfaces directly with macOS `CoreMIDI.framework` via `ctypes`.
  * Connects to UAD Console via native TCP loopback socket on `127.0.0.1:4710`.

---

## Quick Start Guide

### 1. Configure SSL 360° Software
1. Open **SSL 360°** on your Mac.
2. Select your **UF8** $\rightarrow$ **Layer 3** (or an unused layer).
3. Set Layer Profile to **Logic Pro** (or **Mackie Control**).
4. Assign MIDI Input and Output to **`SSL V-MIDI Port 9`** (recommended default).

### 2. Verify Apollo Console
Ensure the **Universal Audio Console** application is running. The background mixer engine listens on local TCP port `4710`.

### 3. Launch UA-MCU Bridge
Double-click [`UA-MCU Bridge.app`](/Applications/UA-MCU%20Bridge.app) or run the launcher:
```bash
./start_bridge.sh
```
Or start the Python bridge directly:
```bash
python3 bridge.py --port 9
```

To build and package the native macOS app bundle:
```bash
./package_app.sh
```

---

## Documentation
* **Comprehensive Operator's Manual:** See [`MANUAL.md`](MANUAL.md) for full architecture diagrams, setup workflows, and MIDI/SysEx reference tables.
* **Terms of Service & EULA:** See [`TERMS_OF_SERVICE.md`](TERMS_OF_SERVICE.md) for legal notices and disclaimers.
