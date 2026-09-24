"""
UAD Apollo Console IPC Client (raw TCP socket on 127.0.0.1:4710)
Connects to UA Mixer Engine and synchronizes channel parameters bi-directionally.
"""

import json
import socket
import threading
import time
from typing import Callable, Dict, List, Optional, Any
from uad_curve import tapered_to_db


class UADSend:
    """Represents a send slot (e.g. AUX 1, AUX 2, CUE 1) on an input channel."""
    def __init__(self, send_idx: int, name: str = "", gain: float = 0.0, gain_db: float = -144.0, pan: float = 0.0, bypass: bool = False):
        self.index = send_idx
        self.name = name or (f"AUX {send_idx + 1}" if send_idx < 2 else f"CUE {send_idx - 1}")
        self.gain = gain            # 0.0 to 1.0 (GainTapered)
        self.gain_db = gain_db      # dB (-144.0 to +12.0)
        self.pan = pan              # -1.0 to 1.0
        self.bypass = bypass        # True = muted/bypassed

    def __repr__(self):
        return f"<UADSend {self.index}: '{self.name}' gain={self.gain:.2f} ({self.gain_db:.1f}dB) pan={self.pan:.2f} bypass={self.bypass}>"


class UADChannel:
    def __init__(self, ch_id: int, name: str = "", fader: float = 0.0, pan: float = 0.0, mute: bool = False, solo: bool = False):
        self.id = ch_id
        self.name = name or f"Ch {ch_id + 1}"
        self.fader = fader          # 0.0 to 1.0 (FaderLevelTapered)
        self.fader_db = tapered_to_db(fader)  # exact dB (-144.0 to +12.0)
        self.pan = pan              # -1.0 to 1.0
        self.mute = mute            # True / False
        self.solo = solo            # True / False
        self.meter_level = -77.0    # dBFS (-77.0 to 0.0)
        self.meter_peak = -77.0     # dBFS
        self.meter_clip = False     # True / False
        # Sends (0: AUX 1, 1: AUX 2, 2..5: CUE 1..4)
        self.sends: Dict[int, UADSend] = {
            i: UADSend(i) for i in range(6)
        }

    def __repr__(self):
        return f"<UADChannel {self.id}: '{self.name}' fader={self.fader:.2f} meter={self.meter_level:.1f}dB pan={self.pan:.2f} mute={self.mute} solo={self.solo}>"


class UADClient:
    """Manages raw TCP connection to the UA Mixer Engine on localhost:4710."""

    def __init__(self, host: str = "127.0.0.1", port: int = 4710):
        self.host = host
        self.port = port
        self.sock: Optional[socket.socket] = None
        self.is_connected = False
        self._running = False
        self._rx_thread: Optional[threading.Thread] = None
        self._meter_thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
        self._func_id = 1000

        # State storage: ch_id -> UADChannel
        self.channels: Dict[int, UADChannel] = {}
        self.device_id = 0
        self.cue_bus_count: int = 4
        self.device_name: str = "Apollo"
        self.active_bank_channels: List[int] = list(range(8))

        # Master Monitor Output tracking
        self.monitor_output_id: int = 20
        self.monitor_level_tapered: float = 0.208
        self.monitor_level_db: float = -37.0
        self.monitor_mute: bool = False

        # Callback hook: fn(event_type: str, ch_id: int, value: Any)
        # event_type in ("fader", "pan", "mute", "solo", "name", "channel_list", "meter")
        self.on_channel_change: Optional[Callable[[str, int, Any], None]] = None

    def set_active_bank(self, channel_ids: List[int]):
        """Update active bank channels so meter poller queries the visible slots."""
        with self._lock:
            self.active_bank_channels = list(channel_ids)

    def connect(self) -> bool:
        """Establish TCP connection to UA Mixer Engine and start listener."""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(5.0)
            self.sock.connect((self.host, self.port))
            self.sock.settimeout(None)
            self.is_connected = True
            self._running = True

            self._rx_thread = threading.Thread(target=self._read_loop, daemon=True)
            self._rx_thread.start()

            self._meter_thread = threading.Thread(target=self._meter_poll_loop, daemon=True)
            self._meter_thread.start()

            print(f"[UAD] Connected to UA Mixer Engine at {self.host}:{self.port}")
            self._discover_channels()
            return True
        except Exception as e:
            print(f"[UAD] Connection failed: {e}")
            self.is_connected = False
            return False

    def _meter_poll_loop(self):
        """Continuously polls meter levels for active bank channels at ~25 Hz."""
        while self._running:
            if self.is_connected and self.sock:
                with self._lock:
                    channels_to_poll = list(self.active_bank_channels)
                if channels_to_poll:
                    cmds = "".join(f"get /devices/{self.device_id}/inputs/{ch}/meters/0\x00" for ch in channels_to_poll)
                    try:
                        self.sock.sendall(cmds.encode('utf-8'))
                    except Exception:
                        pass
            time.sleep(0.04)  # 25 fps smooth metering

    def _next_func_id(self) -> int:
        self._func_id += 1
        return self._func_id

    def send_command(self, cmd: str):
        """Send null-terminated command string over raw TCP."""
        if not self.is_connected or not self.sock:
            return
        with self._lock:
            try:
                payload = cmd.encode('utf-8') + b'\x00'
                self.sock.sendall(payload)
            except Exception as e:
                print(f"[UAD] Send error: {e}")
                self.is_connected = False

    def _discover_channels(self):
        """Query devices and discover all input channels and outputs."""
        self.send_command("get /devices")
        # In Apollo Twin/X/Rack, device 0 is primary. Query its properties, inputs, and outputs.
        self.send_command(f"get /devices/{self.device_id}")
        self.send_command(f"get /devices/{self.device_id}/inputs")
        self.send_command(f"get /devices/{self.device_id}/outputs")

    def _read_loop(self):
        """Background thread reading null-delimited JSON frames from socket."""
        buffer = b""
        while self._running:
            try:
                data = self.sock.recv(4096)
                if not data:
                    print("[UAD] Connection closed by UA Mixer Engine")
                    self.is_connected = False
                    break
                buffer += data
                while b'\x00' in buffer:
                    frame, buffer = buffer.split(b'\x00', 1)
                    if frame:
                        self._handle_frame(frame)
            except Exception as e:
                if self._running:
                    print(f"[UAD] Read loop error: {e}")
                self.is_connected = False
                break

    def _handle_frame(self, frame: bytes):
        """Parse null-terminated JSON frame from UA Mixer Engine."""
        try:
            text = frame.decode('utf-8', errors='ignore')
            obj = json.loads(text)
        except Exception:
            return

        path = obj.get("path", "")
        data = obj.get("data")

        # 0. Primary Device properties: /devices/0
        if path == f"/devices/{self.device_id}":
            if isinstance(data, dict):
                props = data.get("properties", {})
                if "CueBusCount" in props:
                    self.cue_bus_count = int(props["CueBusCount"].get("value", 4))
                if "DeviceName" in props:
                    self.device_name = str(props["DeviceName"].get("value", "Apollo"))
            return

        # 1. Inputs discovery list: /devices/0/inputs
        if path == f"/devices/{self.device_id}/inputs":
            if isinstance(data, dict):
                children = data.get("children", {})
                for ch_str in sorted(children.keys(), key=lambda x: int(x) if x.isdigit() else 999):
                    if ch_str.isdigit():
                        ch_id = int(ch_str)
                        if ch_id not in self.channels:
                            self.channels[ch_id] = UADChannel(ch_id)
                        # Fetch full channel info
                        self.send_command(f"get /devices/{self.device_id}/inputs/{ch_id}")
                        # Subscribe to updates
                        self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/FaderLevel/value")
                        self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/FaderLevelTapered/value")
                        self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/Pan/value")
                        self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/Mute/value")
                        self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/Solo/value")
                        # Discover and subscribe to Sends (0: AUX 1, 1: AUX 2, 2..5: CUE 1..4)
                        for s_idx in range(6):
                            self.send_command(f"get /devices/{self.device_id}/inputs/{ch_id}/sends/{s_idx}")
                            self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/sends/{s_idx}/GainTapered/value")
                            self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/sends/{s_idx}/Pan/value")
                            self.send_command(f"sub /devices/{self.device_id}/inputs/{ch_id}/sends/{s_idx}/Bypass/value")
            if self.on_channel_change:
                self.on_channel_change("channel_list", -1, list(self.channels.keys()))
            return

        # 1b. Outputs discovery list: /devices/0/outputs
        if path == f"/devices/{self.device_id}/outputs":
            if isinstance(data, dict):
                children = data.get("children", {})
                for out_str in children.keys():
                    if out_str.isdigit():
                        self.send_command(f"get /devices/{self.device_id}/outputs/{out_str}")
            return

        # 1c. Output properties: /devices/0/outputs/{id}
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "devices" and parts[2] == "outputs":
            try:
                out_id = int(parts[3])
                if isinstance(data, dict):
                    props = data.get("properties", {})
                    iotype = props.get("IOType", {}).get("value", "")
                    name = props.get("Name", {}).get("value", "")
                    if iotype == "Monitor" or name == "MONITOR":
                        self.monitor_output_id = out_id
                        if "CRMonitorLevelTapered" in props:
                            self.monitor_level_tapered = float(props["CRMonitorLevelTapered"].get("value", 0.0))
                        if "CRMonitorLevel" in props:
                            self.monitor_level_db = float(props["CRMonitorLevel"].get("value", -96.0))
                        if "Mute" in props:
                            self.monitor_mute = bool(props["Mute"].get("value", False))
                        # Subscribe to Monitor output changes
                        self.send_command(f"sub /devices/{self.device_id}/outputs/{out_id}/CRMonitorLevelTapered/value")
                        self.send_command(f"sub /devices/{self.device_id}/outputs/{out_id}/CRMonitorLevel/value")
                        self.send_command(f"sub /devices/{self.device_id}/outputs/{out_id}/Mute/value")
            except (ValueError, TypeError):
                pass
            return

        # 1d. Output property value updates: /devices/0/outputs/{id}/{property}/value
        if len(parts) == 6 and parts[0] == "devices" and parts[2] == "outputs" and parts[5] == "value":
            try:
                out_id = int(parts[3])
                prop = parts[4]
                if out_id == self.monitor_output_id:
                    if prop == "CRMonitorLevelTapered":
                        self.monitor_level_tapered = float(data)
                    elif prop == "CRMonitorLevel":
                        self.monitor_level_db = float(data)
                    elif prop == "Mute":
                        self.monitor_mute = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("monitor", out_id, (self.monitor_level_tapered, self.monitor_level_db, self.monitor_mute))
            except (ValueError, TypeError):
                pass
            return

        # 2. Full Channel properties: /devices/0/inputs/{id}
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[0] == "devices" and parts[2] == "inputs":
            try:
                ch_id = int(parts[3])
                if isinstance(data, dict):
                    props = data.get("properties", {})
                    name_obj = props.get("Name", {})
                    fader_obj = props.get("FaderLevelTapered", {})
                    fader_db_obj = props.get("FaderLevel", {})
                    pan_obj = props.get("Pan", {})
                    mute_obj = props.get("Mute", {})
                    solo_obj = props.get("Solo", {})

                    ch = self.channels.setdefault(ch_id, UADChannel(ch_id))
                    if "value" in name_obj:
                        ch.name = str(name_obj["value"])
                    if "value" in fader_obj:
                        ch.fader = float(fader_obj["value"])
                    if "value" in fader_db_obj:
                        ch.fader_db = float(fader_db_obj["value"])
                    if "value" in pan_obj:
                        ch.pan = float(pan_obj["value"])
                    if "value" in mute_obj:
                        ch.mute = bool(mute_obj["value"])
                    if "value" in solo_obj:
                        ch.solo = bool(solo_obj["value"])

                    if self.on_channel_change:
                        self.on_channel_change("name", ch_id, ch.name)
                        self.on_channel_change("fader", ch_id, ch.fader)
                        self.on_channel_change("fader_db", ch_id, ch.fader_db)
                        self.on_channel_change("pan", ch_id, ch.pan)
                        self.on_channel_change("mute", ch_id, ch.mute)
                        self.on_channel_change("solo", ch_id, ch.solo)
            except ValueError:
                pass
            return

        # 3. Channel meter updates: /devices/0/inputs/{id}/meters/{meter_id}
        if len(parts) >= 6 and parts[0] == "devices" and parts[2] == "inputs" and parts[4] == "meters":
            try:
                ch_id = int(parts[3])
                if isinstance(data, dict):
                    props = data.get("properties", {})
                    lvl_obj = props.get("MeterLevel", {})
                    peak_obj = props.get("MeterPeakLevel", {})
                    clip_obj = props.get("MeterClip", {})
                    ch = self.channels.setdefault(ch_id, UADChannel(ch_id))
                    if "value" in lvl_obj:
                        ch.meter_level = float(lvl_obj["value"])
                    if "value" in peak_obj:
                        ch.meter_peak = float(peak_obj["value"])
                    if "value" in clip_obj:
                        ch.meter_clip = bool(clip_obj["value"])
                    if self.on_channel_change:
                        self.on_channel_change("meter", ch_id, ch.meter_level)
            except (ValueError, TypeError):
                pass
            return

        # 4. Subscribed property updates: /devices/0/inputs/{id}/{property}/value
        if len(parts) == 6 and parts[0] == "devices" and parts[2] == "inputs" and parts[5] == "value":
            try:
                ch_id = int(parts[3])
                prop = parts[4]
                ch = self.channels.setdefault(ch_id, UADChannel(ch_id))

                if prop == "FaderLevelTapered":
                    ch.fader = float(data)
                    ch.fader_db = tapered_to_db(ch.fader)
                    if self.on_channel_change:
                        self.on_channel_change("fader", ch_id, ch.fader)
                elif prop == "FaderLevel":
                    ch.fader_db = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("fader_db", ch_id, ch.fader_db)
                elif prop == "Pan":
                    ch.pan = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("pan", ch_id, ch.pan)
                elif prop == "Mute":
                    ch.mute = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("mute", ch_id, ch.mute)
                elif prop == "Solo":
                    ch.solo = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("solo", ch_id, ch.solo)
            except (ValueError, TypeError):
                pass

        # 5. Full Send properties: /devices/0/inputs/{id}/sends/{send_id}
        if len(parts) == 6 and parts[0] == "devices" and parts[2] == "inputs" and parts[4] == "sends":
            try:
                ch_id = int(parts[3])
                s_idx = int(parts[5])
                ch = self.channels.setdefault(ch_id, UADChannel(ch_id))
                send = ch.sends.setdefault(s_idx, UADSend(s_idx))
                if isinstance(data, dict):
                    props = data.get("properties", {})
                    name_obj = props.get("Name", {})
                    gain_t_obj = props.get("GainTapered", {})
                    gain_db_obj = props.get("Gain", {})
                    pan_obj = props.get("Pan", {})
                    byp_obj = props.get("Bypass", {})

                    if "value" in name_obj:
                        send.name = str(name_obj["value"])
                    if "value" in gain_t_obj:
                        send.gain = float(gain_t_obj["value"])
                        send.gain_db = tapered_to_db(send.gain)
                    if "value" in gain_db_obj:
                        send.gain_db = float(gain_db_obj["value"])
                    if "value" in pan_obj:
                        send.pan = float(pan_obj["value"])
                    if "value" in byp_obj:
                        send.bypass = bool(byp_obj["value"])

                    if self.on_channel_change:
                        self.on_channel_change("send_gain", ch_id, (s_idx, send.gain, send.gain_db))
                        self.on_channel_change("send_pan", ch_id, (s_idx, send.pan))
                        self.on_channel_change("send_bypass", ch_id, (s_idx, send.bypass))
            except (ValueError, TypeError):
                pass
            return

        # 6. Subscribed Send property updates: /devices/0/inputs/{id}/sends/{send_id}/{property}/value
        if len(parts) == 8 and parts[0] == "devices" and parts[2] == "inputs" and parts[4] == "sends" and parts[7] == "value":
            try:
                ch_id = int(parts[3])
                s_idx = int(parts[5])
                prop = parts[6]
                ch = self.channels.setdefault(ch_id, UADChannel(ch_id))
                send = ch.sends.setdefault(s_idx, UADSend(s_idx))

                if prop == "GainTapered":
                    send.gain = float(data)
                    send.gain_db = tapered_to_db(send.gain)
                    if self.on_channel_change:
                        self.on_channel_change("send_gain", ch_id, (s_idx, send.gain, send.gain_db))
                elif prop == "Gain":
                    send.gain_db = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_gain", ch_id, (s_idx, send.gain, send.gain_db))
                elif prop == "Pan":
                    send.pan = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_pan", ch_id, (s_idx, send.pan))
                elif prop == "Bypass":
                    send.bypass = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_bypass", ch_id, (s_idx, send.bypass))
            except (ValueError, TypeError):
                pass
            return

    # --- Outbound Control Methods ---

    def set_send_gain(self, ch_id: int, send_idx: int, value: float):
        """Set channel send gain tapered level (0.0 to 1.0)."""
        val = max(0.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/sends/{send_idx}/GainTapered/value?context_type=main&func_id={fid} {val:.6f}"
        self.send_command(cmd)
        if ch_id in self.channels:
            send = self.channels[ch_id].sends.setdefault(send_idx, UADSend(send_idx))
            send.gain = val
            send.gain_db = tapered_to_db(val)

    def set_send_pan(self, ch_id: int, send_idx: int, value: float):
        """Set channel send pan (-1.0 to 1.0)."""
        val = max(-1.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/sends/{send_idx}/Pan/value?context_type=main&func_id={fid} {val:.4f}"
        self.send_command(cmd)
        if ch_id in self.channels:
            send = self.channels[ch_id].sends.setdefault(send_idx, UADSend(send_idx))
            send.pan = val

    def set_send_bypass(self, ch_id: int, send_idx: int, bypass: bool):
        """Set channel send bypass (True = muted/bypassed, False = active)."""
        fid = self._next_func_id()
        val_str = "true" if bypass else "false"
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/sends/{send_idx}/Bypass/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        if ch_id in self.channels:
            send = self.channels[ch_id].sends.setdefault(send_idx, UADSend(send_idx))
            send.bypass = bypass

    def set_fader(self, ch_id: int, value: float):
        """Set channel fader tapered level (0.0 to 1.0)."""
        val = max(0.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/FaderLevelTapered/value?context_type=main&func_id={fid} {val:.6f}"
        self.send_command(cmd)
        if ch_id in self.channels:
            self.channels[ch_id].fader = val
            self.channels[ch_id].fader_db = tapered_to_db(val)

    def set_pan(self, ch_id: int, value: float):
        """Set channel pan (-1.0 left to 1.0 right)."""
        val = max(-1.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/Pan/value?context_type=main&func_id={fid} {val:.4f}"
        self.send_command(cmd)
        if ch_id in self.channels:
            self.channels[ch_id].pan = val

    def set_mute(self, ch_id: int, muted: bool):
        """Set channel mute state."""
        val_str = "true" if muted else "false"
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/Mute/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        if ch_id in self.channels:
            self.channels[ch_id].mute = muted

    def set_solo(self, ch_id: int, soloed: bool):
        """Set channel solo state."""
        val_str = "true" if soloed else "false"
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/inputs/{ch_id}/Solo/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        if ch_id in self.channels:
            self.channels[ch_id].solo = soloed

    def set_monitor_db(self, db_val: float):
        """Set Apollo master monitor output level in dB (-96.0 to 0.0 dB)."""
        val = max(-96.0, min(0.0, float(db_val)))
        self.monitor_level_db = val
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/outputs/{self.monitor_output_id}/CRMonitorLevel/value?context_type=main&func_id={fid} {val:.1f}"
        self.send_command(cmd)

    def nudge_monitor_db(self, delta_db: float):
        """Nudge Apollo master monitor output level by delta dB (e.g. +/- 1.0 dB)."""
        new_db = max(-96.0, min(0.0, self.monitor_level_db + delta_db))
        self.set_monitor_db(new_db)

    def set_monitor_level(self, value: float):
        """Set Apollo master monitor output tapered level (0.0 to 1.0)."""
        val = max(0.0, min(1.0, float(value)))
        self.monitor_level_tapered = val
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/outputs/{self.monitor_output_id}/CRMonitorLevelTapered/value?context_type=main&func_id={fid} {val:.6f}"
        self.send_command(cmd)

    def nudge_monitor_level(self, delta: float):
        """Nudge Apollo master monitor output level by delta."""
        new_val = max(0.0, min(1.0, self.monitor_level_tapered + delta))
        self.set_monitor_level(new_val)

    def set_monitor_mute(self, muted: bool):
        """Set Apollo master monitor mute state."""
        self.monitor_mute = muted
        fid = self._next_func_id()
        val_str = "true" if muted else "false"
        cmd = f"set /devices/{self.device_id}/outputs/{self.monitor_output_id}/Mute/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)

    def toggle_monitor_mute(self):
        """Toggle Apollo master monitor mute."""
        self.set_monitor_mute(not self.monitor_mute)

    def close(self):
        """Close connection cleanly."""
        self._running = False
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.is_connected = False
        print("[UAD] Closed connection to UA Mixer Engine.")
