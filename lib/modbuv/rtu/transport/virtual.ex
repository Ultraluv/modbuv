defmodule Modbuv.Rtu.Transport.Virtual do
  @moduledoc """
  In-memory virtual serial transport implementation.

  Connects to a `Modbuv.Rtu.VirtualBus` and simulates UART read/write/framing
  behaviour in pure Elixir without any hardware dependencies.
  """

  @behaviour Modbuv.Rtu.Transport

  use GenServer

  alias Modbuv.Rtu.VirtualBus

  defstruct owner: nil,
            tty: "virtual",
            bus: nil,
            active: false,
            framing: nil,
            framing_state: nil,
            rx_buffer: <<>>,
            waiting_reader: nil

  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def open(pid, tty, opts) do
    GenServer.call(pid, {:open, tty, opts})
  end

  @impl true
  def close(pid) do
    GenServer.call(pid, :close)
  end

  @impl true
  def write(pid, data) when is_binary(data) do
    GenServer.call(pid, {:write, data})
  end

  @impl true
  def read(pid, timeout) do
    # Circuits.UART.read semantics: timeout is an integer in milliseconds
    GenServer.call(pid, {:read, timeout}, :infinity)
  end

  @impl true
  def flush(pid, direction \\ :receive) do
    GenServer.call(pid, {:flush, direction})
  end

  @impl true
  def configure(pid, opts) do
    GenServer.call(pid, {:configure, opts})
  end

  @impl true
  def stop(pid) do
    GenServer.stop(pid)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:open, tty, opts}, {caller, _ref}, %__MODULE__{} = state) do
    bus = resolve_bus(tty, opts)
    active = Keyword.get(opts, :active, false)
    {framing_mod, framing_state} = init_framing(opts[:framing])

    case VirtualBus.attach(bus, self()) do
      :ok ->
        new_state = %__MODULE__{
          state
          | owner: caller,
            tty: tty,
            bus: bus,
            active: active,
            framing: framing_mod,
            framing_state: framing_state,
            rx_buffer: <<>>,
            waiting_reader: nil
        }

        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, %__MODULE__{} = state) do
    if state.bus, do: VirtualBus.detach(state.bus, self())
    cancel_waiting_reader(state)
    {:reply, :ok, %__MODULE__{state | bus: nil, rx_buffer: <<>>, waiting_reader: nil}}
  end

  def handle_call({:write, data}, _from, state) do
    if state.bus do
      VirtualBus.broadcast(state.bus, self(), data)
      {:reply, :ok, state}
    else
      {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({:read, timeout}, from, state) do
    cond do
      state.rx_buffer != <<>> ->
        # Data available immediately
        data = state.rx_buffer
        {:reply, {:ok, data}, %{state | rx_buffer: <<>>}}

      timeout <= 0 ->
        # Timeout immediately
        {:reply, {:ok, ""}, state}

      true ->
        # Wait for data or timeout
        ref = make_ref()
        timer = Process.send_after(self(), {:read_timeout, ref}, timeout)
        {:noreply, %{state | waiting_reader: {from, ref, timer}}}
    end
  end

  def handle_call({:flush, direction}, _from, %__MODULE__{} = state) do
    new_framing_state =
      if state.framing && function_exported?(state.framing, :flush, 2) do
        state.framing.flush(direction, state.framing_state)
      else
        state.framing_state
      end

    {:reply, :ok, %{state | rx_buffer: <<>>, framing_state: new_framing_state}}
  end

  def handle_call({:configure, opts}, _from, %__MODULE__{} = state) do
    new_state =
      if Keyword.has_key?(opts, :framing) do
        {framing_mod, framing_state} = init_framing(opts[:framing])
        %{state | framing: framing_mod, framing_state: framing_state}
      else
        state
      end

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:virtual_bus_data, _sender, data}, state) do
    if state.active do
      # Active mode: dispatch framed messages or raw data to owner
      new_state = dispatch_active_data(state, data)
      {:noreply, new_state}
    else
      # Passive mode: buffer data and notify pending reader if any
      new_buffer = state.rx_buffer <> data

      case state.waiting_reader do
        {from, _ref, timer} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:ok, new_buffer})
          {:noreply, %{state | rx_buffer: <<>>, waiting_reader: nil}}

        nil ->
          {:noreply, %{state | rx_buffer: new_buffer}}
      end
    end
  end

  def handle_info({:read_timeout, ref}, state) do
    case state.waiting_reader do
      {from, ^ref, _timer} ->
        GenServer.reply(from, {:ok, ""})
        {:noreply, %{state | waiting_reader: nil}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.bus, do: VirtualBus.detach(state.bus, self())
    cancel_waiting_reader(state)
    :ok
  end

  # Helpers

  defp resolve_bus(tty, opts) do
    cond do
      bus = opts[:virtual_bus] ->
        bus

      is_binary(tty) && String.starts_with?(tty, "virtual:") ->
        String.replace_prefix(tty, "virtual:", "") |> String.to_atom()

      is_binary(tty) && String.starts_with?(tty, "loopback:") ->
        String.replace_prefix(tty, "loopback:", "") |> String.to_atom()

      true ->
        VirtualBus.default_name()
    end
  end

  defp init_framing({mod, args}) when is_atom(mod) do
    case mod.init(args) do
      {:ok, framing_state} -> {mod, framing_state}
      _ -> {nil, nil}
    end
  end

  defp init_framing(_), do: {nil, nil}

  defp dispatch_active_data(%{framing: nil} = state, data) do
    send_to_owner(state.owner, state.tty, data)
    state
  end

  defp dispatch_active_data(%{framing: mod, framing_state: fstate} = state, data) do
    case mod.remove_framing(data, fstate) do
      {:ok, messages, new_fstate} ->
        for msg <- messages do
          send_to_owner(state.owner, state.tty, msg)
        end

        %{state | framing_state: new_fstate}

      {:in_frame, _messages, new_fstate} ->
        %{state | framing_state: new_fstate}

      _ ->
        state
    end
  end

  defp send_to_owner(owner, tty, term) when is_pid(owner) do
    send(owner, {:circuits_uart, tty, term})
  end

  defp send_to_owner(_owner, _tty, _term), do: :ok

  defp cancel_waiting_reader(%{waiting_reader: {_from, _ref, timer}}) when is_reference(timer) do
    Process.cancel_timer(timer)
  end

  defp cancel_waiting_reader(_state), do: :ok
end
