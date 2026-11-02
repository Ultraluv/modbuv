defmodule Modbuv.IEEE754Test do
  use ExUnit.Case, async: true
  alias Modbuv.IEEE754

  test "two registers" do
    assert IEEE754.from_2_regs(0x40A0, 0x0000, :be) == 5.0
    assert IEEE754.from_2_regs([0x40A0, 0x0000], :be) == 5.0
    assert IEEE754.from_2_regs(0x0000, 0x40A0, :le) == 5.0
    assert IEEE754.to_2_regs(-5.0, :be) == [0xC0A0, 0x0000]
    assert IEEE754.to_2_regs(-5.0, :le) == [0x0000, 0xC0A0]
  end

  test "many registers" do
    assert IEEE754.from_2n_regs([0xC0A0, 0x0000, 0x40A0, 0x0000], :be) == [-5.0, 5.0]
    assert IEEE754.to_2n_regs([-5.0, 5.0], :be) == [0xC0A0, 0x0000, 0x40A0, 0x0000]
    assert IEEE754.from_2n_regs([], :be) == []
    assert IEEE754.to_2n_regs([], :be) == []
  end
end
