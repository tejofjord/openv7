# Vendor driver — static analysis notes

Findings from the **stock Windows driver** for the Numark V7 (Ploytec / "Numark
USB Audio" **v2.9.64**, built 2014-05-23), obtained by examining the installed
driver binaries on a Windows 11 machine with the V7 attached.

This complements [PROTOCOL.md](PROTOCOL.md), which records what has been
confirmed on the wire. Nothing here is a substitute for a capture — these are
*strong hints about mechanism*, extracted from the driver's own debug strings.

Legend: 🧩 from driver static analysis (not yet confirmed on the wire) ·
✅ corroborated by observed behaviour.

## ⚠️ The driver is a shared Ploytec codebase

`v7_usb.sys` is **not V7-specific**. Its strings name a whole family of Ploytec
OEM devices:

- TEAC / Tascam `US-322`, `US-366`, `US-600`, `US-1200`, `UH-7000`
- Electrix `EBOX44` (`VENDOR_HANPIN`)
- Elektron (dedicated isoc-in paths: `rtsIsocInputElektron`)
- "Analog4", "crimson", "DOTEC i64", XMOS-based products

So a string's presence does **not** prove the V7 has the feature. In particular
`WM8776` codec access, `RIAA filter channel 1+2 / 3+4`, and the
`MuteLIn / MuteROut / Monitor / MonitorSelection / Master / MicFace` mixer
controls most likely belong to the TEAC siblings, **not** the V7. Treat
anything hardware-specific as unattributed until a capture or the control panel
confirms it on this unit.

What *is* safe to carry over is the **transport architecture**, because that is
the code path every one of these devices runs through — including ours.

## Package layout

| INF | Driver | Binds to | Role |
|---|---|---|---|
| `oem121.inf` | `v7_usb.sys` (503 KB) | `USB\VID_15E4&PID_0075` | USB transport — owns the whole device |
| `oem129.inf` | `v7_midi.sys` (32 KB) | `USB\…&MI_00` | WDM MIDI port (`NUMARK_V7_MIDI01`) |
| `oem142.inf` | `v7_wdm.sys` (57 KB) | `MEDIA\NUMARKV7AUDIOADAPTER` | WDM audio (wave + mixer) |

`v7_midi.sys` original filename is `nmrkusbm.sys`; copyright *Ploytec GmbH
2000-2013*, Schopfheim. All three are `SERVICE_DEMAND_START` (`Start=3`).

The audio INF registers `KSCATEGORY_CAPTURE` as well as `KSCATEGORY_RENDER`,
and Windows enumerates both a `Speakers (Numark V7 Audio)` **and** a
`Line In (Numark V7 Audio)` endpoint — see the PROTOCOL.md correction below.

## 🧩 The keepalive — answers OpenV7 open item #1

The driver has a **dedicated keepalive pipe and transaction stream**, separate
from the audio in/out streams:

```
m_pcOutPipeKeepAlive is %p
m_pcOutPipeKeepAlive->Handle is %p
PGDevice::requestIOKeepAlive() no free-irp found
PGKernelDevice::isocWriteCompleteKeepAlive !m_bStreamingStarted
initNextTransactionKeepAlive CALLBACK to late current:%d diff:%d NTF:%d lostFrames:%d
```

Three things follow, and together they explain the long-idle stall:

1. **It is a first-class transaction stream.** The keepalive has its own
   `initNextTransaction…` scheduler, exactly parallel to the audio ones:

   ```
   initNextTransactionIn        to late current:%d diff:%d NTF:%d lostFrames:%d
   initNextTransactionOut       to late current:%d diff:%d NTF:%d lostFrames:%d
   initNextTransactionKeepAlive CALLBACK to late …
   ```

   `NTF` = next transaction frame. Transactions are scheduled against the **USB
   frame counter**, not a software timer, and the driver logs when one is late
   and how many frames were lost. A wall-clock `every ~25 ms` keepalive is
   therefore the wrong shape — the vendor driver keeps a *frame-locked* stream
   running.

2. **It is driven from the isochronous write-completion callback**
   (`isocWriteCompleteKeepAlive`), i.e. each completed iso-OUT transfer arms the
   next keepalive. The iso stream *is* the clock for the keepalive.

3. **It runs when audio is not streaming.** The guard is
   `!m_bStreamingStarted` — a dedicated code path for exactly the idle case.
   The driver never lets the pipe go quiet just because nothing is playing.

This matches the observed macOS symptom precisely: OpenV7 sustains the device
while it is actively feeding iso-OUT, and the device stops reporting once that
stream stalls or drifts.

Related, for the MIDI/control direction specifically:

```
USBMidiPattern::initForBulk sr:%d rtsBulkOutFramesPerBlock:%d
rtsProcessBulkOutMIDI iUSBFramesAhead < 0 (%d)
ALERT mRtsBulkOutFramesPerBlock==0
```

Bulk-OUT MIDI is emitted in **blocks of N USB frames**, scheduled a number of
frames *ahead* of the current frame, where N is computed from the sample rate.
That is very likely where the 42-byte control frame comes from — it is a
function of `sr`, not a magic constant.

## 🧩 Recovery — answers OpenV7 open item #2

There is an explicit "stream broken" state machine, deliberately punted off the
interrupt path onto a worker thread:

```
PGDevice::irqlOnStreamBroken from %s
PGDevice::irqlOnStreamBroken() - IRQ Level %d below DISPATCH_LEVEL
PGKernelDevice::handleStreamBroken
PGKernelDevice::dispatchHandleStreamBroken
KernelThreadBank::queueHandleStreamBroken - queued
KernelThreadBank::queueHandleStreamBroken - already queued or currently processing
KernelThreadBank::doHandleStreamBroken - processing
KernelThreadBank::threadedHandleStreamBroken
```

and a device-level reset distinct from a USB port reset:

```
RESET REQUEST TO DEVICE
RESET REQUEST TO DEVICE - from ASIO
IoCallDriver cycle port returned :%08X
```

Note **`cycle port`** — `IOCTL_INTERNAL_USB_CYCLE_PORT`, which re-enumerates the
device from the hub without a physical unplug. That is almost certainly the
"software power cycle" OpenV7 is missing; `libusb_reset_device` is a weaker
operation and its coin-flip behaviour is consistent with that.

Detection inputs feeding the broken-stream path:

```
PGDevice::onAjInPipeHalted m_bStreamingStarted:%d mbDeviceHardwareFailure:%d
PGDevice::onHardwareDeviceFailure - ignore during installation
out of sync during start %d errors
rtsIsocInputElektron ISOC mIsocInNumErrors:%d > MAX:%d
```

i.e. a halted IN pipe or an error counter crossing a threshold triggers it.

## 🧩 Frame pattern — relevant to the audio codec (ROADMAP v2)

The Ploytec bit-sliced format is managed by a "frame pattern" computed from the
stream geometry, with an observer that validates and repairs alignment:

```
InitFramePattern freq:%d bpsin:%d chin:%d bpsout:%d chout:%d
PGFramePatternObserver::isocReadComplete repair len:%d expected frames:%d new:%d
FramePattern Locked - reset nErrorCounter
FPO frame not aligned - received %d bytes
FPO frame not aligned - received:%d expected:%d
```

So the packet layout is parameterised by `(freq, bits-per-sample in/out,
channels in/out)` rather than hardcoded, there is a **lock/relock** concept with
an error counter, and misalignment is detected and repaired rather than being
fatal. Anyone implementing the codec should expect to implement the same
alignment search.

## 🧩 A userspace door into the device

```
PGIOCTL_STD_VENDOR_REQUEST deviceRequest returned:%08X
Error: sPGIOCTL_STD_VENDOR_REQUEST STATUS_INVALID_PARAMETER_3 uBufferLength:%d VENDOR_OR_CLASS_REQUEST:%d
ALERT: pUrb->UrbControlVendorClassRequest.TransferBufferLength(%d) > uLength(%d)
PGKernelDevice::onGenericRequest - pBuffer->mSize(%d) != sizeof(PtIOCTL)(%d)
```

The driver exposes an IOCTL that forwards **arbitrary USB vendor/class control
requests** from userspace to the device. If the IOCTL code and the `PtIOCTL` /
`VENDOR_OR_CLASS_REQUEST` struct layouts can be recovered, the V7 could be
probed interactively on Windows *through the vendor driver* — a far better RE
loop than replaying blind guesses over libusb.

Also present: `readUC3UserFlash` / `writeUC3UserFlash` (`PUC2 - UC3`) — the MCU
is an Atmel AVR32 **UC3** with readable/writable user flash, and
`Scanned Firmware Version is :%08X`.

## Corrections to PROTOCOL.md

- **iso IN `0x81` is not "unused; V7 has no inputs".** The vendor driver
  registers a capture category and Windows enumerates a
  `Line In (Numark V7 Audio - WDM 2.9.64)` endpoint. The V7 does have an input
  path. (Whether it is line-only or line/phono is not established — the `RIAA`
  strings may belong to a TEAC sibling.)
- **The control-OUT keepalive is frame-locked, not timer-based** (see above).

## Reproducing

```
powershell -ExecutionPolicy Bypass -File .\tools\win\strings.ps1 `
    -Path C:\Windows\System32\drivers\v7_usb.sys -Min 5 | Sort-Object
```

Extracted string dumps live in `captures/driver-strings/`.
