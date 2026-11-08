defmodule Modbuv.Codec do
  @moduledoc """
  Modbus PDU encoding and decoding. A PDU is `<<fc, body::binary>>`; slave/unit
  ids, CRC, and MBAP live in the transport layers.
  """

  import Bitwise

  alias Modbuv.FcMap

  @exceptions %{
    1 => :efun,
    2 => :eaddr,
    3 => :einval,
    4 => :edevice,
    5 => :ack,
    6 => :sbusy,
    7 => :nack,
    8 => :ememp,
    9 => :error,
    10 => :egpath,
    11 => :egtarg
  }

  @codes Map.new(@exceptions, fn {code, reason} -> {reason, code} end)

  @spec pack_request(tuple()) :: binary()
  def pack_request({slave, {fc, direction, width}, address, argument}) do
    validate_slave!(slave)
    validate_frame!(fc, direction, width, address)
    <<fc, pack_body(direction, width, address, argument)::binary>>
  end

  @spec pack_response(tuple(), list() | nil) :: binary()
  def pack_response({_slave, {fc, :r, width}, _address, count}, values) do
    validate_fc!(fc)
    validate_width!(width)
    validate_read_count!(width, count)
    validate_values!(width, values)
    if length(values) != count, do: raise(ArgumentError, "response value count mismatch")
    data = encode_values(width, values)
    <<fc, byte_size(data)::8, data::binary>>
  end

  def pack_response({_slave, {fc, :w, width}, address, argument}, nil) do
    validate_frame!(fc, :w, width, address)

    body =
      case argument do
        value when is_integer(value) ->
          validate_single_value!(width, value)
          <<address::16, encode_single(width, value)::16>>

        values when is_list(values) ->
          validate_multi_values!(width, values)
          <<address::16, length(values)::16>>
      end

    <<fc, body::binary>>
  end

  @spec pack_exception(integer(), atom()) :: binary()
  def pack_exception(fc, reason) do
    validate_fc!(fc)
    <<fc ||| 0x80, reason_to_code(reason)::8>>
  end

  @spec reason_to_code(atom()) :: 1..11
  def reason_to_code(reason) do
    case Map.fetch(@codes, reason) do
      {:ok, code} -> code
      :error -> raise ArgumentError, "not an exception reason: #{inspect(reason)}"
    end
  end

  @spec code_to_reason(0..255) :: atom() | {:unknown_exception, integer()}
  def code_to_reason(code) when is_integer(code) and code in 0..255 do
    Map.get(@exceptions, code, {:unknown_exception, code})
  end

  @spec response_encodable?(tuple()) :: boolean()
  def response_encodable?({_slave, {_fc, :r, :bit}, _address, count})
      when is_integer(count) and count > 0,
      do: div(count + 7, 8) <= 255

  def response_encodable?({_slave, {_fc, :r, :reg}, _address, count})
      when is_integer(count) and count > 0,
      do: count <= 127

  def response_encodable?(_frame), do: true

  @spec parse_request(0..255, binary(), map()) :: {:ok, tuple()} | {:error, atom()}
  def parse_request(slave, pdu, fc_map) do
    with <<fc, body::binary>> when fc in 1..127 <- pdu,
         {:ok, entry} <- FcMap.lookup(fc_map, fc) do
      parse_request_body(slave, fc, entry, body)
    else
      _ -> {:error, :efun}
    end
  end

  @spec parse_response(tuple(), binary()) :: list() | nil | {:error, term()}
  def parse_response({_slave, {fc, direction, width}, address, argument}, pdu) do
    case pdu do
      <<exception_fc, code>> when exception_fc == fc + 0x80 ->
        {:error, code_to_reason(code)}

      <<^fc, body::binary>> ->
        parse_response_body(direction, width, address, argument, body)

      _ ->
        {:error, :ebadresp}
    end
  end

  defp parse_request_body(slave, fc, {:r, width, _region}, <<address::16, count::16>>)
       when count > 0 do
    {:ok, {slave, {fc, :r, width}, address, count}}
  end

  defp parse_request_body(slave, fc, {:w, width, _region, _mode}, <<address::16, raw::16>>) do
    case decode_single(width, raw) do
      {:ok, value} -> {:ok, {slave, {fc, :w, width}, address, value}}
      :error -> {:error, :einval}
    end
  end

  defp parse_request_body(
         slave,
         fc,
         {:w, width, _region, _mode},
         <<address::16, count::16, byte_count::8, data::binary>>
       )
       when count > 0 do
    expected = byte_count_for(width, count)

    if byte_count == expected and byte_size(data) == expected do
      {:ok, {slave, {fc, :w, width}, address, decode_values(width, data, count)}}
    else
      {:error, :einval}
    end
  end

  defp parse_request_body(_slave, _fc, _entry, _body), do: {:error, :einval}

  defp parse_response_body(:r, width, _address, count, <<byte_count::8, data::binary>>) do
    expected = byte_count_for(width, count)

    if byte_count == expected and byte_size(data) == expected do
      decode_values(width, data, count)
    else
      {:error, :ebadresp}
    end
  end

  defp parse_response_body(:w, width, address, value, <<got_address::16, raw::16>>)
       when is_integer(value) do
    with true <- got_address == address,
         {:ok, decoded} <- decode_single(width, raw),
         true <- decoded == value do
      nil
    else
      _ -> {:error, :ebadresp}
    end
  end

  defp parse_response_body(:w, _width, address, values, <<got_address::16, count::16>>)
       when is_list(values) do
    if got_address == address and count == length(values),
      do: nil,
      else: {:error, :ebadresp}
  end

  defp parse_response_body(_direction, _width, _address, _argument, _body),
    do: {:error, :ebadresp}

  defp decode_single(:bit, 0xFF00), do: {:ok, 1}
  defp decode_single(:bit, 0x0000), do: {:ok, 0}
  defp decode_single(:bit, _raw), do: :error
  defp decode_single(:reg, raw), do: {:ok, raw}

  defp decode_values(:bit, data, count), do: decode_bits(data, count)
  defp decode_values(:reg, data, _count), do: for(<<value::16 <- data>>, do: value)

  defp decode_bits(data, count) do
    for index <- 0..(count - 1)//1 do
      byte = :binary.at(data, div(index, 8))
      byte >>> rem(index, 8) &&& 1
    end
  end

  defp byte_count_for(:bit, count), do: div(count + 7, 8)
  defp byte_count_for(:reg, count), do: 2 * count

  defp pack_body(:r, width, address, count) do
    validate_read_count!(width, count)
    <<address::16, count::16>>
  end

  defp pack_body(:w, width, address, value) when is_integer(value) do
    validate_single_value!(width, value)
    <<address::16, encode_single(width, value)::16>>
  end

  defp pack_body(:w, width, address, values) when is_list(values) do
    validate_multi_values!(width, values)
    data = encode_values(width, values)
    <<address::16, length(values)::16, byte_size(data)::8, data::binary>>
  end

  defp pack_body(:w, _width, _address, _arg) do
    raise ArgumentError, "write argument must be an integer or a non-empty list"
  end

  defp encode_single(:bit, 1), do: 0xFF00
  defp encode_single(:bit, 0), do: 0x0000
  defp encode_single(:reg, value), do: value

  defp encode_values(:bit, values) do
    values
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk ->
      chunk
      |> Enum.with_index()
      |> Enum.reduce(0, fn {value, index}, acc -> acc ||| value <<< index end)
    end)
    |> :binary.list_to_bin()
  end

  defp encode_values(:reg, values) do
    for value <- values, into: <<>>, do: <<value::16>>
  end

  defp validate_frame!(fc, direction, width, address) do
    validate_fc!(fc)

    unless direction in [:r, :w],
      do: raise(ArgumentError, "direction must be :r or :w")

    validate_width!(width)

    unless is_integer(address) and address in 0..65535,
      do: raise(ArgumentError, "address must be in 0..65535")
  end

  defp validate_fc!(fc) do
    unless is_integer(fc) and fc in 1..127,
      do: raise(ArgumentError, "fc must be an integer in 1..127")
  end

  defp validate_slave!(slave) do
    unless is_integer(slave) and slave in 0..255,
      do: raise(ArgumentError, "slave must be an integer in 0..255")
  end

  defp validate_width!(width) do
    unless width in [:bit, :reg],
      do: raise(ArgumentError, "width must be :bit or :reg")
  end

  defp validate_read_count!(:bit, count)
       when is_integer(count) and count > 0 and count <= 2040,
       do: :ok

  defp validate_read_count!(:reg, count)
       when is_integer(count) and count > 0 and count <= 127,
       do: :ok

  defp validate_read_count!(:bit, _count),
    do: raise(ArgumentError, "bit count must be in 1..2040")

  defp validate_read_count!(:reg, _count),
    do: raise(ArgumentError, "register count must be in 1..127")

  defp validate_single_value!(:bit, value) when value in [0, 1], do: :ok
  defp validate_single_value!(:reg, value) when is_integer(value) and value in 0..65535, do: :ok
  defp validate_single_value!(:bit, _value), do: raise(ArgumentError, "bit value must be 0 or 1")

  defp validate_single_value!(:reg, _value),
    do: raise(ArgumentError, "register value out of range")

  defp validate_multi_values!(width, values) when is_list(values) and values != [] do
    validate_read_count!(width, length(values))
    validate_values!(width, values)
  end

  defp validate_multi_values!(_width, _values),
    do: raise(ArgumentError, "write values must be a non-empty list")

  defp validate_values!(:bit, values) do
    unless Enum.all?(values, &(&1 in [0, 1])),
      do: raise(ArgumentError, "bit values must be 0 or 1")
  end

  defp validate_values!(:reg, values) do
    unless Enum.all?(values, &(is_integer(&1) and &1 in 0..65535)),
      do: raise(ArgumentError, "register values must be in 0..65535")
  end
end
