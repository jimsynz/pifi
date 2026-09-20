defmodule PiFi.Plex.Companion.GdmTest do
  use PiFi.DataCase, async: false

  alias PiFi.Device.Identity
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Companion.Gdm
  alias PiFi.Plex.Server

  # **This opens the real port.** A controller reads the source port of the answer, and
  # that rule is the whole point of the module, so a test that called a function would
  # measure nothing. One socket of the test sends the search and reads the reply.
  setup do
    start_supervised!(Gdm)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(socket) end)

    {:ok, socket: socket}
  end

  defp search(socket, line \\ "M-SEARCH * HTTP/1.0\r\n\r\n") do
    :ok = :gen_udp.send(socket, {127, 0, 0, 1}, Gdm.search_port(), line)

    :gen_udp.recv(socket, 0, 2000)
  end

  defp headers(answer) do
    answer
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn line ->
      [name, value] = String.split(line, ": ", parts: 2)
      {name, value}
    end)
  end

  describe "a controller that searches the local network" do
    test "the answer leaves from the port that the search went to", %{socket: socket} do
      assert {:ok, {_address, port, _answer}} = search(socket)
      assert port == Gdm.search_port()
    end

    test "it names what a controller needs to draw a player", %{socket: socket} do
      {:ok, {_address, _port, answer}} = search(socket)

      assert answer =~ "HTTP/1.0 200 OK\r\n"

      headers = headers(answer)

      assert headers["Content-Type"] == "plex/media-player"
      assert headers["Port"] == to_string(Companion.port())
      assert headers["Product"] == Server.product()
      assert headers["Protocol"] == Companion.protocol()
      assert headers["Protocol-Version"] == Companion.protocol_version()
      assert headers["Device-Class"] == Companion.device_class()
      assert headers["Resource-Identifier"] == Server.client_id()
      assert headers["Version"] == Server.version()
      assert headers["Updated-At"] =~ ~r/^\d+$/
    end

    # **The two ways of finding this player must agree.** A controller that met it over
    # UDP and one that read `/resources` would otherwise draw a different set of
    # controls for one device.
    test "it names the capabilities that the router names", %{socket: socket} do
      {:ok, {_address, _port, answer}} = search(socket)

      assert headers(answer)["Protocol-Capabilities"] == Companion.capabilities()
    end

    test "the name is the one that a person gave the device", %{socket: socket} do
      Identity.put_name("Kitchen")
      on_exit(fn -> Identity.put_name("") end)

      {:ok, {_address, _port, answer}} = search(socket)

      assert headers(answer)["Name"] == "Kitchen"
    end

    # Anything else on this port belongs to another program, and a player that answered
    # it would be talking to something that never asked.
    test "a datagram that is no search gets no answer", %{socket: socket} do
      assert {:error, :timeout} = search(socket, "HELLO * HTTP/1.0\r\n\r\n")
    end
  end
end
