defmodule Modbuv.Model do
  @moduledoc """
  Pure functions over the Server/Slave DB:
  `%{slave_id => %{{region, address} => value}}`.
  """

  @type region :: :c | :i | :hr | :ir

  @spec apply(map(), tuple(), region()) :: {term(), map()}
  def apply(model, {slave, {_fc, :r, _width}, address, count}, region) do
    reads(model, {slave, region, address, count})
  end

  def apply(model, {slave, {_fc, :w, _width}, address, value}, region)
      when is_integer(value) do
    write(model, {slave, region, address, value})
  end

  def apply(model, {slave, {_fc, :w, _width}, address, values}, region)
      when is_list(values) do
    writes(model, {slave, region, address, values})
  end

  def apply(model, _frame, _region), do: {nil, model}

  defp reads(model, {slave, region, address, count}) do
    if Map.has_key?(model, slave) do
      try do
        map = Map.fetch!(model, slave)

        values =
          for index <- 0..(count - 1)//1 do
            Map.fetch!(map, {region, address + index})
          end

        {{:ok, values}, model}
      rescue
        _ -> {{:error, :eaddr}, model}
      end
    else
      {nil, model}
    end
  end

  defp write(model, {slave, region, address, value}) do
    if Map.has_key?(model, slave) do
      try do
        map = Map.fetch!(model, slave)
        new_map = Map.replace!(map, {region, address}, value)
        {{:ok, nil}, Map.put(model, slave, new_map)}
      rescue
        _ -> {{:error, :eaddr}, model}
      end
    else
      {nil, model}
    end
  end

  defp writes(model, {slave, region, address, values}) do
    if Map.has_key?(model, slave) do
      try do
        map = Map.fetch!(model, slave)

        new_map =
          values
          |> Enum.with_index(address)
          |> Enum.reduce(map, fn {value, addr}, acc ->
            Map.replace!(acc, {region, addr}, value)
          end)

        {{:ok, nil}, Map.put(model, slave, new_map)}
      rescue
        _ -> {{:error, :eaddr}, model}
      end
    else
      {nil, model}
    end
  end
end
