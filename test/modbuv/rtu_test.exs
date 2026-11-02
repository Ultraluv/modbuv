defmodule Modbuv.RtuTest do
  use ExUnit.Case, async: true
  alias Modbuv.{Rtu, FcMap}

  @read {1, {3, :r, :reg}, 0, 2}
  @write {1, {16, :w, :reg}, 1, [102, 103]}

  test "packs ADUs with low-byte-first CRC" do
    assert Rtu.pack_req({1, {3, :r, :reg}, 0, 1}) == <<1, 3, 0, 0, 0, 1, 0x84, 0x0A>>

    assert Rtu.pack_req(@write) ==
             <<1, 16, 0, 1, 0, 2, 4, 0, 102, 0, 103, 0x93, 0x96>>

    assert Rtu.pack_res(@read, [1, 2]) == <<1, 3, 4, 0, 1, 0, 2, 0x2A, 0x32>>
    assert Rtu.pack_exception(1, 3, :eaddr) == <<1, 0x83, 2, 0xC0, 0xF1>>
  end

  test "parses requests and responses" do
    adu = Rtu.pack_req({1, {3, :r, :reg}, 0, 1})
    assert Rtu.parse_req(adu, FcMap.default()) == {:ok, {1, {3, :r, :reg}, 0, 1}}

    res = Rtu.pack_res(@read, [1, 2])
    assert Rtu.parse_res(@read, res) == [1, 2]

    assert Rtu.parse_res(@read, <<1, 0x83, 2, 0xC0, 0xF1>>) == {:error, :eaddr}
  end

  test "rejects bad CRC, bad slave, and unknown fcs" do
    assert Rtu.parse_req(<<1, 3, 0, 0, 0, 1, 0, 0>>, FcMap.default()) == {:error, :ecrc, nil}

    bad_slave = Rtu.pack_res({2, {3, :r, :reg}, 0, 2}, [1, 2])
    assert Rtu.parse_res(@read, bad_slave) == {:error, :ebadresp}

    assert Rtu.parse_req(Rtu.pack_req({1, {9, :r, :reg}, 0, 1}), FcMap.default()) ==
             {:error, :efun, 9}
  end

  test "derives reply lengths" do
    assert Rtu.response_length(@read, <<>>) == :more
    assert Rtu.response_length(@read, <<1, 3>>) == :more
    assert Rtu.response_length(@read, <<1, 3, 4>>) == {:ok, 9}
    assert Rtu.response_length(@read, <<1, 0x83, 2>>) == {:ok, 5}
    assert Rtu.response_length({1, {6, :w, :reg}, 0, 1}, <<1, 6, 0, 1, 0, 2>>) == {:ok, 8}
    assert Rtu.response_length({1, {6, :w, :reg}, 0, 1}, <<1, 3>>) == {:error, :ebadresp}
  end

  test "RTU ADU limits" do
    assert Rtu.response_fits?({1, {3, :r, :reg}, 0, 125})
    refute Rtu.response_fits?({1, {3, :r, :reg}, 0, 126})
    assert Rtu.response_fits?({1, {1, :r, :bit}, 0, 2008})
    refute Rtu.response_fits?({1, {1, :r, :bit}, 0, 2009})

    assert_raise ArgumentError, fn ->
      Rtu.pack_req({1, {16, :w, :reg}, 0, List.duplicate(0, 124)})
    end
  end

  test "rejects out-of-range slave ids" do
    assert_raise ArgumentError, fn -> Rtu.pack_req({256, {3, :r, :reg}, 0, 1}) end
    assert_raise ArgumentError, fn -> Rtu.pack_exception(256, 3, :eaddr) end
  end

  test "response_length rejects a byte_count that disagrees with the request" do
    assert Rtu.response_length(@read, <<1, 3, 200>>) == {:error, :ebadresp}
    assert Rtu.response_length({1, {1, :r, :bit}, 0, 10}, <<1, 1, 2>>) == {:ok, 7}
    assert Rtu.response_length({1, {1, :r, :bit}, 0, 10}, <<1, 1, 3>>) == {:error, :ebadresp}
  end
end
