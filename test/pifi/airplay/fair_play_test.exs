defmodule PiFi.AirPlay.FairPlayTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.FairPlay

  alias PiFi.AirPlay.FairPlay

  # The four answers as one blob each, exactly as a working receiver sends them. The
  # module builds each one from a header and a body, so comparing against the undivided
  # bytes is what says the division was right.
  @answers %{
    0 =>
      "46504C590301020000000082" <>
        "02000F9F3F9E0A2521DBDF312AB2BFB29E8D232B6376A8C818701D22AE93D82737FEAF9DB4FDF41C" <>
        "2DBA9D1F49CAAABF6591AC1F7BC6F7E0663D21AFE01565953EAB81F418CEED095ADB7C3D0E254909" <>
        "A79831D49C3982973434FACB42C63A1CD911A6FE941A8A6D4A743B46C3A7649E44C78955E49D8155" <>
        "009549C4E2F7A3F6D5BA",
    1 =>
      "46504C590301020000000082" <>
        "0201CF32A25714B2524F8AA0AD7AF164E37BCF4424E200047EFC0AD67AFCD95DED1C2730BB591B96" <>
        "2ED63A9C4DED88BA8FC78DE64D91CCFD5C7B56DA88E31F5CCEAFC7431995A01665A54E1939D25B94" <>
        "DB64B9E45D8D063E1E6AF07E9656162B0EFA404275EA5A44D9591C7256B9FBE6513898B802277219" <>
        "88571650942AD946688A",
    2 =>
      "46504C590301020000000082" <>
        "0202C169A352EEED35B18CDD9C58D64F16C1519A89EB5317BD0D4336CD68F638FF9D016A5B52B7FA" <>
        "9216B2B65482C78444118121A2C7FED83DB7119E9182AAD7D18C7063E2A457555910AF9E0EFC7634" <>
        "7D164043807F581EE4FBE42CA9DEDC1B5EB2A3AA3D2ECD59E7EEE70B3629F22AFD161D877353DDB9" <>
        "9ADC8E07006E56F850CE",
    3 =>
      "46504C590301020000000082" <>
        "02039001E1727E0F57F9F5880DB104A6257A23F5CFFF1ABBE1E93045251AFB97EB9FC0011EBE0F3A" <>
        "81DF5B691D76ACB2F7A5C708E3D328F56BB39DBDE5F29C8A17F481487E3AE863C678325422E6F78E" <>
        "166D18AA7FD636258BCE28726F661F738893CE44311E4BE6C0535193E5EF72E8686233729C227D82" <>
        "0C999445D89246C8C359"
  }

  # Taken from the reference separately from the four above. The module builds both this
  # and the stage one header with the same function, so this pins that function down.
  @setup2_header Base.decode16!("46504C590301040000000014")

  defp answer(mode), do: Base.decode16!(@answers[mode])

  defp setup1(mode), do: <<"FPLY", 3, 1, 1, 0, 130::32, 2, mode>> <> :binary.copy(<<0>>, 128)

  defp setup2(body), do: <<"FPLY", 3, 1, 3, 0, byte_size(body)::32>> <> body

  describe "the header" do
    test "counts the bytes after itself and is always twelve long" do
      assert byte_size(FairPlay.header(2, 130)) == 12
      assert <<_first::binary-size(8), 130::32>> = FairPlay.header(2, 130)
    end

    test "builds the stage two header the reference sends" do
      assert FairPlay.header(4, 20) == @setup2_header
    end

    test "builds the stage one header the reference sends" do
      assert FairPlay.header(2, 130) == binary_part(answer(0), 0, 12)
    end
  end

  describe "the first message" do
    for mode <- 0..3 do
      test "mode #{mode} answers with the bytes a sender expects" do
        mode = unquote(mode)

        assert {:ok, reply} = FairPlay.setup(setup1(mode))
        assert reply == answer(mode)
      end
    end

    test "the four answers differ from one another" do
      replies = Enum.map(0..3, fn mode -> elem(FairPlay.setup(setup1(mode)), 1) end)

      assert length(Enum.uniq(replies)) == 4
    end

    test "names the mode it is answering for, in the second byte of the body" do
      for mode <- 0..3 do
        assert {:ok, <<_header::binary-size(12), 2, ^mode, _rest::binary>>} =
                 FairPlay.setup(setup1(mode))
      end
    end

    test "answers with sequence two, one past the message it answers" do
      assert {:ok, <<"FPLY", 3, 1, 2, 0, _length::32, _rest::binary>>} =
               FairPlay.setup(setup1(0))
    end

    test "refuses a mode that is not one of the four" do
      request = <<"FPLY", 3, 1, 1, 0, 130::32, 2, 9>> <> :binary.copy(<<0>>, 128)

      assert {:error, {:bad_mode, 9}} = FairPlay.setup(request)
    end
  end

  describe "the second message" do
    test "hands back the last twenty bytes and nothing else" do
      tail = :binary.copy("t", 20)

      assert {:ok, reply} = FairPlay.setup(setup2(:binary.copy("x", 144) <> tail))
      assert reply == @setup2_header <> tail
      assert byte_size(reply) == 32
    end

    test "reads from the end and not from a fixed place" do
      tail = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20>>

      for prefix <- [0, 1, 17, 144, 300] do
        assert {:ok, @setup2_header <> ^tail} =
                 FairPlay.setup(setup2(:binary.copy("p", prefix) <> tail))
      end
    end

    test "takes a body that is exactly the twenty bytes" do
      tail = :binary.copy("z", 20)

      assert {:ok, @setup2_header <> ^tail} = FairPlay.setup(setup2(tail))
    end

    # A sequence this module answers, carrying too little to answer with, is truncated
    # and not a sequence it refuses.
    test "refuses a body too short to hold the twenty bytes" do
      assert {:error, :truncated} = FairPlay.setup(setup2(:binary.copy("z", 19)))
    end

    test "answers with sequence four, one past the message it answers" do
      assert {:ok, <<"FPLY", 3, 1, 4, 0, 20::32, _rest::binary>>} =
               FairPlay.setup(setup2(:binary.copy("z", 20)))
    end
  end

  describe "refusing what it cannot answer" do
    test "a version it does not know" do
      assert {:error, {:bad_version, 4}} =
               FairPlay.setup(<<"FPLY", 4, 1, 1, 0, 130::32, 2, 0>>)
    end

    test "a message type it does not know" do
      assert {:error, {:bad_type, 2}} = FairPlay.setup(<<"FPLY", 3, 2, 1, 0, 130::32, 2, 0>>)
    end

    test "a sequence number that is neither of the two" do
      assert {:error, {:bad_sequence, 2}} =
               FairPlay.setup(<<"FPLY", 3, 1, 2, 0, 130::32, 2, 0>>)
    end

    test "a body that does not start with the magic" do
      assert {:error, :truncated} = FairPlay.setup(<<"HTTP", 3, 1, 1, 0, 130::32, 2, 0>>)
    end

    test "an empty body, and one too short to hold a header" do
      assert {:error, :truncated} = FairPlay.setup(<<>>)
      assert {:error, :truncated} = FairPlay.setup(<<"FPLY", 3, 1, 1>>)
    end

    test "a first message that stops before it names its mode" do
      assert {:error, :truncated} = FairPlay.setup(<<"FPLY", 3, 1, 1, 0, 130::32, 2>>)
    end
  end
end
