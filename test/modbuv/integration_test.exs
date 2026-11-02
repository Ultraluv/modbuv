defmodule Modbuv.IntegrationTest do
  use ExUnit.Case, async: false
  alias Modbuv.Tcp.{Client, Server}

  @model %{
    1 => %{
      {:c, 0} => 1,
      {:c, 1} => 0,
      {:i, 0} => 1,
      {:hr, 0} => 10,
      {:hr, 1} => 11,
      {:ir, 0} => 20
    }
  }

  setup do
    {:ok, server} =
      Server.start_link(port: 0, model: @model, fc_map: %{0x64 => {:r, :reg, :hr}})

    {:ok, client} =
      Client.start_link(
        ip: {127, 0, 0, 1},
        tcp_port: :sys.get_state(server).port,
        timeout: 1_000
      )

    :ok = Client.connect(client)
    %{server: server, client: client}
  end

  test "all standard function codes plus a vendor read", %{client: c, server: s} do
    assert :ok = Client.request(c, {1, {1, :r, :bit}, 0, 2})
    assert {:ok, [1, 0]} = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {2, :r, :bit}, 0, 1})
    assert {:ok, [1]} = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})
    assert {:ok, [10, 11]} = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {4, :r, :reg}, 0, 1})
    assert {:ok, [20]} = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {5, :w, :bit}, 1, 1})
    assert :ok = Client.confirmation(c)
    assert Server.get_db(s)[1][{:c, 1}] == 1

    assert :ok = Client.request(c, {1, {6, :w, :reg}, 1, 99})
    assert :ok = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {15, :w, :bit}, 0, [1, 1]})
    assert :ok = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {16, :w, :reg}, 0, [7, 8]})
    assert :ok = Client.confirmation(c)

    assert :ok = Client.request(c, {1, {0x64, :r, :reg}, 0, 2})
    assert {:ok, [7, 8]} = Client.confirmation(c)
  end

  test "vendor multi-write" do
    {:ok, server} =
      Server.start_link(
        port: 0,
        model: @model,
        fc_map: %{0x6E => {:w, :reg, :hr, :multi}}
      )

    {:ok, client} =
      Client.start_link(
        ip: {127, 0, 0, 1},
        tcp_port: :sys.get_state(server).port,
        timeout: 1_000
      )

    :ok = Client.connect(client)
    assert :ok = Client.request(client, {1, {0x6E, :w, :reg}, 0, [5, 6]})
    assert :ok = Client.confirmation(client)
    assert Server.get_db(server)[1][{:hr, 1}] == 6
  end
end
