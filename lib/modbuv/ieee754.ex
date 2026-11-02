defmodule Modbuv.IEEE754 do
  @moduledoc """
  IEEE754 float helper. `:be` keeps the first register as the high word;
  `:le` swaps the two words.
  """

  @spec from_2_regs(integer(), integer(), :be | :le) :: float()
  def from_2_regs(w0, w1, :be) do
    <<value::float-32>> = <<w0::16, w1::16>>
    value
  end

  def from_2_regs(w0, w1, :le) do
    <<value::float-32>> = <<w1::16, w0::16>>
    value
  end

  @spec from_2_regs([integer()], :be | :le) :: float()
  def from_2_regs([w0, w1], :be) do
    <<value::float-32>> = <<w0::16, w1::16>>
    value
  end

  def from_2_regs([w0, w1], :le) do
    <<value::float-32>> = <<w1::16, w0::16>>
    value
  end

  @spec from_2n_regs([integer()], :be | :le) :: [float()]
  def from_2n_regs([], _endianness), do: []

  def from_2n_regs([w0, w1 | tail], endianness) do
    [from_2_regs(w0, w1, endianness) | from_2n_regs(tail, endianness)]
  end

  @spec to_2_regs(float(), :be | :le) :: [integer()]
  def to_2_regs(value, :be) do
    <<w0::16, w1::16>> = <<value::float-32>>
    [w0, w1]
  end

  def to_2_regs(value, :le) do
    <<w0::16, w1::16>> = <<value::float-32>>
    [w1, w0]
  end

  @spec to_2n_regs([float()], :be | :le) :: [integer()]
  def to_2n_regs([], _endianness), do: []

  def to_2n_regs([value | tail], endianness) do
    [w0, w1] = to_2_regs(value, endianness)
    [w0, w1 | to_2n_regs(tail, endianness)]
  end
end
