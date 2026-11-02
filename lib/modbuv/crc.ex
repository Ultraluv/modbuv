defmodule Modbuv.CRC do
  @moduledoc """
  CRC16/MODBUS calculation.
  """

  import Bitwise

  @table (for i <- 0..255 do
            Enum.reduce(1..8, i, fn _, crc ->
              if band(crc, 1) == 1,
                do: bxor(bsr(crc, 1), 0xA001),
                else: bsr(crc, 1)
            end)
          end)
         |> List.to_tuple()

  @spec crc(binary()) :: 0..65535
  def crc(binary), do: do_crc(binary, 0xFFFF)

  defp do_crc(<<>>, acc), do: acc

  defp do_crc(<<byte, rest::binary>>, acc) do
    index = band(bxor(acc, byte), 0xFF)
    do_crc(rest, bxor(bsr(acc, 8), elem(@table, index)))
  end
end
