defmodule Modbuv.RtuSlaveTest do
  use ExUnit.Case, async: false
  alias Modbuv.Rtu.Slave

  @model %{1 => %{{:hr, 0} => 10, {:hr, 1} => 11}}

  test "request updates the local DB" do
    {:ok, pid} = Slave.start_link(tty: "/dev/null", model: @model)
    assert nil == Slave.request(pid, {1, {6, :w, :reg}, 1, 99})
    assert [10, 99] == Slave.request(pid, {1, {3, :r, :reg}, 0, 2})
    assert Slave.get_db(pid)[1][{:hr, 1}] == 99
    assert {:error, :efun} == Slave.request(pid, {1, {9, :r, :reg}, 0, 1})
    assert :ok = Slave.stop(pid)
  end

  @tag :hardware
  test "answers frames over tty0tty" do
    tty = System.get_env("MODBUV_TTY_SLAVE", "tnt1")
    {:ok, pid} = Slave.start_link(tty: tty, model: @model)
    :ok = Slave.raw_write(pid, <<>>)
    Process.sleep(50)
    assert is_pid(pid)
    :ok = Slave.stop(pid)
  end

  test "request mismatch raises in the caller and leaves the slave alive" do
    {:ok, pid} = Slave.start_link(tty: "/dev/null", model: @model)
    assert_raise ArgumentError, fn -> Slave.request(pid, {1, {3, :w, :reg}, 0, 1}) end
    assert Process.alive?(pid)
    :ok = Slave.stop(pid)
  end

  test "stop tears down the UART process" do
    {:ok, pid} = Slave.start_link(tty: "/dev/null", model: @model)
    uart_pid = :sys.get_state(pid).uart_pid
    ref = Process.monitor(uart_pid)
    assert :ok = Slave.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^uart_pid, _reason}, 500
  end

  test "merges custom uart_opts with default rx_framing_timeout" do
    {:ok, pid} =
      Slave.start_link(
        tty: "/dev/null",
        model: @model,
        timeout: 1_234,
        uart_opts: [speed: 9_600]
      )

    opts = :sys.get_state(pid).uart_opts
    assert opts[:speed] == 9_600
    assert opts[:rx_framing_timeout] == 1_234
    :ok = Slave.stop(pid)
  end
end
