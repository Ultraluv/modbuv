defmodule Modbuv.RtuMasterTest do
  use ExUnit.Case, async: false
  alias Modbuv.Rtu.Master

  def handle_telemetry(event, _measurements, metadata, pid) do
    send(pid, {:telemetry, event, metadata})
  end

  test "request on a closed master returns closed" do
    {:ok, pid} = Master.start_link(tty: "/dev/null", timeout: 50)
    :ok = Master.close(pid)
    assert {:error, :closed} = Master.request(pid, {1, {3, :r, :reg}, 0, 1})
  end

  test "rejects a second request while one is in flight" do
    {:ok, pid} = Master.start_link(tty: "/dev/null", timeout: 50)
    :sys.replace_state(pid, fn s -> %{s | status: :open, cmd: {1, {3, :r, :reg}, 0, 1}} end)
    assert {:error, :busy} = Master.request(pid, {1, {3, :r, :reg}, 0, 1})
  end

  @tag :hardware
  test "round-trips against an RTU slave over tty0tty and emits telemetry" do
    slave_tty = System.get_env("MODBUV_TTY_SLAVE", "/dev/tnt1")
    master_tty = System.get_env("MODBUV_TTY_MASTER", "/dev/tnt0")

    handler_id = "rtu-hardware-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:modbuv, :request, :start], [:modbuv, :request, :stop]],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, slave} =
      apply(Modbuv.Rtu.Slave, :start_link, [[tty: slave_tty, model: %{1 => %{{:hr, 0} => 10}}]])

    {:ok, master} = Master.start_link(tty: master_tty, timeout: 500)
    assert {:ok, [10]} = Master.request(master, {1, {3, :r, :reg}, 0, 1})

    expected = %{transport: :rtu, role: :master, mode: :passive, slave: 1, fc: 3}
    assert_receive {:telemetry, [:modbuv, :request, :start], ^expected}
    assert_receive {:telemetry, [:modbuv, :request, :stop], stop_metadata}
    assert stop_metadata == Map.merge(expected, %{result: :ok, reason: nil})

    :ok = apply(Modbuv.Rtu.Slave, :stop, [slave])
    :ok = Master.stop(master)
  end

  test "invalid frames raise in the caller and leave the master alive" do
    {:ok, pid} = Master.start_link(tty: "/dev/null", timeout: 50)
    assert_raise ArgumentError, fn -> Master.request(pid, {1, {3, :r, :reg}, 0, 128}) end
    assert Process.alive?(pid)
  end

  test "stop tears down the UART process" do
    {:ok, pid} = Master.start_link(tty: "/dev/null", timeout: 50)
    uart_pid = :sys.get_state(pid).uart_pid
    ref = Process.monitor(uart_pid)
    assert :ok = Master.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^uart_pid, _reason}, 500
  end
end
