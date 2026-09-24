defmodule PiFi.BundlexProject do
  @moduledoc """
  The native code of this firmware.

  **This is the only thing here that is not Elixir**, and it is here because there is no
  ALAC decoder on Hex and AirPlay sends ALAC. Bundlex already cross-compiles the
  Membrane NIFs for this target, so it is the toolchain the project has rather than a
  new one — and `mix.exs` already sets the four `TARGET_*` variables it reads.
  """

  use Bundlex.Project

  def project do
    [natives: natives()]
  end

  defp natives do
    [
      alac: [
        interface: :nif,
        sources: ["alac/alac.c", "alac/alac_nif.c"],
        preprocessor: [],
        language: :c
      ]
    ]
  end
end
