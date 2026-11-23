defmodule Modbuv.Rtu do
  @moduledoc """
  Modbus RTU ADU framing: `<<slave, pdu, crc::little-16>>`.
  """

  alias Modbuv.{Codec, CRC}

  @spec pack_req(tuple()) :: binary()
  def pack_req({slave, {_fc, direction, _width}, _, _} = frame) do
    validate_req_slave!(slave, direction)
    adu = wrap(slave, Codec.pack_request(frame))
    validate_req!(frame, adu)
    adu
  end

  @spec pack_res(tuple(), list() | nil) :: binary()
  def pack_res({slave, _, _, _} = frame, values) do
    validate_unicast_slave!(slave)
    adu = wrap(slave, Codec.pack_response(frame, values))

    if byte_size(adu) > 256,
      do: raise(ArgumentError, "RTU ADU exceeds 256 bytes")

    adu
  end

  @spec pack_exception(1..247, 1..127, atom()) :: binary()
  def pack_exception(slave, fc, reason) do
    validate_unicast_slave!(slave)
    wrap(slave, Codec.pack_exception(fc, reason))
  end

  @spec parse_req(binary(), map()) ::
          {:ok, tuple()} | {:error, atom(), integer() | nil}
  def parse_req(adu, fc_map) do
    case unwrap(adu) do
      {:ok, slave, pdu} ->
        case Codec.parse_request(slave, pdu, fc_map) do
          {:ok, frame} -> {:ok, frame}
          {:error, reason} -> {:error, reason, pdu_fc(pdu)}
        end

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  @spec parse_res(tuple(), binary()) :: list() | nil | {:error, term()}
  def parse_res({slave, _, _, _} = frame, adu) do
    case unwrap(adu) do
      {:ok, ^slave, pdu} -> Codec.parse_response(frame, pdu)
      {:ok, _other, _pdu} -> {:error, :ebadresp}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec response_length(tuple(), binary()) :: {:ok, pos_integer()} | :more | {:error, term()}
  def response_length({slave, {fc, :w, _width}, _address, _argument}, received) do
    case received do
      <<^slave, got_fc, _rest::binary>> when got_fc == fc + 0x80 -> {:ok, 5}
      <<^slave, got_fc, _rest::binary>> when got_fc == fc -> {:ok, 8}
      <<^slave, _got_fc, _rest::binary>> -> {:error, :ebadresp}
      <<other_slave, _rest::binary>> when other_slave != slave -> {:error, :ebadresp}
      _ -> :more
    end
  end

  def response_length({slave, {fc, :r, width}, _address, count}, received) do
    case received do
      <<^slave, got_fc, _rest::binary>> when got_fc == fc + 0x80 ->
        {:ok, 5}

      <<^slave, got_fc, _rest::binary>> when got_fc != fc ->
        {:error, :ebadresp}

      <<^slave, ^fc, byte_count, _rest::binary>> ->
        if byte_count == expected_byte_count(width, count),
          do: {:ok, 5 + byte_count},
          else: {:error, :ebadresp}

      <<other_slave, _rest::binary>> when other_slave != slave ->
        {:error, :ebadresp}

      _ ->
        :more
    end
  end

  @spec response_fits?(tuple()) :: boolean()
  def response_fits?({_slave, {_fc, :r, :bit}, _address, count}) do
    div(count + 7, 8) + 5 <= 256
  end

  def response_fits?({_slave, {_fc, :r, :reg}, _address, count}) do
    count * 2 + 5 <= 256
  end

  def response_fits?(_frame), do: true

  defp wrap(slave, pdu) do
    validate_slave!(slave)
    payload = <<slave::8, pdu::binary>>
    crc = CRC.crc(payload)
    <<payload::binary, crc::little-16>>
  end

  defp expected_byte_count(:bit, count), do: div(count + 7, 8)
  defp expected_byte_count(:reg, count), do: 2 * count

  defp validate_slave!(slave) do
    unless is_integer(slave) and slave in 0..247,
      do: raise(ArgumentError, "RTU slave must be an integer in 0..247")
  end

  defp validate_req_slave!(slave, :w) do
    unless is_integer(slave) and slave in 0..247,
      do: raise(ArgumentError, "RTU write slave must be an integer in 0..247")
  end

  defp validate_req_slave!(slave, :r) do
    unless is_integer(slave) and slave in 1..247,
      do: raise(ArgumentError, "RTU read slave must be an integer in 1..247")
  end

  defp validate_req_slave!(slave, _direction), do: validate_slave!(slave)

  defp validate_unicast_slave!(slave) do
    unless is_integer(slave) and slave in 1..247,
      do: raise(ArgumentError, "RTU slave must be an integer in 1..247")
  end

  defp unwrap(adu) when byte_size(adu) >= 4 do
    payload_size = byte_size(adu) - 2
    payload = binary_part(adu, 0, payload_size)
    <<crc_lo, crc_hi>> = binary_part(adu, payload_size, 2)

    if CRC.crc(payload) == crc_lo + crc_hi * 256 do
      <<slave, pdu::binary>> = payload
      {:ok, slave, pdu}
    else
      {:error, :ecrc}
    end
  end

  defp unwrap(_adu), do: {:error, :ecrc}

  defp validate_req!({_slave, {_fc, :w, _width}, _address, _argument}, adu) do
    if byte_size(adu) > 256,
      do: raise(ArgumentError, "RTU ADU exceeds 256 bytes")
  end

  defp validate_req!(frame, _adu) do
    unless response_fits?(frame),
      do: raise(ArgumentError, "RTU response exceeds 256 bytes")
  end

  defp pdu_fc(<<fc, _::binary>>), do: fc
  defp pdu_fc(_pdu), do: nil
end
