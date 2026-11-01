defmodule PiFi.BundlexProject do
  @moduledoc """
  ALAC decoder.
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
