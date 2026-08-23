defmodule MyHiFi.Cache.Entry.Changes.Fetch do
  @moduledoc """
  Reads an address and gives the bytes to `MyHiFi.Cache.Entry.Changes.Write`.

  The two changes run in order on the `put_from_url` action. This one fetches and
  sets the `bytes` argument, and `Write` puts those bytes on the disk. Neither one
  repeats the other.

  It sets `content_type` from the header of the answer, and it reads nothing of the
  body to check that. **A caller that needs to know what the bytes are must look at
  them itself**, because a `content-type` header is often wrong and this cache holds
  anything. `MyHiFi.Artwork` reads the first bytes of an image for that reason.

  `max_bytes` stops a body that is too large. Without it a cache of pictures would
  take whatever an address gave it.
  """

  use Ash.Resource.Change

  alias MyHiFi.Cache

  @timeout :timer.seconds(30)
  @user_agent "MyHiFi/0.1 (+https://harton.dev/mypihifiguy/myhifi)"

  @impl true
  def change(changeset, _options, _context) do
    url = Ash.Changeset.get_argument(changeset, :url)
    limit = Ash.Changeset.get_argument(changeset, :max_bytes)

    case get(url) do
      {:ok, body, content_type} ->
        store(changeset, body, content_type, limit)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :url,
          message: "could not be read: #{inspect(reason)}"
        )
    end
  end

  defp store(changeset, body, _content_type, limit)
       when is_integer(limit) and byte_size(body) > limit do
    Ash.Changeset.add_error(changeset,
      field: :url,
      message: "gave #{byte_size(body)} bytes, and the limit is #{limit}"
    )
  end

  defp store(changeset, body, content_type, _limit) do
    changeset
    |> Ash.Changeset.set_argument(:bytes, body)
    |> content_type(content_type)
  end

  # A caller that named a type keeps it, because it may know better than the header.
  defp content_type(changeset, nil), do: changeset

  defp content_type(changeset, type) do
    case Ash.Changeset.get_attribute(changeset, :content_type) do
      nil -> Ash.Changeset.force_change_attribute(changeset, :content_type, type)
      _named -> changeset
    end
  end

  # A test gives a stub with `config :my_hi_fi, MyHiFi.Cache, plug: ...`. Nothing
  # sets this in production.
  defp get(url) do
    [
      url: url,
      headers: [{"user-agent", @user_agent}],
      receive_timeout: @timeout,
      retry: :transient
    ]
    |> Keyword.merge(Application.get_env(:my_hi_fi, Cache, []))
    |> Req.new()
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: body} = response}
      when is_binary(body) and byte_size(body) > 0 ->
        {:ok, body, declared_type(response)}

      {:ok, %{status: 200}} ->
        {:error, :empty}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # The header often names a type with parameters after it, such as
  # `image/jpeg; charset=binary`, and only the type belongs in the field.
  defp declared_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] -> value |> String.split(";") |> hd() |> String.trim() |> presence()
      [] -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value
end
