defmodule PiFi.AirPlay.ConnectionTest do
  use ExUnit.Case, async: true

  alias PiFi.AirPlay.BinaryPlist
  alias PiFi.AirPlay.Device
  alias PiFi.AirPlay.Identity
  alias PiFi.AirPlay.SecureChannel
  alias PiFi.Test.AirPlayPhone, as: Phone

  setup do
    dir = Path.join(System.tmp_dir!(), "airplay-conn-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    key = Identity.public_key(dir)

    device = %{
      device_id: Device.device_id(key),
      model: "PiFi1,1",
      name: "Kitchen",
      pi: Device.uuid(key, "pi"),
      psi: Device.uuid(key, "psi"),
      public_key: key,
      version: "1.4.0"
    }

    {:ok, server} =
      ThousandIsland.start_link(
        port: 0,
        handler_module: PiFi.AirPlay.Connection,
        handler_options: %{device: device, data_dir: dir}
      )

    # The listener is linked to this test, so it goes when the test does.
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{port: port, device: device}
  end

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2000)

    socket
  end

  # **What is left over is handed back and not dropped.** Two replies arrive in one
  # segment as readily as two, so a reader that threw away the tail of a read would find
  # the socket empty when it asked for the second one and sit there until it timed out.
  defp read_reply(socket, leftover \\ "") do
    head = read_until(socket, leftover, "\r\n\r\n")
    [headers, rest] = String.split(head, "\r\n\r\n", parts: 2)

    length =
      case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
        [_whole, found] -> String.to_integer(found)
        nil -> 0
      end

    whole = rest <> read_exactly(socket, length - byte_size(rest))

    {headers, binary_part(whole, 0, length),
     binary_part(whole, length, byte_size(whole) - length)}
  end

  defp read_until(socket, so_far, marker) do
    if String.contains?(so_far, marker) do
      so_far
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 2000)

      read_until(socket, so_far <> more, marker)
    end
  end

  defp read_exactly(_socket, count) when count <= 0, do: ""

  defp read_exactly(socket, count) do
    {:ok, bytes} = :gen_tcp.recv(socket, count, 2000)

    bytes
  end

  defp post(uri, body, cseq) do
    "POST #{uri} RTSP/1.0\r\ncseq: #{cseq}\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
  end

  defp get_info(cseq) do
    "GET /info RTSP/1.0\r\ncseq: #{cseq}\r\ncontent-length: 0\r\n\r\n"
  end

  test "answers a request that arrives whole", %{port: port} do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, get_info(1))

    {headers, body, _rest} = read_reply(socket)

    assert headers =~ "200 OK"
    assert headers =~ "cseq: 1"
    assert {:ok, plist} = BinaryPlist.decode(body)
    assert plist["name"] == "Kitchen"
  end

  # TCP gives no message boundaries, and a four hundred byte pair-setup arrives in two
  # segments as often as one. A handler that parsed once per read would stall here.
  test "answers a request that arrives in pieces", %{port: port} do
    socket = connect(port)
    request = get_info(2)

    for <<byte::binary-size(1) <- request>> do
      :ok = :gen_tcp.send(socket, byte)
    end

    {headers, body, _rest} = read_reply(socket)

    assert headers =~ "200 OK"
    assert headers =~ "cseq: 2"
    assert {:ok, _plist} = BinaryPlist.decode(body)
  end

  # The other half of the same problem: two requests in one segment. A handler that
  # parsed once per read would answer the first and lose the second.
  test "answers both requests when two arrive together", %{port: port} do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, get_info(3) <> get_info(4))

    {first, _body, leftover} = read_reply(socket)
    {second, _body, _rest} = read_reply(socket, leftover)

    assert first =~ "cseq: 3"
    assert second =~ "cseq: 4"
  end

  test "answers request after request on one connection", %{port: port} do
    socket = connect(port)

    for cseq <- 1..5 do
      :ok = :gen_tcp.send(socket, get_info(cseq))
      {headers, _body, _rest} = read_reply(socket)

      assert headers =~ "cseq: #{cseq}"
    end
  end

  test "the senderAddress is the address that connected", %{port: port} do
    socket = connect(port)
    {:ok, {_address, client_port}} = :inet.sockname(socket)

    :ok = :gen_tcp.send(socket, get_info(1))
    {_headers, body, _rest} = read_reply(socket)

    assert {:ok, plist} = BinaryPlist.decode(body)
    assert plist["senderAddress"] == "127.0.0.1:#{client_port}"
  end

  # A buffer that will not parse will not parse any better with more bytes after it, and
  # holding the socket open would leave a telephone waiting.
  test "closes a connection that sends something that is not a request", %{port: port} do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, "\0\0\0 this is not RTSP \r\n\r\n")

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
  end

  describe "once a pairing is done" do
    defp pair(socket) do
      :ok = :gen_tcp.send(socket, post("/pair-setup", Phone.m1(transient?: true), 1))
      {_headers, m2, ""} = read_reply(socket)

      {m3, phone} = Phone.m3(m2)

      :ok = :gen_tcp.send(socket, post("/pair-setup", m3, 2))
      {headers, _m4, leftover} = read_reply(socket)

      {headers, leftover, Phone.channel(phone.session_key)}
    end

    # **The answer that finishes a pairing is the last thing in the clear.** A receiver
    # that switched over one message early would send a reply the telephone could not
    # read, at the one moment it had no way to say so.
    test "the message that finishes it is still plaintext", %{port: port} do
      socket = connect(port)
      {headers, leftover, _channel} = pair(socket)

      assert headers =~ "200 OK"
      assert leftover == ""
    end

    test "the next request has to be encrypted, and its answer comes back encrypted",
         %{port: port} do
      socket = connect(port)
      {_headers, _leftover, channel} = pair(socket)

      {sealed, channel} = SecureChannel.seal(channel, get_info(3))
      :ok = :gen_tcp.send(socket, sealed)

      {:ok, arrived} = :gen_tcp.recv(socket, 0, 2000)

      assert {:ok, plain, "", _channel} = SecureChannel.open(channel, arrived)
      assert plain =~ "cseq: 3"

      [_head, body] = String.split(plain, "\r\n\r\n", parts: 2)

      assert {:ok, plist} = BinaryPlist.decode(body)
      assert plist["name"] == "Kitchen"
    end

    # This is the one that catches the keys being the same way round at both ends.
    test "a request encrypted with the keys the wrong way round closes the connection",
         %{port: port} do
      socket = connect(port)
      {_headers, _leftover, channel} = pair(socket)

      # Swapping read for write is what an accessory naming its keys from the
      # controller's point of view would agree with, and nothing else would.
      swapped = %{channel | read_key: channel.write_key, write_key: channel.read_key}
      {sealed, _swapped} = SecureChannel.seal(swapped, get_info(3))

      :ok = :gen_tcp.send(socket, sealed)

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
    end

    test "plaintext after a pairing closes the connection", %{port: port} do
      socket = connect(port)
      {_headers, _leftover, _channel} = pair(socket)

      :ok = :gen_tcp.send(socket, get_info(3))

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2000)
    end

    test "request after request stays in step", %{port: port} do
      socket = connect(port)
      {_headers, _leftover, channel} = pair(socket)

      Enum.reduce(3..7, channel, fn cseq, channel ->
        {sealed, channel} = SecureChannel.seal(channel, get_info(cseq))
        :ok = :gen_tcp.send(socket, sealed)

        {:ok, arrived} = :gen_tcp.recv(socket, 0, 2000)

        assert {:ok, plain, "", channel} = SecureChannel.open(channel, arrived)
        assert plain =~ "cseq: #{cseq}"

        channel
      end)
    end
  end

  test "one connection's state does not reach another", %{port: port} do
    one = connect(port)
    other = connect(port)

    :ok = :gen_tcp.send(one, get_info(1))
    :ok = :gen_tcp.send(other, get_info(99))

    {one_headers, _body, _rest} = read_reply(one)
    {other_headers, _body, _other_rest} = read_reply(other)

    assert one_headers =~ "cseq: 1"
    assert other_headers =~ "cseq: 99"
  end
end
