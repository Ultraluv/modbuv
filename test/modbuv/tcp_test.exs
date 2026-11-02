defmodule Modbuv.TcpTest do
  use ExUnit.Case, async: true
  alias Modbuv.{Tcp, FcMap}

  @req {1, {3, :r, :reg}, 0, 2}
  @res {1, {3, :r, :reg}, 0, 2}

  test "packs MBAP ADUs" do
    assert Tcp.pack_req(@req, 7) == <<0, 7, 0, 0, 0, 6, 1, 3, 0, 0, 0, 2>>
    assert Tcp.pack_res(@res, [1, 2], 7) == <<0, 7, 0, 0, 0, 7, 1, 3, 4, 0, 1, 0, 2>>
    assert Tcp.pack_exception(1, 3, :eaddr, 7) == <<0, 7, 0, 0, 0, 3, 1, 0x83, 2>>
  end

  test "splits coalesced and fragmented streams" do
    adu = Tcp.pack_req(@req, 1)
    adu2 = Tcp.pack_req(@req, 2)
    assert Tcp.split_adus(adu <> adu2) == {[adu, adu2], <<>>}
    assert Tcp.split_adus(binary_part(adu, 0, 7)) == {[], binary_part(adu, 0, 7)}

    <<head::binary-size(7), tail::binary>> = adu
    assert Tcp.split_adus(head) == {[], head}
    assert Tcp.split_adus(head <> tail) == {[adu], <<>>}
  end

  test "drops malformed MBAP headers and resyncs" do
    adu = Tcp.pack_req(@req, 1)
    assert Tcp.split_adus(<<0, 1, 0, 0, 0, 0>> <> adu) == {[adu], <<>>}
    assert Tcp.split_adus(<<0, 1, 0, 0, 0, 1>> <> adu) == {[adu], <<>>}
  end

  test "rejects out-of-range slave ids" do
    assert_raise ArgumentError, fn -> Tcp.pack_req({256, {3, :r, :reg}, 0, 1}, 1) end
    assert_raise ArgumentError, fn -> Tcp.pack_exception(256, 3, :eaddr, 1) end
  end

  test "parses requests and responses" do
    adu = Tcp.pack_req(@req, 9)
    assert Tcp.parse_req(adu, FcMap.default()) == {:ok, @req, 9}
    assert Tcp.parse_res(@res, Tcp.pack_res(@res, [1, 2], 9)) == [1, 2]

    bad_unit_res = Tcp.pack_res({2, {3, :r, :reg}, 0, 2}, [1, 2], 9)
    assert Tcp.parse_res(@res, bad_unit_res) == {:error, :ebadresp}
  end

  test "rejects bad MBAP and unknown fcs with an fc" do
    assert Tcp.parse_req(<<0, 1, 0, 1, 0, 6, 1, 3, 0, 0, 0, 2>>, FcMap.default()) ==
             {:error, :einval, nil}

    assert Tcp.parse_req(Tcp.pack_req({1, {9, :r, :reg}, 0, 1}, 1), FcMap.default()) ==
             {:error, :efun, 9}
  end
end
