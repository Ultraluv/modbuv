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
end
