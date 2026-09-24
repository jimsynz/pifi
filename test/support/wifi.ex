defmodule PiFi.Test.Wifi do
  @moduledoc """
  Wi-Fi that a test decides the answers for.

  A host build carries no `vintage_net`, so `PiFi.Device.Wifi.Absent` reports no adapter
  and no networks. That is the truth on a laptop and it leaves the settings page with
  nothing to draw, so every test of the page would be a test of the empty state.

  This stands in its place, with a neighbourhood a test names.

      PiFi.Test.Wifi.use_it(seen: [PiFi.Test.Wifi.network("Home", security: :wpa2)])

  Use it with `use_it/1`, which puts the configuration back at the end of the test.
  """

  @behaviour PiFi.Device.Wifi

  @impl true
  def available?, do: state().available?

  @impl true
  def scan do
    put(%{state() | scans: state().scans + 1})

    state().scan_answer
  end

  @impl true
  def seen do
    known = known()

    state().seen
    |> Enum.map(&%{&1 | known?: &1.ssid in known})
    |> Enum.sort_by(&{&1.signal_percent, &1.ssid}, :desc)
  end

  @impl true
  def known, do: state().known

  @impl true
  def join(ssid, passphrase) do
    case state().join_answer do
      :ok ->
        put(%{
          state()
          | known: Enum.uniq(state().known ++ [ssid]),
            joins: state().joins ++ [{ssid, passphrase}]
        })

        :ok

      error ->
        put(%{state() | joins: state().joins ++ [{ssid, passphrase}]})

        error
    end
  end

  @impl true
  def forget(ssid) do
    if ssid in state().known do
      put(%{state() | known: state().known -- [ssid]})

      :ok
    else
      {:error, :not_known}
    end
  end

  @doc """
  One network, for a test to hand to `use_it/1`.

  It is the shape `PiFi.Device.Wifi` reports, and the defaults are an ordinary home
  network so a test names only what it cares about.
  """
  @spec network(String.t(), keyword()) :: PiFi.Device.Wifi.network()
  def network(ssid, options \\ []) do
    %{
      ssid: ssid,
      signal_percent: Keyword.get(options, :signal_percent, 70),
      security: Keyword.get(options, :security, :wpa2),
      known?: false
    }
  end

  @doc "The networks a test asked to join, oldest first, whether or not they worked."
  @spec joins() :: [{String.t(), String.t() | nil}]
  def joins, do: state().joins

  @doc "How many times something asked the adapter to look."
  @spec scans() :: non_neg_integer()
  def scans, do: state().scans

  @doc """
  Make this the Wi-Fi of the firmware for one test.

  Options are `:seen`, `:known`, `:available?`, `:join_answer` and `:scan_answer`. The
  last two are what `join/2` and `scan/0` return, so a test can make either fail.
  """
  @spec use_it(keyword()) :: :ok
  def use_it(options \\ []) do
    put(%{
      available?: Keyword.get(options, :available?, true),
      seen: Keyword.get(options, :seen, []),
      known: Keyword.get(options, :known, []),
      join_answer: Keyword.get(options, :join_answer, :ok),
      scan_answer: Keyword.get(options, :scan_answer, :ok),
      joins: [],
      scans: 0
    })

    Application.put_env(:pifi, :wifi, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:pifi, :wifi)
      :persistent_term.erase(__MODULE__)
    end)
  end

  # `:persistent_term` and not a message, because the LiveView asks from its own process
  # and not from the process of the test.
  defp state, do: :persistent_term.get(__MODULE__, %{})

  defp put(state), do: :persistent_term.put(__MODULE__, state)
end
