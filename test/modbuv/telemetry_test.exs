defmodule Modbuv.TelemetryTest.FakeUART do
  use GenServer

  def start_link(response), do: GenServer.start_link(__MODULE__, response)

  @impl true
  def init(response), do: {:ok, %{response: response}}

  @impl true
  def handle_call({:flush, _direction}, _from, state), do: {:reply, :ok, state}

  def handle_call({:write, _data, _timeout}, _from, state), do: {:reply, :ok, state}

  def handle_call({:read, _timeout}, _from, %{response: response} = state) do
    reply = if response == nil, do: {:ok, ""}, else: {:ok, response}
    {:reply, reply, %{state | response: nil}}
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, state}
  def handle_call(_message, _from, state), do: {:reply, :ok, state}
end

defmodule Modbuv.TelemetryTest do
  use ExUnit.Case, async: false

  alias Modbuv.Rtu
  alias Modbuv.Rtu.Master
  alias Modbuv.Tcp.{Client, Server}

  @model %{1 => %{{:hr, 0} => 10, {:hr, 1} => 11}}

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp attach(events) do
    id = "modbuv-telemetry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp server do
    {:ok, pid} = Server.start_link(port: 0, model: @model)
    {pid, :sys.get_state(pid).port}
  end

  defp client(port, extra \\ []) do
    params =
      Keyword.merge(
        [ip: {127, 0, 0, 1}, tcp_port: port, timeout: 1_000, active: false],
        extra
      )

    {:ok, pid} = Client.start_link(params)
    :ok = Client.connect(pid)
    pid
  end

  test "TCP client passive request emits start and stop with RTT" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    {server, port} = server()
    c = client(port)

    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})

    assert_receive {:telemetry, [:modbuv, :request, :start], start_measurements, start_metadata}

    assert is_integer(start_measurements.system_time)

    assert start_metadata == %{
             transport: :tcp,
             role: :client,
             mode: :passive,
             slave: 1,
             fc: 3
           }

    assert {:ok, [10, 11]} = Client.confirmation(c)

    assert_receive {:telemetry, [:modbuv, :request, :stop], stop_measurements, stop_metadata}

    assert is_integer(stop_measurements.duration)
    assert stop_measurements.duration >= 0
    assert is_integer(stop_measurements.monotonic_time)

    assert stop_metadata == %{
             transport: :tcp,
             role: :client,
             mode: :passive,
             slave: 1,
             fc: 3,
             result: :ok,
             reason: nil
           }

    :ok = Client.stop(c)
    :ok = Server.stop(server)
  end

  test "TCP client passive timeout emits stop with an error result" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    {:ok, c} = Client.start_link(ip: {127, 0, 0, 1}, tcp_port: port, timeout: 100)
    :ok = Client.connect(c)
    {:ok, sock} = :gen_tcp.accept(listen)

    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 1})
    assert_receive {:telemetry, [:modbuv, :request, :start], _, _}

    assert {:error, :timeout} = Client.confirmation(c)

    assert_receive {:telemetry, [:modbuv, :request, :stop], measurements, metadata}, 500
    assert measurements.duration >= 0
    assert metadata.result == :error
    assert metadata.reason == :timeout

    :gen_tcp.close(sock)
    :gen_tcp.close(listen)
    Client.stop(c)
  end

  test "TCP client active response emits start and stop" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    {server, port} = server()
    c = client(port, active: true, d_pid: self())

    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 1})

    assert_receive {:telemetry, [:modbuv, :request, :start], _, start_metadata}
    assert start_metadata == %{transport: :tcp, role: :client, mode: :active, slave: 1, fc: 3}

    assert_receive {:modbuv_tcp, {1, {3, :r, :reg}, 0, 1}, [10]}, 1_000

    assert_receive {:telemetry, [:modbuv, :request, :stop], measurements, stop_metadata},
                   1_000

    assert measurements.duration >= 0

    assert stop_metadata == %{
             transport: :tcp,
             role: :client,
             mode: :active,
             slave: 1,
             fc: 3,
             result: :ok,
             reason: nil
           }

    Client.stop(c)
    Server.stop(server)
  end

  test "RTU master request failure emits start and stop" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    {:ok, master} = Master.start_link(tty: "/dev/null", timeout: 50)
    :sys.replace_state(master, fn state -> %{state | status: :open} end)

    assert {:error, reason} = Master.request(master, {1, {3, :r, :reg}, 0, 1})

    assert_receive {:telemetry, [:modbuv, :request, :start], _, start_metadata}
    assert start_metadata == %{transport: :rtu, role: :master, mode: :passive, slave: 1, fc: 3}

    assert_receive {:telemetry, [:modbuv, :request, :stop], measurements, stop_metadata}

    assert measurements.duration >= 0

    assert stop_metadata == %{
             transport: :rtu,
             role: :master,
             mode: :passive,
             slave: 1,
             fc: 3,
             result: :error,
             reason: reason
           }

    Master.stop(master)
  end

  test "RTU master passive success emits stop with :ok" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    frame = {1, {3, :r, :reg}, 0, 2}
    response = Rtu.pack_res(frame, [10, 11])

    {:ok, master} = Master.start_link(tty: "/dev/null", timeout: 100)
    original_uart = :sys.get_state(master).uart_pid
    {:ok, fake} = Modbuv.TelemetryTest.FakeUART.start_link(response)
    :sys.replace_state(master, fn state -> %{state | uart_pid: fake, status: :open} end)
    Circuits.UART.stop(original_uart)

    assert {:ok, [10, 11]} = Master.request(master, frame)

    assert_receive {:telemetry, [:modbuv, :request, :start], _, start_metadata}
    assert start_metadata == %{transport: :rtu, role: :master, mode: :passive, slave: 1, fc: 3}

    assert_receive {:telemetry, [:modbuv, :request, :stop], measurements, stop_metadata}

    assert measurements.duration >= 0

    assert stop_metadata == %{
             transport: :rtu,
             role: :master,
             mode: :passive,
             slave: 1,
             fc: 3,
             result: :ok,
             reason: nil
           }

    Master.stop(master)
  end

  test "RTU master active response emits start and stop" do
    attach([[:modbuv, :request, :start], [:modbuv, :request, :stop]])
    frame = {1, {3, :r, :reg}, 0, 2}
    response = Rtu.pack_res(frame, [10, 11])

    {:ok, master} = Master.start_link(tty: "/dev/null", timeout: 100, active: true)
    original_uart = :sys.get_state(master).uart_pid
    {:ok, fake} = Modbuv.TelemetryTest.FakeUART.start_link(response)
    :sys.replace_state(master, fn state -> %{state | uart_pid: fake, status: :open} end)
    Circuits.UART.stop(original_uart)

    assert :ok = Master.request(master, frame)

    assert_receive {:telemetry, [:modbuv, :request, :start], _, start_metadata}
    assert start_metadata == %{transport: :rtu, role: :master, mode: :active, slave: 1, fc: 3}

    assert_receive {:modbuv_rtu, {:slave_response, ^frame, [10, 11]}}, 1_000

    assert_receive {:telemetry, [:modbuv, :request, :stop], measurements, stop_metadata},
                   1_000

    assert measurements.duration >= 0

    assert stop_metadata == %{
             transport: :rtu,
             role: :master,
             mode: :active,
             slave: 1,
             fc: 3,
             result: :ok,
             reason: nil
           }

    Master.stop(master)
  end
end
