# Changelog

## 0.1.0 - 2026-10-31

### Features
- **Numeric Function-Code Driven**: API driven directly by numeric function codes (`1..127`), without hardcoding fixed operation atoms.
- **Universal Frame Model**: Unified `{slave, {fc, direction, width}, address, argument}` frame tuple across all roles.
- **Modbus TCP**:
  - `Modbuv.Tcp.Client`: Supports both passive (synchronous) and active (asynchronous event streaming) modes, stream MBAP deframing, unit ID validation, and stale response isolation.
  - `Modbuv.Tcp.Server`: Connection-per-handler architecture using `DynamicSupervisor`, in-memory shared data model, clean port collision stop, and active owner notifications.
- **Modbus RTU**:
  - `Modbuv.Rtu.Master`: In-flight serialization with `:busy` protection, automatic response length derivation, and fault-tolerant UART I/O.
  - `Modbuv.Rtu.Slave`: Integrated with `Circuits.UART.Framing`, dynamic frame length derivation via `fc_map`, automatic sliding-window byte resync, and safe `rx_framing_timeout` merging.
- **Custom Function Codes (`FcMap`)**: Extensible registry supporting vendor function codes with customizable direction, width, address region, and single/multi write layout.
- **In-Memory Model & Shared Agent**: Atomic multi-address writes, pure `Modbuv.Model` operations, and thread-safe `Modbuv.Model.Shared` Agent.
- **Helpers**:
  - `Modbuv.CRC`: Fast, table-driven CRC16 calculation.
  - `Modbuv.IEEE754`: 32-bit and 64-bit float conversions with big-endian (`:be`) and little-endian (`:le`) word order support.
  - Comprehensive exception mapping covering standard codes (1..11) and vendor/zero codes.
