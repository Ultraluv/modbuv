defmodule Modbuv.Rtu do
  @moduledoc """
  Modbus RTU ADU framing: `<<slave, pdu, crc::little-16>>`.
  """

  alias Modbuv.{Codec, CRC}

  @spec pack_req(tuple()) :: binary()
  def pack_req({slave, _, _, _} = frame) do
    adu = wrap(slave, Codec.pack_request(frame))
    validate_req!(frame, adu)
    adu
  end

  @spec pack_res(tuple(), list() | nil) :: binary()
  def pack_res({slave, _, _, _} = frame, values) do
    adu = wrap(slave, Codec.pack_response(frame, values))

    if byte_size(adu) > 256,
      do: raise(ArgumentError, "RTU ADU exceeds 256 bytes")

    adu
  end

  @spec pack_exception(0..255, 1..127, atom()) :: binary()
  def pack_exception(slave, fc, reason) do
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
  def response_length({_slave, {fc, :w, _width}, _address, _argument}, received) do
    case received do
      <<_slave, got_fc, _rest::binary>> when got_fc == fc + 0x80 -> {:ok, 5}
      <<_slave, got_fc, _rest::binary>> when got_fc == fc -> {:ok, 8}
      <<_slave, _got_fc, _rest::binary>> -> {:error, :ebadresp}
      _ -> :more
    end
  end

  def response_length({_slave, {fc, :r, width}, _address, count}, received) do
    case received do
      <<_slave, got_fc, _rest::binary>> when got_fc == fc + 0x80 ->
        {:ok, 5}

      <<_slave, got_fc, _rest::binary>> when got_fc != fc ->
        {:error, :ebadresp}

      <<_slave, ^fc, byte_count, _rest::binary>> ->
        if byte_count == expected_byte_count(width, count),
          do: {:ok, 5 + byte_count},
          else: {:error, :ebadresp}

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
    unless is_integer(slave) and slave in 0..255,
      do: raise(ArgumentError, "slave must be an integer in 0..255")
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
