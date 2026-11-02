defmodule Modbuv.ModelTest do
  use ExUnit.Case, async: true
  alias Modbuv.Model
  alias Modbuv.Model.Shared

  @model %{
    1 => %{
      {:c, 0} => 1,
      {:c, 1} => 0,
      {:c, 2} => 1,
      {:i, 0} => 1,
      {:hr, 0} => 10,
      {:hr, 1} => 11,
      {:ir, 0} => 20
    }
  }

  test "reads" do
    assert {{:ok, [10, 11]}, _} = Model.apply(@model, {1, {3, :r, :reg}, 0, 2}, :hr)
    assert {{:ok, [1, 0, 1]}, _} = Model.apply(@model, {1, {1, :r, :bit}, 0, 3}, :c)
    assert {{:error, :eaddr}, _} = Model.apply(@model, {1, {3, :r, :reg}, 1, 5}, :hr)
    assert {nil, _} = Model.apply(@model, {2, {3, :r, :reg}, 0, 1}, :hr)
  end

  test "writes" do
    assert {{:ok, nil}, m} = Model.apply(@model, {1, {6, :w, :reg}, 1, 99}, :hr)
    assert m[1][{:hr, 1}] == 99
    assert {{:error, :eaddr}, _} = Model.apply(@model, {1, {6, :w, :reg}, 9, 99}, :hr)
    assert {{:ok, nil}, m2} = Model.apply(@model, {1, {16, :w, :reg}, 0, [7, 8]}, :hr)
    assert m2[1][{:hr, 0}] == 7
    assert m2[1][{:hr, 1}] == 8
  end

  test "multi write is atomic" do
    assert {{:error, :eaddr}, m} = Model.apply(@model, {1, {16, :w, :reg}, 1, [7, 8, 9]}, :hr)
    assert m == @model
  end

  test "shared agent" do
    {:ok, pid} = Shared.start_link(@model)
    assert {:ok, [10, 11]} = Shared.apply(pid, {1, {3, :r, :reg}, 0, 2}, :hr)
    assert Shared.state(pid)[1][{:hr, 0}] == 10
    assert :ok = Shared.stop(pid)
  end
end
