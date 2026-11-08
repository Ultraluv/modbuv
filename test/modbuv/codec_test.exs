defmodule Modbuv.CodecPackingTest do
  use ExUnit.Case, async: true
  alias Modbuv.Codec

  test "packs read requests" do
    assert Codec.pack_request({1, {3, :r, :reg}, 1, 2}) == <<3, 0, 1, 0, 2>>
    assert Codec.pack_request({1, {1, :r, :bit}, 0, 10}) == <<1, 0, 0, 0, 10>>
  end

  test "packs single writes" do
    assert Codec.pack_request({1, {5, :w, :bit}, 0, 1}) == <<5, 0, 0, 0xFF, 0>>
    assert Codec.pack_request({1, {5, :w, :bit}, 0, 0}) == <<5, 0, 0, 0, 0>>
    assert Codec.pack_request({1, {6, :w, :reg}, 1, 102}) == <<6, 0, 1, 0, 102>>
  end

  test "packs multi writes" do
    assert Codec.pack_request({1, {15, :w, :bit}, 0, [1, 0, 1]}) ==
             <<15, 0, 0, 0, 3, 1, 5>>

    assert Codec.pack_request({1, {16, :w, :reg}, 1, [102, 103]}) ==
             <<16, 0, 1, 0, 2, 4, 0, 102, 0, 103>>
  end

  test "rejects frames that cannot be encoded" do
    frames = [
      {1, {0, :r, :reg}, 0, 1},
      {1, {128, :r, :reg}, 0, 1},
      {1, {3, :x, :reg}, 0, 1},
      {1, {3, :r, :word}, 0, 1},
      {1, {3, :r, :reg}, 0, 0},
      {1, {3, :r, :reg}, 0, 128},
      {1, {1, :r, :bit}, 0, 2041},
      {1, {3, :w, :reg}, 0, 65_536},
      {1, {5, :w, :bit}, 0, 2},
      {1, {16, :w, :reg}, 0, []},
      {1, {6, :w, :reg}, 0, "100"},
      {1, {3, :r, :reg}, 0, :invalid}
    ]

    for frame <- frames do
      assert_raise ArgumentError, fn -> Codec.pack_request(frame) end
    end
  end

  test "packs responses and exceptions" do
    assert Codec.pack_response({1, {3, :r, :reg}, 0, 2}, [1, 2]) == <<3, 4, 0, 1, 0, 2>>

    assert Codec.pack_response({1, {1, :r, :bit}, 0, 10}, [1, 0, 1, 1, 0, 0, 1, 1, 1, 0]) ==
             <<1, 2, 0xCD, 0x01>>

    assert Codec.pack_response({1, {6, :w, :reg}, 1, 102}, nil) == <<6, 0, 1, 0, 102>>
    assert Codec.pack_response({1, {16, :w, :reg}, 1, [102, 103]}, nil) == <<16, 0, 1, 0, 2>>
    assert Codec.pack_exception(3, :eaddr) == <<0x83, 2>>
    assert_raise ArgumentError, fn -> Codec.pack_response({1, {3, :r, :reg}, 0, 2}, [1]) end
  end

  test "response encodability and exception mapping" do
    assert Codec.response_encodable?({1, {3, :r, :reg}, 0, 127})
    refute Codec.response_encodable?({1, {3, :r, :reg}, 0, 128})
    assert Codec.response_encodable?({1, {1, :r, :bit}, 0, 2040})
    refute Codec.response_encodable?({1, {1, :r, :bit}, 0, 2041})
    assert Codec.reason_to_code(:eaddr) == 2
    assert Codec.code_to_reason(2) == :eaddr
    assert Codec.code_to_reason(0) == {:unknown_exception, 0}
    assert Codec.code_to_reason(12) == {:unknown_exception, 12}
    assert_raise ArgumentError, fn -> Codec.reason_to_code(:ecrc) end
  end
end

defmodule Modbuv.CodecParsingTest do
  use ExUnit.Case, async: true
  alias Modbuv.{Codec, FcMap}

  test "parses read responses" do
    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<3, 4, 0, 1, 0, 2>>) == [1, 2]

    assert Codec.parse_response({1, {1, :r, :bit}, 0, 10}, <<1, 2, 0xCD, 0x01>>) ==
             [1, 0, 1, 1, 0, 0, 1, 1, 1, 0]
  end

  test "parses write echoes" do
    assert Codec.parse_response({1, {6, :w, :reg}, 1, 102}, <<6, 0, 1, 0, 102>>) == nil
    assert Codec.parse_response({1, {16, :w, :reg}, 1, [102, 103]}, <<16, 0, 1, 0, 2>>) == nil
  end

  test "parses exceptions" do
    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<0x83, 2>>) == {:error, :eaddr}

    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<0x83, 0>>) ==
             {:error, {:unknown_exception, 0}}

    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<0x83, 12>>) ==
             {:error, {:unknown_exception, 12}}
  end

  test "rejects mismatched responses" do
    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<4, 4, 0, 1, 0, 2>>) ==
             {:error, :ebadresp}

    assert Codec.parse_response({1, {3, :r, :reg}, 0, 2}, <<3, 2, 0, 1>>) ==
             {:error, :ebadresp}

    assert Codec.parse_response({1, {6, :w, :reg}, 1, 102}, <<6, 0, 1, 0, 103>>) ==
             {:error, :ebadresp}

    assert Codec.parse_response({1, {16, :w, :reg}, 1, [102, 103]}, <<16, 0, 1, 0, 3>>) ==
             {:error, :ebadresp}
  end

  test "parses standard and vendor requests" do
    map = FcMap.merge(%{0x64 => {:r, :reg, :hr}, 0x6E => {:w, :reg, :hr, :multi}})
    assert Codec.parse_request(1, <<3, 0, 1, 0, 2>>, map) == {:ok, {1, {3, :r, :reg}, 1, 2}}
    assert Codec.parse_request(1, <<5, 0, 0, 0xFF, 0>>, map) == {:ok, {1, {5, :w, :bit}, 0, 1}}
    assert Codec.parse_request(1, <<6, 0, 1, 0, 102>>, map) == {:ok, {1, {6, :w, :reg}, 1, 102}}

    assert Codec.parse_request(1, <<15, 0, 0, 0, 3, 1, 5>>, map) ==
             {:ok, {1, {15, :w, :bit}, 0, [1, 0, 1]}}

    assert Codec.parse_request(1, <<16, 0, 1, 0, 2, 4, 0, 102, 0, 103>>, map) ==
             {:ok, {1, {16, :w, :reg}, 1, [102, 103]}}

    assert Codec.parse_request(1, <<0x64, 0, 1, 0, 2>>, map) == {:ok, {1, {0x64, :r, :reg}, 1, 2}}
  end

  test "custom write function code parses both single and multi write formats" do
    map = FcMap.merge(%{0x65 => {:w, :reg, :hr, :multi}, 0x66 => {:w, :reg, :hr, :single}})

    # 0x65 is declared as :multi, but can also parse single write PDU
    assert Codec.parse_request(1, <<0x65, 0, 1, 0, 102>>, map) ==
             {:ok, {1, {0x65, :w, :reg}, 1, 102}}

    # 0x65 parses multi write PDU
    assert Codec.parse_request(1, <<0x65, 0, 1, 0, 2, 4, 0, 102, 0, 103>>, map) ==
             {:ok, {1, {0x65, :w, :reg}, 1, [102, 103]}}

    # 0x66 is declared as :single, but can also parse multi write PDU
    assert Codec.parse_request(1, <<0x66, 0, 1, 0, 2, 4, 0, 102, 0, 103>>, map) ==
             {:ok, {1, {0x66, :w, :reg}, 1, [102, 103]}}

    # 0x66 parses single write PDU
    assert Codec.parse_request(1, <<0x66, 0, 1, 0, 102>>, map) ==
             {:ok, {1, {0x66, :w, :reg}, 1, 102}}
  end

  test "rejects malformed requests" do
    map = FcMap.default()
    assert Codec.parse_request(1, <<9, 0, 1, 0, 2>>, map) == {:error, :efun}
    assert Codec.parse_request(1, <<0, 0, 1, 0, 2>>, map) == {:error, :efun}
    assert Codec.parse_request(1, <<200, 0, 1, 0, 2>>, map) == {:error, :efun}
    assert Codec.parse_request(1, <<3, 0, 1, 0, 0>>, map) == {:error, :einval}
    assert Codec.parse_request(1, <<15, 0, 0, 0, 3, 2, 1>>, map) == {:error, :einval}
    assert Codec.parse_request(1, <<3, 0, 1, 0>>, map) == {:error, :einval}
  end

  test "rejects out-of-range slave ids" do
    assert_raise ArgumentError, fn -> Codec.pack_request({256, {3, :r, :reg}, 0, 1}) end
    assert_raise ArgumentError, fn -> Codec.pack_request({-1, {3, :r, :reg}, 0, 1}) end
  end
end
