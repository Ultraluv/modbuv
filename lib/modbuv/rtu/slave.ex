defmodule Modbuv.Rtu.Slave do
  @moduledoc """
  Modbus RTU slave. The UART runs with `Modbuv.Rtu.Framer` in active mode;
  complete frames are decoded, applied to the shared DB, and answered.
  """

  use GenServer

  require Logger

  alias Circuits.UART
  alias Modbuv.{FcMap, Rtu}
  alias Modbuv.Model.Shared
  alias Modbuv.Rtu.Framer

  defstruct model_pid: nil,
            parent_pid: nil,
            tty: nil,
            uart_pid: nil,
            uart_opts: [],
            fc_map: %{},
            status: :closed

  @doc "Starts the RTU slave GenServer. `params` must include `:tty` and `:model`, and may include `:active`, `:timeout`, `:uart_opts`, and `:fc_map`."
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, {params, self()}, gen_opts)
  end

  @doc "Stops the RTU slave GenServer process."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Returns the current internal state struct of the RTU slave."
  @spec state(pid()) :: %__MODULE__{}
  def state(pid), do: GenServer.call(pid, :state)

  @doc "Applies a frame tuple to the slave's local DB, similar to `Tcp.Server.update/2`. Validates the frame against the fc_map and returns the result."
  @spec request(pid(), tuple()) :: term()
  def request(pid, frame) do
    state = GenServer.call(pid, :state)

    case lookup_entry(state.fc_map, frame) do
      {:ok, entry} ->
        validate_entry!(entry, frame)
        GenServer.call(pid, {:request, frame})

      :error ->
        {:error, :efun}
    end
  end

  @doc "Returns the raw DB map currently held by the slave's shared model."
  @spec get_db(pid()) :: map()
  def get_db(pid), do: GenServer.call(pid, :get_db)

  @doc "Sends raw bytes directly over the UART without any framing or encoding. Useful for injecting pre-built RTU frames or test data."
  @spec raw_write(pid(), binary()) :: :ok
  def raw_write(pid, data), do: GenServer.call(pid, {:raw_write, data})

  @doc "Updates the slave's function code mapping at runtime and updates the UART framer."
  @spec set_fc_map(pid(), map()) :: :ok
  def set_fc_map(pid, overrides) when is_map(overrides) do
    GenServer.call(pid, {:set_fc_map, overrides})
  end

  @impl true
  def init({params, parent_pid}) do
    active = Keyword.get(params, :active, false)
    tty = Keyword.fetch!(params, :tty)
    model = Keyword.fetch!(params, :model)
    timeout = Keyword.get(params, :timeout, 5_000)
    default_uart_opts = [speed: 115_200, rx_framing_timeout: timeout]
    uart_opts = Keyword.merge(default_uart_opts, Keyword.get(params, :uart_opts, []))

    fc_map = FcMap.merge(Keyword.get(params, :fc_map, %{}))
    parent_pid = if active, do: parent_pid

    {:ok, model_pid} = Shared.start_link(model)
    {:ok, uart_pid} = UART.start_link()

    status =
      case UART.open(
             uart_pid,
             tty,
             [framing: {Framer, fc_map: fc_map}, active: true] ++ uart_opts
           ) do
        :ok -> :open
        {:error, _reason} -> :closed
      end

    state = %__MODULE__{
      model_pid: model_pid,
      parent_pid: parent_pid,
      tty: tty,
      uart_pid: uart_pid,
      uart_opts: uart_opts,
      fc_map: fc_map,
      status: status
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:request, frame}, _from, state) do
    result =
      with {_slave, {fc, _direction, _width}, _address, _argument} <- frame,
           {:ok, entry} <- FcMap.lookup(state.fc_map, fc) do
        state.model_pid |> Shared.apply(frame, region(entry)) |> unwrap()
      else
        _ -> {:error, :efun}
      end

    {:reply, result, state}
  end

  def handle_call(:get_db, _from, state) do
    {:reply, Shared.state(state.model_pid), state}
  end

  def handle_call({:raw_write, data}, _from, state) do
    UART.write(state.uart_pid, data)
    {:reply, :ok, state}
  end

  def handle_call({:set_fc_map, overrides}, _from, state) do
    new_fc_map = FcMap.merge(state.fc_map, overrides)

    if state.status == :open and is_pid(state.uart_pid) and Process.alive?(state.uart_pid) do
      UART.configure(state.uart_pid, framing: {Framer, fc_map: new_fc_map})
    end

    {:reply, :ok, %{state | fc_map: new_fc_map}}
  end

  @impl true
  def terminate(_reason, state) do
    UART.close(state.uart_pid)
    UART.stop(state.uart_pid)
    Shared.stop(state.model_pid)
    :ok
  end

  @impl true
  def handle_info({:circuits_uart, _device, frame}, state) when is_binary(frame) do
    handle_frame(frame, state)
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _device, {:error, :ecrc, raw}}, state) do
    notify(state.parent_pid, {:slave_error, raw, :ecrc})
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _device, {:error, reason, raw}}, state) do
    notify(state.parent_pid, {:slave_error, raw, reason})
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _device, {:partial, data}}, state) do
    Logger.warning("Modbuv RTU slave partial frame: #{inspect(data, base: :hex)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_frame(raw, state) do
    case Rtu.parse_req(raw, state.fc_map) do
      {:ok, {slave, {fc, direction, _width}, _address, _argument} = frame} ->
        if known_slave?(state.model_pid, slave) do
          entry = FcMap.lookup(state.fc_map, fc)

          with {:ok, entry} <- entry do
            region = region(entry)

            if direction == :r and not Rtu.response_fits?(frame) do
              send_response(state, Rtu.pack_exception(slave, fc, :einval))
            else
              case Shared.apply(state.model_pid, frame, region) do
                {:ok, values} -> send_response(state, Rtu.pack_res(frame, values))
                {:error, reason} -> send_response(state, Rtu.pack_exception(slave, fc, reason))
                nil -> :ok
              end
            end

            notify(state.parent_pid, {:slave_request, frame})
          end
        end

      {:error, reason, fc} ->
        maybe_exception(raw, fc, reason, state)
    end
  end

  defp maybe_exception(_raw, _fc, :ecrc, _state), do: :ok

  defp maybe_exception(raw, fc, reason, state)
       when is_integer(fc) and fc in 1..127 and byte_size(raw) >= 1 do
    slave = :binary.at(raw, 0)

    if known_slave?(state.model_pid, slave) do
      send_response(state, Rtu.pack_exception(slave, fc, reason))
      notify(state.parent_pid, {:slave_exception, raw, slave, fc, reason})
    end
  end

  defp maybe_exception(_raw, _fc, _reason, _state), do: :ok

  defp known_slave?(model_pid, slave) do
    model_pid |> Shared.state() |> Map.has_key?(slave)
  end

  defp send_response(state, adu) do
    case UART.write(state.uart_pid, adu) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Modbuv RTU slave write failed: #{inspect(reason)}")
    end
  end

  defp region({:r, _width, region}), do: region
  defp region({:w, _width, region, _mode}), do: region

  defp lookup_entry(fc_map, {_slave, {fc, _direction, _width}, _address, _argument}),
    do: FcMap.lookup(fc_map, fc)

  defp lookup_entry(_fc_map, _frame), do: :error

  defp validate_entry!(entry, {_slave, {_fc, direction, width}, _address, _argument}) do
    validate_entry!(entry, direction, width)
  end

  defp validate_entry!(_entry, _frame), do: raise(ArgumentError, "invalid frame")

  defp notify(nil, _message), do: :ok
  defp notify(pid, message), do: send(pid, {:modbuv_rtu, message})

  defp validate_entry!({entry_direction, entry_width, _region}, direction, width)
       when entry_direction == direction and entry_width == width,
       do: true

  defp validate_entry!({entry_direction, entry_width, _region, _mode}, direction, width)
       when entry_direction == direction and entry_width == width,
       do: true

  defp validate_entry!(_entry, _direction, _width) do
    raise ArgumentError, "frame direction/width must match the fc_map entry"
  end

  defp unwrap({:ok, values}), do: values
  defp unwrap(other), do: other
end
