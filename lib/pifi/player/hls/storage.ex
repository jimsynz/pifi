defmodule PiFi.Player.Hls.Storage do
  @moduledoc """
  Reads an HLS playlist and its segments over HTTP.

  `kim_hls` ships `HLS.Storage.Req`, and this firmware does not use it. That
  module sits inside `if Code.ensure_loaded?(Req)`, and `kim_hls` names `req` as a
  test dependency of its own. A build of this firmware therefore has that module
  or does not, and the answer depends on the order that the dependencies compile
  in. A device must not depend on such an answer.

  This module also sets the timeouts of this firmware, and it uses the one HTTP
  client that the rest of the firmware uses. A test gives its own answers with
  `Req.Test`.

  A player reads and never writes, so `put` and `delete` give an error.
  """

  defstruct [:request]

  @type t :: %__MODULE__{request: Req.Request.t()}

  @doc "A storage that reads over HTTP."
  @spec new() :: t()
  def new, do: %__MODULE__{request: request()}

  @doc """
  The HTTP client for a playlist and for a segment.

  A live playlist changes each few seconds, and one failed read must not stop the
  music, so this retries.
  """
  @spec request() :: Req.Request.t()
  def request do
    :pifi
    |> Application.get_env(PiFi.Player.Hls, [])
    |> Keyword.put_new(:receive_timeout, :timer.seconds(15))
    |> Keyword.put_new(:retry, :transient)
    |> Keyword.put_new(:max_retries, 3)
    |> Req.new()
  end

  defimpl HLS.Storage do
    def get(storage, uri, _options) do
      case Req.get(storage.request, url: uri) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: 404}} -> {:error, :not_found}
        {:ok, %{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end

    def put(_storage, _uri, _binary, _options), do: {:error, :read_only}

    def delete(_storage, _uri, _options), do: {:error, :read_only}
  end
end
