defmodule PiFi.Hardware.ConfigTxt do
  @moduledoc """
  The block of `config.txt` that this firmware owns.

  A person chooses a hardware profile, and the lines of it go in a block with a mark at
  each end. Everything outside the two marks belongs to the Nerves system, so a later
  version of the system changes `config.txt` freely and this firmware keeps its four
  lines.

      # --- PiFi hardware profile: begin ---
      dtoverlay=hifiberry-dac
      gpio=25=op,dh
      # --- PiFi hardware profile: end ---

  ## Why a block, and not a file of its own

  The bootloader of the Raspberry Pi reads `config.txt` before Linux, so a fragment
  would have to live on the boot partition beside it. **`fwup` formats that partition
  for each upgrade**: `task upgrade.a` calls `fat_mkfs` before it writes. Nothing on
  that partition lasts, so nothing there can hold the choice of a person.

  The choice therefore lives in the settings, on the data partition that no upgrade
  touches, and `PiFi.Hardware` writes this block again when a boot finds it absent.

  ## Every function here is pure

  A read of a file, a mount, and a restart all belong to `PiFi.Hardware`. This module
  takes the text and gives the text, so a host can test each rule of it.
  """

  @begin "# --- PiFi hardware profile: begin ---"
  @finish "# --- PiFi hardware profile: end ---"

  @doc """
  Put the lines of a profile into the text, in the place of any block that is there.

  A profile of no lines takes the block away and adds none.
  """
  @spec put(String.t(), [String.t()]) :: String.t()
  def put(contents, []), do: without_block(contents)

  def put(contents, lines) do
    without_block(contents) <> "\n" <> block(lines) <> "\n"
  end

  @doc """
  The lines that the text holds now, or `[]` for a text that holds no block.
  """
  @spec lines(String.t()) :: [String.t()]
  def lines(contents) do
    case String.split(contents, [@begin, @finish]) do
      [_before, inside | _rest] ->
        inside
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _other ->
        []
    end
  end

  @doc """
  Whether the text already holds these lines, and these lines alone.

  `PiFi.Hardware` reads this at each boot. It compares the text of the file and never
  the hardware that answers, so a profile that names an overlay which the boot partition
  does not hold writes one time and no more. A restart that repeats has no way to begin.
  """
  @spec carries?(String.t(), [String.t()]) :: boolean()
  def carries?(contents, lines), do: lines(contents) == lines

  @doc "The block, with a mark at each end."
  @spec block([String.t()]) :: String.t()
  def block(lines), do: Enum.join([@begin | lines] ++ [@finish], "\n")

  # A text that holds no block comes back with its own last newline, so a block that
  # follows begins on a line of its own.
  defp without_block(contents) do
    case String.split(contents, @begin, parts: 2) do
      [before, rest] ->
        after_block =
          case String.split(rest, @finish, parts: 2) do
            [_inside, tail] -> tail
            [_no_end] -> ""
          end

        String.trim_trailing(before <> after_block) <> "\n"

      [whole] ->
        String.trim_trailing(whole) <> "\n"
    end
  end
end
