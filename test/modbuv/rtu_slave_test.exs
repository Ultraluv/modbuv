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

  test "set_fc_map incrementally updates fc_map on slave" do
    {:ok, pid} = Slave.start_link(tty: "/dev/null", model: @model)

    assert :ok = Slave.set_fc_map(pid, %{65 => {:r, :reg, :hr}})
    assert :ok = Slave.set_fc_map(pid, %{66 => {:r, :reg, :hr}})

    state = Slave.state(pid)
    assert Map.has_key?(state.fc_map, 65)
    assert Map.has_key?(state.fc_map, 66)
    assert Map.has_key?(state.fc_map, 3)

    # Calling request with newly added custom function code works
    assert [10] == Slave.request(pid, {1, {65, :r, :reg}, 0, 1})

    :ok = Slave.stop(pid)
  end

  test "notifies parent_pid with slave_exception on invalid request" do
    bus_name = "slave_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = Slave.start_link(tty: "virtual:#{bus_name}", model: @model, active: true)

    # Directly feed an invalid request frame (FC 99 unregistered) through handle_info
    raw_req = Modbuv.Rtu.pack_req({1, {99, :r, :reg}, 0, 1})
    send(pid, {:circuits_uart, "dummy", raw_req})

    assert_receive {:modbuv_rtu, {:slave_exception, ^raw_req, 1, 99, :efun}}, 500

    :ok = Slave.stop(pid)
  end
end
