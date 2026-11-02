defmodule Modbuv.Tcp.Client do
  @moduledoc """
  Modbus TCP client. In passive mode `request/2` followed by `confirmation/1`
  returns the result synchronously; in active mode responses are sent to
  `d_pid` as `{:modbuv_tcp, frame, result}`.
  """

  use GenServer

  alias Modbuv.{Telemetry, Tcp}

  defstruct ip: {127, 0, 0, 1},
            tcp_port: 502,
            timeout: 5_000,
            active: false,
            d_pid: nil,
            socket: nil,
            status: :closed,
            transid: 0,
            sent_transid: nil,
            cmd: nil,
            req_started_at: nil,
            pending_msg: %{},
            pending_started: %{},
            buffer: <<>>

  @doc "Starts the TCP client GenServer. `params` accepts `:ip`, `:tcp_port`, `:timeout`, `:active`, and `:d_pid`; `gen_opts` are passed to `GenServer.start_link/3`."
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, params, gen_opts)
  end

  @doc "Updates the client's connection parameters (`:ip`, `:tcp_port`, `:timeout`, `:active`, `:d_pid`) while the socket is closed. Returns `:error` if the socket is already connected."
  @spec configure(pid(), keyword()) :: :ok | :error
  def configure(pid, params), do: GenServer.call(pid, {:configure, params})

  @doc "Opens a TCP connection to the configured host and port. Returns `:ok` on success or `{:error, reason}` on failure."
  @spec connect(pid()) :: :ok | {:error, term()}
  def connect(pid), do: GenServer.call(pid, :connect)

  @doc "Closes the underlying TCP socket and resets the client state. Always returns `:ok`."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  @doc "Stops the client GenServer process."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Returns the current internal state struct of the client."
  @spec state(pid()) :: %__MODULE__{}
  def state(pid), do: GenServer.call(pid, :state)

  @doc "Sends a Modbus frame to the server. In passive mode call `confirmation/1` afterward to receive the result; in active mode returns `:ok` immediately."
  @spec request(pid(), tuple()) :: :ok | {:error, term()}
  def request(pid, frame), do: GenServer.call(pid, {:request, frame})

  @doc "Waits for and parses the server response for the last `request/2` call in passive mode. Returns `:error` if used in active mode."
  @spec confirmation(pid()) :: :ok | {:ok, list()} | {:error, term()} | :error
  def confirmation(pid), do: GenServer.call(pid, :confirmation)

  @doc "Returns and clears the map of pending active-mode messages that have not yet been matched to a response."
  @spec flush(pid()) :: {:ok, map()}
  def flush(pid), do: GenServer.call(pid, :flush)

  @impl true
  def init(params) do
    state = %__MODULE__{
      ip: Keyword.get(params, :ip, {127, 0, 0, 1}),
      tcp_port: Keyword.get(params, :tcp_port, 502),
      timeout: Keyword.get(params, :timeout, 5_000),
      active: Keyword.get(params, :active, false),
      d_pid: Keyword.get(params, :d_pid)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:configure, params}, _from, %__MODULE__{status: :closed} = state) do
    new_state = %__MODULE__{
      state
      | ip: Keyword.get(params, :ip, state.ip),
        tcp_port: Keyword.get(params, :tcp_port, state.tcp_port),
        timeout: Keyword.get(params, :timeout, state.timeout),
        active: Keyword.get(params, :active, state.active),
        d_pid: Keyword.get(params, :d_pid, state.d_pid)
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:configure, _params}, _from, state), do: {:reply, :error, state}

  def handle_call(:connect, {from, _ref}, state) do
    case :gen_tcp.connect(
           state.ip,
           state.tcp_port,
           [:binary, packet: :raw, active: state.active],
           state.timeout
         ) do
      {:ok, socket} ->
        new_state = %{state | socket: socket, status: :connected, d_pid: state.d_pid || from}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, close_socket(state)}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:request, _frame}, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:request, frame}, _from, state) do
    adu = Tcp.pack_req(frame, state.transid)

    case :gen_tcp.send(state.socket, adu) do
      :ok ->
        if state.active do
          started = Telemetry.start(Telemetry.request_metadata(:tcp, :client, :active, frame))
          pending = Map.put(state.pending_msg, state.transid, frame)
          pending_started = Map.put(state.pending_started, state.transid, started)

          new_state = %{
            state
            | pending_msg: pending,
              pending_started: pending_started,
              transid: next_transid(state.transid)
          }

          {:reply, :ok, new_state}
        else
          sent = state.transid

          started =
            Telemetry.start(Telemetry.request_metadata(:tcp, :client, :passive, frame))

          {:reply, :ok,
           %{
             state
             | cmd: frame,
               sent_transid: sent,
               transid: next_transid(sent),
               req_started_at: started
           }}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, close_socket(state)}
    end
  end

  def handle_call(:confirmation, _from, %{active: true} = state) do
    {:reply, :error, state}
  end

  def handle_call(:confirmation, _from, %{status: :closed} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call(:confirmation, _from, %{cmd: nil} = state) do
    {:reply, {:error, :ebadresp}, state}
  end

  def handle_call(:confirmation, _from, state) do
    case :gen_tcp.recv(state.socket, 6, state.timeout) do
      {:ok, <<transid::16, protocol::16, length::16>>}
      when protocol == 0 and length >= 2 and transid == state.sent_transid ->
        case :gen_tcp.recv(state.socket, length, state.timeout) do
          {:ok, body} ->
            adu = <<transid::16, protocol::16, length::16, body::binary>>
            result = parse_result(Tcp.parse_res(state.cmd, adu))
            stop_passive(state, result)
            new_state = %{state | cmd: nil, sent_transid: nil, req_started_at: nil}
            {:reply, result, new_state}

          {:error, reason} ->
            stop_passive(state, {:error, reason})
            {:reply, {:error, reason}, close_socket(state)}
        end

      {:ok, _bad_header} ->
        stop_passive(state, {:error, :ebadresp})
        {:reply, {:error, :ebadresp}, close_socket(state)}

      {:error, reason} ->
        stop_passive(state, {:error, reason})
        {:reply, {:error, reason}, close_socket(state)}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, {:ok, state.pending_msg}, %{state | pending_msg: %{}, pending_started: %{}}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    {adus, buffer} = Tcp.split_adus(state.buffer <> data)
    new_state = Enum.reduce(adus, %{state | buffer: buffer}, &process_adu/2)
    {:noreply, new_state}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:noreply, close_socket(state)}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:noreply, close_socket(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{socket: nil}), do: :ok

  def terminate(_reason, %__MODULE__{} = state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  defp process_adu(adu, state) do
    <<transid::16, _::binary>> = adu

    case Map.fetch(state.pending_msg, transid) do
      {:ok, frame} ->
        result = Tcp.parse_res(frame, adu)
        stop_active(state, frame, transid, result)
        send(state.d_pid, {:modbuv_tcp, frame, result})

        %{
          state
          | pending_msg: Map.delete(state.pending_msg, transid),
            pending_started: Map.delete(state.pending_started, transid)
        }

      :error ->
        state
    end
  end

  defp stop_active(state, frame, transid, result) do
    case Map.fetch(state.pending_started, transid) do
      {:ok, started} ->
        Telemetry.stop(
          Telemetry.request_metadata(:tcp, :client, :active, frame),
          started,
          result
        )

      :error ->
        :ok
    end
  end

  defp stop_passive(%__MODULE__{req_started_at: nil}, _result), do: :ok

  defp stop_passive(state, result) do
    Telemetry.stop(
      Telemetry.request_metadata(:tcp, :client, :passive, state.cmd),
      state.req_started_at,
      result
    )
  end

  defp parse_result(nil), do: :ok
  defp parse_result(values) when is_list(values), do: {:ok, values}
  defp parse_result({:error, reason}), do: {:error, reason}
  defp parse_result(_other), do: {:error, :ebadresp}

  defp next_transid(transid) when transid + 1 > 0xFFFF, do: 0
  defp next_transid(transid), do: transid + 1

  defp close_socket(%__MODULE__{socket: nil} = state) do
    %{
      state
      | status: :closed,
        cmd: nil,
        sent_transid: nil,
        req_started_at: nil,
        pending_msg: %{},
        pending_started: %{},
        buffer: <<>>
    }
  end

  defp close_socket(%__MODULE__{} = state) do
    :gen_tcp.close(state.socket)

    %__MODULE__{
      state
      | socket: nil,
        status: :closed,
        cmd: nil,
        sent_transid: nil,
        req_started_at: nil,
        pending_msg: %{},
        pending_started: %{},
        buffer: <<>>
    }
  end
end
