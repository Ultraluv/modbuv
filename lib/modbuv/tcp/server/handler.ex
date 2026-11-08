defmodule Modbuv.Tcp.Server.Handler do
  @moduledoc false

  use GenServer

  alias Modbuv.{Codec, FcMap, Tcp}
  alias Modbuv.Model.Shared

  @spec start_link({port(), map()}) :: {:ok, pid()}
  def start_link({socket, opts}) do
    GenServer.start_link(__MODULE__, {socket, opts})
  end

  @spec child_spec({port(), map()}) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  @impl true
  def init({socket, opts}) do
    state = %{
      socket: socket,
      model_pid: opts.model_pid,
      parent_pid: opts.parent_pid,
      fc_map: opts.fc_map,
      buffer: <<>>
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:socket_ready, state) do
    :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, data}, state) do
    {adus, buffer} = Tcp.split_adus(state.buffer <> data)
    Enum.each(adus, &handle_adu(&1, state))
    :inet.setopts(state.socket, active: :once)
    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info({:set_fc_map, new_fc_map}, state) when is_map(new_fc_map) do
    {:noreply, %{state | fc_map: new_fc_map}}
  end

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _socket, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_adu(adu, state) do
    <<transid::16, _::binary>> = adu
    unit = :binary.at(adu, 6)

    case Tcp.parse_req(adu, state.fc_map) do
      {:ok, frame, _transid} ->
        if known_slave?(state.model_pid, unit), do: process_frame(frame, transid, state)

      {:error, reason, fc} ->
        if is_integer(fc) and fc in 1..127 and known_slave?(state.model_pid, unit) do
          send_exception(state.socket, unit, fc, reason, transid)
          notify_exception(state.parent_pid, adu, unit, fc, reason, transid)
        end
    end
  end

  defp process_frame({unit, {fc, direction, _width}, _address, _argument} = frame, transid, state) do
    case FcMap.lookup(state.fc_map, fc) do
      {:ok, entry} ->
        region = region(entry)

        if direction == :r and not Codec.response_encodable?(frame) do
          send_exception(state.socket, unit, fc, :einval, transid)
        else
          case Shared.apply(state.model_pid, frame, region) do
            {:ok, values} -> :gen_tcp.send(state.socket, Tcp.pack_res(frame, values, transid))
            {:error, reason} -> send_exception(state.socket, unit, fc, reason, transid)
            nil -> :ok
          end
        end

        notify(state.parent_pid, frame)

      :error ->
        send_exception(state.socket, unit, fc, :efun, transid)
    end
  end

  defp region({:r, _width, region}), do: region
  defp region({:w, _width, region, _mode}), do: region

  defp known_slave?(model_pid, unit) do
    model_pid |> Shared.state() |> Map.has_key?(unit)
  end

  defp send_exception(socket, unit, fc, reason, transid) do
    :gen_tcp.send(socket, Tcp.pack_exception(unit, fc, reason, transid))
  end

  defp notify(nil, _frame), do: :ok
  defp notify(pid, frame), do: send(pid, {:modbuv_tcp, {:server_request, frame}})

  defp notify_exception(nil, _adu, _unit, _fc, _reason, _transid), do: :ok

  defp notify_exception(pid, adu, unit, fc, reason, transid) do
    send(pid, {:modbuv_tcp, {:server_exception, adu, unit, fc, reason, transid}})
  end
end
