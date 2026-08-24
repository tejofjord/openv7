# V7 hardware — what the board actually does

Derived from the Numark V7 (NK14) service manual, Rev 1 (2010-04-13), which is
included in this repository as [`V7-Service-Manual-Rev1-2010.pdf`](V7-Service-Manual-Rev1-2010.pdf), and from measurements on real hardware.

**Why the manual is here.** The V7 was discontinued and its driver abandoned at
macOS 10.12 (2016); on Apple Silicon the hardware is a brick with no vendor
path back. Repairing and interoperating with hardware you own is protected
activity — see the LEGAL section of the [README](../README.md), which cites
DMCA §1201(f) and Article 6 of Directive 2009/24/EC. The document is retained on
a right-to-repair basis so that owners of this deck can keep it working. It
carries a vendor confidentiality notice; it is reproduced here for repair and
interoperability, not for competition with any service business.

## Boards

| Board | Contents |
|---|---|
| **MAIN PCB** (`TWPC09C02201`) | MCU, FPGA, USB, DACs |
| **MOTOR CONTROL PCB** | 3-phase BLDC drive, Hall feedback, its own controller |
| **FUNCTION PCB** | panel switches, 72 LEDs behind nine `74ACT574` latches |
| Switching power, Bleep/Reverse | — |

## Main board parts that matter

| Ref | Part | Role |
|---|---|---|
| U5 | **UPSD3433EV-40U6** | 8051-core MCU with USB, 40 MHz (X1 = 40.000 MHz) |
| U4 | **LCMX0256C-3T100C** | Lattice MachXO FPGA, 100-pin |
| U3 | **ISP1583BS** | NXP USB 2.0 peripheral controller |
| U11, U14 | **CS4345** ×2 | Cirrus stereo DACs → the four outputs |
| X3 | **11.2896 MHz** | audio master clock = 44100 × 256 |

## The platter path

    ENC_PLATTER0/1 ─┐
    ENC_VINYL0/1   ─┤
    FX_ENC0/1      ─┼─► U4 (FPGA) ─ DATA[0..7] + ADDRESS[0..5] ─► U5 (MCU) ─► USB
    UI_ENC0/1      ─┘

**There are two platter encoders**, not one: `ENC_PLATTER` (motor shaft) and
`ENC_VINYL` (the disc the DJ touches). Both are quadrature, and both are counted
**in the FPGA, in hardware** — not in firmware.

That last point has a direct consequence for driver design: **encoder ticks are
never lost, however busy the MCU gets.** Measured over 88 s of motor-driven
rotation, summing the position deltas recovered 33.34 RPM against a documented
33.29, with no drift, across every reporting gap. Position is always true; only
the *reporting cadence* varies.

The encoder signals reach the main board through the **motor PCB connector**,
which also carries `SPI_CLK/CS/MOSI/MISO` between the MCU and the motor
controller.

## Faders are the genuinely high-resolution input

`HIRES_TOP`, `HIRES_WIPER0..3`, `HIRES_BOTTOM`, `HIRES_BANK_SEL` and
`CAP_DISCHARGE` drive `LM339` comparators as a **dual-slope ADC**. This is where
the 14-bit coarse+fine fader pairs in [CONTROL-MAP.md](CONTROL-MAP.md) come
from. "HIRES" refers to the faders, not the platter.

## Clocks, and where the platter timestamp comes from

The `0xE0` timestamp clock measured at **2,822,400 Hz** ([PROTOCOL.md](PROTOCOL.md))
is exactly `11.2896 MHz ÷ 4` — the audio crystal on the main board. So the
platter timestamp is generated from the deck's own oscillator and does not
depend on the host's isochronous stream. Measured median interval 2822 units
against 2825 theoretical, p25/p75 within ±7 units.

## Why a USB reset costs motor control

The motor is a **separate subsystem with its own controller**, reached over SPI.
A USB port reset re-enumerates the main board's USB device; it has no path to
re-arm the motor controller. Measured: after a reset the encoder, buttons and
faders all report normally while the motor ignores every documented start
command until the deck is **power-cycled**. `src/main.c` performs a reset only as
last-resort stall recovery, and says so in its operator message.
