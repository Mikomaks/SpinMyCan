# Trouble codes (FI light): reading and clearing

How SpinMyCan reads and clears the stored trouble codes of the Suzuki GSX-S1000GX through the
optional CAN board. In the app: **Settings → CAN bridge → Fault codes (FI)**.

Needs board firmware **v11** or newer (the app offers the update over Bluetooth).

## Two sources of codes

| | Frame `0x441` (passive) | OBD request (active) |
|---|---|---|
| What | the bike's own list of stored codes, broadcast about 9 times a second | standard OBD-II services on CAN (ISO 15765-4) |
| Board transmits? | **no** — listen only | yes, for a few seconds |
| Works with engine running? | yes | no — the board refuses |
| Used for | **Read**, and the check after clearing | **Clear** (service `04`), **OBD test** (service `03`) |

Why the passive list is the one shown: on this bike OBD service `03` reports only
emission-related codes and answered "no codes" while the FI light was on and `0x441` listed
five codes (2026-10-25). The list in `0x441` is what matches the light.

### Frame `0x441`

One frame carries one code; the bike cycles through the list.

| Byte | Meaning |
|---|---|
| 1–2 | the code, SAE J2012 encoding (below) |
| 3 | number of stored codes (0 = none; then bytes 0–5 are zero) |
| 4 | position of this code in the list, 1…n |
| 6 | rolling counter |

Code encoding (the same in OBD replies): bits 7–6 of the first byte are the letter
(`00` P, `01` C, `10` B, `11` U), bits 5–4 the first digit, the remaining 12 bits three hex
digits. Example: `C1 55` → `U0155`.

This layout was worked out from recordings of our own motorcycle, not from Suzuki documentation.
`P1xxx` codes are manufacturer-specific and their meaning is not known to the app.

## What the buttons do

**Read** — listens for `0x441` for up to 6 s and stops as soon as every position of the list
(or two "no codes" frames) has been seen. Nothing is sent to the bus.

**Clear codes** — one button, the whole procedure:

1. read the list (as above),
2. send the clear request, service `04`: first straight to the engine control unit (`0x7E0`),
   then, only if nobody confirmed, to the general address `0x7DF`, then the 29-bit general
   address `0x18DB33F1`; a positive reply is `44`,
3. wait a moment and read the list again,
4. say what really happened: *cleared and the list is empty*, *confirmed but the codes are
   back* (the fault is still present), *the control unit refused* (with the reason), or
   *nobody answered*.

It takes up to about half a minute. Conditions: ignition on, engine **off**, bike standing.
Clearing a code does not repair anything — if the fault is still there, the code and the
light come back.

**OBD test** — sends the read request (service `03`) to all three addresses and shows every
reply, raw. For checking how a bike answers; not needed in normal use.

## Safety rules of the board

The board is listen-only. It switches the CAN controller to normal mode only for the duration
of one command and always switches back, whatever the outcome. The rules live in
`firmware/can-ble-bridge/src/diag_core.h` so they can be tested without hardware
(`make can-test`):

- a command runs only when the phone asks for it, at most once every 3 s,
- refused when the engine runs or a wheel turns, and when the bus is silent (ignition off),
- at most 3 requests and 8 flow-control frames per command,
- every frame is sent single-shot; a frame that lost arbitration or was not acknowledged is
  repeated at most 3 times, and one command never makes more than 16 transmissions,
- the command ends after 2 s of silence (5.5 s after a "please wait" reply), hard limit 9 s.

Why the repeats: the bus is about half full (roughly 2000 frames a second) and diagnostic
frames have the lowest priority, so a single-shot frame often loses arbitration and is dropped.
Before v11 that made reading and clearing work only some of the time.

## Messages and what to do

| Message | Meaning |
|---|---|
| Can't see the code list on the bus | ignition off, or the Bluetooth link to the board is weak — try again |
| The board refused: engine running or a wheel turning | switch the engine off, leave the ignition on |
| The control unit refused to clear: conditions not met | same as above, on the bike's side |
| Confirmed, but the codes are on the list again | the fault is still present — fix the cause |
| The request did not get onto the bus | bus too busy or wiring problem — try again; if it repeats, check CAN-H / CAN-L |
| No control unit answered | ignition off or engine running; otherwise run **OBD test** and look at the replies |

Every attempt is written to the link log (`canlogs/link_*.csv`, lines `E,…,diag,…`) with the
lists before and after, the replies and the transmission counters.

## References

- SAE J1979 / ISO 15031-5 — OBD services (`03` read stored codes, `04` clear)
- ISO 15765-4 — OBD on CAN: addresses, timing; ISO 15765-2 — multi-frame replies
- SAE J2012 — trouble code format and the generic code list
- Code: `MySpin/ObdDiagnostics.swift`, `MySpin/BikeLinkManager.swift` (section "Trouble codes"),
  `firmware/can-ble-bridge/src/diag_core.h`; tests: `MySpin/FeatureSelfTest.swift`,
  `tools/can/fw_core_test.cpp`
