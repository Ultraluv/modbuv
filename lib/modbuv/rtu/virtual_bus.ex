defmodule Modbuv.Rtu.VirtualBus do
  @moduledoc """
  In-memory virtual serial bus for Modbus RTU communications.

  Simulates an RS-485 multi-drop serial bus in memory without requiring
  physical serial hardware or operating-system pseudo-terminals (`pty`).
  """

  use GenServer

  @default_name Modbuv.Rtu.VirtualBus.Default

  @doc "Returns the default registered name for the shared virtual bus."
  def default_name, do: @default_name

  @doc "Starts a virtual bus GenServer with the given options."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc "Retrieves the virtual bus process or starts one if not already running."
  def get_or_start(bus \\ @default_name)

  def get_or_start(bus_pid) when is_pid(bus_pid) do
    if Process.alive?(bus_pid), do: {:ok, bus_pid}, else: {:error, :dead}
  end

  def get_or_start(bus_name) when is_atom(bus_name) do
    case Process.whereis(bus_name) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_link(name: bus_name)

      nil ->
        case start_link(name: bus_name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          err -> err
        end
    end
  end

  @doc "Attaches a transport peer to the virtual bus."
  def attach(bus \\ @default_name, uart_pid) do
    with {:ok, pid} <- get_or_start(bus) do
      GenServer.call(pid, {:attach, uart_pid})
    end
  end

  @doc "Detaches a transport peer from the virtual bus."
  def detach(bus \\ @default_name, uart_pid) do
    case resolve_pid(bus) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.call(pid, {:detach, uart_pid}), else: :ok

      _ ->
        :ok
    end
  end

  @doc "Broadcasts binary data to all peers on the bus except the sender."
  def broadcast(bus \\ @default_name, sender_pid, data) when is_binary(data) do
    case resolve_pid(bus) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: GenServer.cast(pid, {:broadcast, sender_pid, data}), else: :ok

      _ ->
        :ok
    end
  end

  @doc "Returns the list of currently attached peer PIDs on the bus."
  def peers(bus \\ @default_name) do
    case resolve_pid(bus) do
      pid when is_pid(pid) -> GenServer.call(pid, :peers)
      _ -> []
    end
  end

  @impl true
  def init(:ok) do
    {:ok, %{peers: MapSet.new(), monitors: %{}}}
  end

  @impl true
  def handle_call({:attach, uart_pid}, _from, state) do
    if MapSet.member?(state.peers, uart_pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(uart_pid)
      new_peers = MapSet.put(state.peers, uart_pid)
      new_monitors = Map.put(state.monitors, uart_pid, ref)
      {:reply, :ok, %{state | peers: new_peers, monitors: new_monitors}}
    end
  end

  def handle_call({:detach, uart_pid}, _from, state) do
    case Map.pop(state.monitors, uart_pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {ref, new_monitors} ->
        Process.demonitor(ref, [:flush])
        new_peers = MapSet.delete(state.peers, uart_pid)
        {:reply, :ok, %{state | peers: new_peers, monitors: new_monitors}}
    end
  end

  def handle_call(:peers, _from, state) do
    {:reply, MapSet.to_list(state.peers), state}
  end

  @impl true
  def handle_cast({:broadcast, sender, data}, state) do
    for peer <- state.peers, peer != sender, Process.alive?(peer) do
      send(peer, {:virtual_bus_data, sender, data})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    new_peers = MapSet.delete(state.peers, pid)
    new_monitors = Map.reject(state.monitors, fn {_, r} -> r == ref end)
    {:noreply, %{state | peers: new_peers, monitors: new_monitors}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp resolve_pid(bus) when is_pid(bus), do: bus
  defp resolve_pid(bus) when is_atom(bus), do: Process.whereis(bus)
  defp resolve_pid(_), do: nil
end
