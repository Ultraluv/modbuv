defmodule Modbuv.FcMap do
  @moduledoc """
  Server/Slave function-code registry: maps a numeric function code to the
  direction, data width, address region, and (for writes) single/multi layout.

  ### Write Layouts (`:single` vs `:multi`)
  - **Modbus TCP**: The MBAP header provides the exact PDU byte length, so custom
    write function codes automatically parse both single-write (4-byte body) and
    multi-write (`5 + byte_count` body) requests regardless of the layout tag.
  - **Modbus RTU**: Serial stream framing in `Modbuv.Rtu.Framer` relies on the
    function code to determine expected frame length. For RTU, you must register
    the code explicitly as `:single` (fixed 8-byte ADU) or `:multi` (variable
    length derived from `byte_count`).
  """

  @regions [:c, :i, :hr, :ir]
  @widths [:bit, :reg]

  @default %{
    1 => {:r, :bit, :c},
    2 => {:r, :bit, :i},
    3 => {:r, :reg, :hr},
    4 => {:r, :reg, :ir},
    5 => {:w, :bit, :c, :single},
    6 => {:w, :reg, :hr, :single},
    15 => {:w, :bit, :c, :multi},
    16 => {:w, :reg, :hr, :multi}
  }

  @spec default() :: map()
  def default, do: @default

  @doc "Merges overrides into the base map (defaults to `@default`). Overrides must have integer keys in 1..127 and valid entries."
  @spec merge(map(), map()) :: map()
  def merge(base \\ @default, overrides) when is_map(base) and is_map(overrides) do
    Enum.each(overrides, fn {fc, entry} -> validate!(fc, entry) end)
    Map.merge(base, overrides)
  end

  @spec lookup(map(), integer()) :: {:ok, tuple()} | :error
  def lookup(map, fc), do: Map.fetch(map, fc)

  defp validate!(fc, entry) when is_integer(fc) and fc in 1..127 do
    validate_entry!(entry)
  end

  defp validate!(_fc, _entry) do
    raise ArgumentError, "fc_map keys must be integers in 1..127"
  end

  defp validate_entry!({:r, width, region})
       when width in @widths and region in @regions,
       do: :ok

  defp validate_entry!({:w, width, region, mode})
       when width in @widths and region in @regions and mode in [:single, :multi],
       do: :ok

  defp validate_entry!(_entry) do
    raise ArgumentError, "invalid fc_map entry"
  end
end
