defmodule PiFi.Plex.Companion.Gdm do
  @moduledoc """
  Answers the controllers that look for a player on the local network.

  Plex calls this GDM. A controller sends `M-SEARCH * HTTP/1.0` as a UDP datagram to
  port 32412, and every player on the network answers with a block of headers that says
  what it is and where to reach it. A player also sends a `HELLO` of its own, so a
  controller that was already listening learns of a device that has just come up.

  **This is the way a desktop controller finds a player, and it needs no account.**
  `PiFi.Plex.Companion.Announcement` is the other way, through plex.tv, and the
  telephone of a person uses that one.

  ## Three rules, and a reading of another project got each one wrong

  - **The answer leaves from port 32412**, and not from an ephemeral port that the
    system chose. A controller reads the source port of the datagram, so an answer from
    anywhere else is an answer that it drops. One socket therefore listens and replies.
  - **The `HELLO` goes to the multicast group**, 239.0.0.250 on port 32413, and not to
    the broadcast address of the network.
  - **The listening socket joins that group.** A controller may send the search to the
    group rather than to the broadcast address, and a socket that never joined it sees
    no such datagram.

  A network with no multicast still works. `add_membership` fails there, so this opens
  the socket again without it and answers the searches that arrive by broadcast. A
  player that answers half of the controllers is better than one that will not start.

  ## It opens the socket again when an address arrives

  **`PiFi.Application` starts the player at the boot, and Wi-Fi is not up then.**
  `add_membership` on a machine with no interface but the loopback fails, the fallback
  above then opens a socket that joined no group, and the responder hears nothing for
  as long as it runs: a controller sends the search to 239.0.0.250 and this player is
  not listening to it. That is the state a cold boot used to leave, and the only way
  out of it was turning the player off and on again once the network was up.

  `PiFi.Event.Device.NetworkChanged` is the one that says an address arrived, so this
  closes the socket and opens it again for each one. An interface that comes back on
  another address rejoins the group for the same reason.

  ## What the headers say

  They are the fields of `/resources` under other names, and
  `PiFi.Plex.Companion` holds the four facts that both carry. See
  `PiFi.Plex.Companion.Router`.

  **None of this is a published specification.** Every line comes from reading what
  other implementations send.
  """

  use GenServer

  require Logger

  alias PiFi.Event
  alias PiFi.Event.Device.NetworkChanged
  alias PiFi.Plex.Companion
  alias PiFi.Plex.Server

  # A controller sends the search here, and a player answers from here.
  @search_port 32_412

  # A player sends its own `HELLO` here, and a controller that listens reads it.
  @hello_port 32_413

  @group {239, 0, 0, 250}

  # A datagram of this protocol never leaves the home network, and this is the number
  # that the implementations I read send.
  @ttl 4

  @doc "The port that a controller sends its search to, and that this answers from."
  @spec search_port() :: pos_integer()
  def search_port, do: @search_port

  @doc "The port that this sends its `HELLO` to."
  @spec hello_port() :: pos_integer()
  def hello_port, do: @hello_port

  @doc """
  The block of headers that this player sends, under a given first line.

  `PiFi.Plex.Companion.Gdm` sends it twice: once as the answer to a search, and once as
  a `HELLO`. The two differ in that line alone, so a controller reads one player
  whichever way it met it.
  """
  @spec message(String.t()) :: binary()
  def message(first_line) do
    [
      first_line,
      "Content-Type: plex/media-player",
      "Name: #{Server.device_name()}",
      "Port: #{Companion.port()}",
      "Product: #{Server.product()}",
      "Protocol: #{Companion.protocol()}",
      "Protocol-Version: #{Companion.protocol_version()}",
      "Protocol-Capabilities: #{Companion.capabilities()}",
      "Device-Class: #{Companion.device_class()}",
      "Resource-Identifier: #{Server.client_id()}",
      "Version: #{Server.version()}",
      "Updated-At: #{System.system_time(:second)}"
    ]
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n\r\n")
  end

  @doc false
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc false
  @impl GenServer
  def init(_options) do
    # **A person who turns the player off must not kill a `HELLO` in the middle of
    # it.** The headers name the device, so building one reads the settings, and a stop
    # that arrived in the middle of that read took the connection of the database with
    # it. A process that traps the exit reads the stop as a message instead, so the
    # `HELLO` finishes and the `BYE` of `terminate/2` follows it. This is the rule that
    # `PiFi.Plex.Companion.Announcement` follows, and for the same reason.
    Process.flag(:trap_exit, true)

    :ok = Event.subscribe(:device)

    case open() do
      {:ok, socket} -> {:ok, socket, {:continue, :hello}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @doc false
  @impl GenServer
  def handle_continue(:hello, socket) do
    send_to(socket, @group, @hello_port, message("HELLO * HTTP/1.0"))

    {:noreply, socket}
  end

  @doc false
  @impl GenServer
  def handle_info({:udp, _socket, address, port, packet}, socket) do
    if search?(packet), do: send_to(socket, address, port, message("HTTP/1.0 200 OK"))

    {:noreply, socket}
  end

  # **A socket that joined no group hears nothing**, and that is what a boot with no
  # network leaves behind. See the module documentation.
  def handle_info(%NetworkChanged{}, socket) do
    :gen_udp.close(socket)

    case open() do
      {:ok, opened} ->
        send_to(opened, @group, @hello_port, message("HELLO * HTTP/1.0"))

        {:noreply, opened}

      # The port is the one thing here that another program can hold, and a player
      # that cannot open it is one that a person turns off and on again. Stopping
      # says so, where carrying on with a closed socket would look like working.
      {:error, reason} ->
        {:stop, reason, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # **A controller that stops asking must not keep the player in its list.** A `BYE`
  # says that this player has gone, and a person who turns the player off in the
  # settings expects it to leave the controller that they are holding.
  @doc false
  @impl GenServer
  def terminate(_reason, socket) do
    send_to(socket, @group, @hello_port, message("BYE * HTTP/1.0"))

    :gen_udp.close(socket)
  end

  defp open do
    case :gen_udp.open(@search_port, options() ++ [add_membership: {@group, {0, 0, 0, 0}}]) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        Logger.info(
          "The Plex player found no multicast, so it answers a broadcast alone: " <>
            "#{inspect(reason)}"
        )

        :gen_udp.open(@search_port, options())
    end
  end

  defp options do
    [:binary, active: true, reuseaddr: true, broadcast: true, multicast_ttl: @ttl]
  end

  # A controller sends one line and this player answers one shape, so the first word is
  # the whole of the parsing. Anything else on this port belongs to another program.
  defp search?(packet), do: String.starts_with?(packet, "M-SEARCH")

  # **A send that fails must not stop the player.** A board with no network gives
  # `:enetunreach` for the group, and the HTTP listener still answers a controller that
  # a person points at it by hand.
  defp send_to(socket, address, port, message) do
    case :gen_udp.send(socket, address, port, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "The Plex player could not answer #{:inet.ntoa(address)}: " <>
            "#{inspect(reason)}"
        )

        :ok
    end
  end
end
