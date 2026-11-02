defmodule Modbuv.TcpServerTest do
  use ExUnit.Case, async: false
  alias Modbuv.Tcp
  alias Modbuv.Tcp.Server

  @model %{1 => %{{:hr, 0} => 10, {:hr, 1} => 11, {:hr, 2} => 12}}

  defp start_server(extra \\ []) do
    params = Keyword.merge([port: 0, model: @model, timeout: 1_000], extra)
    {:ok, pid} = Server.start_link(params)
    {:ok, pid, :sys.get_state(pid).port}
  end

  defp recv_adu(sock, timeout \\ 1_000) do
    {:ok, header} = :gen_tcp.recv(sock, 6, timeout)
    <<_transid::16, _protocol::16, length::16>> = header
    {:ok, payload} = :gen_tcp.recv(sock, length, timeout)
    header <> payload
  end

  defp raw_request(port, frame, transid) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(sock, Tcp.pack_req(frame, transid))
    {:ok, resp} = :gen_tcp.recv(sock, 0, 1_000)
    :gen_tcp.close(sock)
    resp
  end

  test "serves a read and an exception" do
    {:ok, _pid, port} = start_server()
    resp = raw_request(port, {1, {3, :r, :reg}, 0, 2}, 1)
    assert Tcp.parse_res({1, {3, :r, :reg}, 0, 2}, resp) == [10, 11]

    resp = raw_request(port, {1, {3, :r, :reg}, 9, 2}, 2)
    assert Tcp.parse_res({1, {3, :r, :reg}, 9, 2}, resp) == {:error, :eaddr}
  end

  test "update and get_db" do
    {:ok, pid, _port} = start_server()
    assert Server.update(pid, {1, {6, :w, :reg}, 0, 99}) == nil
    assert Server.get_db(pid)[1][{:hr, 0}] == 99
    assert Server.update(pid, {1, {3, :r, :reg}, 0, 1}) == [99]
    assert {:error, :efun} = Server.update(pid, {1, {9, :r, :reg}, 0, 1})
  end

  test "ignores other unit ids and notifies the owner" do
    {:ok, _pid, port} = start_server(active: true)
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(sock, Tcp.pack_req({2, {3, :r, :reg}, 0, 1}, 1))
    assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 200)
    :gen_tcp.close(sock)

    resp = raw_request(port, {1, {3, :r, :reg}, 0, 1}, 2)
    assert Tcp.parse_res({1, {3, :r, :reg}, 0, 1}, resp) == [10]
    assert_receive {:modbuv_tcp, {:server_request, {1, {3, :r, :reg}, 0, 1}}}, 1_000
  end

  test "handles split and coalesced ADUs" do
    {:ok, _pid, port} = start_server()
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    adu = Tcp.pack_req({1, {3, :r, :reg}, 0, 1}, 1)
    <<a::binary-size(5), b::binary>> = adu
    :ok = :gen_tcp.send(sock, a)
    :ok = :gen_tcp.send(sock, b)
    resp = recv_adu(sock)
    assert Tcp.parse_res({1, {3, :r, :reg}, 0, 1}, resp) == [10]

    two = Tcp.pack_req({1, {3, :r, :reg}, 0, 1}, 2) <> Tcp.pack_req({1, {3, :r, :reg}, 1, 1}, 3)
    :ok = :gen_tcp.send(sock, two)
    r1 = recv_adu(sock)
    r2 = recv_adu(sock)
    assert Tcp.parse_res({1, {3, :r, :reg}, 0, 1}, r1) == [10]
    assert Tcp.parse_res({1, {3, :r, :reg}, 1, 1}, r2) == [11]
    :gen_tcp.close(sock)
  end

  test "update raises in the caller and leaves the server alive" do
    {:ok, pid, _port} = start_server()
    assert_raise ArgumentError, fn -> Server.update(pid, {1, {3, :w, :reg}, 0, 1}) end
    assert Process.alive?(pid)
  end

  test "stop tears down the model agent" do
    {:ok, pid, _port} = start_server()
    model_pid = :sys.get_state(pid).model_pid
    ref = Process.monitor(model_pid)
    assert :ok = Server.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^model_pid, _reason}, 500
  end

  test "port collision stops cleanly with error" do
    old_trap = Process.flag(:trap_exit, true)

    try do
      {:ok, pid, port} = start_server()
      assert {:error, :eaddrinuse} = Server.start_link(port: port, model: @model)
      :ok = Server.stop(pid)
    after
      Process.flag(:trap_exit, old_trap)
    end
  end
end
