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
* **Preamp Focus & Unison Channel Inspector Mode (Concept 1):**
  * Pressing **`CHANNEL`** (Note 40) or **`PLUG-IN`** (Note 43) expands the selected Apollo track across all 8 physical fader slots on the SSL UF8.
  * **Slot 1:** Motorized Preamp Gain (+10 to +65 dB) with 14-bit tactile tracking and fine V-Pot rotary trim (+/- 1 dB).
  * **Slot 2:** +48V Phantom Power with a **Safety Double-Tap Interlock** protecting delicate ribbon microphones from accidental phantom power surges.
  * **Slot 3:** -20 dB Pad toggle with red tally LED.
  * **Slot 4:** 75 Hz High-Pass Low-Cut filter toggle.
  * **Slot 5:** Phase Invert (Ø) polarity toggle.
  * **Slot 6:** Input Source selector (Mic vs. Line vs. front-panel Hi-Z).
  * **Slot 7:** Output Level motorized fader and V-Pot pan.
  * **Slot 8:** Unison DSP plug-in power & bypass toggle with live plugin name display (`610-B`, `NEVE107`, `API-VIS`).
  * **Preamp Channel Stepping:** Pressing **`< BANK >`** or rotating the Master Jog Wheel steps directly between preamp channels (Apollo 1 $\longleftrightarrow$ Apollo 2).
  * **Instant Return:** Double-pressing **`FLIP`** instantly escapes focus mode and returns directly to the Main Mix at Track 1.
* **Apollo TALKBACK Channel & Studio Slate Control:**
  * Discovers Apollo's hardware Talkback microphone and maps it seamlessly to the mixing surface directly adjacent to tracking inputs (Channel 25).
  * 100mm motorized fader controls Talkback level in real time with 14-bit precision.
  * Channel **MUTE** button acts as a tactile Talkback Mute switch with instant red tally LED and voice feedback (*"TALKBACK unmuted"* / *"TALKBACK muted"*).
  * Real-time 16-segment VU meter ladder on the scribble strip displays live talkback microphone voice levels.
  * Internal DSP matrix dummy slots (such as `N/A 1`) are automatically filtered out.
* **Master AUX 1 & AUX 2 Returns on Faders:**
  * Master Aux returns sit directly adjacent to Talkback on the mixer surface (Channels 26 and 27).
  * Motorized faders adjust Aux master return levels with live peak/RMS VU ladder metering and Mute toggling.
  * Fully routable into headphone cue mixes during CUE send modes.
* **Centered LCD Scribble Strips with Marquee Scrolling:**
  * **Screen Center Alignment:** Channel names are displayed prominently in the center of the UF8 LCD displays (SysEx offset `56`).
  * **dB / Status Readouts:** Precise dB readouts and status banners are displayed directly below channel names (SysEx offset `0`).
  * **Dual SysEx Broadcast:** Simultaneously transmits to both Logic Control (`0x10`) and MCU (`0x14`) formats.
  * **Smooth 4 Hz Marquee:** Long track names (> 7 characters) scroll smoothly with initial and trailing pause holds.
* **Channel Rotary Wheel (Default: Apollo Master Monitor Volume):**
  * **Option 1 (Default: Apollo Master Monitor Volume):** Trims Apollo Main Monitor volume by $\pm 1.0\text{ dB}$ per tick with instant on-screen HUD readout (`>>> MONITOR: -24.0 dB <<<`) and debounced spoken confirmation.
  * **Option 2 (Track Navigation):** Nudges fader banking by 1 track per tick.
  * Toggle modes by pressing the wheel down or using the macOS menu bar icon.
* **Dedicated Navigation Controls (PAGE vs BANK):**
  * **PAGE Buttons (`< PAGE >`):** Jumps the fader surface in clean **8-channel pages** (1–8 $\rightarrow$ 9–16 $\rightarrow$ 17–24 $\rightarrow$ 25–27) with vocal span announcements (*"Apollo 1 through QC"*, *"TALKBACK through AUX 2"*) and boundary alerts (*"First page"*, *"Last page"*).
  * **BANK Buttons (`< BANK >`):** Nudges faders by **1 single track step** at a time (1–8 $\rightarrow$ 2–9 $\rightarrow$ 3–10) with edge notifications (*"Start of tracks"*, *"End of tracks"*).
* **Sends on Faders (`FLIP` Mode) & Direct Return Gesture:**
  * Cycles through `AUX 1` $\rightarrow$ `AUX 2` $\rightarrow$ `CUE 1` $\rightarrow$ `CUE 2` $\rightarrow$ `CUE 3` $\rightarrow$ `CUE 4` $\rightarrow$ `MAIN MIX`.
  * Physical faders reposition immediately to show send levels; V-Pots adjust send pan; Mutes toggle send bypass.
  * **Direct Main Mix & First Channel Gesture:** Double-pressing the **`FLIP`** button at any time instantly snaps straight back to Main Mix and resets the fader surface to the first channel (Tracks 1–8) without cycling through remaining cue buses.
* **Real-Time VU Level Metering:**
  * Dedicated 25 FPS background poller queries live Apollo input meters (`/devices/0/inputs/{ch}/meters/0`).
  * Streams MCU Channel Pressure (`0xD0`) to the physical 16-segment ladder meters on the UF8.
* **Built-In Voice Guidance & Non-Visual Speech Feedback (Accessibility):**
  * Built-in asynchronous speech synthesis speaks channel names, dB levels, pan positions, mute/solo states, and menu selections.
  * **Concise "d B" Pronunciation:** Speeches pronounce "dB" as the letters **"d B"** (*"dee bee"*) rather than the lengthy word *"decibels"*.
  * Completely independent of macOS system VoiceOver — works out of the box for screenless audio operation.
  * Instant gesture interruption and intelligent debouncing (350ms for rotary monitor wheel) ensure speech never lags behind physical mixing.
  * Can be toggled ON or OFF directly from the native macOS menu bar status icon.
* **Native macOS Menu Bar App:**
  * Clean status indicator (Green = Running, Red = Stopped).
  * Instant port switching (Ports 1–12; default is Port 9).
  * Channel Wheel mode selector (Option 1: Apollo Monitor Volume / Option 2: Track Nav).
  * Voice Guidance setting toggle (Enabled / Disabled).
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
