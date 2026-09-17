defmodule PiFiTest do
  use ExUnit.Case
  doctest PiFi

  test "greets the world" do
    assert PiFi.hello() == :world
  end
end
