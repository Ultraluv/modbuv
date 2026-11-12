defmodule Modbuv.Rtu.VirtualBusTest do
  use ExUnit.Case, async: true

  alias Modbuv.Rtu.VirtualBus

  test "attaches peers, tracks them, and detaches cleanly" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, bus} = VirtualBus.start_link(name: bus_name)

    assert VirtualBus.peers(bus) == []

    p1 = spawn(fn -> Process.sleep(5_000) end)
    p2 = spawn(fn -> Process.sleep(5_000) end)

    assert :ok == VirtualBus.attach(bus, p1)
    assert :ok == VirtualBus.attach(bus, p2)

    peers = VirtualBus.peers(bus)
    assert length(peers) == 2
    assert p1 in peers
    assert p2 in peers

    assert :ok == VirtualBus.detach(bus, p1)
    assert VirtualBus.peers(bus) == [p2]

    Process.exit(p1, :kill)
    Process.exit(p2, :kill)
  end

  test "broadcasts data to all peers except sender" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, bus} = VirtualBus.start_link(name: bus_name)

    me = self()
    p2 = spawn(fn ->
      receive do
        {:virtual_bus_data, sender, data} -> send(me, {:p2_got, sender, data})
      end
    end)

    VirtualBus.attach(bus, self())
    VirtualBus.attach(bus, p2)

    VirtualBus.broadcast(bus, self(), <<1, 2, 3>>)

    # Self should not receive anything
    refute_receive {:virtual_bus_data, _, _}, 100

    # Peer 2 receives it
    assert_receive {:p2_got, ^me, <<1, 2, 3>>}, 500

    Process.exit(p2, :kill)
  end

  test "automatically cleans up crashed peers via process monitor" do
    bus_name = :"bus_#{System.unique_integer([:positive])}"
    {:ok, bus} = VirtualBus.start_link(name: bus_name)

    peer = spawn(fn -> Process.sleep(5_000) end)
    VirtualBus.attach(bus, peer)
    assert VirtualBus.peers(bus) == [peer]

    Process.exit(peer, :kill)
    Process.sleep(50)

    assert VirtualBus.peers(bus) == []
  end
end

