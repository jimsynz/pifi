defmodule PiFi.Settings do
  @moduledoc """
  The configuration of the device.

  A device has no environment to read a value from, so it keeps its configuration
  in the database. `fetch/1` reads one value, and `put/2` writes one. A caller that
  needs a default writes the `case` itself, because no caller needs one yet.

  ## The answers live in memory

  **A setting is read many times and written almost never**, and the database is on
  an SD card. `fetch/1` therefore reads `PiFi.Settings.Cache`, and it reads the
  card for a key that the memory does not hold. `put/2` and `delete/1` write the
  memory as well, so this module is the one door to the table and nothing else may
  write a row of it.
  """

  use Ash.Domain, otp_app: :pifi

  @typedoc """
  One value that a person can change on the settings page, for a source or a
  peripheral.

  `key` names the field to the `put_settings/1` of its owner, and it is also the name
  of the control on a page. `type` decides the control: `:text` shows the value,
  `:password` hides it, `:number` takes a whole number, and `:select` offers the
  `options`, each a value and the words a person reads for it. Each one is a type
  that `PiFiWeb.CoreComponents.input/1` draws, and the settings page passes it
  through with no rule of its own.

  `value` is what the owner reports now, and it is nil for a field with
  `write_only?` set. A page then shows an empty control, and it never sends the
  value of that field to a browser.

  `link` names one page that tells a person more, such as where to ask for a key.
  It is separate from `description` because the web interface draws an anchor and
  the device screen can open nothing.

  See `c:PiFi.Source.settings/0` and `c:PiFi.Peripheral.settings/0`.
  """
  @type field :: %{
          required(:key) => String.t(),
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:link) => %{href: String.t(), title: String.t()} | nil,
          required(:type) => :number | :password | :select | :text,
          required(:value) => String.t() | nil,
          required(:write_only?) => boolean(),
          optional(:options) => [{String.t(), String.t()}]
        }

  alias PiFi.Settings.Cache

  resources do
    resource PiFi.Settings.Setting do
      define :list_settings, action: :read
      define :read_setting, action: :by_key, args: [:key]
      define :write_setting, action: :put, args: [:key, :value]
      define :destroy_setting, action: :delete
    end
  end

  @doc """
  Remove one setting, so the default of the caller applies again.
  """
  @spec delete(PiFi.Settings.Setting.t()) :: :ok | {:error, term()}
  def delete(setting) do
    with :ok <- destroy_setting(setting), do: Cache.forget(setting.key)
  end

  @doc """
  Remove one setting, and raise for an error.
  """
  @spec delete!(PiFi.Settings.Setting.t()) :: :ok
  def delete!(setting) do
    destroy_setting!(setting)

    Cache.forget(setting.key)
  end

  @doc """
  Read one setting. It returns an error for a key that no row holds.

  **The answer for a key that no row holds is held as well.** A source that a person
  never chose is the usual case, and a page asks for one on each navigation.
  """
  @spec fetch(String.t()) :: {:ok, PiFi.Settings.Setting.t()} | {:error, term()}
  def fetch(key) do
    case Cache.fetch(key) do
      {:ok, answer} ->
        answer

      :miss ->
        remember(key, read_setting(key))
    end
  end

  @doc """
  Read one setting, and raise for a key that no row holds.
  """
  @spec fetch!(String.t()) :: PiFi.Settings.Setting.t()
  def fetch!(key) do
    case fetch(key) do
      {:ok, setting} -> setting
      {:error, error} -> raise error
    end
  end

  @doc """
  Write a value for a key. A second call for the same key replaces the value.
  """
  @spec put(String.t(), String.t()) :: {:ok, PiFi.Settings.Setting.t()} | {:error, term()}
  def put(key, value), do: remember(key, write_setting(key, value))

  @doc """
  Write a value for a key, and raise for an error.
  """
  @spec put!(String.t(), String.t()) :: PiFi.Settings.Setting.t()
  def put!(key, value) do
    setting = write_setting!(key, value)
    Cache.put(key, {:ok, setting})

    setting
  end

  # **A key that no row holds is an answer, and an error of the database is not.** A
  # source that a person never chose gives the first one on each navigation, and a
  # card that cannot answer must be asked again.
  defp remember(key, {:ok, setting}) do
    Cache.put(key, {:ok, setting})

    {:ok, setting}
  end

  defp remember(key, {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} = answer) do
    Cache.put(key, answer)

    answer
  end

  defp remember(key, answer) do
    Cache.forget(key)

    answer
  end
end
