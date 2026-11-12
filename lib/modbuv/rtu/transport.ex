defmodule Modbuv.Rtu.Transport do
  @moduledoc """
  Behaviour for Modbus RTU communications transport layers.

  Decouples `Modbuv.Rtu.Master` and `Modbuv.Rtu.Slave` from specific hardware drivers,
  allowing seamless switching between real physical serial ports (`Circuits.UART`)
  and in-memory virtual serial buses (`Modbuv.Rtu.Transport.Virtual`) for simulation
  and hardware-free testing.
  """

  @type transport_ref :: pid() | term()
  @type tty :: String.t() | atom() | term()
  @type opts :: keyword()

  @doc "Starts the transport process."
  @callback start_link(opts()) :: {:ok, transport_ref()} | {:error, term()}

  @doc "Opens the transport connection for the given tty/device."
  @callback open(transport_ref(), tty(), opts()) :: :ok | {:error, term()}

  @doc "Closes the transport connection."
  @callback close(transport_ref()) :: :ok | {:error, term()}

  @doc "Writes raw binary data over the transport."
  @callback write(transport_ref(), binary()) :: :ok | {:error, term()}

  @doc "Reads data from the transport with a timeout."
  @callback read(transport_ref(), timeout()) ::
              {:ok, binary()}
              | {:ok, {:partial, binary()}}
              | {:ok, {:error, term(), term()}}
              | {:error, term()}

  @doc "Flushes input/output buffers in the transport."
  @callback flush(transport_ref(), :receive | :transmit | :both) :: :ok | {:error, term()}

  @doc "Reconfigures the transport (e.g. framing changes at runtime)."
  @callback configure(transport_ref(), opts()) :: :ok | {:error, term()}

  @doc "Stops the transport process."
  @callback stop(transport_ref()) :: :ok

  @doc """
  Resolves the transport module to use based on params and the given tty.

  - If `:transport` is explicitly provided in `params`, that module is returned.
  - If `tty` is a virtual identifier (e.g. `"virtual"`, `"virtual:" <> _`, or `:virtual`),
    `Modbuv.Rtu.Transport.Virtual` is used.
  - Otherwise, defaults to `Modbuv.Rtu.Transport.UART` (wrapping `Circuits.UART`).
  """
  @spec resolve_transport(keyword(), tty()) :: module()
  def resolve_transport(params, tty) do
    case Keyword.get(params, :transport) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      _ ->
        if virtual_tty?(tty) do
          Modbuv.Rtu.Transport.Virtual
        else
          Modbuv.Rtu.Transport.UART
        end
    end
  end

  @doc """
  Checks if a given tty represents an in-memory virtual bus.
  """
  @spec virtual_tty?(term()) :: boolean()
  def virtual_tty?(:virtual), do: true
  def virtual_tty?("virtual"), do: true
  def virtual_tty?("virtual:" <> _), do: true
  def virtual_tty?("loopback"), do: true
  def virtual_tty?("loopback:" <> _), do: true
  def virtual_tty?(_other), do: false
end

