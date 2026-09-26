"""
Mackie Control Universal (MCU) Protocol Engine for SSL UF8
Translates bidirectional MIDI messages (14-bit faders, V-Pots, Mutes, Solos, LCD SysEx)
between SSL UF8 and UAD Apollo Console.
"""

import json
import math
import os
import re
import subprocess
import threading
import time
from typing import Callable, Dict, List, Optional
from uad_client import UADClient, UADChannel, UADSend
from uad_curve import tapered_to_db, db_to_tapered, format_db_7char

CONFIG_PATH = os.path.expanduser("~/.uamcu_config.json")


def load_wheel_mode() -> str:
    """Read wheel mode preference: 'monitor' (Default: Apollo Master Volume) or 'channel' (Track Navigation)."""
    try:
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH, "r") as f:
                cfg = json.load(f)
                return cfg.get("wheel_mode", "monitor")
    except Exception:
        pass
    return "monitor"


def save_wheel_mode(mode: str):
    """Save wheel mode preference to ~/.uamcu_config.json."""
    try:
        cfg = {}
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r") as f:
                    cfg = json.load(f)
            except Exception:
                cfg = {}
        cfg["wheel_mode"] = mode
        with open(CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass


def load_speech_mode() -> bool:
    """Read voice guidance preference (default: True for accessibility)."""
    try:
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH, "r") as f:
                cfg = json.load(f)
                return cfg.get("speech_feedback", True)
    except Exception:
        pass
    return True


def save_speech_mode(enabled: bool):
    """Save voice guidance preference to ~/.uamcu_config.json."""
    try:
        cfg = {}
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r") as f:
                    cfg = json.load(f)
            except Exception:
                cfg = {}
        cfg["speech_feedback"] = enabled
        with open(CONFIG_PATH, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass


def format_db_speech(db: float) -> str:
    """Format dB float to clear natural speech for blind audio engineers."""
    if db <= -140.0:
        return "minus infinity d B"
    if abs(db) < 0.1:
        return "zero d B"
    if db > 0:
        return f"plus {db:.1f} d B"
    return f"{db:.1f} d B"


def format_pan_speech(pan: float) -> str:
    """Format pan float (-1.0 to 1.0) to natural speech."""
    if abs(pan) < 0.05:
        return "center"
    pct = int(round(abs(pan) * 100))
    side = "left" if pan < 0 else "right"
    return f"{side} {pct} percent"


class VoiceAnnouncer:
    """Non-blocking, interruptible speech announcer for blind and screenless audio operation.
    Uses macOS native /usr/bin/say at a natural pace (-r 210) for instant tactile feedback.
    Never blocks MIDI parsing or audio threads.
    """
    def __init__(self):
        self._proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()
        self._debounce_timer: Optional[threading.Timer] = None

    @staticmethod
    def _sanitize_for_speech(text: str) -> str:
        """Ensure 'dB' is spoken as the letters 'd B' instead of expanding to 'decibels'."""
        text = re.sub(r'(\d|\b)dB\b', r'\1 d B', text)
        text = re.sub(r'(\d|\b)db\b', r'\1 d B', text)
        text = re.sub(r'(\d|\b)DB\b', r'\1 d B', text)
        return re.sub(r'\s+', ' ', text).strip()

    def is_enabled(self) -> bool:
        return load_speech_mode()

    def speak(self, text: str, interrupt: bool = True):
        """Speak the given text if voice guidance is enabled. Non-blocking."""
        if not self.is_enabled() or not text:
            return

        text = self._sanitize_for_speech(text)

        with self._lock:
            if self._debounce_timer:
                try:
                    self._debounce_timer.cancel()
                except Exception:
                    pass
                self._debounce_timer = None

            if interrupt and self._proc is not None:
                try:
                    if self._proc.poll() is None:
                        self._proc.terminate()
                except Exception:
                    pass
                self._proc = None

            try:
                self._proc = subprocess.Popen(
                    ["/usr/bin/say", "-r", "210", text],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            except Exception as e:
                print(f"[Voice] Speech error: {e}")

    def speak_debounced(self, text: str, delay: float = 0.35):
        """Debounce speech (e.g. rapid wheel turns), speaking only after user pauses."""
        if not self.is_enabled() or not text:
            return

        with self._lock:
            if self._debounce_timer:
                try:
                    self._debounce_timer.cancel()
                except Exception:
                    pass
            self._debounce_timer = threading.Timer(delay, self.speak, args=[text])
            self._debounce_timer.daemon = True
            self._debounce_timer.start()

    def stop(self):
        with self._lock:
            if self._debounce_timer:
                try:
                    self._debounce_timer.cancel()
                except Exception:
                    pass
            if self._proc is not None:
                try:
                    if self._proc.poll() is None:
                        self._proc.terminate()
                except Exception:
                    pass
                self._proc = None


class SlotMarquee:
    """Manages smooth marquee scrolling for a 7-character LCD slot.
    Pauses on initial characters, scrolls through long text, pauses at end, then loops cleanly.
    """
    def __init__(self, step_interval: float = 0.25, start_pause: int = 5, end_pause: int = 3):
        self.current_text = ""
        self.start_pause = start_pause  # 5 ticks * 0.25s = 1.25s hold at start
        self.end_pause = end_pause      # 3 ticks * 0.25s = 0.75s hold at end
        self.step_counter = 0

    def reset(self):
        self.step_counter = 0

    def update_text(self, new_text: str):
        cleaned = new_text.strip()
        if cleaned != self.current_text:
            self.current_text = cleaned
            self.step_counter = 0

    def get_display_str(self) -> str:
        text = self.current_text
        if len(text) <= 7:
            return f"{text:^7}"[:7]

        padded = text + "   "
        total_len = len(padded)
        end_idx = len(text) - 7

        total_cycle = self.start_pause + end_idx + self.end_pause + (total_len - end_idx)
        c = self.step_counter % total_cycle

        if c < self.start_pause:
            offset = 0
        elif c < self.start_pause + end_idx:
            offset = c - self.start_pause
        elif c < self.start_pause + end_idx + self.end_pause:
            offset = end_idx
        else:
            scroll_after = c - (self.start_pause + end_idx + self.end_pause)
            offset = (end_idx + 1 + scroll_after) % total_len

        double_padded = padded + padded
        return double_padded[offset : offset + 7]

    def tick(self):
        if len(self.current_text) > 7:
            self.step_counter += 1


def pan_to_str(pan: float) -> str:
    """Format pan (-1.0 to 1.0) as 6-char string (e.g. ' L 50 ', '   C  ', ' R 25 ')."""
    if abs(pan) < 0.03:
        return "  C   "
    elif pan < 0:
        val = int(abs(pan) * 100)
        return f" L {val:<2d} "
    else:
        val = int(pan * 100)
        return f" R {val:<2d} "


# Apollo Console meter scale calibration matching hardware GUI tick marks:
# [-oo, -60, -46, -36, -27, -21, -18, -15, -12, -9, -6, -3, 0 dB]
METER_TICKS = [
    (-60.0, 0x01),  # -60 dB
    (-46.0, 0x02),  # -46 dB
    (-36.0, 0x03),  # -36 dB
    (-27.0, 0x04),  # -27 dB
    (-21.0, 0x05),  # -21 dB
    (-18.0, 0x06),  # -18 dB
    (-15.0, 0x07),  # -15 dB
    (-12.0, 0x08),  # -12 dB
    (-9.0,  0x09),  # -9 dB
    (-6.0,  0x0A),  # -6 dB
    (-3.0,  0x0B),  # -3 dB
    (-0.2,  0x0C),  # 0 dB
]


def db_to_mcu_meter(db: float, is_clip: bool = False) -> int:
    """
    Map Apollo audio dBFS to MCU 4-bit meter nibble matching Apollo Console meter ticks:
    -oo (0x0), -60, -46, -36, -27, -21, -18, -15, -12, -9, -6, -3, 0 dB (0xC), CLIP (0xE)
    """
    if is_clip or db >= 0.0:
        return 0x0E
    if db <= -60.0:
        return 0x00
    for threshold, seg in reversed(METER_TICKS):
        if db >= threshold:
            return seg
    return 0x01


class MCUEngine:
    """Handles Mackie Control Universal protocol encoding and decoding for 8-channel surface."""

    def __init__(self, uad_client: UADClient, send_midi_fn: Callable[[bytes], None]):
        self.uad = uad_client
        self.send_midi = send_midi_fn

        self.bank_offset = 0  # Starting input channel index (0, 8, 16...)
        self.num_slots = 8
        self.fader_touched = [False] * self.num_slots
        self.zero_mode_held = False
        self.zero_mode_latched = False
        self.selected_slot: Optional[int] = None

        # Double-press (0 dB) & Long-press (Lowest Level -oo dB) tracking for SEL buttons
        self._sel_press_time = [0.0] * self.num_slots
        self._sel_release_time = [0.0] * self.num_slots
        self._sel_long_timer: List[Optional[threading.Timer]] = [None] * self.num_slots
        self._sel_long_fired = [False] * self.num_slots
        self._sel_click_timer: List[Optional[threading.Timer]] = [None] * self.num_slots

        # Cache of displayed LCD text to minimize redundant SysEx traffic
        self._last_row1_text = ""
        self._last_row2_text = ""
        self._lock = threading.Lock()

        # Connect UAD state change hook
        self.uad.on_channel_change = self._on_uad_channel_change

        # Sends on Faders (FLIP): None = Main Volumes, 0 = AUX 1, 1 = AUX 2, 2..5 = CUE 1..4
        self.active_send_idx: Optional[int] = None
        self._last_flip_press_time: float = 0.0
        self._flip_timer: Optional[threading.Timer] = None
        self.send_flip_led(False)

        # Preamp Focus / Channel Inspector Mode (Concept 1)
        self.preamp_focus_mode: bool = False
        self.preamp_focus_channel: int = 0
        self._48v_arm_time: float = 0.0

        # Channel Rotary Wheel Mode: 'channel' (Option 1) or 'monitor' (Option 2)
        self._config_mtime: float = 0.0
        self.wheel_mode: str = load_wheel_mode()
        self._wheel_strobe_active: bool = False
        self._last_wheel_strobe: float = 0.0
        self._hud_active: bool = False
        self._hud_timer: Optional[threading.Timer] = None

        # Marquee scrolling for track names longer than 7 characters
        self.marquees = [SlotMarquee() for _ in range(self.num_slots)]
        self._running = True
        self._marquee_thread = threading.Thread(target=self._marquee_loop, daemon=True)
        self._marquee_thread.start()

        # Initialize Voice Guidance for blind and screenless accessibility
        self.voice = VoiceAnnouncer()
        threading.Timer(0.8, lambda: self.voice.speak("Tactile Accessibility Bridge connected. Voice guidance enabled.")).start()

        # Initialize hardware meters
        self.enable_meters()

    # --- Incoming MIDI from SSL UF8 ---

    def handle_midi_bytes(self, raw: bytes):
        """Parse incoming raw MIDI packet from SSL UF8."""
        if not raw:
            return

        i = 0
        while i < len(raw):
            status = raw[i]

            # Running status or incomplete
            if status < 0x80:
                i += 1
                continue

            # 1. Pitch Bend: Fader position (0xE0 to 0xE7 for ch 0..7)
            if 0xE0 <= status <= 0xE7:
                if i + 2 < len(raw):
                    ch = status - 0xE0
                    lsb = raw[i + 1]
                    msb = raw[i + 2]
                    val_14bit = (msb << 7) | lsb
                    tapered = val_14bit / 16383.0

                    if self.preamp_focus_mode:
                        self._handle_preamp_fader(ch, tapered)
                    else:
                        target_channel = self.bank_offset + ch
                        if self.active_send_idx is not None:
                            ch_obj = self.uad.channels.get(target_channel)
                            if getattr(ch_obj, "ch_type", "input") == "aux" and self.active_send_idx < 2:
                                pass  # Aux returns do not send to Aux 1 or Aux 2
                            else:
                                self.uad.set_send_gain(target_channel, self.active_send_idx, tapered)
                        else:
                            self.uad.set_fader(target_channel, tapered)
                            if target_channel in self.uad.channels:
                                self.uad.channels[target_channel].fader_db = tapered_to_db(tapered)
                        self._update_lcd_row2()
                        if self.zero_mode_held or self.zero_mode_latched:
                            self.send_sel_led(ch, self.is_channel_at_zero(target_channel))
                    i += 3
                    continue

            # 2. Note On: Button press / Fader Touch (0x90)
            elif status == 0x90:
                if i + 2 < len(raw):
                    note = raw[i + 1]
                    vel = raw[i + 2]
                    self._handle_note(note, vel > 0)
                    i += 3
                    continue

            # 3. Note Off: Button release / Fader Release (0x80)
            elif status == 0x80:
                if i + 2 < len(raw):
                    note = raw[i + 1]
                    self._handle_note(note, False)
                    i += 3
                    continue

            # 4. Control Change: V-Pot Encoders (0xB0)
            elif status == 0xB0:
                if i + 2 < len(raw):
                    cc = raw[i + 1]
                    val = raw[i + 2]
                    self._handle_cc(cc, val)
                    i += 3
                    continue

            # Unknown / unhandled byte
            i += 1

    def _handle_note(self, note: int, is_down: bool):
        """Handle MCU buttons and touch notes."""
        print(f"[MCU] Button: note={note} (0x{note:02X}) is_down={is_down}")

        # Fader Touch: 0x68..0x6F (104..111)
        if 104 <= note <= 111:
            slot = note - 104
            self.fader_touched[slot] = is_down
            return

        # Wheel encoder active indicator from SSL UF8 (Note 83 / 0x53)
        if note == 83:
            self._wheel_strobe_active = is_down
            if is_down:
                self._last_wheel_strobe = time.time()
            return

        # Channel / Plug-in buttons: Note 40 (0x28) / Note 43 (0x2B) -> Toggle Preamp Focus Mode
        if note in (40, 43):
            if is_down:
                self.toggle_preamp_focus_mode()
            return

        # FLIP Button: 0x32 (50) -> Single-press: Cycle sends; Double-press: Direct return to Main Mix
        if note == 50:
            if is_down:
                self._handle_flip_button()
            return

        # If in Preamp Focus Mode, delegate buttons to _handle_preamp_note
        if self.preamp_focus_mode:
            self._handle_preamp_note(note, is_down)
            return

        # ZERO / AUTO modifier buttons:
        # 71 = Option (Logic/SSL ZERO), 73 = Alt (Pro Tools ZERO), 74 = Read/Auto (Cubase)
        ZERO_NOTES = (71, 73, 74, 75, 76, 77, 78, 70, 72)
        if note in ZERO_NOTES:
            self.zero_mode_held = is_down
            if is_down:
                self.zero_mode_latched = not self.zero_mode_latched
                print(f"[MCU] ZERO/AUTO button pressed (note {note}) -> zero mode {'ARMED' if self.zero_mode_latched else 'DISARMED'}")
            vel = 0x7F if (self.zero_mode_held or self.zero_mode_latched) else 0x00
            self.send_midi(bytes([0x90, note, vel]))
            self.update_zero_mode_leds()

        # Channel Select Buttons: 0x18..0x1F (24..31)
        # Double-press: Reset fader to 0.0 dB
        # Long-press (> 0.5s): Reset fader to lowest level (-oo dB)
        # Single-press: Normal channel selection
        if 24 <= note <= 31:
            slot = note - 24
            target_ch = self.bank_offset + slot
            self._handle_sel_button(slot, target_ch, is_down)
            return

        if not is_down:
            return  # Trigger actions on button press

        # V-Pot Push: 0x20..0x27 (32..39) -> Reset Pan to Center (0.0)
        if 32 <= note <= 39:
            slot = note - 32
            target_ch = self.bank_offset + slot
            ch_obj = self.uad.channels.get(target_ch)
            ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
            if self.active_send_idx is not None:
                if getattr(ch_obj, "ch_type", "input") == "aux":
                    return  # Aux cue sends are stereo without pan
                info = self.get_send_info(self.active_send_idx)
                print(f"[MCU] V-Pot Push: Reset channel {target_ch + 1} {info['name']} Pan to Center")
                self.uad.set_send_pan(target_ch, self.active_send_idx, 0.0)
                self.voice.speak(f"{ch_name} {info['name']} pan centered")
            else:
                if getattr(ch_obj, "ch_type", "input") == "aux":
                    return  # Aux return is stereo without pan
                print(f"[MCU] V-Pot Push: Reset channel {target_ch + 1} Pan to Center")
                self.uad.set_pan(target_ch, 0.0)
                self._update_lcd_row2()
                self.voice.speak(f"{ch_name} pan centered")
            self.send_vpot_led_ring(slot, 0.0)
            return

        # Mute Buttons: 0x10..0x17 (16..23) -> Toggle Mute (Normal) or Send Bypass (Send Mode)
        if 16 <= note <= 23:
            slot = note - 16
            target_ch = self.bank_offset + slot
            ch_obj = self.uad.channels.get(target_ch)
            ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
            if self.active_send_idx is not None:
                if getattr(ch_obj, "ch_type", "input") == "aux" and self.active_send_idx < 2:
                    return  # Aux returns do not send to Aux 1 or Aux 2
                send = ch_obj.sends.setdefault(self.active_send_idx, UADSend(self.active_send_idx)) if ch_obj else None
                new_byp = not (send.bypass if send else False)
                self.uad.set_send_bypass(target_ch, self.active_send_idx, new_byp)
                self.send_mute_led(slot, new_byp)
                self._update_lcd_row2()
                info = self.get_send_info(self.active_send_idx)
                byp_state = "bypassed" if new_byp else "active"
                self.voice.speak(f"{ch_name} {info['name']} send {byp_state}")
                return
            else:
                new_mute = not (ch_obj.mute if ch_obj else False)
                self.uad.set_mute(target_ch, new_mute)
                self.send_mute_led(slot, new_mute)
                self._update_lcd_row2()
                mute_state = "muted" if new_mute else "unmuted"
                self.voice.speak(f"{ch_name} {mute_state}")
                return

        # Solo Buttons: 0x08..0x0F (8..15)
        if 8 <= note <= 15:
            slot = note - 8
            target_ch = self.bank_offset + slot
            ch_obj = self.uad.channels.get(target_ch)
            ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
            new_solo = not (ch_obj.solo if ch_obj else False)
            self.uad.set_solo(target_ch, new_solo)
            self.send_solo_led(slot, new_solo)
            solo_state = "solo on" if new_solo else "solo off"
            self.voice.speak(f"{ch_name} {solo_state}")
            return

        # Channel Rotary Wheel Push / Click: Note 84 (Jog Click) / Note 100 / Note 101 / Note 79
        # Toggles Channel Wheel between Option 1 (1-Track Navigation) and Option 2 (Monitor Volume)
        if note in (84, 100, 101, 79):
            self.toggle_wheel_mode()
            return

        # Navigation Buttons & Rotary Wheel Controls
        # Physical Controls on SSL UF8:
        # Note 83 is the physical wheel encoder active indicator emitted by SSL UF8 on every rotation step.
        is_wheel_rotation = self._wheel_strobe_active or (time.time() - self._last_wheel_strobe < 0.20)

        # 1. Rotary Master Wheel turned (Notes 46/47 or 48/49 with wheel strobe)
        if is_wheel_rotation and note in (46, 47, 48, 49):
            direction = -1 if note in (46, 48) else 1
            mode = self.get_wheel_mode()
            if mode == "monitor":
                changed = self.uad.nudge_monitor_db(direction * 1.0)
                disp_str = f"MONITOR: {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "MONITOR: MUTED"
                self.show_temp_hud(f">>> {disp_str} <<<", duration=1.2)
                if changed:
                    spk_str = f"Monitor {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "Monitor Muted"
                    self.voice.speak_debounced(spk_str, delay=0.35)
                else:
                    if direction > 0:
                        self.voice.speak_debounced("Monitor maximum 0 dB", delay=0.35)
                    else:
                        self.voice.speak_debounced("Monitor minimum -96 dB", delay=0.35)
                return
            else:
                self.bank_by(direction)
                return

        # 2. Hardware PAGE buttons on SSL UF8:
        # Move active bank in 8-channel pages (e.g. Channels 1-8 -> 9-16 -> 17-24 -> 25-27)
        # Note 48/49 (when pressed as buttons, not rotary encoder), Note 104/105 (MCU Assign Page L/R), Note 44/45 (Page L/R)
        if note in (48, 44, 104):
            self.page_by(-1)
            return
        if note in (49, 45, 105):
            self.page_by(1)
            return

        # 3. Hardware BANK buttons on SSL UF8:
        # Nudge active bank by 1 single track step (e.g. Channels 1-8 -> 2-9 -> 3-10)
        # Notes 46 (< BANK), 47 (BANK >), and cursor navigation 98/99
        if note in (46, 98):
            self.bank_by(-1)
            return
        if note in (47, 99):
            self.bank_by(1)
            return

    def return_to_main_mix(self):
        """Immediately return from any send/cue mode or preamp focus mode directly back to normal Main Mix and reset to the first channel (Tracks 1-8)."""
        if self._flip_timer:
            try:
                self._flip_timer.cancel()
            except Exception:
                pass
            self._flip_timer = None
        self._last_flip_press_time = 0.0

        was_preamp_mode = self.preamp_focus_mode
        was_send_mode = (self.active_send_idx is not None)
        was_offset = (self.bank_offset != 0)

        self.preamp_focus_mode = False
        self.send_midi(bytes([0x90, 40, 0x00]))  # CHANNEL LED off
        self.send_midi(bytes([0x90, 43, 0x00]))  # PLUG-IN LED off

        self.active_send_idx = None
        self.bank_offset = 0
        self._cancel_all_sel_timers()
        for m in self.marquees:
            m.reset()
        self.send_flip_led(False)
        self.refresh_all_slots()

        print("[MCU] FLIP Double-Press -> Returned directly to MAIN MIX & First Channel (Tracks 1-8)")
        total_ch = len(self.uad.channels) if self.uad.channels else 25
        end_num = min(8, total_ch)
        first_ch = self.uad.channels.get(0)
        last_ch = self.uad.channels.get(end_num - 1)
        first_name = first_ch.name.strip() if first_ch else ""
        last_name = last_ch.name.strip() if last_ch else ""

        if was_preamp_mode:
            self.voice.speak("Exiting preamp focus, Main mix")
        elif was_offset and first_name and last_name:
            self.voice.speak(f"Main mix, {first_name} through {last_name}")
        elif was_offset:
            self.voice.speak("Main mix, channel 1")
        else:
            self.voice.speak("Main mix")

    def cycle_send_mode(self):
        """Cycle to the next send mode (Normal -> Aux 1 -> Aux 2 -> Cue 1..N -> Normal)."""
        self._last_flip_press_time = 0.0
        modes = self.get_available_send_modes()
        if self.active_send_idx is None:
            self.active_send_idx = modes[0][0]
            mode_name = f"{modes[0][2]} (SENDS ON FADERS)"
        else:
            curr_idx = -1
            for i, m in enumerate(modes):
                if m[0] == self.active_send_idx:
                    curr_idx = i
                    break
            if curr_idx != -1 and curr_idx + 1 < len(modes):
                next_mode = modes[curr_idx + 1]
                self.active_send_idx = next_mode[0]
                mode_name = f"{next_mode[2]} (SENDS ON FADERS)"
            else:
                self.active_send_idx = None
                mode_name = "MAIN MIX (NORMAL)"

        print(f"[MCU] FLIP pressed -> Switched to {mode_name}")
        if self.active_send_idx is not None:
            spk_mode = mode_name.replace(" (SENDS ON FADERS)", " sends on faders")
            self.voice.speak(spk_mode)
        else:
            self.voice.speak("Main mix")
        for m in self.marquees:
            m.reset()
        self.send_flip_led(self.active_send_idx is not None)
        self.refresh_all_slots()

    def _handle_flip_button(self):
        """Handle FLIP button: Single-press cycles send modes, Double-press returns directly to Main Mix."""
        now = time.time()
        if now - self._last_flip_press_time < 0.35:
            # Double-press detected: jump directly to Main Mix!
            if self._flip_timer:
                try:
                    self._flip_timer.cancel()
                except Exception:
                    pass
                self._flip_timer = None
            self.return_to_main_mix()
        else:
            self._last_flip_press_time = now
            if self._flip_timer:
                try:
                    self._flip_timer.cancel()
                except Exception:
                    pass
            timer = threading.Timer(0.30, self.cycle_send_mode)
            timer.daemon = True
            timer.start()
            self._flip_timer = timer

    def _handle_cc(self, cc: int, val: int):
        """Handle Rotary V-Pots (CC 16..23) and Channel Rotary Wheel (CC 60)."""
        if self.preamp_focus_mode:
            if 16 <= cc <= 23:
                slot = cc - 16
                delta = -(val & 0x3F) if (val & 0x40) else (val & 0x3F)
                self._handle_preamp_vpot(slot, delta)
                return
            elif cc == 60:
                delta = -(val & 0x3F) if (val & 0x40) else (val & 0x3F)
                if delta != 0:
                    self.step_preamp_channel(delta)
                return

        if 16 <= cc <= 23:
            slot = cc - 16
            target_ch = self.bank_offset + slot
            # Relative 2's complement: 0x01..0x3F is positive, 0x41..0x7F is negative
            if val & 0x40:
                delta = -(val & 0x3F)
            else:
                delta = val & 0x3F

            ch_obj = self.uad.channels.get(target_ch)
            if getattr(ch_obj, "ch_type", "input") == "aux":
                return  # Aux master return and cue sends are stereo without pan
            if self.active_send_idx is not None:
                send = ch_obj.sends.setdefault(self.active_send_idx, UADSend(self.active_send_idx)) if ch_obj else None
                current_pan = send.pan if send else 0.0
                new_pan = max(-1.0, min(1.0, current_pan + (delta * 0.02)))
                self.uad.set_send_pan(target_ch, self.active_send_idx, new_pan)
                self.send_vpot_led_ring(slot, new_pan)
            else:
                current_pan = ch_obj.pan if ch_obj else 0.0
                new_pan = max(-1.0, min(1.0, current_pan + (delta * 0.02)))
                self.uad.set_pan(target_ch, new_pan)
                self.send_vpot_led_ring(slot, new_pan)
                self._update_lcd_row2()

        # Channel Rotary Wheel (Mackie Jog / Scrub Wheel: CC 60 / 0x3C)
        elif cc == 60:
            if val & 0x40:
                delta = -(val & 0x3F)
            else:
                delta = val & 0x3F

            if delta == 0:
                return

            mode = self.get_wheel_mode()
            if mode == "monitor":
                changed = self.uad.nudge_monitor_db(delta * 1.0)
                disp_str = f"MONITOR: {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "MONITOR: MUTED"
                self.show_temp_hud(f">>> {disp_str} <<<", duration=1.2)
                if changed:
                    spk_str = f"Monitor {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "Monitor Muted"
                    self.voice.speak_debounced(spk_str, delay=0.35)
                else:
                    if delta > 0:
                        self.voice.speak_debounced("Monitor maximum 0 dB", delay=0.35)
                    else:
                        self.voice.speak_debounced("Monitor minimum -96 dB", delay=0.35)
            else:
                self.bank_by(delta)

    # --- Outbound MCU Feedback to SSL UF8 ---

    def send_fader_position(self, slot: int, tapered: float):
        """Send motorized fader position (14-bit pitch bend)."""
        if self.fader_touched[slot]:
            return  # Do not fight user's physical touch
        val_14 = int(max(0.0, min(1.0, tapered)) * 16383.0)
        lsb = val_14 & 0x7F
        msb = (val_14 >> 7) & 0x7F
        self.send_midi(bytes([0xE0 + slot, lsb, msb]))

    def send_mute_led(self, slot: int, is_muted: bool):
        """Update Mute button LED state."""
        vel = 0x7F if is_muted else 0x00
        self.send_midi(bytes([0x90, 16 + slot, vel]))

    def send_solo_led(self, slot: int, is_soloed: bool):
        """Update Solo button LED state."""
        vel = 0x7F if is_soloed else 0x00
        self.send_midi(bytes([0x90, 8 + slot, vel]))

    def send_sel_led(self, slot: int, is_selected: bool):
        """Update Channel Select button LED state (0x18..0x1F)."""
        vel = 0x7F if is_selected else 0x00
        self.send_midi(bytes([0x90, 24 + slot, vel]))

    def is_channel_at_zero(self, ch_id: int) -> bool:
        """Check if channel fader is at 0.0 dB unity gain."""
        ch = self.uad.channels.get(ch_id)
        if not ch:
            return False
        db_val = getattr(ch, 'fader_db', None)
        if db_val is not None and abs(db_val) < 0.15:
            return True
        return abs(ch.fader - 0.7818182) < 0.006

    def update_zero_mode_leds(self):
        """
        Update channel SEL button LEDs:
        In ZERO mode:
          - If fader is at 0.0 dB: SEL LED is ON.
          - If fader is NOT at 0.0 dB: SEL LED is OFF (ready to be zeroed).
        In Normal mode:
          - SEL LED reflects normal track selection (selected_slot).
        """
        if self.zero_mode_held or self.zero_mode_latched:
            for slot in range(self.num_slots):
                ch_id = self.bank_offset + slot
                at_zero = self.is_channel_at_zero(ch_id)
                self.send_sel_led(slot, at_zero)
        else:
            for slot in range(self.num_slots):
                self.send_sel_led(slot, slot == self.selected_slot)

    def select_slot(self, slot: int):
        """Select a channel slot and update SEL LEDs."""
        self.selected_slot = slot if self.selected_slot != slot else None
        for s in range(self.num_slots):
            self.send_sel_led(s, s == self.selected_slot)

        if self.selected_slot is not None:
            ch_id = self.bank_offset + slot
            ch = self.uad.channels.get(ch_id)
            if ch:
                ch_name = ch.name.strip() or f"Channel {ch_id + 1}"
                if self.active_send_idx is not None:
                    info = self.get_send_info(self.active_send_idx)
                    if getattr(ch, "ch_type", "input") == "aux" and self.active_send_idx < 2:
                        self.voice.speak(f"{ch_name}, no send")
                    else:
                        send = ch.sends.get(self.active_send_idx)
                        gain_db = send.gain_db if send else -144.0
                        byp = send.bypass if send else False
                        byp_str = ", bypassed" if byp else ""
                        if getattr(ch, "ch_type", "input") == "aux":
                            self.voice.speak(f"{info['name']}, {ch_name}, {format_db_speech(gain_db)}{byp_str}")
                        else:
                            pan = send.pan if send else 0.0
                            self.voice.speak(f"{info['name']}, {ch_name}, {format_db_speech(gain_db)}, {format_pan_speech(pan)}{byp_str}")
                else:
                    db_val = getattr(ch, 'fader_db', None)
                    if db_val is None:
                        db_val = tapered_to_db(ch.fader)
                    status_parts = []
                    if ch.mute:
                        status_parts.append("muted")
                    if ch.solo:
                        status_parts.append("soloed")
                    stat_str = (", " + ", ".join(status_parts)) if status_parts else ""
                    if getattr(ch, "ch_type", "input") == "aux":
                        self.voice.speak(f"{ch_name}, {format_db_speech(db_val)}{stat_str}")
                    else:
                        self.voice.speak(f"{ch_name}, {format_db_speech(db_val)}, {format_pan_speech(ch.pan)}{stat_str}")

    def _handle_sel_button(self, slot: int, target_ch: int, is_down: bool):
        """Handle SEL button: Double-Press (0.0 dB), Long-Press (Lowest Level -oo dB), Single-Press (Select)."""
        now = time.time()

        if is_down:
            # Button Down: cancel any pending single-click
            if self._sel_click_timer[slot] is not None:
                try:
                    self._sel_click_timer[slot].cancel()
                except Exception:
                    pass
                self._sel_click_timer[slot] = None

            self._sel_press_time[slot] = now
            self._sel_long_fired[slot] = False

            # Cancel existing long-press timer if active
            if self._sel_long_timer[slot] is not None:
                try:
                    self._sel_long_timer[slot].cancel()
                except Exception:
                    pass
                self._sel_long_timer[slot] = None

            # Start long-press timer (500ms): snaps fader to lowest level (-oo dB)
            timer = threading.Timer(0.5, self._on_sel_long_press, args=[slot, target_ch])
            timer.daemon = True
            timer.start()
            self._sel_long_timer[slot] = timer

        else:
            # Button Up: cancel long-press timer
            if self._sel_long_timer[slot] is not None:
                try:
                    self._sel_long_timer[slot].cancel()
                except Exception:
                    pass
                self._sel_long_timer[slot] = None

            # If long-press already triggered, do not trigger click / double-click
            if self._sel_long_fired[slot]:
                self._sel_long_fired[slot] = False
                self._sel_release_time[slot] = 0.0
                return

            # Check if ZERO mode was armed
            if self.zero_mode_held or self.zero_mode_latched:
                ch_obj = self.uad.channels.get(target_ch)
                ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
                print(f"[MCU] ZERO + SEL: Resetting channel {target_ch + 1} (slot {slot + 1}) to 0.0 dB")
                self.uad.set_fader(target_ch, 0.7818182)
                self.send_fader_position(slot, 0.7818182)
                self._update_lcd_row2()
                self.send_sel_led(slot, True)
                self._sel_release_time[slot] = 0.0
                self.voice.speak(f"{ch_name} reset to zero dB")
                return

            # Check for double-press (released within 350ms of previous release)
            if now - self._sel_release_time[slot] < 0.35:
                # Double-press detected: Reset to 0.0 dB
                self._sel_release_time[slot] = 0.0
                ch_obj = self.uad.channels.get(target_ch)
                ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
                if self.active_send_idx is not None:
                    info = self.get_send_info(self.active_send_idx)
                    print(f"[MCU] SEL {slot + 1} Double-Press: Resetting channel {target_ch + 1} {info['name']} to 0.0 dB")
                    self.uad.set_send_gain(target_ch, self.active_send_idx, 0.7818182)
                    self.voice.speak(f"{ch_name} {info['name']} send reset to zero dB")
                else:
                    print(f"[MCU] SEL {slot + 1} Double-Press: Resetting channel {target_ch + 1} to 0.0 dB")
                    self.uad.set_fader(target_ch, 0.7818182)
                    self.voice.speak(f"{ch_name} reset to zero dB")
                self.send_fader_position(slot, 0.7818182)
                self._update_lcd_row2()
                self.send_sel_led(slot, True)
            else:
                # Potential single-press: start timer to execute single click if no second tap arrives
                self._sel_release_time[slot] = now
                timer = threading.Timer(0.35, self._on_sel_single_click, args=[slot])
                timer.daemon = True
                timer.start()
                self._sel_click_timer[slot] = timer

    def _on_sel_long_press(self, slot: int, target_ch: int):
        """Callback when SEL button is held for > 0.5s: Reset fader to lowest level (-oo dB)."""
        self._sel_long_fired[slot] = True
        ch_obj = self.uad.channels.get(target_ch)
        ch_name = ch_obj.name.strip() if ch_obj else f"Channel {target_ch + 1}"
        if self.active_send_idx is not None:
            info = self.get_send_info(self.active_send_idx)
            print(f"[MCU] SEL {slot + 1} Long-Press: Resetting channel {target_ch + 1} {info['name']} to lowest level (-oo dB)")
            self.uad.set_send_gain(target_ch, self.active_send_idx, 0.0)
            self.voice.speak(f"{ch_name} {info['name']} send set to minus infinity")
        else:
            print(f"[MCU] SEL {slot + 1} Long-Press: Resetting channel {target_ch + 1} to lowest level (-oo dB)")
            self.uad.set_fader(target_ch, 0.0)
            self.voice.speak(f"{ch_name} set to minus infinity")
        self.send_fader_position(slot, 0.0)
        self._update_lcd_row2()
        self.send_sel_led(slot, False)

    def _on_sel_single_click(self, slot: int):
        """Callback when single-click timer expires without a second tap: Select slot."""
        self._sel_release_time[slot] = 0.0
        self.select_slot(slot)

    def _cancel_all_sel_timers(self):
        """Cancel any pending SEL timers across all slots."""
        for s in range(self.num_slots):
            if self._sel_long_timer[s] is not None:
                try:
                    self._sel_long_timer[s].cancel()
                except Exception:
                    pass
                self._sel_long_timer[s] = None
            if self._sel_click_timer[s] is not None:
                try:
                    self._sel_click_timer[s].cancel()
                except Exception:
                    pass
                self._sel_click_timer[s] = None
            self._sel_long_fired[s] = False
            self._sel_release_time[s] = 0.0

    def send_vpot_led_ring(self, slot: int, pan: float):
        """Update V-Pot LED ring pan position (CC 48..55, values 0x01..0x0B)."""
        # MCU LED ring: 11 positions (0x01 to 0x0B)
        pos = int((pan + 1.0) / 2.0 * 10.0) + 1
        pos = max(1, min(11, pos))
        self.send_midi(bytes([0xB0, 48 + slot, pos]))

    def send_lcd_text(self, row: int, text: str):
        """Send 56-character string to UF8 LCD Scribble Strip via SysEx.
        On SSL UF8 display:
          - Offset 56 places text in the CENTER of the screen (UpLCD).
          - Offset 0 places text UNDER the center (LowLCD).
        row == 1 (Channel names) -> sent to offset 56 (Center of screen).
        row == 2 (dB info / HUD) -> sent to offset 0 (Under channel text).
        """
        offset = 56 if row == 1 else 0
        padded = text.ljust(56)[:56]

        # Send to both Logic Control (0x10) and Mackie Control Universal (0x14)
        for model_id in (0x10, 0x14):
            sysex = bytearray([0xF0, 0x00, 0x00, 0x66, model_id, 0x12, offset])
            sysex.extend(padded.encode('ascii', errors='replace'))
            sysex.append(0xF7)
            self.send_midi(bytes(sysex))

    def get_send_info(self, send_idx: int) -> dict:
        """Return prefix and display name for a send index."""
        if send_idx == 0:
            return {"prefix": "A1", "name": "AUX 1"}
        elif send_idx == 1:
            return {"prefix": "A2", "name": "AUX 2"}
        elif 2 <= send_idx <= 5:
            cue_num = send_idx - 1
            return {"prefix": f"C{cue_num}", "name": f"CUE {cue_num}"}
        return {"prefix": f"S{send_idx + 1}", "name": f"SEND {send_idx + 1}"}

    def get_available_send_modes(self) -> list:
        """Return list of active send modes: AUX 1, AUX 2, followed by CUE 1..N."""
        modes = [
            (0, "A1", "AUX 1"),
            (1, "A2", "AUX 2"),
        ]
        cue_count = getattr(self.uad, 'cue_bus_count', 4)
        for c in range(cue_count):
            s_idx = 2 + c
            modes.append((s_idx, f"C{c + 1}", f"CUE {c + 1}"))
        return modes

    def enable_meters(self):
        """Enable Mackie Control level meters (LCD & hardware LEDs)."""
        # 1. Global LCD Meter Mode & Channel Meter Mode for both 0x10 and 0x14
        for model_id in (0x10, 0x14):
            self.send_midi(bytes([0xF0, 0x00, 0x00, 0x66, model_id, 0x21, 0x01, 0xF7]))
            for slot in range(self.num_slots):
                self.send_midi(bytes([0xF0, 0x00, 0x00, 0x66, model_id, 0x20, slot, 0x03, 0xF7]))

    def send_flip_led(self, is_on: bool):
        """Update FLIP button LED (Note 50 / 0x32)."""
        self.send_midi(bytes([0x90, 50, 0x7F if is_on else 0x00]))

    def send_meter_level(self, slot: int, db: float, is_clip: bool = False):
        """Send real-time MCU Channel Pressure meter message (0xD0)."""
        if 0 <= slot < self.num_slots:
            val = db_to_mcu_meter(db, is_clip)
            # Channel Pressure: 0xD0, (slot << 4) | val
            self.send_midi(bytes([0xD0, (slot << 4) | val]))

    # --- Full Refresh & Banking ---

    def page_by(self, direction: int):
        """Move active bank in 8-channel pages (e.g. 1-8, 9-16, 17-24, 25-27)."""
        total_ch = len(self.uad.channels) if self.uad.channels else 25
        max_page_offset = max(0, ((total_ch - 1) // 8) * 8)
        if direction > 0:
            new_offset = min(max_page_offset, ((self.bank_offset // 8) + 1) * 8)
        else:
            new_offset = max(0, ((self.bank_offset - 1) // 8) * 8)

        if new_offset != self.bank_offset:
            self._cancel_all_sel_timers()
            self.bank_offset = new_offset
            for m in self.marquees:
                m.reset()
            print(f"[MCU] Page switched to channels {self.bank_offset + 1} - {min(self.bank_offset + 8, total_ch)}")
            self.refresh_all_slots()
            start_num = self.bank_offset + 1
            end_num = min(self.bank_offset + 8, total_ch)
            first_ch = self.uad.channels.get(self.bank_offset)
            last_ch = self.uad.channels.get(end_num - 1)
            first_name = first_ch.name.strip() if first_ch else ""
            last_name = last_ch.name.strip() if last_ch else ""
            if first_name and last_name:
                if first_name == last_name:
                    self.voice.speak_debounced(f"{first_name}", delay=0.25)
                else:
                    self.voice.speak_debounced(f"{first_name} through {last_name}", delay=0.25)
            elif first_name:
                self.voice.speak_debounced(f"{first_name}", delay=0.25)
            else:
                self.voice.speak_debounced(f"{start_num} through {end_num}", delay=0.25)
        else:
            if direction > 0:
                self.voice.speak_debounced("Last page", delay=0.25)
            else:
                self.voice.speak_debounced("First page", delay=0.25)

    def bank_by(self, delta: int):
        """Shift active bank by delta tracks (1-track steps)."""
        max_ch = max(self.uad.channels.keys()) if self.uad.channels else 25
        new_offset = max(0, min(max_ch, self.bank_offset + delta))
        if new_offset != self.bank_offset:
            self._cancel_all_sel_timers()
            self.bank_offset = new_offset
            for m in self.marquees:
                m.reset()
            print(f"[MCU] Bank shifted to channels {self.bank_offset + 1} - {min(self.bank_offset + 8, max_ch + 1)}")
            self.refresh_all_slots()
            start_num = self.bank_offset + 1
            end_num = min(self.bank_offset + 8, len(self.uad.channels) if self.uad.channels else self.bank_offset + 8)
            first_ch = self.uad.channels.get(self.bank_offset)
            last_ch = self.uad.channels.get(end_num - 1)
            first_name = first_ch.name.strip() if first_ch else ""
            last_name = last_ch.name.strip() if last_ch else ""
            if first_name and last_name:
                if first_name == last_name:
                    self.voice.speak_debounced(f"{first_name}", delay=0.25)
                else:
                    self.voice.speak_debounced(f"{first_name} through {last_name}", delay=0.25)
            elif first_name:
                self.voice.speak_debounced(f"{first_name}", delay=0.25)
            else:
                self.voice.speak_debounced(f"{start_num} through {end_num}", delay=0.25)
        else:
            if delta > 0:
                self.voice.speak_debounced("End of tracks", delay=0.25)
            else:
                self.voice.speak_debounced("Start of tracks", delay=0.25)

    def refresh_all_slots(self):
        """Synchronize all 8 physical faders, LEDs, and LCD rows with current bank & mode."""
        for slot in range(self.num_slots):
            ch_id = self.bank_offset + slot
            ch = self.uad.channels.get(ch_id)
            if ch:
                if self.active_send_idx is not None:
                    if getattr(ch, "ch_type", "input") == "aux" and self.active_send_idx < 2:
                        self.send_fader_position(slot, 0.0)
                        self.send_mute_led(slot, False)
                        self.send_solo_led(slot, False)
                        self.send_vpot_led_ring(slot, 0.0)
                    else:
                        send = ch.sends.get(self.active_send_idx)
                        gain = send.gain if send else 0.0
                        pan = send.pan if send else 0.0
                        byp = send.bypass if send else False
                        self.send_fader_position(slot, gain)
                        self.send_mute_led(slot, byp)
                        self.send_solo_led(slot, False)
                        self.send_vpot_led_ring(slot, pan)
                else:
                    self.send_fader_position(slot, ch.fader)
                    self.send_mute_led(slot, ch.mute)
                    self.send_solo_led(slot, ch.solo)
                    self.send_vpot_led_ring(slot, ch.pan)
            else:
                self.send_fader_position(slot, 0.0)
                self.send_mute_led(slot, False)
                self.send_solo_led(slot, False)
                self.send_vpot_led_ring(slot, 0.0)

        self.update_zero_mode_leds()
        self._update_lcd_row1()
        self._update_lcd_row2()

        # Update active bank in UAD client for targeted meter polling
        active_ids = [self.bank_offset + s for s in range(self.num_slots)]
        self.uad.set_active_bank(active_ids)
        self.enable_meters()

    def _marquee_loop(self):
        """Background thread updating marquee text at 4 Hz for slots with > 7 characters."""
        while self._running:
            time.sleep(0.25)
            if self.preamp_focus_mode:
                continue
            with self._lock:
                has_scrolling = any(len(m.current_text) > 7 for m in self.marquees)
                if has_scrolling:
                    for m in self.marquees:
                        m.tick()
                    self._update_lcd_row1()

    def _update_lcd_row1(self):
        """Format 7-character channel names across 8 channels with Marquee support for long text."""
        names = []
        for slot in range(self.num_slots):
            ch_id = self.bank_offset + slot
            ch = self.uad.channels.get(ch_id)
            if ch:
                if self.active_send_idx is not None:
                    # Send mode indicator: e.g. "A1:Apollo 1", "C1:Overhead Right"
                    info = self.get_send_info(self.active_send_idx)
                    full_name = f"{info['prefix']}:{ch.name.strip()}"
                else:
                    full_name = ch.name.strip()

                # If name is 8 chars with a space before a digit (e.g. "Apollo 1"),
                # compress to 7 chars ("Apollo1") so it fits and centers cleanly
                if len(full_name) == 8 and full_name[-2] == " " and full_name[-1].isdigit():
                    display_name = full_name[:-2] + full_name[-1]
                else:
                    display_name = full_name

                self.marquees[slot].update_text(display_name)
                names.append(self.marquees[slot].get_display_str())
            else:
                self.marquees[slot].update_text("")
                names.append("       ")
        row1 = "".join(names)
        if row1 != self._last_row1_text:
            self._last_row1_text = row1
            self.send_lcd_text(1, row1)

    def show_temp_hud(self, text: str, duration: float = 1.5):
        """Display a temporary centered HUD banner across Row 2."""
        with self._lock:
            self._hud_active = True
            padded = f"{text:^56}"[:56]
            self.send_lcd_text(2, padded)
            if self._hud_timer:
                try:
                    self._hud_timer.cancel()
                except Exception:
                    pass
            self._hud_timer = threading.Timer(duration, self._clear_hud)
            self._hud_timer.daemon = True
            self._hud_timer.start()

    def _clear_hud(self):
        """Restore row 2 values after temporary HUD banner expires."""
        with self._lock:
            self._hud_active = False
            self._last_row2_text = ""
            self._update_lcd_row2()

    def get_wheel_mode(self) -> str:
        """Check if wheel mode changed in config file or memory."""
        try:
            if os.path.exists(CONFIG_PATH):
                mtime = os.path.getmtime(CONFIG_PATH)
                if mtime != self._config_mtime:
                    self._config_mtime = mtime
                    self.wheel_mode = load_wheel_mode()
        except Exception:
            pass
        return self.wheel_mode

    def toggle_wheel_mode(self):
        """Toggle between Option 1 (1-track navigation) and Option 2 (Apollo Monitor volume)."""
        current = self.get_wheel_mode()
        if current == "channel":
            new_mode = "monitor"
            msg = ">>> WHEEL: APOLLO MONITOR VOL <<<"
            self.voice.speak("Channel wheel: Apollo Monitor Volume")
        else:
            new_mode = "channel"
            msg = ">>> WHEEL: TRACK NAV (1-CH) <<<"
            self.voice.speak("Channel wheel: Track Navigation")
        self.wheel_mode = new_mode
        save_wheel_mode(new_mode)
        try:
            self._config_mtime = os.path.getmtime(CONFIG_PATH)
        except Exception:
            pass
        print(f"[MCU] Toggled Wheel Mode -> {new_mode}")
        self.show_temp_hud(msg, duration=1.5)

    def _update_lcd_row2(self):
        """Format dB levels or status across 8 channels."""
        if self._hud_active:
            return  # Do not overwrite temporary HUD banner
        levels = []
        for slot in range(self.num_slots):
            ch_id = self.bank_offset + slot
            ch = self.uad.channels.get(ch_id)
            if ch:
                if self.active_send_idx is not None:
                    if getattr(ch, "ch_type", "input") == "aux" and self.active_send_idx < 2:
                        levels.append(f"{'---':^7}")
                    else:
                        send = ch.sends.get(self.active_send_idx)
                        if send and send.bypass:
                            levels.append(f"{'BYP':^7}")
                        else:
                            db_val = send.gain_db if send else -144.0
                            levels.append(format_db_7char(db_val))
                else:
                    if ch.mute:
                        levels.append(f"{'MUTE':^7}")
                    else:
                        db_val = getattr(ch, 'fader_db', None)
                        if db_val is None:
                            db_val = tapered_to_db(ch.fader)
                        levels.append(format_db_7char(db_val))
            else:
                levels.append(f"{'---':^7}")
        row2 = "".join(levels)
        if row2 != self._last_row2_text:
            self._last_row2_text = row2
            self.send_lcd_text(2, row2)

    # --- Event Callback from UAD Client ---

    def _on_uad_channel_change(self, event_type: str, ch_id: int, value):
        """Handle asynchronous state changes from Apollo Console."""
        if event_type in ("channel_list", "refresh_all"):
            if self.preamp_focus_mode:
                self.refresh_preamp_focus_surface()
            else:
                self.refresh_all_slots()
            return

        if event_type == "monitor":
            return

        # Preamp Focus Mode routing
        if self.preamp_focus_mode:
            if ch_id == self.preamp_focus_channel:
                if event_type in ("preamp", "preamp_prop", "unison", "unison_prop", "effect", "effect_prop", "fader", "fader_db", "mute", "solo", "pan", "name"):
                    self.refresh_preamp_focus_surface()
                elif event_type == "meter":
                    ch_obj = self.uad.channels.get(ch_id)
                    is_clip = ch_obj.meter_clip if ch_obj else False
                    self.send_meter_level(0, float(value), is_clip)
                    self.send_meter_level(6, float(value), is_clip)
            return

        slot = ch_id - self.bank_offset
        if not (0 <= slot < self.num_slots):
            return  # Changed channel is outside current visible bank

        if event_type == "fader":
            if self.active_send_idx is None:
                self.send_fader_position(slot, float(value))
                self._update_lcd_row2()
                if self.zero_mode_held or self.zero_mode_latched:
                    self.send_sel_led(slot, self.is_channel_at_zero(ch_id))
        elif event_type == "fader_db":
            if self.active_send_idx is None:
                self._update_lcd_row2()
                if self.zero_mode_held or self.zero_mode_latched:
                    self.send_sel_led(slot, self.is_channel_at_zero(ch_id))
        elif event_type == "send_gain":
            s_idx, s_gain, s_db = value
            if self.active_send_idx == s_idx:
                self.send_fader_position(slot, float(s_gain))
                self._update_lcd_row2()
        elif event_type == "send_pan":
            s_idx, s_pan = value
            if self.active_send_idx == s_idx:
                self.send_vpot_led_ring(slot, float(s_pan))
        elif event_type == "send_bypass":
            s_idx, s_byp = value
            if self.active_send_idx == s_idx:
                self.send_mute_led(slot, bool(s_byp))
                self._update_lcd_row2()
        elif event_type == "mute":
            if self.active_send_idx is None:
                self.send_mute_led(slot, bool(value))
                self._update_lcd_row2()
        elif event_type == "solo":
            if self.active_send_idx is None:
                self.send_solo_led(slot, bool(value))
        elif event_type == "pan":
            if self.active_send_idx is None:
                self.send_vpot_led_ring(slot, float(value))
        elif event_type == "name":
            self._update_lcd_row1()
        elif event_type == "meter":
            ch_obj = self.uad.channels.get(ch_id)
            is_clip = ch_obj.meter_clip if ch_obj else False
            self.send_meter_level(slot, float(value), is_clip)

    # --- Plugin & Preamp Mode (Supporting Unison Preamp & Regular Inserts) ---

    def clean_plugin_name(self, raw_name: str) -> str:
        """Clean plug-in name for display and voice synthesis."""
        if not raw_name or raw_name.strip() in ("", "None"):
            return ""
        name = raw_name.replace("Universal Audio ", "").replace("UAD ", "").replace("Legacy", "").strip()
        return name

    def format_channel_plugin_talkback(self, ch: Optional[UADChannel], prefix: str = "Plugin mode: ") -> str:
        """Generate talkback voice text according to channel capabilities."""
        if not ch:
            return f"{prefix}Unknown channel"
        ch_name = ch.name.strip()
        if ch.preamp.has_preamp:
            uni = ch.preamp.unison_plugin_name.strip()
            if uni and uni != "None":
                clean_uni = self.clean_plugin_name(uni)
                return f"{prefix}{ch_name}, Unison Preamp: {clean_uni}"
            else:
                return f"{prefix}{ch_name}, Unison Preamp"
        else:
            plugins = [
                self.clean_plugin_name(e.name)
                for e in sorted(ch.effects.values(), key=lambda x: x.index)
                if e.name and e.name.strip() and e.name != "None"
            ]
            if plugins:
                p_list = ", ".join(plugins[:2])
                return f"{prefix}{ch_name}, {p_list}"
            else:
                return f"{prefix}{ch_name}, no plugins"

    def get_plugin_channels(self) -> List[int]:
        """Return all valid input channels that can be inspected in Plugin Mode."""
        input_ids = [
            cid for cid, c in sorted(self.uad.channels.items())
            if c.ch_type == "input"
        ]
        if not input_ids:
            return list(range(min(8, len(self.uad.channels))))
        return input_ids

    def get_preamp_channels(self) -> List[int]:
        """Alias for get_plugin_channels."""
        return self.get_plugin_channels()

    def toggle_preamp_focus_mode(self, target_ch: Optional[int] = None):
        """Toggle Plugin Mode (with Unison Preamp & Insert Control)."""
        if self.preamp_focus_mode:
            self.preamp_focus_mode = False
            self.send_midi(bytes([0x90, 40, 0x00]))  # CHANNEL LED off
            self.send_midi(bytes([0x90, 43, 0x00]))  # PLUG-IN LED off
            for m in self.marquees:
                m.reset()
            self.refresh_all_slots()
            self.show_temp_hud(">>> EXIT PLUGIN MODE <<<", duration=1.2)
            self.voice.speak("Exiting plugin mode, Main mix")
            print("[MCU] Exited Plugin Mode -> Returned to Main Mix")
        else:
            # If in send mode, turn it off
            if self.active_send_idx is not None:
                self.active_send_idx = None
                self.send_flip_led(False)

            plugin_channels = self.get_plugin_channels()
            if not plugin_channels:
                self.voice.speak("No channels available for plugin mode")
                return

            if target_ch is not None and target_ch in plugin_channels:
                candidate = target_ch
            elif self.selected_slot is not None and (self.bank_offset + self.selected_slot) in plugin_channels:
                candidate = self.bank_offset + self.selected_slot
            elif self.bank_offset in plugin_channels:
                candidate = self.bank_offset
            else:
                candidate = plugin_channels[0]

            self.preamp_focus_mode = True
            self.preamp_focus_channel = candidate
            self._48v_arm_time = 0.0

            # Light up CHANNEL & PLUG-IN LEDs
            self.send_midi(bytes([0x90, 40, 0x7F]))
            self.send_midi(bytes([0x90, 43, 0x7F]))

            ch = self.uad.channels.get(candidate)
            ch_name = ch.name.strip() if ch else f"Channel {candidate + 1}"
            hud_title = "UNISON PREAMP" if (ch and ch.preamp.has_preamp) else "PLUGIN MODE"
            self.show_temp_hud(f">>> {hud_title}: {ch_name.upper()} <<<", duration=1.5)
            self.voice.speak(self.format_channel_plugin_talkback(ch, prefix="Plugin mode: "))
            print(f"[MCU] Entered Plugin Mode on channel {candidate} ({ch_name})")
            self.refresh_preamp_focus_surface()

    def toggle_plugin_mode(self, target_ch: Optional[int] = None):
        """Semantic alias for toggle_preamp_focus_mode."""
        self.toggle_preamp_focus_mode(target_ch)

    def step_preamp_channel(self, delta: int):
        """Step to previous or next channel in Plugin Mode."""
        plugin_channels = self.get_plugin_channels()
        if not plugin_channels:
            return
        try:
            curr_idx = plugin_channels.index(self.preamp_focus_channel)
        except ValueError:
            curr_idx = 0

        new_idx = max(0, min(len(plugin_channels) - 1, curr_idx + delta))
        if new_idx != curr_idx:
            self.preamp_focus_channel = plugin_channels[new_idx]
            self._48v_arm_time = 0.0
            ch = self.uad.channels.get(self.preamp_focus_channel)
            ch_name = ch.name.strip() if ch else f"Channel {self.preamp_focus_channel + 1}"
            hud_title = "UNISON" if (ch and ch.preamp.has_preamp) else "PLUGIN"
            self.show_temp_hud(f">>> {hud_title}: {ch_name.upper()} <<<", duration=1.2)
            self.voice.speak_debounced(self.format_channel_plugin_talkback(ch, prefix="Focused on "), delay=0.25)
            self.refresh_preamp_focus_surface()
        else:
            if delta > 0:
                self.voice.speak_debounced("Last channel", delay=0.25)
            else:
                self.voice.speak_debounced("First channel", delay=0.25)

    def refresh_preamp_focus_surface(self):
        """Update all 8 physical motorized faders, LEDs, V-Pots, and LCD scribble strips for Plugin / Preamp Mode."""
        ch = self.uad.channels.get(self.preamp_focus_channel)
        if not ch:
            return
        pre = ch.preamp

        if pre.has_preamp:
            # --- Hardware Analog Preamp & Unison Preamp Channel (e.g. Apollo 1, Apollo 2) ---
            # Slot 0: Preamp Gain
            self.send_fader_position(0, pre.gain_tapered)
            self.send_mute_led(0, ch.mute)
            self.send_solo_led(0, ch.solo)
            self.send_sel_led(0, False)
            gain_vpot = int(max(1, min(11, pre.gain_tapered * 10 + 1)))
            self.send_midi(bytes([0xB0, 48, gain_vpot]))

            # Slot 1: +48V Phantom Power
            self.send_fader_position(1, 1.0 if pre.phantom_48v else 0.0)
            self.send_mute_led(1, pre.phantom_48v)
            self.send_solo_led(1, False)
            self.send_sel_led(1, pre.phantom_48v)
            self.send_midi(bytes([0xB0, 49, 11 if pre.phantom_48v else 1]))

            # Slot 2: -20 dB Pad
            self.send_fader_position(2, 1.0 if pre.pad else 0.0)
            self.send_mute_led(2, pre.pad)
            self.send_solo_led(2, False)
            self.send_sel_led(2, pre.pad)
            self.send_midi(bytes([0xB0, 50, 11 if pre.pad else 1]))

            # Slot 3: High Pass / Low Cut 75 Hz
            self.send_fader_position(3, 1.0 if pre.low_cut else 0.0)
            self.send_mute_led(3, pre.low_cut)
            self.send_solo_led(3, False)
            self.send_sel_led(3, pre.low_cut)
            self.send_midi(bytes([0xB0, 51, 11 if pre.low_cut else 1]))

            # Slot 4: Phase Invert (Ø)
            self.send_fader_position(4, 1.0 if pre.phase else 0.0)
            self.send_mute_led(4, pre.phase)
            self.send_solo_led(4, False)
            self.send_sel_led(4, pre.phase)
            self.send_midi(bytes([0xB0, 52, 11 if pre.phase else 1]))

            # Slot 5: Input Source (Mic vs Line vs Hi-Z)
            src_fader = 0.5 if pre.hiz else (1.0 if pre.iotype == "Line" else 0.0)
            self.send_fader_position(5, src_fader)
            self.send_mute_led(5, pre.iotype == "Line")
            self.send_solo_led(5, False)
            self.send_sel_led(5, pre.hiz)
            self.send_midi(bytes([0xB0, 53, 11 if pre.iotype == "Line" else 1]))

            # Slot 6: Output Fader Level & Pan
            self.send_fader_position(6, ch.fader)
            self.send_mute_led(6, ch.mute)
            self.send_solo_led(6, ch.solo)
            self.send_sel_led(6, False)
            pan_pos = int((ch.pan + 1.0) / 2.0 * 10.0) + 1
            self.send_midi(bytes([0xB0, 54, max(1, min(11, pan_pos))]))

            # Slot 7: Unison Plug-in
            has_unison = bool(pre.unison_plugin_name and pre.unison_plugin_name.strip() and pre.unison_plugin_name != "None")
            self.send_fader_position(7, 1.0 if (has_unison and pre.unison_power) else 0.0)
            self.send_mute_led(7, has_unison and not pre.unison_power)
            self.send_solo_led(7, False)
            self.send_sel_led(7, has_unison and pre.unison_power)
            self.send_midi(bytes([0xB0, 55, 11 if (has_unison and pre.unison_power) else 1]))

            # Row 1 (Parameter Labels)
            if has_unison:
                p_clean = self.clean_plugin_name(pre.unison_plugin_name)
                p_label = f"{p_clean[:7]:^7}"
            else:
                p_label = "UNISON "

            row1_slots = [
                " PREAMP",  # Slot 0
                "+48V   ",  # Slot 1
                "  PAD  ",  # Slot 2
                "LOWCUT ",  # Slot 3
                " PHASE ",  # Slot 4
                " SOURCE",  # Slot 5
                " OUTPUT",  # Slot 6
                p_label,    # Slot 7
            ]

            # Row 2 (Values & States)
            if pre.custom_text and len(pre.custom_text.strip()) > 0 and pre.custom_text.strip() != "---":
                gain_disp = f"{pre.custom_text.strip()[:7]:^7}"
            else:
                gain_disp = f"{pre.gain:+.1f}dB"

            val_48v = "+48V ON" if pre.phantom_48v else "  OFF  "
            val_pad = "-20 dB " if pre.pad else "  OFF  "
            val_lc  = " 75 Hz " if pre.low_cut else "  OFF  "
            val_ph  = "INVERT " if pre.phase else "NORMAL "
            val_src = " HI-Z  " if pre.hiz else f"{pre.iotype.upper():^7}"
            val_out = format_db_7char(ch.fader_db)
            if not has_unison:
                val_uni = " EMPTY "
            else:
                val_uni = " ACTIVE" if pre.unison_power else "BYPASS "

            row2_slots = [
                gain_disp,  # Slot 0
                val_48v,    # Slot 1
                val_pad,    # Slot 2
                val_lc,     # Slot 3
                val_ph,     # Slot 4
                val_src,    # Slot 5
                val_out,    # Slot 6
                val_uni,    # Slot 7
            ]

        else:
            # --- Regular Tracking / ADAT Channel (e.g. Neve1, Neve2, OH-HH, etc.) ---
            # Slots 0 to 5: Inserts 1 to 6
            row1_slots = []
            row2_slots = []
            for i in range(6):
                eff = ch.effects.get(i)
                has_fx = bool(eff and eff.name and eff.name.strip() and eff.name != "None")
                is_on = eff.power if has_fx else False

                self.send_fader_position(i, 1.0 if (has_fx and is_on) else 0.0)
                self.send_mute_led(i, has_fx and not is_on)
                self.send_solo_led(i, False)
                self.send_sel_led(i, has_fx and is_on)
                self.send_midi(bytes([0xB0, 48 + i, 11 if (has_fx and is_on) else 1]))

                if has_fx:
                    p_clean = self.clean_plugin_name(eff.name)
                    row1_slots.append(f"{p_clean[:7]:^7}")
                    row2_slots.append(" ACTIVE" if is_on else "BYPASS ")
                else:
                    row1_slots.append(f" INS {i+1} ")
                    row2_slots.append(" EMPTY ")

            # Slot 6: Output Channel Fader & Pan
            self.send_fader_position(6, ch.fader)
            self.send_mute_led(6, ch.mute)
            self.send_solo_led(6, ch.solo)
            self.send_sel_led(6, False)
            pan_pos = int((ch.pan + 1.0) / 2.0 * 10.0) + 1
            self.send_midi(bytes([0xB0, 54, max(1, min(11, pan_pos))]))
            row1_slots.append(" OUTPUT")
            row2_slots.append(format_db_7char(ch.fader_db))

            # Slot 7: All Insert Bypass Toggle
            has_any_fx = any(bool(e.name and e.name.strip() and e.name != "None") for e in ch.effects.values())
            any_on = any(e.power for e in ch.effects.values() if e.name and e.name.strip() and e.name != "None")
            self.send_fader_position(7, 1.0 if any_on else 0.0)
            self.send_mute_led(7, has_any_fx and not any_on)
            self.send_solo_led(7, False)
            self.send_sel_led(7, any_on)
            self.send_midi(bytes([0xB0, 55, 11 if any_on else 1]))
            row1_slots.append("ALL FX ")
            if not has_any_fx:
                row2_slots.append(" EMPTY ")
            else:
                row2_slots.append(" ACTIVE" if any_on else "BYPASS ")

        row1_text = "".join(f"{s:^7}"[:7] for s in row1_slots)
        if row1_text != self._last_row1_text:
            self._last_row1_text = row1_text
            self.send_lcd_text(1, row1_text)

        row2_text = "".join(f"{v:^7}"[:7] for v in row2_slots)
        if row2_text != self._last_row2_text and not self._hud_active:
            self._last_row2_text = row2_text
            self.send_lcd_text(2, row2_text)

    def _handle_preamp_fader(self, slot: int, tapered: float):
        """Handle physical fader movements in Plugin / Preamp Mode."""
        ch = self.uad.channels.get(self.preamp_focus_channel)
        if not ch:
            return
        pre = ch.preamp

        if pre.has_preamp:
            if slot == 0:
                # Motorized Preamp Gain (+10 to +65 dB)
                self.uad.set_preamp_gain(self.preamp_focus_channel, tapered)
                gain_db = 10.0 + (tapered * 55.0)
                pre.gain = gain_db
                self.refresh_preamp_focus_surface()
                self.voice.speak_debounced(f"Preamp gain {gain_db:.1f} d B", delay=0.35)

            elif slot == 6:
                # Output Channel Level
                self.uad.set_fader(self.preamp_focus_channel, tapered)
                ch.fader_db = tapered_to_db(tapered)
                self.refresh_preamp_focus_surface()
                self.voice.speak_debounced(f"Output {format_db_speech(ch.fader_db)}", delay=0.35)
        else:
            # Regular tracking channel
            if 0 <= slot <= 5:
                eff = ch.effects.get(slot)
                if eff and eff.name and eff.name.strip() and eff.name != "None":
                    new_pow = tapered > 0.5
                    if new_pow != eff.power:
                        self.uad.set_effect_power(self.preamp_focus_channel, slot, new_pow)
                        self.refresh_preamp_focus_surface()
                        p_name = self.clean_plugin_name(eff.name)
                        self.voice.speak_debounced(f"{p_name} {'active' if new_pow else 'bypassed'}", delay=0.35)
            elif slot == 6:
                self.uad.set_fader(self.preamp_focus_channel, tapered)
                ch.fader_db = tapered_to_db(tapered)
                self.refresh_preamp_focus_surface()
                self.voice.speak_debounced(f"Output {format_db_speech(ch.fader_db)}", delay=0.35)
            elif slot == 7:
                new_pow = tapered > 0.5
                self.uad.set_all_effects_power(self.preamp_focus_channel, new_pow)
                self.refresh_preamp_focus_surface()
                self.voice.speak_debounced(f"All plugins {'active' if new_pow else 'bypassed'}", delay=0.35)

    def _handle_preamp_vpot(self, slot: int, delta: int):
        """Handle rotary V-Pot turns in Plugin / Preamp Mode."""
        ch = self.uad.channels.get(self.preamp_focus_channel)
        if not ch:
            return
        pre = ch.preamp

        if pre.has_preamp:
            if slot == 0:
                # V-Pot 0: Fine Preamp Gain Trim (+/- 1 dB)
                new_db = self.uad.nudge_preamp_gain_db(self.preamp_focus_channel, float(delta * 1.0))
                self.refresh_preamp_focus_surface()
                self.voice.speak_debounced(f"Preamp gain {new_db:.1f} d B", delay=0.35)

            elif slot == 5:
                # V-Pot 5: Toggle Mic/Line source
                if not pre.hiz:
                    new_type = "Line" if delta > 0 else "Mic"
                    self.uad.set_preamp_iotype(self.preamp_focus_channel, new_type)
                    self.refresh_preamp_focus_surface()
                    self.voice.speak_debounced(f"Input source {new_type}", delay=0.35)

            elif slot == 6:
                # V-Pot 6: Output Channel Pan
                new_pan = max(-1.0, min(1.0, ch.pan + (delta * 0.02)))
                self.uad.set_pan(self.preamp_focus_channel, new_pan)
                self.send_vpot_led_ring(6, new_pan)
        else:
            if 0 <= slot <= 5:
                eff = ch.effects.get(slot)
                if eff and eff.name and eff.name.strip() and eff.name != "None":
                    new_pow = delta > 0
                    if new_pow != eff.power:
                        self.uad.set_effect_power(self.preamp_focus_channel, slot, new_pow)
                        self.refresh_preamp_focus_surface()
                        p_name = self.clean_plugin_name(eff.name)
                        self.voice.speak_debounced(f"{p_name} {'active' if new_pow else 'bypassed'}", delay=0.35)
            elif slot == 6:
                new_pan = max(-1.0, min(1.0, ch.pan + (delta * 0.02)))
                self.uad.set_pan(self.preamp_focus_channel, new_pan)
                self.send_vpot_led_ring(6, new_pan)

    def _handle_preamp_note(self, note: int, is_down: bool):
        """Handle MCU buttons when in Plugin / Preamp Mode."""
        if not is_down:
            return

        ch = self.uad.channels.get(self.preamp_focus_channel)
        if not ch:
            return
        pre = ch.preamp

        # Hardware Navigation: Bank L/R (46/47, 98/99), Page L/R (48/49, 44/45, 104/105)
        # Nudges plugin focus channel across all input channels!
        is_wheel_rotation = self._wheel_strobe_active or (time.time() - self._last_wheel_strobe < 0.20)
        if (is_wheel_rotation and note in (46, 47, 48, 49)) or note in (46, 47, 48, 49, 44, 45, 98, 99, 104, 105):
            direction = -1 if note in (46, 48, 44, 98, 104) else 1
            self.step_preamp_channel(direction)
            return

        # V-Pot Push: 0x20..0x27 (32..39)
        if 32 <= note <= 39:
            slot = note - 32
            if pre.has_preamp:
                if slot == 0:
                    self.uad.set_preamp_gain_db(self.preamp_focus_channel, 10.0)
                    self.refresh_preamp_focus_surface()
                    self.voice.speak("Preamp gain reset to 10 d B")
                elif slot == 6:
                    self.uad.set_pan(self.preamp_focus_channel, 0.0)
                    self.send_vpot_led_ring(6, 0.0)
                    self.voice.speak("Output pan centered")
            else:
                if 0 <= slot <= 5:
                    eff = ch.effects.get(slot)
                    if eff and eff.name and eff.name.strip() and eff.name != "None":
                        new_pow = self.uad.toggle_effect_power(self.preamp_focus_channel, slot)
                        self.refresh_preamp_focus_surface()
                        p_name = self.clean_plugin_name(eff.name)
                        self.voice.speak(f"{p_name} {'active' if new_pow else 'bypassed'}")
                elif slot == 6:
                    self.uad.set_pan(self.preamp_focus_channel, 0.0)
                    self.send_vpot_led_ring(6, 0.0)
                    self.voice.speak("Output pan centered")
                elif slot == 7:
                    new_pow = self.uad.toggle_all_effects_power(self.preamp_focus_channel)
                    self.refresh_preamp_focus_surface()
                    self.voice.speak(f"All plugins {'active' if new_pow else 'bypassed'}")
            return

        # Mute Buttons: 0x10..0x17 (16..23)
        # SEL Buttons: 0x18..0x1F (24..31)
        slot = None
        if 16 <= note <= 23:
            slot = note - 16
        elif 24 <= note <= 31:
            slot = note - 24

        if slot is not None:
            if pre.has_preamp:
                if slot == 0:
                    if 16 <= note <= 23:
                        new_mute = not ch.mute
                        self.uad.set_mute(self.preamp_focus_channel, new_mute)
                        self.send_mute_led(0, new_mute)
                        self.voice.speak(f"{ch.name.strip()} {'muted' if new_mute else 'unmuted'}")
                    else:
                        self.uad.set_preamp_gain_db(self.preamp_focus_channel, 10.0)
                        self.refresh_preamp_focus_surface()
                        self.voice.speak("Preamp gain reset to 10 d B")
                    return

                elif slot == 1:
                    # Slot 1: +48V Phantom Power with Safety Double-Tap Interlock
                    now = time.time()
                    if not pre.phantom_48v:
                        if now - self._48v_arm_time < 0.85:
                            self.uad.set_preamp_48v(self.preamp_focus_channel, True)
                            self._48v_arm_time = 0.0
                            self.voice.speak("Plus 48 volts enabled")
                            self.refresh_preamp_focus_surface()
                        else:
                            self._48v_arm_time = now
                            self.voice.speak("Press again to confirm 48 volt phantom power")
                    else:
                        self.uad.set_preamp_48v(self.preamp_focus_channel, False)
                        self._48v_arm_time = 0.0
                        self.voice.speak("Plus 48 volts off")
                        self.refresh_preamp_focus_surface()
                    return

                elif slot == 2:
                    # Slot 2: -20 dB Pad
                    new_pad = self.uad.toggle_preamp_pad(self.preamp_focus_channel)
                    self.voice.speak("Pad minus 20 d B on" if new_pad else "Pad off")
                    self.refresh_preamp_focus_surface()
                    return

                elif slot == 3:
                    # Slot 3: Low Cut (75 Hz)
                    new_lc = self.uad.toggle_preamp_lowcut(self.preamp_focus_channel)
                    self.voice.speak("Low cut filter 75 Hertz on" if new_lc else "Low cut off")
                    self.refresh_preamp_focus_surface()
                    return

                elif slot == 4:
                    # Slot 4: Phase Invert (Ø)
                    new_ph = self.uad.toggle_preamp_phase(self.preamp_focus_channel)
                    self.voice.speak("Phase inverted" if new_ph else "Phase normal")
                    self.refresh_preamp_focus_surface()
                    return

                elif slot == 5:
                    # Slot 5: Input Source (Mic vs Line vs Hi-Z)
                    if pre.hiz:
                        self.voice.speak("Hi-Z instrument input locked by front panel jack")
                    else:
                        new_src = self.uad.toggle_preamp_iotype(self.preamp_focus_channel)
                        self.voice.speak(f"Input source {new_src}")
                        self.refresh_preamp_focus_surface()
                    return

                elif slot == 6:
                    # Slot 6: Output Channel Level & Pan
                    if 16 <= note <= 23:
                        new_mute = not ch.mute
                        self.uad.set_mute(self.preamp_focus_channel, new_mute)
                        self.send_mute_led(6, new_mute)
                        self.voice.speak(f"{ch.name.strip()} {'muted' if new_mute else 'unmuted'}")
                    else:
                        self.uad.set_fader(self.preamp_focus_channel, 0.7818182)
                        self.send_fader_position(6, 0.7818182)
                        self.refresh_preamp_focus_surface()
                        self.voice.speak("Output reset to zero dB")
                    return

                elif slot == 7:
                    # Slot 7: Unison Plug-in Power / Bypass
                    if not pre.unison_plugin_name or pre.unison_plugin_name.strip() in ("", "None"):
                        self.voice.speak("No Unison plugin inserted")
                    else:
                        new_pow = self.uad.toggle_unison_power(self.preamp_focus_channel)
                        st = "active" if new_pow else "bypassed"
                        clean_u = self.clean_plugin_name(pre.unison_plugin_name)
                        self.voice.speak(f"Unison {clean_u} {st}")
                        self.refresh_preamp_focus_surface()
                    return
            else:
                # --- Regular Tracking / ADAT Channel (e.g. Neve1, Neve2, OH-HH) ---
                if 0 <= slot <= 5:
                    eff = ch.effects.get(slot)
                    if not eff or not eff.name or eff.name.strip() in ("", "None"):
                        self.voice.speak(f"Insert {slot + 1} empty")
                        return

                    clean_p = self.clean_plugin_name(eff.name)
                    if 16 <= note <= 23:
                        # Mute Button -> Toggle insert bypass
                        new_pow = self.uad.toggle_effect_power(self.preamp_focus_channel, slot)
                        self.refresh_preamp_focus_surface()
                        self.voice.speak(f"{clean_p} {'active' if new_pow else 'bypassed'}")
                    else:
                        # SEL Button -> Announce status
                        st = "active" if eff.power else "bypassed"
                        self.voice.speak(f"Insert {slot + 1}: {clean_p}, {st}")
                    return

                elif slot == 6:
                    if 16 <= note <= 23:
                        new_mute = not ch.mute
                        self.uad.set_mute(self.preamp_focus_channel, new_mute)
                        self.send_mute_led(6, new_mute)
                        self.voice.speak(f"{ch.name.strip()} {'muted' if new_mute else 'unmuted'}")
                    else:
                        self.uad.set_fader(self.preamp_focus_channel, 0.7818182)
                        self.send_fader_position(6, 0.7818182)
                        self.refresh_preamp_focus_surface()
                        self.voice.speak("Output reset to zero dB")
                    return

                elif slot == 7:
                    # Slot 7: All Insert Bypass Toggle
                    new_pow = self.uad.toggle_all_effects_power(self.preamp_focus_channel)
                    self.refresh_preamp_focus_surface()
                    self.voice.speak(f"All plugins {'active' if new_pow else 'bypassed'}")
                    return

        # Solo Buttons: 0x08..0x0F (8..15)
        if 8 <= note <= 15:
            slot = note - 8
            if slot in (0, 6):
                new_solo = not ch.solo
                self.uad.set_solo(self.preamp_focus_channel, new_solo)
                self.send_solo_led(slot, new_solo)
                self.voice.speak(f"{ch.name.strip()} {'solo on' if new_solo else 'solo off'}")
            return
