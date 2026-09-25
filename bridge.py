#!/usr/bin/env python3
"""
Tactile Hardware Accessibility Bridge for UAD Apollo using SSL UF8
Connects SSL UF8 (via Mackie Control Universal protocol) to UAD Console (raw TCP 127.0.0.1:4710)
Creator: S&D A11y Solutions (snda11ysolutions@gmail.com)
Date: September 24, 2026
License & Terms: See TERMS_OF_SERVICE.md and LICENSE
"""

import argparse
import os
import signal
import sys
import time

from coremidi_adapter import CoreMIDIAdapter, list_destinations, list_sources
from mcu_engine import MCUEngine, format_db_7char, pan_to_str, tapered_to_db
from uad_client import UADClient


def render_dashboard(engine: MCUEngine, uad: UADClient, midi: CoreMIDIAdapter, port_num: int):
    """Render a dynamic live status table in the terminal."""
    # Move cursor home and clear
    sys.stdout.write("\033[H\033[J")

    print("================================================================================")
    print("    TACTILE HARDWARE ACCESSIBILITY BRIDGE: SSL UF8 <---> UAD APOLLO CONSOLE    ")
    print("================================================================================")
    midi_stat = f"\033[92mONLINE (SSL V-MIDI Port {port_num})\033[0m" if midi.is_connected else "\033[91mDISCONNECTED\033[0m"
    uad_stat = "\033[92mONLINE (127.0.0.1:4710)\033[0m" if uad.is_connected else "\033[91mDISCONNECTED\033[0m"
    total_ch = len(uad.channels)
    bank_start = engine.bank_offset + 1
    bank_end = min(total_ch, engine.bank_offset + 8) if total_ch > 0 else engine.bank_offset + 8

    if engine.preamp_focus_mode:
        f_ch = uad.channels.get(engine.preamp_focus_channel)
        f_name = f_ch.name.strip() if f_ch else f"Channel {engine.preamp_focus_channel + 1}"
        f_uni = f" [{f_ch.preamp.unison_plugin_name}]" if f_ch and f_ch.preamp.unison_plugin_name else ""
        mode_label = f"\033[92mPREAMP FOCUS: {f_name}{f_uni}\033[0m"
    elif engine.active_send_idx is None:
        mode_label = "\033[96mMAIN MIX (Volumes)\033[0m"
    else:
        info = engine.get_send_info(engine.active_send_idx)
        color = "\033[93m" if "AUX" in info['name'] else "\033[95m"
        mode_label = f"{color}{info['name']} (Sends on Faders)\033[0m"

    wheel_mode = getattr(engine, 'wheel_mode', 'monitor')
    wheel_label = "\033[95mMonitor Vol\033[0m" if wheel_mode == "monitor" else "\033[92mTrack Nav (1-CH)\033[0m"
    voice_label = "\033[92mON (Speech)\033[0m" if getattr(engine, 'voice', None) and engine.voice.is_enabled() else "\033[90mOFF\033[0m"

    print(f" CoreMIDI: {midi_stat:<35} | UAD Mixer: {uad_stat}")
    print(f" Active Bank: Channels {bank_start} - {bank_end} (Total: {total_ch}) | Mode: {mode_label} | Wheel: {wheel_label} | Voice: {voice_label}")
    print("-----------------------------------------------------------------------------------------")

    if engine.preamp_focus_mode:
        f_ch = uad.channels.get(engine.preamp_focus_channel)
        pre = f_ch.preamp if f_ch else None
        print(" Slot | Parameter Name  | Control / State  | Hardware Value  | Description / Accessibility Action   ")
        print("------+-----------------+------------------+-----------------+--------------------------------------")
        if f_ch and pre:
            p_slots = [
                ("1", "Preamp Gain", f"[{('#' * int(pre.gain_tapered * 12)).ljust(12)}]", f"{pre.gain:+.1f} dB", "Motorized Fader 1 / V-Pot Fine Trim (+10 to +65 dB)"),
                ("2", "+48V Phantom", "\033[91m [ ACTIVE ] \033[0m" if pre.phantom_48v else " [  OFF   ] ", "+48V ON" if pre.phantom_48v else "OFF", "Safety Double-Tap to enable / Immediate single tap off"),
                ("3", "-20 dB Pad", "\033[91m [ ENGAGED] \033[0m" if pre.pad else " [  OFF   ] ", "-20 dB" if pre.pad else "OFF", "Toggle -20 dB input attenuation pad"),
                ("4", "Low Cut Filter", "\033[93m [ 75 Hz  ] \033[0m" if pre.low_cut else " [  OFF   ] ", "75 Hz" if pre.low_cut else "OFF", "High-Pass Low-Cut 75 Hz filter toggle"),
                ("5", "Phase Invert", "\033[95m [ INVERT ] \033[0m" if pre.phase else " [ NORMAL ] ", "INVERT" if pre.phase else "NORMAL", "Phase polarity invert (Ø) toggle"),
                ("6", "Input Source", f" [ {pre.iotype.upper():^6} ] ", pre.iotype, "Mic / Line input source selector (or Hi-Z front jack)"),
                ("7", "Channel Output", f"[{('#' * int(f_ch.fader * 12)).ljust(12)}]", format_db_7char(f_ch.fader_db).strip(), f"Channel fader level / V-Pot pan ({pan_to_str(f_ch.pan).strip()})"),
                ("8", "Unison Plug-in", "\033[92m [ ACTIVE ] \033[0m" if pre.unison_power else "\033[90m [ BYPASS ] \033[0m", pre.unison_plugin_name or "None", "Unison analog modeling DSP preamp slot power / bypass"),
            ]
            for s_num, p_name, p_ctrl, p_val, p_desc in p_slots:
                print(f"  {s_num}   | {p_name:<15} | {p_ctrl:<16} | {p_val:^15} | {p_desc}")
    else:
        print(" Slot | Channel Name | Level (tapered) | Volume dB | Live Meter (dBFS) |   Pan   |  Mute  |  Solo  ")
        print("------+--------------+-----------------+-----------+-------------------+---------+--------+--------")

        for slot in range(8):
            ch_id = engine.bank_offset + slot
            ch = uad.channels.get(ch_id)
            if ch:
                if engine.active_send_idx is not None:
                    send = ch.sends.get(engine.active_send_idx)
                    gain = send.gain if send else 0.0
                    gain_db = send.gain_db if send else -144.0
                    pan = send.pan if send else 0.0
                    byp = send.bypass if send else False

                    fader_bar_len = int(gain * 12)
                    fader_bar = ("#" * fader_bar_len).ljust(12)
                    db_str = format_db_7char(gain_db)
                    pan_str = pan_to_str(pan)
                    mute_str = "\033[91m BYP\033[0m" if byp else " -- "
                    solo_str = " -- "
                else:
                    fader_bar_len = int(ch.fader * 12)
                    fader_bar = ("#" * fader_bar_len).ljust(12)
                    db_val = getattr(ch, 'fader_db', None)
                    if db_val is None:
                        db_val = tapered_to_db(ch.fader)
                    db_str = format_db_7char(db_val)
                    pan_str = pan_to_str(ch.pan)
                    mute_str = "\033[91mMUTE\033[0m" if ch.mute else " -- "
                    solo_str = "\033[93mSOLO\033[0m" if ch.solo else " -- "

                # Live meter visualization
                m_lvl = ch.meter_level
                if m_lvl <= -65.0:
                    meter_disp = "[        ]  -oo dB"
                else:
                    m_ratio = max(0.0, min(1.0, (m_lvl + 60.0) / 60.0))
                    m_bars = int(m_ratio * 8)
                    meter_disp = f"[{('|' * m_bars).ljust(8)}] {m_lvl:+5.1f}dB"

                print(f"  {slot + 1}   | {ch.name[:12]:^12} | [{fader_bar}] | {db_str:^9} | {meter_disp:<17} | {pan_str} |  {mute_str}  |  {solo_str}  ")
            else:
                print(f"  {slot + 1}   | {'---':^12} | [{' ':12}] | {'---':^9} | [        ]    ---   |   ---   |   --   |   --   ")

    print("-----------------------------------------------------------------------------------------")
    print(" Hardware Controls:")
    print("   * Faders: Physical motorized tracking <-> Apollo volume")
    print("   * V-Pots: Panning with LED ring feedback")
    print("   * Mute / Solo: Bi-directional button and LED sync")
    print("   * Bank L / R: Shift bank by 8 tracks | Channel L / R: Shift by 1 track")
    print("   * LCD Displays: Track names and dB values in real time")
    print("\n [Press Ctrl+C to stop bridge cleanly]")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description="UA-MCU Bridge: Connect SSL UF8 to UAD Console")
    parser.add_argument("--port", type=int, default=3, help="SSL V-MIDI port number to use (default: 3)")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="UA Mixer Engine IP (default: 127.0.0.1)")
    parser.add_argument("--uad-port", type=int, default=4710, help="UA Mixer Engine port (default: 4710)")
    parser.add_argument("--list-ports", action="store_true", help="List all available CoreMIDI ports and exit")
    args = parser.parse_args()

    if args.list_ports:
        print("\n--- Available CoreMIDI Sources ---")
        for idx, name, _ in list_sources():
            print(f"  [{idx}] {name}")
        print("\n--- Available CoreMIDI Destinations ---")
        for idx, name, _ in list_destinations():
            print(f"  [{idx}] {name}")
        return

    port_name = f"SSL V-MIDI Port {args.port}"
    print(f"[Init] Initializing UA-MCU Bridge on {port_name}...")

    # 1. Initialize UAD Client
    uad = UADClient(host=args.host, port=args.uad_port)
    if not uad.connect():
        print(f"[Error] Could not connect to UA Mixer Engine at {args.host}:{args.uad_port}.")
        print("Please ensure UAD Console is running.")
        sys.exit(1)

    # 2. Initialize CoreMIDI Adapter
    midi = CoreMIDIAdapter(client_name="UAMCUBridge")

    # 3. Initialize MCU Protocol Engine
    engine = MCUEngine(uad_client=uad, send_midi_fn=midi.send_midi)

    # 4. Connect MIDI In/Out
    source_query = f"{port_name} Source"
    dest_query = f"{port_name} Destination"
    if not midi.connect(source_query, dest_query, on_midi_received=engine.handle_midi_bytes):
        print(f"[Error] Failed to bind to {port_name}.")
        print("Please verify that SSL 360° is running and virtual ports are enabled.")
        uad.close()
        sys.exit(1)

    # Initial sync
    time.sleep(0.3)
    engine.refresh_all_slots()

    # Graceful shutdown handler
    def shutdown_handler(signum, frame):
        print("\n[Shutdown] Cleaning up...")
        # Reset UF8 scribble strips and LEDs
        try:
            for s in range(8):
                midi.send_midi(bytes([0x90, 16 + s, 0x00]))  # Mute off
                midi.send_midi(bytes([0x90, 8 + s, 0x00]))   # Solo off
            engine.send_lcd_text(1, " " * 56)
            engine.send_lcd_text(2, " " * 56)
        except Exception:
            pass

        midi.close()
        uad.close()
        print("[Shutdown] Bridge stopped cleanly.")
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown_handler)
    signal.signal(signal.SIGTERM, shutdown_handler)

    # Live dashboard refresh loop
    try:
        while True:
            render_dashboard(engine, uad, midi, args.port)
            time.sleep(0.5)
    except KeyboardInterrupt:
        shutdown_handler(None, None)


if __name__ == "__main__":
    main()
