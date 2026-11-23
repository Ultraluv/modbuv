defmodule Modbuv.RtuVirtualTest do
  use ExUnit.Case, async: true

  alias Modbuv.Rtu.{Master, Slave}

  @model %{
    1 => %{
      {:hr, 0} => 10,
      {:hr, 1} => 11,
      {:c, 0} => 1,
      {:c, 1} => 0
    },
    2 => %{
      {:hr, 0} => 200,
      {:hr, 1} => 201
    }
  }

  setup do
    bus_name = :"vbus_#{System.unique_integer([:positive])}"
    tty = "virtual:#{bus_name}"
    {:ok, %{tty: tty}}
  end

  test "master reads and writes slave over in-memory virtual bus without hardware", %{tty: tty} do
    {:ok, slave} = Slave.start_link(tty: tty, model: @model)
    {:ok, master} = Master.start_link(tty: tty, timeout: 1_000)

    # 1. Read holding registers (FC 3)
    assert {:ok, [10, 11]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})

    # 2. Write single holding register (FC 6)
    assert :ok = Master.request(master, {1, {6, :w, :reg}, 1, 99})

    # 3. Read back to verify write took effect
    assert {:ok, [10, 99]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})

    # 4. Write multiple holding registers (FC 16)
    assert :ok = Master.request(master, {1, {16, :w, :reg}, 0, [50, 60]})
    assert {:ok, [50, 60]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})

    # 5. Read coils (FC 1)
    assert {:ok, [1, 0]} = Master.request(master, {1, {1, :r, :bit}, 0, 2})

    Slave.stop(slave)
    Master.stop(master)
  end

  test "handles multi-slave addressing on the same shared virtual bus", %{tty: tty} do
    # Start Slave 1 and Slave 2 on the same virtual bus
    {:ok, slave1} = Slave.start_link(tty: tty, model: @model)
    {:ok, master} = Master.start_link(tty: tty, timeout: 1_000)

    # Query Slave 1
    assert {:ok, [10, 11]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})

    # Query Slave 2
    assert {:ok, [200, 201]} = Master.request(master, {2, {3, :r, :reg}, 0, 2})

    Slave.stop(slave1)
    Master.stop(master)
  end

  test "master handles exception frames from slave over virtual bus", %{tty: tty} do
    {:ok, slave} = Slave.start_link(tty: tty, model: @model)
    {:ok, master} = Master.start_link(tty: tty, timeout: 500)

    # Query unregistered function code -> returns exception :efun
    assert {:error, :efun} = Master.request(master, {1, {99, :r, :reg}, 0, 1})

    # Query out-of-range address -> returns exception :eaddr
    assert {:error, :eaddr} = Master.request(master, {1, {3, :r, :reg}, 999, 1})

    Slave.stop(slave)
    Master.stop(master)
  end

  test "master active mode delivers slave response to parent_pid asynchronously", %{tty: tty} do
    {:ok, slave} = Slave.start_link(tty: tty, model: @model)
    {:ok, master} = Master.start_link(tty: tty, active: true, timeout: 1_000)

    req = {1, {3, :r, :reg}, 0, 2}
    assert :ok = Master.request(master, req)

    assert_receive {:modbuv_rtu, {:slave_response, ^req, [10, 11]}}, 1_000

    Slave.stop(slave)
    Master.stop(master)
  end

  def handle_telemetry(event, measurements, metadata, config) do
    send(config.test_pid, {:telemetry_event, event, measurements, metadata})
  end

  test "emits telemetry events during virtual bus request", %{tty: tty} do
    test_pid = self()
    handler_id = "test-virtual-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:modbuv, :request, :stop],
      &__MODULE__.handle_telemetry/4,
      %{test_pid: test_pid}
    )

    {:ok, slave} = Slave.start_link(tty: tty, model: @model)
    {:ok, master} = Master.start_link(tty: tty, timeout: 1_000)

    assert {:ok, [10, 11]} = Master.request(master, {1, {3, :r, :reg}, 0, 2})

    assert_receive {:telemetry_event, [:modbuv, :request, :stop], %{duration: _},
                    %{role: :master, transport: :rtu, result: :ok}},
                   500

    :telemetry.detach(handler_id)
    Slave.stop(slave)
    Master.stop(master)
  end

  test "master discards stale other-slave frames and leading noise before valid reply", %{
    tty: tty
  } do
    bus_name = String.replace_prefix(tty, "virtual:", "") |> String.to_atom()
    :ok = Modbuv.Rtu.VirtualBus.attach(bus_name, self())

    {:ok, master} = Master.start_link(tty: tty, timeout: 1_000)

    req = {2, {3, :r, :reg}, 0, 2}
    task = Task.async(fn -> Master.request(master, req) end)

    assert_receive {:virtual_bus_data, _sender, _req_adu}, 500

    # Inject:
    # 1. Stale reply from slave 1 with same FC and byte count
    # 2. Stale reply from slave 1 with different FC
    # 3. Leading noise bytes (including accidental slave 2 + fc 3 prefix with bad CRC)
    # 4. Valid reply from slave 2
    stale_same_fc = Modbuv.Rtu.pack_res({1, {3, :r, :reg}, 0, 2}, [10, 11])
    stale_other_fc = Modbuv.Rtu.pack_res({1, {6, :w, :reg}, 0, 99}, nil)
    noise = <<0xFF, 0x00, 2, 3, 4, 0, 0, 0, 0, 0, 0>>
    valid_reply = Modbuv.Rtu.pack_res(req, [200, 201])

    Modbuv.Rtu.VirtualBus.broadcast(bus_name, self(), stale_same_fc <> stale_other_fc)
    Modbuv.Rtu.VirtualBus.broadcast(bus_name, self(), noise <> valid_reply)

    assert {:ok, [200, 201]} = Task.await(task, 1_000)

    Modbuv.Rtu.VirtualBus.detach(bus_name, self())
    Master.stop(master)
  end

  test "broadcast write (slave 0) returns :ok immediately without waiting for timeout", %{
    tty: tty
  } do
    bus_name = String.replace_prefix(tty, "virtual:", "") |> String.to_atom()
    :ok = Modbuv.Rtu.VirtualBus.attach(bus_name, self())

    {:ok, master} = Master.start_link(tty: tty, timeout: 5_000)

    broadcast_req = {0, {6, :w, :reg}, 0, 123}
    expected_adu = Modbuv.Rtu.pack_req(broadcast_req)

    started = System.monotonic_time(:millisecond)
    assert :ok = Master.request(master, broadcast_req)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 500
    assert_receive {:virtual_bus_data, _sender, ^expected_adu}, 500

    # Broadcast write in active mode with turnaround_delay
    {:ok, active_master} =
      Master.start_link(tty: tty, active: true, timeout: 5_000, turnaround_delay: 10)

    assert :ok = Master.request(active_master, broadcast_req)
    assert_receive {:modbuv_rtu, {:slave_response, ^broadcast_req, :ok}}, 500

    Modbuv.Rtu.VirtualBus.detach(bus_name, self())
    Master.stop(master)
    Master.stop(active_master)
  end
end
