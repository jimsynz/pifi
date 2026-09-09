defmodule MyHiFi.Device.Storage.Usage do
  @moduledoc """
  Reads which kind of media holds the room of the writable partition.

  **A download belongs to the source that gave it, and the cache cannot say which.**
  `MyHiFi.Cache` holds every episode and every track in the one namespace `download`,
  keyed by the identifier of the item, so a sum of that namespace gives one number for
  every service together. A person who wants to know whether to remove the podcasts or
  the albums needs the two apart. This therefore reads the items that hold audio and
  groups them by their source. There are 20 such rows on a device with 614 MB of
  downloads, so the read is small.

  Artwork is one kind, and it needs no such work: it is a namespace of its own.

  **`other` holds what is left, and it is large.** A measurement on 2026-09-09 gave
  3.56 GB in use, of which the cache held 1.82 GB and the database 59 MB. The rest is
  the firmware, the logs, and what a file system needs for 10054 small files. A bar
  that showed the kinds alone would say that half the card holds nothing, so this
  names the remainder and a person reads a bar that adds up.
  """

  use Ash.Resource.Actions.Implementation

  alias MyHiFi.Artwork
  alias MyHiFi.Cache.Entry
  alias MyHiFi.Device
  alias MyHiFi.Playback
  alias MyHiFi.Source

  require Ash.Query

  @impl true
  def run(_input, _options, _context) do
    report = Device.storage!()
    kinds = downloads() ++ [artwork(), database(report)]

    {:ok, order(kinds ++ [other(report, kinds)])}
  end

  defp downloads do
    Playback.items_holding_audio!()
    |> Enum.group_by(& &1.source, & &1.audio_file.byte_size)
    |> Enum.map(fn {source, sizes} ->
      %{key: source, label: source_label(source), bytes: Enum.sum(sizes)}
    end)
  end

  # A row of an older firmware can name a source that this one does not hold, and the
  # slug of it says more to a person than nothing at all.
  defp source_label(source) do
    case Source.from_slug(source) do
      {:ok, module} -> module.title()
      {:error, _reason} -> source
    end
  end

  defp artwork do
    query = Ash.Query.filter(Entry, namespace == ^Artwork.namespace())

    %{key: "artwork", label: "Artwork", bytes: Ash.sum!(query, :byte_size) || 0}
  end

  defp database(report), do: %{key: "database", label: "Database", bytes: report.database_bytes}

  # A card that a person wrote outside this firmware, and a read of `df` that failed,
  # both give a number that no kind can account for. 0 is the floor, because a
  # negative segment cannot be drawn.
  defp other(report, kinds) do
    named = Enum.sum(Enum.map(kinds, & &1.bytes))

    %{key: "other", label: "Other", bytes: Kernel.max(report.used_bytes - named, 0)}
  end

  # **The order is fixed, and it is not the size.** A colour follows a kind, and a
  # person who removed the episodes of one source must not find that every other
  # colour moved. The sources come first, in the order of `MyHiFi.Source.all/0`, and
  # `other` comes last because it is the fold of what no kind names.
  #
  # `MyHiFiWeb.SettingsLive` holds a colour for each key of this list, and the two must
  # agree. The colours are measured for the pairs that touch on the bar, so a kind that
  # moved would put two of them side by side that no measurement covers.
  #
  # A kind of no bytes is absent: a device that holds no Jellyfin album must draw no
  # row for one.
  defp order(kinds) do
    keys = Enum.map(Source.all(), &Source.slug/1) ++ ["artwork", "database", "other"]

    kinds
    |> Enum.reject(&(&1.bytes == 0))
    |> Enum.sort_by(fn kind -> Enum.find_index(keys, &(&1 == kind.key)) || length(keys) end)
  end
end
