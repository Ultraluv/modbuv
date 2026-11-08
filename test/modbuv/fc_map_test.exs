defmodule Modbuv.FcMapTest do
  use ExUnit.Case, async: true
  alias Modbuv.FcMap

  test "default table" do
    assert FcMap.lookup(FcMap.default(), 3) == {:ok, {:r, :reg, :hr}}
    assert FcMap.lookup(FcMap.default(), 5) == {:ok, {:w, :bit, :c, :single}}
    assert FcMap.lookup(FcMap.default(), 16) == {:ok, {:w, :reg, :hr, :multi}}
    assert FcMap.lookup(FcMap.default(), 0x64) == :error
  end

  test "merge adds and overrides" do
    map = FcMap.merge(%{3 => {:r, :bit, :c}, 0x64 => {:r, :reg, :hr}})
    assert FcMap.lookup(map, 3) == {:ok, {:r, :bit, :c}}
    assert FcMap.lookup(map, 0x64) == {:ok, {:r, :reg, :hr}}
    assert FcMap.lookup(map, 16) == {:ok, {:w, :reg, :hr, :multi}}
  end

  test "merge/2 incrementally merges on top of base map without dropping previous overrides" do
    base = FcMap.merge(%{65 => {:r, :reg, :hr}})
    assert FcMap.lookup(base, 65) == {:ok, {:r, :reg, :hr}}

    updated = FcMap.merge(base, %{66 => {:w, :reg, :hr, :single}})
    assert FcMap.lookup(updated, 65) == {:ok, {:r, :reg, :hr}}
    assert FcMap.lookup(updated, 66) == {:ok, {:w, :reg, :hr, :single}}
    assert FcMap.lookup(updated, 3) == {:ok, {:r, :reg, :hr}}
  end

  test "invalid keys and shapes raise" do
    assert_raise ArgumentError, fn -> FcMap.merge(%{0 => {:r, :bit, :c}}) end
    assert_raise ArgumentError, fn -> FcMap.merge(%{128 => {:r, :bit, :c}}) end
    assert_raise ArgumentError, fn -> FcMap.merge(%{1 => {:r, :bit}}) end
    assert_raise ArgumentError, fn -> FcMap.merge(%{1 => {:w, :bit, :c}}) end
  end
end
