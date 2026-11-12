defmodule Modbuv.Rtu.Transport.VirtualTest do
  use ExUnit.Case, async: true

  alias Modbuv.Rtu.Transport.Virtual
  alias Modbuv.Rtu.{Framer, VirtualBus}

  test "passive mode: read immediately when buffer is ready, or blocks until data arrives or timeout" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, v1} = Virtual.start_link()
    {:ok, v2} = Virtual.start_link()

    assert :ok = Virtual.open(v1, "virtual", virtual_bus: bus_name, active: false)
    assert :ok = Virtual.open(v2, "virtual", virtual_bus: bus_name, active: false)

    # v1 reads with 50ms timeout when nothing sent -> {:ok, ""}
    assert {:ok, ""} = Virtual.read(v1, 50)

    # v2 writes data, v1 reads it
    :ok = Virtual.write(v2, <<0xAA, 0xBB>>)
    assert {:ok, <<0xAA, 0xBB>>} = Virtual.read(v1, 500)

    Virtual.stop(v1)
    Virtual.stop(v2)
  end

  test "active mode: runs framer and dispatches framed messages to owner" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, receiver} = Virtual.start_link()
    {:ok, sender} = Virtual.start_link()

    assert :ok =
             Virtual.open(receiver, "virtual",
               virtual_bus: bus_name,
               active: true,
               framing: {Framer, []}
             )

    assert :ok = Virtual.open(sender, "virtual", virtual_bus: bus_name, active: false)

    # Pack a valid Modbus RTU frame
    valid_frame = Modbuv.Rtu.pack_req({1, {3, :r, :reg}, 0, 2})

    # Send in chunks to test framer accumulation over virtual bus
    <<chunk1::binary-size(4), chunk2::binary>> = valid_frame
    :ok = Virtual.write(sender, chunk1)
    :ok = Virtual.write(sender, chunk2)

    assert_receive {:circuits_uart, "virtual", ^valid_frame}, 500

    Virtual.stop(receiver)
    Virtual.stop(sender)
  end

  test "flush and configure operations" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, v} = Virtual.start_link()
    assert :ok = Virtual.open(v, "virtual", virtual_bus: bus_name, active: false)

    # Inject data into bus
    VirtualBus.broadcast(bus_name, nil, <<1, 2, 3>>)
    Process.sleep(20)

    assert :ok = Virtual.flush(v)
    assert {:ok, ""} = Virtual.read(v, 20)

    assert :ok = Virtual.configure(v, framing: {Framer, []})

    Virtual.stop(v)
  end
end
