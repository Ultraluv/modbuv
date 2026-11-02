defmodule Modbuv.Tcp.Server do
  @moduledoc """
  Modbus TCP server: listens on a port, serves each connection from the shared
  DB, and optionally notifies the owner of parsed requests.
  """

  use GenServer

  alias Modbuv.{FcMap, Model.Shared}
  alias Modbuv.Tcp.Server.{Handler, Supervisor}

  @doc "Starts the TCP server GenServer. `params` must include `:model` and may include `:port`, `:timeout`, `:active`, `:fc_map`, and `:sup_opts`."
  @spec start_link(keyword(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(params, gen_opts \\ []) do
    GenServer.start_link(__MODULE__, {params, self()}, gen_opts)
  end

  @doc "Stops the TCP server GenServer process."
  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid)

  @doc "Reads or writes the server's local DB using a frame tuple. Validates the frame against the fc_map and returns the result or `{:error, :efun}` for unknown function codes."
  @spec update(pid(), tuple()) :: term()
  def update(pid, frame) do
    fc_map = GenServer.call(pid, :get_fc_map)

    case lookup_entry(fc_map, frame) do
      {:ok, entry} ->
        validate_entry!(entry, frame)
        GenServer.call(pid, {:update, frame})

      :error ->
        {:error, :efun}
    end
  end

  @doc "Returns the raw DB map currently held by the server's shared model."
  @spec get_db(pid()) :: map()
  def get_db(pid), do: GenServer.call(pid, :get_db)

  @impl true
  def init({params, parent_pid}) do
    port = Keyword.get(params, :port, 502)
    timeout = Keyword.get(params, :timeout, 5_000)
    model = Keyword.fetch!(params, :model)
    active = Keyword.get(params, :active, false)
    parent_pid = if active, do: parent_pid
    fc_map = FcMap.merge(Keyword.get(params, :fc_map, %{}))
    sup_opts = Keyword.get(params, :sup_opts, [])

    case :gen_tcp.listen(port, [
           :binary,
           packet: :raw,
           active: false,
           reuseaddr: true,
           nodelay: true
         ]) do
      {:ok, listen} ->
        {:ok, actual_port} = :inet.port(listen)
        {:ok, model_pid} = Shared.start_link(model)
        {:ok, sup} = Supervisor.start_link(sup_opts)

        {:ok, acceptor} =
          Task.start_link(fn -> accept_loop(listen, sup, model_pid, parent_pid, fc_map) end)

        state = %{
          port: actual_port,
          listen: listen,
          sup: sup,
          acceptor: acceptor,
          model_pid: model_pid,
          parent_pid: parent_pid,
          fc_map: fc_map,
          timeout: timeout
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:update, frame}, _from, state) do
    result =
      with {_unit, {fc, _direction, _width}, _address, _argument} <- frame,
           {:ok, entry} <- FcMap.lookup(state.fc_map, fc) do
        state.model_pid |> Shared.apply(frame, region(entry)) |> unwrap()
      else
        _ -> {:error, :efun}
      end

    {:reply, result, state}
  end

  def handle_call(:get_fc_map, _from, state) do
    {:reply, state.fc_map, state}
  end

  def handle_call(:get_db, _from, state) do
    {:reply, Shared.state(state.model_pid), state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    DynamicSupervisor.stop(state.sup)
    Process.unlink(state.acceptor)
    Process.exit(state.acceptor, :kill)
    Shared.stop(state.model_pid)
    :ok
  end

  defp accept_loop(listen, sup, model_pid, parent_pid, fc_map) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        args = %{model_pid: model_pid, parent_pid: parent_pid, fc_map: fc_map}
        {:ok, handler} = DynamicSupervisor.start_child(sup, {Handler, {socket, args}})
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :socket_ready)
        accept_loop(listen, sup, model_pid, parent_pid, fc_map)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        accept_loop(listen, sup, model_pid, parent_pid, fc_map)
    end
  end

  defp region({:r, _width, region}), do: region
  defp region({:w, _width, region, _mode}), do: region

  defp lookup_entry(fc_map, {_unit, {fc, _direction, _width}, _address, _argument}),
    do: FcMap.lookup(fc_map, fc)

  defp lookup_entry(_fc_map, _frame), do: :error

  defp validate_entry!(entry, {_unit, {_fc, direction, width}, _address, _argument}) do
    validate_entry!(entry, direction, width)
  end

  defp validate_entry!(_entry, _frame) do
    raise ArgumentError, "invalid frame"
  end

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
