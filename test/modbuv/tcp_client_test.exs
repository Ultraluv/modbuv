defmodule Modbuv.TcpClientTest do
  use ExUnit.Case, async: false
  alias Modbuv.Tcp
  alias Modbuv.Tcp.{Client, Server}

  @model %{1 => %{{:hr, 0} => 10, {:hr, 1} => 11}}

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

  test "passive read, write, and exception" do
    {_s, port} = server()
    c = client(port)
    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})
    assert {:ok, [10, 11]} = Client.confirmation(c)
    assert :ok = Client.request(c, {1, {6, :w, :reg}, 0, 99})
    assert :ok = Client.confirmation(c)
    assert :ok = Client.request(c, {1, {3, :r, :reg}, 9, 1})
    assert {:error, :eaddr} = Client.confirmation(c)
  end

  test "active read notification" do
    {_s, port} = server()
    c = client(port, active: true, d_pid: self())
    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 1})
    assert_receive {:modbuv_tcp, {1, {3, :r, :reg}, 0, 1}, [10]}, 1_000
    assert :error = Client.confirmation(c)
  end

  test "closed client returns closed" do
    {_s, port} = server()
    c = client(port)
    assert :ok = Client.close(c)
    assert {:error, :closed} = Client.request(c, {1, {3, :r, :reg}, 0, 1})
  end

  test "configure and flush contracts" do
    {_s, port} = server()
    c = client(port)
    assert :error = Client.configure(c, ip: {127, 0, 0, 1})
    assert {:ok, %{}} = Client.flush(c)
    assert :ok = Client.close(c)
    assert :ok = Client.configure(c, ip: {127, 0, 0, 1}, tcp_port: port)
  end

  test "active client reassembles a response split across packets" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    {:ok, c} =
      Client.start_link(
        ip: {127, 0, 0, 1},
        tcp_port: port,
        timeout: 1_000,
        active: true,
        d_pid: self()
      )

    :ok = Client.connect(c)
    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 2})
    {:ok, sock} = :gen_tcp.accept(listen)
    {:ok, _req} = :gen_tcp.recv(sock, 0, 1_000)
    adu = Tcp.pack_res({1, {3, :r, :reg}, 0, 2}, [10, 11], 0)
    <<a::binary-size(4), b::binary>> = adu
    :ok = :gen_tcp.send(sock, a)
    Process.sleep(20)
    :ok = :gen_tcp.send(sock, b)
    assert_receive {:modbuv_tcp, {1, {3, :r, :reg}, 0, 2}, [10, 11]}, 1_000
    :gen_tcp.close(sock)
    :gen_tcp.close(listen)
  end

  test "passive timeout closes the client and does not reuse a stale response" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    {:ok, c} = Client.start_link(ip: {127, 0, 0, 1}, tcp_port: port, timeout: 100)
    :ok = Client.connect(c)
    {:ok, sock} = :gen_tcp.accept(listen)

    assert :ok = Client.request(c, {1, {3, :r, :reg}, 0, 1})
    assert {:error, :timeout} = Client.confirmation(c)

    _ = :gen_tcp.send(sock, Tcp.pack_res({1, {3, :r, :reg}, 0, 1}, [111], 0))
    assert {:error, :closed} = Client.request(c, {1, {3, :r, :reg}, 5, 1})

    :gen_tcp.close(sock)
    :gen_tcp.close(listen)
  end
end
