# USB captures — filtered

Raw USBPcap captures of the V7 running under the **stock Ploytec/Numark vendor
driver v2.9.64** on Windows. These are the reference: the OEM stack driving this
deck correctly.

## Why filtered

The originals total **~309 MB**, and `idle-USBPcap1.pcap` alone is 192 MB —
past GitHub's hard 100 MB per-file limit, so it cannot be pushed at all. Almost
all of that bulk is isochronous audio padding, which is not what makes the
captures interesting.

Filtering to the **control** traffic — bulk IN `0x83`, bulk OUT `0x04`, and EP0
control transfers — gives **2.0 MB total**, a 150× reduction with nothing of
value lost:

```
tshark -r <original>.pcap \
  -Y 'usb.endpoint_address==0x83 || usb.endpoint_address==0x04 || usb.transfer_type==0x02 || usb.transfer_type==0xfe' \
  -w <name>-control.pcap
```

The unfiltered originals stay in `captures/raw/`, which is gitignored. They are
re-capturable with the `tools/win/capture-*.ps1` scripts.

## What each contains

| File | Packets | Contents |
|---|---|---|
| `idle-USBPcap1-control.pcap` | 24,332 | **The valuable one.** 45 s idle, 12 s motor running, 30 s idle. The motor phase carries 12,161 platter frames on `0x83` — the raw side of experiment X1 |
| `sweep-USBPcap3-control.pcap` | 996 | Every output message swept at the raw USB level. **996 packets out, 0 in** — the device answers nothing, which is why there is no interrogation path |
| `init-USBPcap1-control.pcap` | 10 | ⚠️ Despite the name this is a **recovery**, not a cold handshake. Its one interesting packet is `bRequest 9` (SET_CONFIGURATION) with 8 bytes, corroborating the documented recovery sequence. A cold vendor init is **not** on disk — the filter missed it, or a device-node disable/enable does not replay one |
| `audio-USBPcap3-control.pcap` | 0 | Empty by construction: that capture is entirely isochronous, so nothing survives a control filter. Kept so its absence is not mistaken for a lost file |

## Derived data

`platter-frames.tsv` is the extracted `0x83` payload stream from the idle
capture's motor phase — timestamp, length, hex — produced by:

```
tshark -r idle-USBPcap1.pcap -Y 'usb.endpoint_address==0x83 && usb.data_len>0' \
       -T fields -e frame.time_relative -e usb.data_len -e usb.capdata
```

Analyse it with `tools/win/parse-control-stream.ps1`, which reconstructs the
byte stream correctly. **Do not parse the 42-byte frames independently** — see
that script's header, and `docs/PROTOCOL.md`, for why: MIDI messages span frame
boundaries and ~12 % of frames begin mid-message.
