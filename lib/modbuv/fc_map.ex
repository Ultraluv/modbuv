defmodule Modbuv.FcMap do
  @moduledoc """
  Server/Slave function-code registry: maps a numeric function code to the
  direction, data width, address region, and (for writes) single/multi layout.
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

  @spec merge(map()) :: map()
  def merge(overrides) when is_map(overrides) do
    Enum.each(overrides, fn {fc, entry} -> validate!(fc, entry) end)
    Map.merge(@default, overrides)
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
