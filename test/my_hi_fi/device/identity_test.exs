defmodule MyHiFi.Device.IdentityTest do
  @moduledoc """
  What a person calls the device, and the picture that they give it.

  The name lives in `Nerves.Runtime.KV`, which is one store for the whole node, so
  these tests cannot run at the same time as each other. A host build keeps that store
  in memory, so each test writes the default back when it ends.
  """

  use MyHiFi.DataCase, async: false

  alias MyHiFi.Artwork
  alias MyHiFi.Cache
  alias MyHiFi.Device.Identity
  alias MyHiFi.Event
  alias MyHiFi.Event.Device.IdentityChanged
  alias Nerves.Runtime.KV

  doctest MyHiFi.Device.Identity, import: true

  # **Two PNG files of 2 by 2 pixels, and each one is whole.** `MyHiFi.Artwork.put/1`
  # runs `vipsthumbnail` over the bytes, so a header alone is not enough here: a
  # machine that holds libvips answers that such a file is not a picture, and a machine
  # without it answers that the picture is held. Both answers are correct, and only a
  # real picture gives one answer on each machine.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGM4IacBRAwQCgAgFgQ5YebC6gAAAABJRU5ErkJggg=="
       )
  @other_png Base.decode64!(
               "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGMQsTkBRAwQCgAb3gRhsgNjogAAAABJRU5ErkJggg=="
             )
  @gif <<"GIF89a", "the rest of a small image">>

  setup do
    on_exit(fn ->
      KV.put("myhifi_device_name", "")
      File.rm_rf(Artwork.directory())
    end)

    :ok
  end

  describe "name/0" do
    test "a device that no person named holds the name of the product" do
      assert Identity.name() == "PiFi"
    end

    test "it gives the name that a person wrote" do
      assert :ok = Identity.put_name("Kitchen")
      assert Identity.name() == "Kitchen"
    end
  end

  describe "put_name/1" do
    test "it removes the space at each end, because a person cannot see one" do
      assert :ok = Identity.put_name("  Kitchen  ")
      assert Identity.name() == "Kitchen"
    end

    test "a device needs a name" do
      assert {:error, "A device needs a name."} = Identity.put_name("   ")
      assert Identity.name() == "PiFi"
    end

    # An SSID holds 32 bytes, and the wizard cuts a longer one. A person reads the whole
    # name of the access point on a phone for that reason.
    test "a name holds 32 bytes or less" do
      assert {:error, message} = Identity.put_name(String.duplicate("a", 33))
      assert message =~ "32 characters or less"
    end

    test "a control character reads as nothing, so it is not a name" do
      assert {:error, message} = Identity.put_name("Kitchen\nRadio")
      assert message =~ "characters that a person reads"
    end

    test "it tells the screens and the pages" do
      Event.subscribe(:device)

      assert :ok = Identity.put_name("Study")
      assert_receive %IdentityChanged{name: "Study", splash_path: nil}
    end
  end

  describe "the picture of the idle screen" do
    test "a device holds none until a person gives one" do
      assert Identity.splash_name() == nil
      assert Identity.splash_path() == nil
    end

    test "it holds the picture and it names the address of it" do
      assert :ok = Identity.put_splash(@png)

      name = Identity.splash_name()

      assert String.match?(name, ~r/\A[0-9a-f]{64}\z/)
      assert Identity.splash_path() == "/artwork/#{name}"
      assert {:ok, _path, "image/png", _etag} = Artwork.serve(name)
    end

    # No address can read these bytes again, so an eviction must never take them.
    test "the entry stays against every eviction" do
      assert :ok = Identity.put_splash(@png)
      assert {:ok, entry} = Cache.fetch("artwork", Identity.splash_name())
      assert entry.keep?
    end

    test "it tells the screens and the pages" do
      Event.subscribe(:device)

      assert :ok = Identity.put_splash(@png)
      assert_receive %IdentityChanged{name: "PiFi", splash_path: "/artwork/" <> _name}
    end

    # libvips in this firmware writes neither GIF nor WebP, so such a picture can hold
    # no thumbnail, and a screen draws the thumbnail and never the picture.
    test "a GIF is refused, because no screen could ever draw it" do
      assert {:error, message} = Identity.put_splash(@gif)
      assert message =~ "not a JPEG and not a PNG"
      assert Identity.splash_name() == nil
    end

    # The first bytes say PNG and the rest of the file says nothing. `vipsthumbnail`
    # reads the rest, so a machine that holds libvips refuses the file here.
    test "a file that names a type it does not hold is refused in words" do
      if System.find_executable("vipsthumbnail") do
        assert {:error, message} =
                 Identity.put_splash(<<0x89, "PNG\r\n", 0x1A, "\n", "and nothing else">>)

        assert message =~ "not a picture that this device can read"
      end
    end

    test "a picture that is too large is refused" do
      assert {:error, message} =
               Identity.put_splash(@png <> String.duplicate("x", 4 * 1024 * 1024))

      assert message =~ "4096 KB or less"
    end

    test "a second picture takes the place of the first, and the first one goes" do
      assert :ok = Identity.put_splash(@png)
      first = Identity.splash_name()

      assert :ok = Identity.put_splash(@other_png)
      second = Identity.splash_name()

      assert second != first
      assert {:error, _reason} = Cache.fetch("artwork", first)
      assert {:ok, _entry} = Cache.fetch("artwork", second)
    end

    test "the same picture again holds one entry" do
      assert :ok = Identity.put_splash(@png)
      first = Identity.splash_name()

      assert :ok = Identity.put_splash(@png)

      assert Identity.splash_name() == first
      assert {:ok, _entry} = Cache.fetch("artwork", first)
    end

    test "a person takes the picture away, and the bytes go with it" do
      assert :ok = Identity.put_splash(@png)
      name = Identity.splash_name()

      assert :ok = Identity.remove_splash()

      assert Identity.splash_path() == nil
      assert {:error, _reason} = Cache.fetch("artwork", name)
    end

    test "a device that holds no picture answers a person who removes one" do
      assert :ok = Identity.remove_splash()
    end
  end

  describe "the picture that this firmware ships" do
    # **A device that a person gave no picture is not a device with no picture.** A
    # screen that plays nothing draws the mark of the product.
    test "it holds one for each screen that this firmware drives" do
      assert path = Identity.shipped_splash({320, 240})
      assert Path.basename(path) == "320x240.png"
      assert File.exists?(path)

      assert path = Identity.shipped_splash({240, 240})
      assert Path.basename(path) == "240x240.png"
      assert File.exists?(path)
    end

    # A new screen needs a file and no code.
    test "a size that this firmware holds no picture for gives nothing" do
      assert Identity.shipped_splash({128, 64}) == nil
    end

    # A picture of another size would cost a scale for each draw, and one that a screen
    # has to crop would lose the ends of the waveform.
    test "each picture is the size of the screen that it belongs to" do
      for {width, height} <- [{320, 240}, {240, 240}] do
        path = Identity.shipped_splash({width, height})
        {output, 0} = System.cmd("file", [path])

        assert output =~ "#{width} x #{height}", "#{path} is not #{width} by #{height}"
      end
    end
  end

  describe "slug/1" do
    test "it gives one label of a host name" do
      assert Identity.slug("Kitchen HiFi") == "kitchen-hifi"
      assert Identity.slug("James' Stereo!") == "james-stereo"
      assert Identity.slug("PiFi") == "pifi"
    end

    test "a name that gives no label at all gives the name of the product" do
      assert Identity.slug("音楽") == "pifi"
      assert Identity.slug("---") == "pifi"
    end
  end
end
