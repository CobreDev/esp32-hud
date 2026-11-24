# MacHUD Serial Protocol (v1)

Transport: USB-CDC (ESP32-S3 native USB Serial/JTAG). Baud rate is ignored by the
device; the host configures 115200 8N1 raw. All multi-byte integers are **little-endian**.

## Packet layout

Both directions use the same framing:

| Offset | Size | Field    | Notes                                              |
|-------:|-----:|----------|----------------------------------------------------|
| 0      | 1    | magic0   | `0xA5`                                             |
| 1      | 1    | magic1   | `0x5A`                                             |
| 2      | 1    | type     | message type (table below)                         |
| 3      | 1    | seq      | sender-chosen sequence number, echoed in replies   |
| 4      | 4    | length   | payload length in bytes (u32)                      |
| 8      | N    | payload  |                                                    |
| 8+N    | 4    | crc32    | CRC-32 (IEEE 802.3) over bytes `2 .. 8+N-1`         |

The CRC covers type, seq, length and payload. It is the standard reflected CRC-32
(poly `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`, as in zlib's `crc32()`).
Check value: `crc32("123456789") = 0xCBF43926`.

Overhead is 12 bytes per packet.

## Message types

### Host → device

| Type   | Name          | Payload            | Device reply                     |
|--------|---------------|--------------------|----------------------------------|
| `0x01` | HELLO         | none               | HELLO_REPLY                      |
| `0x02` | PING          | none               | PONG                             |
| `0x10` | FRAME         | JPEG bytes         | ACK (after the frame is drawn)   |
| `0x11` | DISPLAY_ON    | none               | ACK                              |
| `0x12` | DISPLAY_OFF   | none               | ACK                              |

### Device → host

| Type   | Name          | Payload                                                     |
|--------|---------------|-------------------------------------------------------------|
| `0x81` | HELLO_REPLY   | ASCII `key=value` pairs separated by `;` (see below)        |
| `0x82` | PONG          | none                                                        |
| `0x90` | ACK           | `seq:u8, status:u8, draw_ms:u16`                            |

`ACK.seq` is the `seq` of the host packet being acknowledged. `draw_ms` is the time the
device spent decoding and drawing (0 for non-frame commands).

ACK status codes:

| Code | Meaning                                                            |
|-----:|--------------------------------------------------------------------|
| 0    | OK                                                                 |
| 1    | BAD_CRC: packet received but checksum mismatch; host should resend |
| 2    | TOO_LARGE: length exceeded `max` (payload was discarded)           |
| 3    | DECODE_FAILED: JPEG could not be decoded                           |
| 4    | DISPLAY_OFF: frame accepted but not drawn because display is off   |
| 5    | UNKNOWN_TYPE                                                       |

### HELLO_REPLY payload

Example: `id=ESP32-HUD;fw=1.0.0;proto=1;w=240;h=240;max=98304`

| Key     | Meaning                                       |
|---------|-----------------------------------------------|
| `id`    | Always `ESP32-HUD`. Used for auto-detection.  |
| `fw`    | Firmware version (semver)                     |
| `proto` | Protocol version (this document = 1)          |
| `w`,`h` | Panel size in pixels                          |
| `max`   | Maximum FRAME payload size in bytes           |

Unknown keys must be ignored.

## FRAME payload

A baseline JPEG of exactly 240×240 pixels (the full round panel, including the corners
that fall outside the visible circle). Progressive JPEGs are not supported by the decoder.
The device decodes it into an off-screen PSRAM sprite and pushes it to the panel in one go.

## Flow control

* The host has **at most one FRAME in flight**. After sending a FRAME it waits for the
  ACK with the matching `seq` before sending the next one. Frames produced in the meantime
  are coalesced: only the newest pending frame is kept.
* ACK timeout: 1.5 s. On timeout the host **resyncs**: discards its receive buffer,
  sends HELLO, and waits up to 1 s for HELLO_REPLY. On success it resends the newest
  frame; after 3 failed resyncs it closes the port and goes back to discovery.
* An ACK with status BAD_CRC triggers one immediate resend of the newest frame.

## Receiver resync (both directions)

The parser hunts for `A5 5A`. A packet is dropped and the parser goes back to hunting when:
* `length` > `max` (device answers ACK/TOO_LARGE, then skips the announced bytes if they arrive
  within the timeout), or
* no byte arrives for 500 ms in the middle of a packet, or
* the CRC fails (device answers ACK/BAD_CRC with the header's `seq`).

## Keepalive and idle screen

The device shows an idle "Waiting for Mac..." screen when no valid packet has been received
for 10 s (unless the display was turned off with DISPLAY_OFF). Because the host only sends
frames when something visibly changes, it sends PING every 3 s while otherwise idle. PING
uses the same one-in-flight slot as FRAME; a PING with no PONG within 1.5 s is treated like an
ACK timeout (resync).

## Display off

DISPLAY_OFF fills the panel black, then sends GC9A01 `DISPOFF (0x28)` and `SLPIN (0x10)`.
The module has no backlight control pin, so the backlight stays lit. Black pixels on a
sleeping panel are as dark as this hardware gets. DISPLAY_ON sends `SLPOUT`/`DISPON`. The host
then sends a fresh FRAME. While off, the idle screen is suppressed.

## Auto-detection (host)

1. Enumerate IOKit `IOSerialBSDClient` services whose USB ancestor has
   `idVendor == 0x303A` (Espressif). Use the callout device (`/dev/cu.*`).
2. Open, configure raw mode, set DTR on and RTS off (on the USB Serial/JTAG controller,
   raising RTS while DTR is low resets the chip, so the host never does that).
3. Send HELLO, accept the port if a HELLO_REPLY with `id=ESP32-HUD` arrives within 1 s.

The host does not take exclusive access (`TIOCEXCL`), so other tools can still open the
port. They will conflict with the HUD stream, though. Use the app's **Release Port** item
before uploading firmware.
