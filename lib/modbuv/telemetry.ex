defmodule Modbuv.Telemetry do
  @moduledoc """
  Telemetry instrumentation for `Modbuv.Tcp.Client` and `Modbuv.Rtu.Master`
  requests.

  Each request emits `[:modbuv, :request, :start]` when it is sent and
  `[:modbuv, :request, :stop]` when it completes, fails, or times out.

  Start measurements are `%{system_time: native}`. Stop measurements are
  `%{duration: native, monotonic_time: native}`; convert `duration` with
  `System.convert_time_unit/3` to get RTT.

  Metadata contains `:transport` (`:tcp` or `:rtu`), `:role` (`:client` or
  `:master`), `:mode` (`:passive` or `:active`), `:slave`, and `:fc`. The stop
  event adds `:result` (`:ok` or `:error`) and `:reason` (`nil` on success).
  """

  @doc false
  @spec start(map()) :: integer()
  def start(metadata) do
    :telemetry.execute(
      [:modbuv, :request, :start],
      %{system_time: System.system_time(:native)},
      metadata
    )

    System.monotonic_time()
  end

  @doc false
  @spec stop(map(), integer(), term()) :: :ok
  def stop(metadata, started_at, result) do
    now = System.monotonic_time()
    {status, reason} = normalize(result)

    metadata =
      metadata
      |> Map.put(:result, status)
      |> Map.put(:reason, reason)

    :telemetry.execute(
      [:modbuv, :request, :stop],
      %{duration: now - started_at, monotonic_time: now},
      metadata
    )
  end

  @doc false
  @spec request_metadata(:tcp | :rtu, :client | :master, :passive | :active, tuple()) :: map()
  def request_metadata(
        transport,
        role,
        mode,
        {slave, {fc, _direction, _width}, _address, _argument}
      ) do
    %{transport: transport, role: role, mode: mode, slave: slave, fc: fc}
  end

  defp normalize(:ok), do: {:ok, nil}
  defp normalize(nil), do: {:ok, nil}
  defp normalize({:ok, _values}), do: {:ok, nil}
  defp normalize(values) when is_list(values), do: {:ok, nil}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, other}
end
