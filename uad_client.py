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
    def __init__(self, ch_id: int, name: str = "", fader: float = 0.0, pan: float = 0.0, mute: bool = False, solo: bool = False, ch_type: str = "input", dev_path: str = ""):
        self.id = ch_id
        self.ch_type = ch_type      # "input" or "aux"
        self.dev_path = dev_path    # e.g. "/devices/0/inputs/0" or "/devices/0/auxs/0"
        self.name = name or (f"AUX {ch_id + 1}" if ch_type == "aux" else f"Ch {ch_id + 1}")
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
        return f"<UADChannel {self.id} ({self.ch_type}): '{self.name}' fader={self.fader:.2f} meter={self.meter_level:.1f}dB pan={self.pan:.2f} mute={self.mute} solo={self.solo}>"


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
        self._lock = threading.RLock()
        self._func_id = 1000

        # State storage: ch_id -> UADChannel
        self.channels: Dict[int, UADChannel] = {}
        self.path_to_channel: Dict[str, UADChannel] = {}
        self._pending_input_ids: set = set()
        self._pending_aux_ids: set = set()
        self._raw_inputs: Dict[int, dict] = {}
        self._raw_auxs: Dict[int, dict] = {}
        self._build_timer: Optional[threading.Timer] = None

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
        # event_type in ("fader", "pan", "mute", "solo", "name", "channel_list", "meter", "refresh_all")
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
                    cmds = []
                    for ch_id in channels_to_poll:
                        ch = self.channels.get(ch_id)
                        if ch and ch.dev_path:
                            cmds.append(f"get {ch.dev_path}/meters/0\x00")
                if cmds:
                    try:
                        self.sock.sendall("".join(cmds).encode('utf-8'))
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
        """Query devices and discover all input channels, aux channels, and outputs."""
        with self._lock:
            self._pending_input_ids.clear()
            self._pending_aux_ids.clear()
            self._raw_inputs.clear()
            self._raw_auxs.clear()
        self.send_command("get /devices")
        # In Apollo Twin/X/Rack, device 0 is primary. Query its properties, inputs, auxs, and outputs.
        self.send_command(f"get /devices/{self.device_id}")
        self.send_command(f"get /devices/{self.device_id}/inputs")
        self.send_command(f"get /devices/{self.device_id}/auxs")
        self.send_command(f"get /devices/{self.device_id}/outputs")

    def _schedule_channel_rebuild(self):
        """Schedule or trigger channel map build once inputs and auxs have reported."""
        inputs_done = bool(self._pending_input_ids and self._pending_input_ids.issubset(self._raw_inputs.keys()))
        auxs_done = bool(self._pending_aux_ids and self._pending_aux_ids.issubset(self._raw_auxs.keys()))
        if inputs_done and auxs_done:
            if self._build_timer:
                try:
                    self._build_timer.cancel()
                except Exception:
                    pass
                self._build_timer = None
            self._rebuild_channel_map()
        else:
            if not self._build_timer:
                self._build_timer = threading.Timer(0.15, self._rebuild_channel_map)
                self._build_timer.daemon = True
                self._build_timer.start()

    def _rebuild_channel_map(self):
        """Build ordered channel list: valid active inputs followed by AUX 1 and AUX 2."""
        with self._lock:
            if self._build_timer:
                try:
                    self._build_timer.cancel()
                except Exception:
                    pass
                self._build_timer = None

            # Filter valid active inputs: skip Active == False, IOType == "None", or name starting with "N/A"
            valid_inputs = []
            for inp_id in sorted(self._raw_inputs.keys()):
                raw = self._raw_inputs[inp_id]
                props = raw.get("properties", {})
                active = props.get("Active", {}).get("value", True)
                iotype = props.get("IOType", {}).get("value", "")
                name = str(props.get("Name", {}).get("value", ""))
                if not active or iotype == "None" or name.startswith("N/A"):
                    continue
                valid_inputs.append(inp_id)

            # Valid active auxs
            valid_auxs = []
            for aux_id in sorted(self._raw_auxs.keys()):
                raw = self._raw_auxs[aux_id]
                props = raw.get("properties", {})
                active = props.get("Active", {}).get("value", True)
                if not active:
                    continue
                valid_auxs.append(aux_id)

            new_channels = {}
            new_path_map = {}
            bridge_idx = 0

            # 1. Active Inputs (e.g. 0..24: Mic, Line, ADAT, SPDIF, Virtual, Talkback)
            for inp_id in valid_inputs:
                raw = self._raw_inputs[inp_id]
                props = raw.get("properties", {})
                dev_path = f"/devices/{self.device_id}/inputs/{inp_id}"
                ch = self.channels.get(bridge_idx) or UADChannel(bridge_idx)
                ch.id = bridge_idx
                ch.ch_type = "input"
                ch.dev_path = dev_path
                ch.name = str(props.get("Name", {}).get("value", f"Ch {bridge_idx + 1}"))
                f_t = props.get("FaderLevelTapered", {}).get("value")
                if f_t is not None:
                    ch.fader = float(f_t)
                f_db = props.get("FaderLevel", {}).get("value")
                if f_db is not None:
                    ch.fader_db = float(f_db)
                else:
                    ch.fader_db = tapered_to_db(ch.fader)
                pan_v = props.get("Pan", {}).get("value")
                if pan_v is not None:
                    ch.pan = float(pan_v)
                mute_v = props.get("Mute", {}).get("value")
                if mute_v is not None:
                    ch.mute = bool(mute_v)
                solo_v = props.get("Solo", {}).get("value")
                if solo_v is not None:
                    ch.solo = bool(solo_v)

                new_channels[bridge_idx] = ch
                new_path_map[dev_path] = ch
                bridge_idx += 1

                # Subscriptions for input
                self.send_command(f"subscribe {dev_path}/FaderLevel/value")
                self.send_command(f"subscribe {dev_path}/FaderLevelTapered/value")
                self.send_command(f"subscribe {dev_path}/Pan/value")
                self.send_command(f"subscribe {dev_path}/Mute/value")
                self.send_command(f"subscribe {dev_path}/Solo/value")
                self.send_command(f"subscribe {dev_path}/Name/value")
                for s_idx in range(6):
                    self.send_command(f"get {dev_path}/sends/{s_idx}")
                    self.send_command(f"subscribe {dev_path}/sends/{s_idx}/Gain/value")
                    self.send_command(f"subscribe {dev_path}/sends/{s_idx}/GainTapered/value")
                    self.send_command(f"subscribe {dev_path}/sends/{s_idx}/Pan/value")
                    self.send_command(f"subscribe {dev_path}/sends/{s_idx}/Bypass/value")

            # 2. Active Auxes (e.g. 25: AUX 1, 26: AUX 2)
            for aux_id in valid_auxs:
                raw = self._raw_auxs[aux_id]
                props = raw.get("properties", {})
                dev_path = f"/devices/{self.device_id}/auxs/{aux_id}"
                ch = self.channels.get(bridge_idx) or UADChannel(bridge_idx)
                ch.id = bridge_idx
                ch.ch_type = "aux"
                ch.dev_path = dev_path
                ch.name = str(props.get("Name", {}).get("value", f"AUX {aux_id + 1}"))
                f_t = props.get("FaderLevelTapered", {}).get("value")
                if f_t is not None:
                    ch.fader = float(f_t)
                f_db = props.get("FaderLevel", {}).get("value")
                if f_db is not None:
                    ch.fader_db = float(f_db)
                else:
                    ch.fader_db = tapered_to_db(ch.fader)
                ch.pan = 0.0
                mute_v = props.get("Mute", {}).get("value")
                if mute_v is not None:
                    ch.mute = bool(mute_v)
                ch.solo = False

                new_channels[bridge_idx] = ch
                new_path_map[dev_path] = ch
                bridge_idx += 1

                # Subscriptions for aux
                self.send_command(f"subscribe {dev_path}/FaderLevel/value")
                self.send_command(f"subscribe {dev_path}/FaderLevelTapered/value")
                self.send_command(f"subscribe {dev_path}/Mute/value")
                self.send_command(f"subscribe {dev_path}/Name/value")
                # Aux Cue sends (indices 0..3 map to MCU CUE 1..4, i.e. send_mode 2..5)
                for cue_idx in range(4):
                    self.send_command(f"get {dev_path}/sends/{cue_idx}")
                    self.send_command(f"subscribe {dev_path}/sends/{cue_idx}/Gain/value")
                    self.send_command(f"subscribe {dev_path}/sends/{cue_idx}/GainTapered/value")
                    self.send_command(f"subscribe {dev_path}/sends/{cue_idx}/Bypass/value")

            self.channels = new_channels
            self.path_to_channel = new_path_map
            print(f"[UAD] Active channels ({len(self.channels)}): {[ch.name for ch in self.channels.values()]}")

        if self.on_channel_change:
            self.on_channel_change("channel_list", -1, list(self.channels.keys()))
            self.on_channel_change("refresh_all", -1, None)

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
                        self._pending_input_ids.add(ch_id)
                        self.send_command(f"get /devices/{self.device_id}/inputs/{ch_id}")
            return

        # 1b. Auxs discovery list: /devices/0/auxs
        if path == f"/devices/{self.device_id}/auxs":
            if isinstance(data, dict):
                children = data.get("children", {})
                for aux_str in sorted(children.keys(), key=lambda x: int(x) if x.isdigit() else 999):
                    if aux_str.isdigit():
                        aux_id = int(aux_str)
                        self._pending_aux_ids.add(aux_id)
                        self.send_command(f"get /devices/{self.device_id}/auxs/{aux_id}")
            return

        # 1c. Outputs discovery list: /devices/0/outputs
        if path == f"/devices/{self.device_id}/outputs":
            if isinstance(data, dict):
                children = data.get("children", {})
                for out_str in children.keys():
                    if out_str.isdigit():
                        self.send_command(f"get /devices/{self.device_id}/outputs/{out_str}")
            return

        parts = path.strip("/").split("/")

        # 1d. Detailed Input discovery property response: /devices/0/inputs/{id}
        if len(parts) == 4 and parts[0] == "devices" and parts[2] == "inputs":
            try:
                inp_id = int(parts[3])
                if isinstance(data, dict):
                    self._raw_inputs[inp_id] = data
                    self._schedule_channel_rebuild()
            except ValueError:
                pass
            return

        # 1e. Detailed Aux discovery property response: /devices/0/auxs/{id}
        if len(parts) == 4 and parts[0] == "devices" and parts[2] == "auxs":
            try:
                aux_id = int(parts[3])
                if isinstance(data, dict):
                    self._raw_auxs[aux_id] = data
                    self._schedule_channel_rebuild()
            except ValueError:
                pass
            return

        # 1f. Output properties: /devices/0/outputs/{id}
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
                        self.send_command(f"subscribe /devices/{self.device_id}/outputs/{out_id}/CRMonitorLevelTapered/value")
                        self.send_command(f"subscribe /devices/{self.device_id}/outputs/{out_id}/CRMonitorLevel/value")
                        self.send_command(f"subscribe /devices/{self.device_id}/outputs/{out_id}/Mute/value")
            except (ValueError, TypeError):
                pass
            return

        # 1g. Output property value updates: /devices/0/outputs/{id}/{property}/value
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

        # 3. Channel meter updates: /devices/0/inputs/{id}/meters/{meter_id} or /devices/0/auxs/{id}/meters/{meter_id}
        if len(parts) >= 6 and parts[0] == "devices" and parts[2] in ("inputs", "auxs") and parts[4] == "meters":
            base_path = f"/devices/{parts[1]}/{parts[2]}/{parts[3]}"
            ch = self.path_to_channel.get(base_path)
            if ch and isinstance(data, dict):
                props = data.get("properties", {})
                lvl_obj = props.get("MeterLevel", {})
                peak_obj = props.get("MeterPeakLevel", {})
                clip_obj = props.get("MeterClip", {})
                if "value" in lvl_obj:
                    ch.meter_level = float(lvl_obj["value"])
                if "value" in peak_obj:
                    ch.meter_peak = float(peak_obj["value"])
                if "value" in clip_obj:
                    ch.meter_clip = bool(clip_obj["value"])
                if self.on_channel_change:
                    self.on_channel_change("meter", ch.id, ch.meter_level)
            return

        # 4. Subscribed property updates: /devices/0/inputs/{id}/{property}/value or /devices/0/auxs/{id}/{property}/value
        if len(parts) == 6 and parts[0] == "devices" and parts[2] in ("inputs", "auxs") and parts[5] == "value":
            base_path = f"/devices/{parts[1]}/{parts[2]}/{parts[3]}"
            ch = self.path_to_channel.get(base_path)
            if ch:
                prop = parts[4]
                if prop == "FaderLevelTapered":
                    ch.fader = float(data)
                    ch.fader_db = tapered_to_db(ch.fader)
                    if self.on_channel_change:
                        self.on_channel_change("fader", ch.id, ch.fader)
                elif prop == "FaderLevel":
                    ch.fader_db = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("fader_db", ch.id, ch.fader_db)
                elif prop == "Pan":
                    ch.pan = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("pan", ch.id, ch.pan)
                elif prop == "Mute":
                    ch.mute = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("mute", ch.id, ch.mute)
                elif prop == "Solo":
                    ch.solo = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("solo", ch.id, ch.solo)
                elif prop == "Name":
                    ch.name = str(data)
                    if self.on_channel_change:
                        self.on_channel_change("name", ch.id, ch.name)
            return

        # 5. Full Send properties: /devices/0/inputs/{id}/sends/{send_id} or /devices/0/auxs/{id}/sends/{send_id}
        if len(parts) == 6 and parts[0] == "devices" and parts[2] in ("inputs", "auxs") and parts[4] == "sends":
            base_path = f"/devices/{parts[1]}/{parts[2]}/{parts[3]}"
            ch = self.path_to_channel.get(base_path)
            if ch and isinstance(data, dict):
                raw_s_idx = int(parts[5])
                s_idx = (raw_s_idx + 2) if ch.ch_type == "aux" else raw_s_idx
                send = ch.sends.setdefault(s_idx, UADSend(s_idx))
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
                    self.on_channel_change("send_gain", ch.id, (s_idx, send.gain, send.gain_db))
                    self.on_channel_change("send_pan", ch.id, (s_idx, send.pan))
                    self.on_channel_change("send_bypass", ch.id, (s_idx, send.bypass))
            return

        # 6. Subscribed Send property updates: /devices/0/inputs/{id}/sends/{send_id}/{property}/value or auxs
        if len(parts) == 8 and parts[0] == "devices" and parts[2] in ("inputs", "auxs") and parts[4] == "sends" and parts[7] == "value":
            base_path = f"/devices/{parts[1]}/{parts[2]}/{parts[3]}"
            ch = self.path_to_channel.get(base_path)
            if ch:
                raw_s_idx = int(parts[5])
                s_idx = (raw_s_idx + 2) if ch.ch_type == "aux" else raw_s_idx
                prop = parts[6]
                send = ch.sends.setdefault(s_idx, UADSend(s_idx))

                if prop == "GainTapered":
                    send.gain = float(data)
                    send.gain_db = tapered_to_db(send.gain)
                    if self.on_channel_change:
                        self.on_channel_change("send_gain", ch.id, (s_idx, send.gain, send.gain_db))
                elif prop == "Gain":
                    send.gain_db = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_gain", ch.id, (s_idx, send.gain, send.gain_db))
                elif prop == "Pan":
                    send.pan = float(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_pan", ch.id, (s_idx, send.pan))
                elif prop == "Bypass":
                    send.bypass = bool(data)
                    if self.on_channel_change:
                        self.on_channel_change("send_bypass", ch.id, (s_idx, send.bypass))
            return

    # --- Outbound Control Methods ---

    def set_send_gain(self, ch_id: int, send_idx: int, value: float):
        """Set channel send gain tapered level (0.0 to 1.0)."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path:
            return
        if ch.ch_type == "aux" and send_idx < 2:
            return  # Aux returns do not send to Aux 1 or Aux 2
        val = max(0.0, min(1.0, float(value)))
        fid = self._next_func_id()
        target_send_idx = (send_idx - 2) if ch.ch_type == "aux" else send_idx
        cmd = f"set {ch.dev_path}/sends/{target_send_idx}/GainTapered/value?context_type=main&func_id={fid} {val:.6f}"
        self.send_command(cmd)
        send = ch.sends.setdefault(send_idx, UADSend(send_idx))
        send.gain = val
        send.gain_db = tapered_to_db(val)

    def set_send_pan(self, ch_id: int, send_idx: int, value: float):
        """Set channel send pan (-1.0 to 1.0)."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path:
            return
        if ch.ch_type == "aux":
            return  # Aux sends to Cues are stereo without pan
        val = max(-1.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set {ch.dev_path}/sends/{send_idx}/Pan/value?context_type=main&func_id={fid} {val:.4f}"
        self.send_command(cmd)
        send = ch.sends.setdefault(send_idx, UADSend(send_idx))
        send.pan = val

    def set_send_bypass(self, ch_id: int, send_idx: int, bypass: bool):
        """Set channel send bypass (True = muted/bypassed, False = active)."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path:
            return
        if ch.ch_type == "aux" and send_idx < 2:
            return
        fid = self._next_func_id()
        val_str = "true" if bypass else "false"
        target_send_idx = (send_idx - 2) if ch.ch_type == "aux" else send_idx
        cmd = f"set {ch.dev_path}/sends/{target_send_idx}/Bypass/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        send = ch.sends.setdefault(send_idx, UADSend(send_idx))
        send.bypass = bypass

    def set_fader(self, ch_id: int, value: float):
        """Set channel fader tapered level (0.0 to 1.0)."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path:
            return
        val = max(0.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set {ch.dev_path}/FaderLevelTapered/value?context_type=main&func_id={fid} {val:.6f}"
        self.send_command(cmd)
        ch.fader = val
        ch.fader_db = tapered_to_db(val)

    def set_pan(self, ch_id: int, value: float):
        """Set channel pan (-1.0 left to 1.0 right)."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path or ch.ch_type == "aux":
            return  # Aux is stereo return
        val = max(-1.0, min(1.0, float(value)))
        fid = self._next_func_id()
        cmd = f"set {ch.dev_path}/Pan/value?context_type=main&func_id={fid} {val:.4f}"
        self.send_command(cmd)
        ch.pan = val

    def set_mute(self, ch_id: int, muted: bool):
        """Set channel mute state."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path:
            return
        val_str = "true" if muted else "false"
        fid = self._next_func_id()
        cmd = f"set {ch.dev_path}/Mute/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        ch.mute = muted

    def set_solo(self, ch_id: int, soloed: bool):
        """Set channel solo state."""
        ch = self.channels.get(ch_id)
        if not ch or not ch.dev_path or ch.ch_type == "aux":
            return  # Aux has no solo
        val_str = "true" if soloed else "false"
        fid = self._next_func_id()
        cmd = f"set {ch.dev_path}/Solo/value?context_type=main&func_id={fid} {val_str}"
        self.send_command(cmd)
        ch.solo = soloed

    def set_monitor_db(self, db_val: float):
        """Set Apollo master monitor output level in dB (-96.0 to 0.0 dB)."""
        val = max(-96.0, min(0.0, float(db_val)))
        self.monitor_level_db = val
        fid = self._next_func_id()
        cmd = f"set /devices/{self.device_id}/outputs/{self.monitor_output_id}/CRMonitorLevel/value?context_type=main&func_id={fid} {val:.1f}"
        self.send_command(cmd)

    def nudge_monitor_db(self, delta_db: float) -> bool:
        """Nudge Apollo master monitor output level by delta dB (e.g. +/- 1.0 dB).
        Returns True if the level actually changed, False if unchanged (clamped)."""
        old_db = self.monitor_level_db
        new_db = max(-96.0, min(0.0, self.monitor_level_db + delta_db))
        if abs(new_db - old_db) < 0.05:
            return False
        self.set_monitor_db(new_db)
        return True

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
