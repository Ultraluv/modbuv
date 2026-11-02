# modbuv

[![Hex.pm](https://img.shields.io/hexpm/v/modbuv.svg)](https://hex.pm/packages/modbuv)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`modbuv` is a high-performance, robust Elixir/OTP Modbus library driven by **numeric function codes** (`1..127`). It provides complete support for **Modbus TCP (Client & Server)** and **Modbus RTU (Master & Slave)**.

Unlike legacy libraries that bind commands to fixed atomic symbols (e.g., `:rhr`, `:rc`), `modbuv` handles any standard or vendor-specific function code without modifying the library or configuring translations.

---

## Features

- **Numeric Function-Code Driven**: Function codes (`1..127`) are passed directly into the API without hardcoded symbol tables.
- **Vendor-Specific Function Codes**: Seamlessly supports proprietary function codes through configurable `FcMap` registries.
- **Robust Framing & Deframing**:
  - **TCP**: Full MBAP header stream framing, handling split packets and coalesced messages.
  - **RTU**: Sliding-window byte-by-byte resynchronization and dynamic frame length deduction via `Circuits.UART.Framing`.
- **Concurrency & Serialization**: RTU Master request serialization with `:busy` protection.
- **Dual Operating Modes**: Both `active` (asynchronous event streaming) and `passive` (synchronous call/confirmation) modes for all roles.
- **Atomic Multi-Writes**: All-or-nothing in-memory register/coil transactions.
- **Pure Function Decoupling**: Pure PDU encoding/decoding and DB state transitions separate from OTP transport processes.
- **Standard Helpers**: IEEE754 32-bit float conversions (big-endian and little-endian word orders) and fast table-driven CRC16.
- **Telemetry**: Start/stop events with RTT for TCP Client and RTU Master requests.

---

## Installation

Add `modbuv` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:modbuv, "~> 0.1.0"}
  ]
end
```

---

## Core Frame Model

Every request frame is represented as a 4-element tuple:

```elixir
{slave, {fc, direction, width}, address, argument}
```

| Field | Type | Description |
|---|---|---|
| `slave` | `0..255` | RTU slave address or TCP Unit ID |
| `fc` | `1..127` | Numeric Modbus function code |
| `direction` | `:r \| :w` | `:r` for read, `:w` for write |
| `width` | `:bit \| :reg` | `:bit` for coils/discrete inputs, `:reg` for 16-bit registers |
| `address` | `0..65535` | 0-based starting address |
| `argument` | integer / list | Read: count (positive integer). Single-write: value (integer). Multi-write: values (non-empty list). |

### Examples

```elixir
# Standard reads
{1, {1, :r, :bit}, 0, 10}             # Read 10 coils starting from address 0
{1, {3, :r, :reg}, 100, 2}            # Read 2 holding registers starting from address 100

# Standard writes
{1, {5, :w, :bit}, 0, 1}              # Write single coil 0 to ON (1)
{1, {6, :w, :reg}, 100, 1234}         # Write single holding register 100
{1, {15, :w, :bit}, 0, [1, 0, 1]}     # Write multiple coils
{1, {16, :w, :reg}, 100, [10, 20]}    # Write multiple holding registers

# Vendor-specific function codes
{1, {0x64, :r, :reg}, 0, 4}           # Vendor function code 0x64 (read 4 registers)
{1, {0x6E, :w, :reg}, 0, [5, 6]}      # Vendor function code 0x6E (multi-register write)
```

---

## Usage Guide

### 1. Modbus TCP Client

#### Passive Mode (Synchronous)

```elixir
alias Modbuv.Tcp.Client

# Start and connect
{:ok, c} = Client.start_link(ip: {192, 168, 1, 10}, tcp_port: 502, timeout: 2_000)
:ok = Client.connect(c)

# Read holding registers
:ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})
{:ok, [10, 20]} = Client.confirmation(c)

# Write holding registers
:ok = Client.request(c, {1, {16, :w, :reg}, 0, [30, 40]})
:ok = Client.confirmation(c)

# Clean up
Client.close(c)
Client.stop(c)
```

#### Active Mode (Asynchronous Notifications)

```elixir
# Responses are delivered directly to d_pid (defaults to calling process)
{:ok, c} = Client.start_link(ip: {127, 0, 0, 1}, tcp_port: 502, active: true, d_pid: self())
:ok = Client.connect(c)

:ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})

receive do
  {:modbuv_tcp, {1, {3, :r, :reg}, 0, 2}, [10, 20]} ->
    IO.puts("Received registers asynchronously!")
  {:modbuv_tcp, frame, {:error, reason}} ->
    IO.puts("Request failed: #{inspect(reason)}")
end
```

---

### 2. Modbus TCP Server

```elixir
alias Modbuv.Tcp.Server

# Define initial data model
# Format: %{slave_id => %{{region, address} => value}}
# Regions: :c (coil), :i (discrete input), :hr (holding register), :ir (input register)
model = %{
  1 => %{
    {:c, 0} => 1,
    {:hr, 0} => 10,
    {:hr, 1} => 20
  }
}

# Start server listening on port 502 (or 0 for ephemeral port)
{:ok, server} = Server.start_link(port: 502, model: model)

# Directly update or query server DB from Elixir
Server.update(server, {1, {6, :w, :reg}, 0, 99})
[99] = Server.update(server, {1, {3, :r, :reg}, 0, 1})
db = Server.get_db(server)

# Stop server cleanly
Server.stop(server)
```

---

### 3. Modbus RTU Master

```elixir
alias Modbuv.Rtu.Master

# Start master on serial port
{:ok, master} =
  Master.start_link(
    tty: "/dev/ttyUSB0",
    timeout: 1_000,
    uart_opts: [speed: 9600, data_bits: 8, stop_bits: 1, parity: :none]
  )

# Send request (Master automatically derives response length and verifies CRC)
{:ok, [10, 20]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})
:ok = Master.request(master, {1, {6, :w, :reg}, 0, 99})

# Stop master
Master.stop(master)
```

---

### 4. Modbus RTU Slave

```elixir
alias Modbuv.Rtu.Slave

model = %{
  1 => %{
    {:hr, 0} => 10,
    {:hr, 1} => 20
  }
}

{:ok, slave} =
  Slave.start_link(
    tty: "/dev/ttyUSB1",
    model: model,
    timeout: 1_000,
    uart_opts: [speed: 9600, data_bits: 8, stop_bits: 1, parity: :none]
  )

# Query local DB
current_db = Slave.get_db(slave)

# Stop slave
Slave.stop(slave)
```

---

### 5. Vendor Custom Function Codes (`FcMap`)

For Server and Slave roles, function codes are mapped to memory regions using `Modbuv.FcMap`. You can register custom function codes during startup:

```elixir
# Register:
# - FC 0x64 as a read of holding registers (:hr)
# - FC 0x6E as a multiple-write of holding registers (:hr, :multi)
custom_map = %{
  0x64 => {:r, :reg, :hr},
  0x6E => {:w, :reg, :hr, :multi}
}

# Provide to TCP Server or RTU Slave
{:ok, server} = Modbuv.Tcp.Server.start_link(port: 502, model: model, fc_map: custom_map)
{:ok, slave}  = Modbuv.Rtu.Slave.start_link(tty: "/dev/ttyUSB1", model: model, fc_map: custom_map)
```

---

### 6. Helpers

#### IEEE754 Float Conversion

```elixir
alias Modbuv.IEEE754

# Big-endian (high register first)
IEEE754.from_2_regs(0x40A0, 0x0000, :be)    # => 5.0
IEEE754.to_2_regs(5.0, :be)                 # => [0x40A0, 0x0000]

# Little-endian (low register first)
IEEE754.from_2_regs(0x0000, 0x40A0, :le)    # => 5.0
IEEE754.to_2_regs(5.0, :le)                 # => [0x0000, 0x40A0]

# Multiple floats
IEEE754.from_2n_regs([0xC0A0, 0x0000, 0x40A0, 0x0000], :be) # => [-5.0, 5.0]
```

#### CRC16 Calculation

```elixir
Modbuv.CRC.crc(<<0x01, 0x03, 0x00, 0x00, 0x00, 0x01>>) # => 0x0A84
```

---

### 7. Telemetry

TCP Client and RTU Master requests emit `[:modbuv, :request, :start]` and
`[:modbuv, :request, :stop]` events:

```elixir
:telemetry.attach(
  "modbuv-rtt",
  [:modbuv, :request, :stop],
  fn _event, %{duration: duration}, metadata, _config ->
    rtt_us = System.convert_time_unit(duration, :native, :microsecond)

    IO.puts(
      "#{metadata.transport} #{metadata.slave}/#{metadata.fc} " <>
        "rtt=#{rtt_us}us result=#{metadata.result}"
    )
  end,
  nil
)
```

- Stop measurements are `%{duration: native, monotonic_time: native}`; RTT is
  `duration`.
- Metadata is `%{transport: :tcp | :rtu, role: :client | :master, mode: :passive | :active, slave: slave, fc: fc}`.
  The stop event adds `result: :ok | :error` and `reason: nil | term`.
- Loss rate: count stop events with `result: :error` (for example
  `reason: :timeout`).
- Requests still in flight when the client is closed do not emit a stop event.
  Active mode also has no per-request timeout, so a lost active response is not
  reported. Use passive mode when you need loss detection.

---

## Testing

```bash
# Run the standard suite (hardware-tagged tests excluded)
mix test

# Run the full suite including the two RTU virtual-serial tests
socat -d -d pty,raw,echo=0,link=/tmp/modbuv_tnt0 pty,raw,echo=0,link=/tmp/modbuv_tnt1 &
MODBUV_TTY_MASTER=/tmp/modbuv_tnt0 MODBUV_TTY_SLAVE=/tmp/modbuv_tnt1 mix test --include hardware
```

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
