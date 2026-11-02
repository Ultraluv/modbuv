defmodule Modbuv.Rtu.FramerTest do
  use ExUnit.Case, async: true
  alias Modbuv.{Rtu, FcMap}
  alias Modbuv.Rtu.Framer

  defp state, do: elem(Framer.init(fc_map: FcMap.default()), 1)

  test "frames a complete read request" do
    adu = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    assert {:ok, [^adu], _} = Framer.remove_framing(adu, state())
  end

  test "waits for fragments and handles coalesced frames" do
    adu = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    <<a::binary-size(3), b::binary>> = adu
    assert {:in_frame, [], s} = Framer.remove_framing(a, state())
    assert {:ok, [^adu], _} = Framer.remove_framing(b, s)

    adu2 = Rtu.pack_req({1, {6, :w, :reg}, 0, 1})
    assert {:ok, [^adu, ^adu2], _} = Framer.remove_framing(adu <> adu2, state())
  end

  test "reports a CRC failure for a registered fc" do
    adu = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    <<head::binary-size(6), _::binary>> = adu
    bad = head <> <<0, 0>>
    assert {:ok, [{:error, :ecrc, ^bad}], _} = Framer.remove_framing(bad, state())
  end

  test "resyncs past a bad unknown-fc probe to a valid frame" do
    good = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    bad8 = <<1, 9, 0, 0, 0, 1, 0, 0>>
    assert {:ok, frames, _} = Framer.remove_framing(bad8 <> good, state())
    assert good in frames
  end

  test "derives multi-write length" do
    adu = Rtu.pack_req({1, {16, :w, :reg}, 0, [1, 2, 3]})
    assert {:ok, [^adu], _} = Framer.remove_framing(adu, state())
  end

  test "discards multi-write with oversized byte_count > 247" do
    good = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    bad_multi = <<1, 16, 0, 0, 0, 1, 250>>
    assert {:ok, frames, _} = Framer.remove_framing(bad_multi <> good, state())
    assert good in frames
  end

  test "timeout returns the partial buffer" do
    {:ok, s} = Framer.init(fc_map: FcMap.default())
    {:in_frame, [], s} = Framer.remove_framing(<<1, 3, 0>>, s)
    assert {:ok, [{:partial, <<1, 3, 0>>}], _} = Framer.frame_timeout(s)
  end
end
