defmodule Modbuv.Rtu.Framer do
  @moduledoc """
  Circuits.UART framer for Modbus RTU slave traffic. It accumulates bytes,
  derives the expected length from the fc_map, validates CRC, and resyncs
  byte-by-byte when a candidate is invalid.
  """

  @behaviour Circuits.UART.Framing

  alias Modbuv.{CRC, FcMap}

  defstruct buffer: <<>>, fc_map: %{}

  @impl true
  def init(args) do
    {:ok, %__MODULE__{fc_map: Keyword.get(args, :fc_map, FcMap.default())}}
  end

  @impl true
  def add_framing(data, state), do: {:ok, data, state}

  @impl true
  def remove_framing(data, state) do
    {emitted, buffer} = scan(state.buffer <> data, state.fc_map, [])
    new_state = %{state | buffer: buffer}

    case emitted do
      [] -> {:in_frame, [], new_state}
      terms -> {:ok, Enum.reverse(terms), new_state}
    end
  end

  @impl true
  def frame_timeout(%__MODULE__{buffer: <<>>} = state) do
    {:ok, [], %__MODULE__{fc_map: state.fc_map}}
  end

  def frame_timeout(state) do
    {:ok, [{:partial, state.buffer}], %__MODULE__{fc_map: state.fc_map}}
  end

  @impl true
  def flush(direction, %__MODULE__{} = state) when direction in [:receive, :both] do
    %__MODULE__{fc_map: state.fc_map}
  end

  def flush(_direction, state), do: state

  defp scan(<<>>, _fc_map, acc), do: {acc, <<>>}

  defp scan(<<_slave, fc, _::binary>> = buffer, fc_map, acc)
       when fc == 0 or fc >= 128 do
    scan(drop_one(buffer), fc_map, acc)
  end

  defp scan(<<_slave, fc, _::binary>> = buffer, fc_map, acc) do
    case frame_length(fc, buffer, fc_map) do
      {:ok, length} ->
        if byte_size(buffer) < length do
          {acc, buffer}
        else
          candidate = binary_part(buffer, 0, length)
          rest = binary_part(buffer, length, byte_size(buffer) - length)

          if crc_ok?(candidate) do
            scan(rest, fc_map, [candidate | acc])
          else
            acc =
              if registered?(fc_map, fc),
                do: [{:error, :ecrc, candidate} | acc],
                else: acc

            scan(drop_one(buffer), fc_map, acc)
          end
        end

      :more ->
        {acc, buffer}

      :error ->
        scan(drop_one(buffer), fc_map, acc)
    end
  end

  defp scan(buffer, _fc_map, acc), do: {acc, buffer}

  defp frame_length(fc, buffer, fc_map) do
    case FcMap.lookup(fc_map, fc) do
      {:ok, {:r, _width, _region}} ->
        {:ok, 8}

      {:ok, {:w, _width, _region, :single}} ->
        {:ok, 8}

      {:ok, {:w, _width, _region, :multi}} ->
        if byte_size(buffer) >= 7 do
          <<_slave, _fc, _address::16, _count::16, byte_count, _::binary>> = buffer
          total = 9 + byte_count

          if total <= 256,
            do: {:ok, total},
            else: :error
        else
          :more
        end

      :error ->
        {:ok, 8}
    end
  end

  defp crc_ok?(candidate) when byte_size(candidate) >= 4 do
    size = byte_size(candidate) - 2
    payload = binary_part(candidate, 0, size)
    <<lo, hi>> = binary_part(candidate, size, 2)
    CRC.crc(payload) == lo + hi * 256
  end

  defp crc_ok?(_candidate), do: false

  defp registered?(fc_map, fc), do: match?({:ok, _entry}, FcMap.lookup(fc_map, fc))

  defp drop_one(<<_byte, rest::binary>>), do: rest
  defp drop_one(<<>>), do: <<>>
end
