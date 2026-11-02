defmodule Modbuv.Tcp do
  @moduledoc """
  Modbus TCP ADU framing: MBAP header plus the Codec PDU.
  """

  alias Modbuv.Codec

  @doc "Packs a Modbus TCP request ADU (MBAP header + PDU). `transid` is the transaction identifier (0–65535)."
  @spec pack_req(tuple(), 0..65535) :: binary()
  def pack_req({slave, _, _, _} = frame, transid) do
    pdu = Codec.pack_request(frame)
    wrap(transid, slave, pdu)
  end

  @doc "Encodes a frame tuple and its response values into a Modbus TCP response ADU using the given transaction ID."
  @spec pack_res(tuple(), list() | nil, 0..65535) :: binary()
  def pack_res({slave, _, _, _} = frame, values, transid) do
    pdu = Codec.pack_response(frame, values)
    wrap(transid, slave, pdu)
  end

  @doc "Encodes a Modbus exception response into a TCP ADU for the given slave, function code, reason, and transaction ID."
  @spec pack_exception(0..255, 1..127, atom(), 0..65535) :: binary()
  def pack_exception(slave, fc, reason, transid) do
    pdu = Codec.pack_exception(fc, reason)
    wrap(transid, slave, pdu)
  end

  @doc "Parses a Modbus TCP request ADU binary using the given fc_map. Returns `{:ok, frame, transid}` on success or `{:error, reason, fc}` on failure."
  @spec parse_req(binary(), map()) ::
          {:ok, tuple(), 0..65535} | {:error, atom(), integer() | nil}
  def parse_req(<<transid::16, protocol::16, length::16, rest::binary>>, fc_map)
      when protocol == 0 and length in 2..254 and byte_size(rest) >= length do
    pdu_size = length - 1
    unit = :binary.at(rest, 0)
    pdu = binary_part(rest, 1, pdu_size)

    case Codec.parse_request(unit, pdu, fc_map) do
      {:ok, frame} -> {:ok, frame, transid}
      {:error, reason} -> {:error, reason, pdu_fc(pdu)}
    end
  end

  def parse_req(_adu, _fc_map), do: {:error, :einval, nil}

  @spec parse_res(tuple(), binary()) :: list() | nil | {:error, term()}
  def parse_res(
        {slave, _, _, _} = frame,
        <<_transid::16, protocol::16, length::16, unit::8, rest::binary>>
      )
      when protocol == 0 and length in 2..254 and byte_size(rest) >= length - 1 do
    if unit == slave do
      pdu_size = length - 1
      pdu = binary_part(rest, 0, pdu_size)
      Codec.parse_response(frame, pdu)
    else
      {:error, :ebadresp}
    end
  end

  def parse_res(_frame, _adu), do: {:error, :ebadresp}

  @spec split_adus(binary()) :: {[binary()], binary()}
  def split_adus(data), do: split_adus(data, [])

  defp split_adus(
         <<transid::16, protocol::16, length::16, tail::binary>>,
         frames
       )
       when protocol == 0 and length in 2..254 and byte_size(tail) >= length do
    payload = binary_part(tail, 0, length)
    rest = binary_part(tail, length, byte_size(tail) - length)
    adu = <<transid::16, protocol::16, length::16, payload::binary>>
    split_adus(rest, [adu | frames])
  end

  defp split_adus(
         <<_transid::16, protocol::16, length::16, _tail::binary>> = data,
         frames
       )
       when protocol != 0 or length < 2 or length > 254 do
    <<_byte, rest::binary>> = data
    split_adus(rest, frames)
  end

  defp split_adus(rest, frames), do: {Enum.reverse(frames), rest}

  defp wrap(transid, slave, pdu) do
    validate_slave!(slave)
    <<transid::16, 0::16, 1 + byte_size(pdu)::16, slave::8, pdu::binary>>
  end

  defp validate_slave!(slave) do
    unless is_integer(slave) and slave in 0..255,
      do: raise(ArgumentError, "slave must be an integer in 0..255")
  end

  defp pdu_fc(<<fc, _::binary>>), do: fc
  defp pdu_fc(_pdu), do: nil
end
