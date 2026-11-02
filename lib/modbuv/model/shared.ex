defmodule Modbuv.Model.Shared do
  @moduledoc """
  Agent that holds the Server/Slave DB.
  """

  alias Modbuv.Model

  @spec start_link(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(model, opts \\ []) do
    Agent.start_link(fn -> model end, opts)
  end

  @spec state(pid()) :: map()
  def state(pid), do: Agent.get(pid, & &1)

  @spec apply(pid(), tuple(), Model.region()) :: term()
  def apply(pid, frame, region) do
    Agent.get_and_update(pid, fn model -> Model.apply(model, frame, region) end)
  end

  @spec stop(pid()) :: :ok
  def stop(pid), do: Agent.stop(pid)
end
