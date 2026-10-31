# ESP32-CAR BLE Protocol v1

## GATT

- Advertised name: `ESP32-CAR-BLE`
- Service: `8E7A0001-9C6B-4A6B-8F31-4C4152434152`
- Command (Write / Write Without Response): `8E7A0002-9C6B-4A6B-8F31-4C4152434152`
- Telemetry (Read / Notify): `8E7A0003-9C6B-4A6B-8F31-4C4152434152`

All multibyte integers are little-endian.

## Command frame — 12 bytes

| Offset | Type | Meaning |
|---:|---|---|
| 0 | UInt8 | Protocol version (`1`) |
| 1 | UInt8 | Opcode |
| 2 | UInt32 | Monotonic sequence (`0...2^31-1`) |
| 6 | Int8 | `vx`, right positive (`-100...100`) |
| 7 | Int8 | `vy`, forward positive (`-100...100`) |
| 8 | Int8 | `omega`, clockwise positive (`-100...100`) |
| 9 | UInt8 | Speed limit (`0...60`) |
| 10 | UInt8 | Reserved flags |
| 11 | UInt8 | CRC-8/ATM over bytes `0...10` (poly `0x07`, init `0`) |

Opcodes:

- `1`: ARM
- `2`: DRIVE
- `3`: STOP
- `4`: ESTOP
- `5`: RESET

For ARM/STOP/ESTOP/RESET, vector and speed fields are zero. Critical commands use BLE write-with-response; DRIVE uses write-without-response at up to 20Hz.

## Telemetry frame — 20 bytes

| Offset | Type | Meaning |
|---:|---|---|
| 0 | UInt8 | Protocol version (`1`) |
| 1 | UInt8 | Safety state: 0 disarmed, 1 armed, 2 estop, 3 fault |
| 2 | UInt8 | Command code |
| 3 | UInt8 | Reason code |
| 4 | UInt8 | Current speed target |
| 5 | Int8 | Front-left target |
| 6 | Int8 | Front-right target |
| 7 | Int8 | Rear-left target |
| 8 | Int8 | Rear-right target |
| 9 | UInt16 | Distance in millimetres; `0xFFFF` means unavailable |
| 11 | UInt8 | Flags |
| 12 | UInt32 | Last accepted sequence |
| 16 | UInt32 | Board uptime in milliseconds |

Flag bits:

- bit 0: sonar valid
- bit 1: obstacle
- bit 2: motor hardware ready
- bit 3: BLE connected
- bit 4: recent remote command

## Safety contract

- A connection starts DISARMED.
- DRIVE before ARM is rejected.
- BLE disconnect immediately stops and disarms the BLE owner.
- App background/inactive sends STOP, clears local input state, and never resumes motion automatically.
- DRIVE must be refreshed while input is active; the board's existing 900ms timeout remains authoritative.
- STOP and ESTOP are always allowed; RESET is only accepted from the emergency-stop owner.
