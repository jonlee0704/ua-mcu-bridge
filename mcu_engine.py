"""
Mackie Control Universal (MCU) Protocol Engine for SSL UF8
Translates bidirectional MIDI messages (14-bit faders, V-Pots, Mutes, Solos, LCD SysEx)
between SSL UF8 and UAD Apollo Console.
"""

import json
import math
import os
import subprocess
import threading
import time
from typing import Callable, Dict, List, Optional
from uad_client import UADClient, UADChannel, UADSend
from uad_curve import tapered_to_db, db_to_tapered, format_db_7char

CONFIG_PATH = os.path.expanduser("~/.uamcu_config.json")


def load_wheel_mode() -> str:
    """Read wheel mode preference: 'channel' (Option 1) or 'monitor' (Option 2)."""
    try:
        if os.path.exists(CONFIG_PATH):
            with open(CONFIG_PATH, "r") as f:
                cfg = json.load(f)
                return cfg.get("wheel_mode", "channel")
    except Exception:
        pass
    return "channel"


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
        return "minus infinity dB"
    if abs(db) < 0.1:
        return "zero dB"
    if db > 0:
        return f"plus {db:.1f} dB"
    return f"{db:.1f} dB"


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

    def is_enabled(self) -> bool:
        return load_speech_mode()

    def speak(self, text: str, interrupt: bool = True):
        """Speak the given text if voice guidance is enabled. Non-blocking."""
        if not self.is_enabled() or not text:
            return

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
        self.send_flip_led(False)

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

                    target_channel = self.bank_offset + ch
                    if self.active_send_idx is not None:
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
                info = self.get_send_info(self.active_send_idx)
                print(f"[MCU] V-Pot Push: Reset channel {target_ch + 1} {info['name']} Pan to Center")
                self.uad.set_send_pan(target_ch, self.active_send_idx, 0.0)
                self.voice.speak(f"{ch_name} {info['name']} pan centered")
            else:
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
        # Physical Buttons on SSL UF8:
        # Notes: 44 (< PAGE), 45 (PAGE >), 46 (< BANK), 47 (BANK >), 48 (< CHANNEL), 49 (CHANNEL >)
        # Note 83 is the physical wheel encoder touch/strobe indicator on SSL UF8.
        is_wheel_rotation = self._wheel_strobe_active or (time.time() - self._last_wheel_strobe < 0.15)

        # 1. Rotary Wheel turned via Notes 48/49 (when SSL 360 wheel is in Nav emulation mode)
        if is_wheel_rotation and note in (48, 49):
            direction = -1 if note == 48 else 1
            mode = self.get_wheel_mode()
            if mode == "monitor":
                if self.uad.nudge_monitor_db(direction * 1.0):
                    disp_str = f"MONITOR: {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "MONITOR: MUTED"
                    self.show_temp_hud(f">>> {disp_str} <<<", duration=1.2)
                    spk_str = f"Monitor {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "Monitor Muted"
                    self.voice.speak_debounced(spk_str, delay=0.35)
                return
            else:
                self.bank_by(direction)
                return

        # 2. Dedicated Hardware Navigation Buttons on SSL UF8:
        # < CHANNEL > buttons (Notes 48, 49) always shift bank by 1 track
        if note == 48:
            self.bank_by(-1)
            return
        if note == 49:
            self.bank_by(1)
            return

        # < PAGE > (Notes 44, 45) and < BANK > (Notes 46, 47) always shift bank by 8 tracks
        if note in (46, 44):
            self.bank_by(-8)
            return
        if note in (47, 45):
            self.bank_by(8)
            return

        # FLIP Button: 0x32 (50) -> Toggle Sends on Faders (NORMAL -> AUX 1 -> AUX 2 -> CUE 1..N -> NORMAL)
        if note == 50:
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
            spk_mode = mode_name.replace(" (SENDS ON FADERS)", " sends on faders").replace(" (NORMAL)", "")
            self.voice.speak(f"Active mode: {spk_mode}")
            for m in self.marquees:
                m.reset()
            self.send_flip_led(self.active_send_idx is not None)
            self.refresh_all_slots()
            return

    def _handle_cc(self, cc: int, val: int):
        """Handle Rotary V-Pots (CC 16..23) and Channel Rotary Wheel (CC 60)."""
        if 16 <= cc <= 23:
            slot = cc - 16
            target_ch = self.bank_offset + slot
            # Relative 2's complement: 0x01..0x3F is positive, 0x41..0x7F is negative
            if val & 0x40:
                delta = -(val & 0x3F)
            else:
                delta = val & 0x3F

            ch_obj = self.uad.channels.get(target_ch)
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
                if self.uad.nudge_monitor_db(delta * 1.0):
                    disp_str = f"MONITOR: {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "MONITOR: MUTED"
                    self.show_temp_hud(f">>> {disp_str} <<<", duration=1.2)
                    spk_str = f"Monitor {self.uad.monitor_level_db:+.1f} dB" if not self.uad.monitor_mute else "Monitor Muted"
                    self.voice.speak_debounced(spk_str, delay=0.35)
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
                ch_name = ch.name.strip()
                if self.active_send_idx is not None:
                    info = self.get_send_info(self.active_send_idx)
                    send = ch.sends.get(self.active_send_idx)
                    gain_db = send.gain_db if send else -144.0
                    pan = send.pan if send else 0.0
                    byp = send.bypass if send else False
                    byp_str = ", bypassed" if byp else ""
                    self.voice.speak(f"{info['name']}, Channel {ch_id + 1}, {ch_name}, {format_db_speech(gain_db)}, {format_pan_speech(pan)}{byp_str}")
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
                    self.voice.speak(f"Channel {ch_id + 1}, {ch_name}, {format_db_speech(db_val)}, {format_pan_speech(ch.pan)}{stat_str}")

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

    def bank_by(self, delta: int):
        """Shift active 8-channel bank."""
        max_ch = max(self.uad.channels.keys()) if self.uad.channels else 25
        new_offset = max(0, min(max_ch - 7, self.bank_offset + delta))
        if new_offset != self.bank_offset:
            self._cancel_all_sel_timers()
            self.bank_offset = new_offset
            for m in self.marquees:
                m.reset()
            print(f"[MCU] Bank switched to channels {self.bank_offset + 1} - {self.bank_offset + 8}")
            self.refresh_all_slots()
            start_num = self.bank_offset + 1
            end_num = min(self.bank_offset + 8, len(self.uad.channels) if self.uad.channels else self.bank_offset + 8)
            first_ch = self.uad.channels.get(self.bank_offset)
            last_ch = self.uad.channels.get(end_num - 1)
            first_name = first_ch.name.strip() if first_ch else ""
            last_name = last_ch.name.strip() if last_ch else ""
            if first_name and last_name:
                self.voice.speak_debounced(f"Bank channels {start_num} to {end_num}, {first_name} through {last_name}", delay=0.25)
            else:
                self.voice.speak_debounced(f"Bank channels {start_num} to {end_num}", delay=0.25)

    def refresh_all_slots(self):
        """Synchronize all 8 physical faders, LEDs, and LCD rows with current bank & mode."""
        for slot in range(self.num_slots):
            ch_id = self.bank_offset + slot
            ch = self.uad.channels.get(ch_id)
            if ch:
                if self.active_send_idx is not None:
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
        if event_type == "channel_list":
            self.refresh_all_slots()
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
