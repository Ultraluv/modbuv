defmodule Modbuv.Rtu.Transport.UART do
  @moduledoc """
  Physical serial transport implementation backed by `Circuits.UART`.
  """

  @behaviour Modbuv.Rtu.Transport

  alias Circuits.UART

  @impl true
  def start_link(opts \\ []) do
    UART.start_link(opts)
  end

  @impl true
  def open(pid, tty, opts) do
    UART.open(pid, tty, opts)
  end

  @impl true
  def close(pid) do
    UART.close(pid)
  end

  @impl true
  def write(pid, data) do
    UART.write(pid, data)
  end

  @impl true
  def read(pid, timeout) do
    UART.read(pid, timeout)
  end

  @impl true
  def flush(pid, direction \\ :receive) do
    UART.flush(pid, direction)
  end

  @impl true
  def configure(pid, opts) do
    UART.configure(pid, opts)
  end

  @impl true
  def stop(pid) do
    UART.stop(pid)
  end
end

