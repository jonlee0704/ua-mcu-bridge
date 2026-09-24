"""
CoreMIDI Adapter for macOS (Pure ctypes - Zero External Dependencies)
Provides bidirectional MIDI communication to SSL V-MIDI ports.
"""

import ctypes
import struct
import threading
from typing import Callable, List, Optional, Tuple

# Load CoreMIDI & CoreFoundation
coremidi = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreMIDI.framework/CoreMIDI')
cf = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

# String constants
kMIDIPropertyDisplayName = ctypes.c_void_p.in_dll(coremidi, 'kMIDIPropertyDisplayName')

# CF functions
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p

cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint]
cf.CFStringGetCString.restype = ctypes.c_bool

cf.CFRelease.argtypes = [ctypes.c_void_p]

# CoreMIDI signatures
coremidi.MIDIGetNumberOfSources.restype = ctypes.c_uint
coremidi.MIDIGetSource.argtypes = [ctypes.c_uint]
coremidi.MIDIGetSource.restype = ctypes.c_void_p

coremidi.MIDIGetNumberOfDestinations.restype = ctypes.c_uint
coremidi.MIDIGetDestination.argtypes = [ctypes.c_uint]
coremidi.MIDIGetDestination.restype = ctypes.c_void_p

coremidi.MIDIObjectGetStringProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIObjectGetStringProperty.restype = ctypes.c_int32

coremidi.MIDIClientCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIClientCreate.restype = ctypes.c_int32

coremidi.MIDIClientDispose.argtypes = [ctypes.c_void_p]
coremidi.MIDIClientDispose.restype = ctypes.c_int32

MIDIReadProc = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)

coremidi.MIDIInputPortCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, MIDIReadProc, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIInputPortCreate.restype = ctypes.c_int32

coremidi.MIDIOutputPortCreate.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIOutputPortCreate.restype = ctypes.c_int32

coremidi.MIDIPortConnectSource.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIPortConnectSource.restype = ctypes.c_int32

coremidi.MIDIPortDisconnectSource.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDIPortDisconnectSource.restype = ctypes.c_int32

coremidi.MIDIPortDispose.argtypes = [ctypes.c_void_p]
coremidi.MIDIPortDispose.restype = ctypes.c_int32

coremidi.MIDISend.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
coremidi.MIDISend.restype = ctypes.c_int32

coremidi.MIDIPacketListInit.argtypes = [ctypes.c_void_p]
coremidi.MIDIPacketListInit.restype = ctypes.c_void_p

coremidi.MIDIPacketListAdd.argtypes = [
    ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
    ctypes.c_uint64, ctypes.c_size_t, ctypes.c_char_p
]
coremidi.MIDIPacketListAdd.restype = ctypes.c_void_p


def get_endpoint_name(endpoint: ctypes.c_void_p) -> str:
    """Read display name of a MIDI endpoint."""
    cf_str = ctypes.c_void_p()
    status = coremidi.MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, ctypes.byref(cf_str))
    if status == 0 and cf_str:
        buf = ctypes.create_string_buffer(256)
        cf.CFStringGetCString(cf_str, buf, 256, 0x08000100)  # UTF-8
        cf.CFRelease(cf_str)
        return buf.value.decode('utf-8', errors='replace')
    return 'Unknown'


def list_sources() -> List[Tuple[int, str, ctypes.c_void_p]]:
    """List all available MIDI source endpoints."""
    count = coremidi.MIDIGetNumberOfSources()
    res = []
    for i in range(count):
        ep = coremidi.MIDIGetSource(i)
        res.append((i, get_endpoint_name(ep), ep))
    return res


def list_destinations() -> List[Tuple[int, str, ctypes.c_void_p]]:
    """List all available MIDI destination endpoints."""
    count = coremidi.MIDIGetNumberOfDestinations()
    res = []
    for i in range(count):
        ep = coremidi.MIDIGetDestination(i)
        res.append((i, get_endpoint_name(ep), ep))
    return res


class CoreMIDIAdapter:
    """Manages CoreMIDI Client, Input Port, and Output Port."""

    def __init__(self, client_name: str = "UAMCUBridge"):
        self.client_name = client_name
        self.client_ref = ctypes.c_void_p()
        self.in_port_ref = ctypes.c_void_p()
        self.out_port_ref = ctypes.c_void_p()
        self.source_endpoint = None
        self.dest_endpoint = None
        self.callback: Optional[Callable[[bytes], None]] = None
        self._c_callback_holder = None  # Prevent GC
        self._send_lock = threading.Lock()
        self.is_connected = False

    def connect(self, source_name_substr: str, dest_name_substr: str, on_midi_received: Callable[[bytes], None]) -> bool:
        """Connect to source and destination matching the substring (e.g. 'SSL V-MIDI Port 3')."""
        self.callback = on_midi_received

        # Locate endpoints
        sources = list_sources()
        for idx, name, ep in sources:
            if source_name_substr.lower() in name.lower():
                self.source_endpoint = ep
                self.source_name = name
                break

        dests = list_destinations()
        for idx, name, ep in dests:
            if dest_name_substr.lower() in name.lower():
                self.dest_endpoint = ep
                self.dest_name = name
                break

        if not self.source_endpoint:
            print(f"[CoreMIDI] Could not find MIDI source matching '{source_name_substr}'")
            return False

        if not self.dest_endpoint:
            print(f"[CoreMIDI] Could not find MIDI destination matching '{dest_name_substr}'")
            return False

        # Create Client
        c_name = cf.CFStringCreateWithCString(None, self.client_name.encode('utf-8'), 0x08000100)
        status = coremidi.MIDIClientCreate(c_name, None, None, ctypes.byref(self.client_ref))
        cf.CFRelease(c_name)
        if status != 0:
            print(f"[CoreMIDI] Failed to create MIDI Client, status {status}")
            return False

        # Input Port with Read Callback
        def _read_proc(pktlist_ptr, refcon, conn_refcon):
            if not pktlist_ptr or not self.callback:
                return
            try:
                # Read numPackets (UInt32 at offset 0)
                num_packets = struct.unpack_from('<I', ctypes.string_at(pktlist_ptr, 4), 0)[0]
                cur_pkt_addr = pktlist_ptr + 4
                for _ in range(num_packets):
                    # Header: UInt64 timeStamp (8 bytes) + UInt16 length (2 bytes)
                    hdr = struct.unpack_from('<QH', ctypes.string_at(cur_pkt_addr, 10), 0)
                    pkt_len = hdr[1]
                    data_bytes = ctypes.string_at(cur_pkt_addr + 10, pkt_len)
                    if data_bytes:
                        self.callback(data_bytes)
                    # Next packet offset: (cur_pkt_addr + 10 + length + 3) & ~3
                    cur_pkt_addr = (cur_pkt_addr + 10 + pkt_len + 3) & ~3
            except Exception as e:
                print(f"[CoreMIDI] Error processing packet: {e}")

        self._c_callback_holder = MIDIReadProc(_read_proc)

        in_name = cf.CFStringCreateWithCString(None, b"MCUInPort", 0x08000100)
        status = coremidi.MIDIInputPortCreate(
            self.client_ref, in_name, self._c_callback_holder, None, ctypes.byref(self.in_port_ref)
        )
        cf.CFRelease(in_name)
        if status != 0:
            print(f"[CoreMIDI] Failed to create Input Port, status {status}")
            self.close()
            return False

        # Output Port
        out_name = cf.CFStringCreateWithCString(None, b"MCUOutPort", 0x08000100)
        status = coremidi.MIDIOutputPortCreate(self.client_ref, out_name, ctypes.byref(self.out_port_ref))
        cf.CFRelease(out_name)
        if status != 0:
            print(f"[CoreMIDI] Failed to create Output Port, status {status}")
            self.close()
            return False

        # Connect Source to Input Port
        status = coremidi.MIDIPortConnectSource(self.in_port_ref, self.source_endpoint, None)
        if status != 0:
            print(f"[CoreMIDI] Failed to connect source '{self.source_name}', status {status}")
            self.close()
            return False

        self.is_connected = True
        print(f"[CoreMIDI] Connected to '{self.source_name}' and '{self.dest_name}'")
        return True

    def send_midi(self, data: bytes):
        """Send raw MIDI message bytes to the connected destination."""
        if not self.is_connected or not self.dest_endpoint:
            return

        with self._send_lock:
            # Buffer for MIDIPacketList (1024 bytes)
            buf = ctypes.create_string_buffer(max(1024, len(data) + 64))
            pkt = coremidi.MIDIPacketListInit(buf)
            pkt = coremidi.MIDIPacketListAdd(
                buf, len(buf), pkt, 0, len(data), ctypes.c_char_p(data)
            )
            if pkt:
                coremidi.MIDISend(self.out_port_ref, self.dest_endpoint, buf)

    def close(self):
        """Cleanly close and dispose ports and client."""
        if self.in_port_ref and self.source_endpoint:
            try:
                coremidi.MIDIPortDisconnectSource(self.in_port_ref, self.source_endpoint)
            except Exception:
                pass

        if self.in_port_ref:
            coremidi.MIDIPortDispose(self.in_port_ref)
            self.in_port_ref = ctypes.c_void_p()

        if self.out_port_ref:
            coremidi.MIDIPortDispose(self.out_port_ref)
            self.out_port_ref = ctypes.c_void_p()

        if self.client_ref:
            coremidi.MIDIClientDispose(self.client_ref)
            self.client_ref = ctypes.c_void_p()

        self.is_connected = False
        print("[CoreMIDI] Closed and released resources.")
