defmodule MyHiFiTest do
  use ExUnit.Case
  doctest MyHiFi

  test "greets the world" do
    assert MyHiFi.hello() == :world
  end
end
