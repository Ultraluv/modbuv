defmodule Modbuv.Rtu.Master do
  @moduledoc """
  Modbus RTU master. Reads raw UART bytes and frames replies from the request
  currently in flight. Only one request may be in flight at a time.
  """

  use GenServer

  alias Circuits.UART
  alias Modbuv.{Rtu, Telemetry}

  defstruct parent_pid: nil,
            tty: nil,
            active: false,
            uart_pid: nil,
            timeout: 5_000,
            uart_opts: [],
            status: :closed,
            cmd: nil,
            last_cmd: nil

  @doc "Starts the RTU master GenServer. `params` must include `:tty` and may include `:active`, `:timeout`, and `:uart_opts`."
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, {params, self()}, gen_opts)
  end

  @doc "Stops the RTU master GenServer process."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Returns the current internal state struct of the RTU master."
  @spec state(pid()) :: %__MODULE__{}
  def state(pid), do: GenServer.call(pid, :state)

  @doc "Updates the master's connection parameters (`:tty`, `:active`, `:timeout`, `:uart_opts`) at runtime, reopening the UART port."
  @spec configure(pid(), keyword()) :: :ok
  def configure(pid, params), do: GenServer.call(pid, {:configure, params})

  @doc "Opens the UART port for the configured TTY device."
  @spec open(pid()) :: :ok
  def open(pid), do: GenServer.call(pid, :open)

  @doc "Closes the UART port. Returns `:ok` and clears any pending command."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @doc "Packs and sends a Modbus frame over RTU. In passive mode blocks until the slave responds; in active mode returns `:ok` and delivers the result to `parent_pid`."
  @spec request(pid(), tuple()) :: :ok | {:ok, list()} | {:error, term()}
  def request(pid, frame) do
    adu = Rtu.pack_req(frame)
    GenServer.call(pid, {:request, frame, adu}, :infinity)
  end

  @doc "Re-reads the UART for the last sent command in passive mode. Returns `nil` if no command has been sent yet, or `:error` in active mode."
  @spec read(pid()) :: nil | :ok | {:ok, list()} | {:error, term()}
  def read(pid), do: GenServer.call(pid, :read, :infinity)

  @impl true
  def init({params, parent_pid}) do
    active = Keyword.get(params, :active, false)
    tty = Keyword.fetch!(params, :tty)
    timeout = Keyword.get(params, :timeout, 5_000)
    uart_opts = Keyword.get(params, :uart_opts, speed: 115_200)
    parent_pid = if active, do: parent_pid

    {:ok, uart_pid} = UART.start_link()
    status = open_uart(uart_pid, tty, uart_opts)

    state = %__MODULE__{
      parent_pid: parent_pid,
      tty: tty,
      active: active,
      uart_pid: uart_pid,
      timeout: timeout,
      uart_opts: uart_opts,
      status: status
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:open, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | status: open_uart(state.uart_pid, state.tty, state.uart_opts)}}
  end

  def handle_call(:close, _from, %__MODULE__{} = state) do
    UART.close(state.uart_pid)
    {:reply, :ok, %{state | status: :closed, cmd: nil, last_cmd: nil}}
  end

  def handle_call({:request, _frame, _adu}, _from, %__MODULE__{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:request, _frame, _adu}, _from, %__MODULE__{cmd: cmd} = state)
      when cmd != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:request, frame, adu}, _from, %__MODULE__{} = state) do
    metadata = Telemetry.request_metadata(:rtu, :master, mode(state), frame)
    started = Telemetry.start(metadata)

    with :ok <- UART.flush(state.uart_pid),
         :ok <- UART.write(state.uart_pid, adu) do
      if state.active do
        master = self()
        uart_pid = state.uart_pid
        timeout = state.timeout

        Task.start_link(fn ->
          result = read_reply(uart_pid, frame, timeout)
          Telemetry.stop(metadata, started, result)
          send(master, {:async_done, frame, result})
        end)

        {:reply, :ok, %{state | cmd: frame}}
      else
        result = read_reply(state.uart_pid, frame, state.timeout)
        Telemetry.stop(metadata, started, result)
        {:reply, result, %{state | cmd: nil, last_cmd: frame}}
      end
    else
      {:error, reason} ->
        Telemetry.stop(metadata, started, {:error, reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:read, _from, %__MODULE__{active: true} = state), do: {:reply, :error, state}
  def handle_call(:read, _from, %__MODULE__{last_cmd: nil} = state), do: {:reply, nil, state}

  def handle_call(:read, _from, state) do
    {:reply, read_reply(state.uart_pid, state.last_cmd, state.timeout), state}
  end

  def handle_call({:configure, params}, {caller, _ref}, %__MODULE__{} = state) do
    UART.close(state.uart_pid)
    UART.stop(state.uart_pid)

    active = if params[:active] == nil, do: state.active, else: params[:active]
    tty = params[:tty] || state.tty
    timeout = params[:timeout] || state.timeout
    uart_opts = params[:uart_opts] || state.uart_opts
    parent_pid = if active and state.parent_pid == nil, do: caller, else: state.parent_pid

    {:ok, uart_pid} = UART.start_link()
    status = open_uart(uart_pid, tty, uart_opts)

    new_state = %__MODULE__{
      state
      | parent_pid: parent_pid,
        tty: tty,
        active: active,
        uart_pid: uart_pid,
        timeout: timeout,
        uart_opts: uart_opts,
        status: status,
        cmd: nil,
        last_cmd: nil
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:async_done, frame, result}, %__MODULE__{} = state) do
    notify(state.parent_pid, frame, result)
    {:noreply, %{state | cmd: nil, last_cmd: frame}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    UART.close(state.uart_pid)
    UART.stop(state.uart_pid)
    :ok
  end

  defp read_reply(uart_pid, frame, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    read_loop(uart_pid, frame, <<>>, deadline)
  end

  defp read_loop(uart_pid, frame, buffer, deadline) do
    case Rtu.response_length(frame, buffer) do
      {:ok, length} when byte_size(buffer) >= length ->
        adu = binary_part(buffer, 0, length)

        case Rtu.parse_res(frame, adu) do
          values when is_list(values) -> {:ok, values}
          nil -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _length} ->
        continue_read(uart_pid, frame, buffer, deadline)

      :more ->
        continue_read(uart_pid, frame, buffer, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_read(uart_pid, frame, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case UART.read(uart_pid, remaining) do
        {:ok, ""} -> {:error, :timeout}
        {:ok, {:error, reason, _message}} -> {:error, reason}
        {:ok, {:partial, data}} -> read_loop(uart_pid, frame, buffer <> data, deadline)
        {:ok, data} when is_binary(data) -> read_loop(uart_pid, frame, buffer <> data, deadline)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp open_uart(uart_pid, tty, uart_opts) do
    case UART.open(uart_pid, tty, [active: false] ++ uart_opts) do
      :ok -> :open
      {:error, _reason} -> :closed
    end
  end

  defp mode(%__MODULE__{active: true}), do: :active
  defp mode(%__MODULE__{}), do: :passive

  defp notify(nil, _frame, _result), do: :ok

  defp notify(pid, frame, {:ok, values}),
    do: send(pid, {:modbuv_rtu, {:slave_response, frame, values}})

  defp notify(pid, frame, :ok),
    do: send(pid, {:modbuv_rtu, {:slave_response, frame, :ok}})

  defp notify(pid, frame, {:error, reason}),
    do: send(pid, {:modbuv_rtu, {:slave_error, frame, reason}})
end
