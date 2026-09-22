defmodule PiFi.AirPlay.RtspTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Rtsp

  alias PiFi.AirPlay.Rtsp
  alias PiFi.AirPlay.Rtsp.Request

  defp message(lines, body \\ ""), do: Enum.join(lines, "\r\n") <> "\r\n\r\n" <> body

  describe "reading a request" do
    test "a request with no body" do
      assert {:ok, request, ""} = Rtsp.parse(message(["OPTIONS * RTSP/1.0", "CSeq: 1"]))

      assert request.method == "OPTIONS"
      assert request.uri == "*"
      assert request.version == "RTSP/1.0"
      assert request.body == ""
    end

    test "a request with a body" do
      raw = message(["POST /pair-setup HTTP/1.1", "Content-Length: 5"], "hello")

      assert {:ok, %Request{body: "hello", method: "POST"}, ""} = Rtsp.parse(raw)
    end

    # **A telephone sends both versions down one socket**: RTSP for the control
    # channel and HTTP for the pairing requests.
    test "it takes either version" do
      assert {:ok, %Request{version: "RTSP/1.0"}, ""} = Rtsp.parse(message(["SETUP / RTSP/1.0"]))
      assert {:ok, %Request{version: "HTTP/1.1"}, ""} = Rtsp.parse(message(["POST / HTTP/1.1"]))
    end

    # **A header arrives in whatever case a sender felt like.** `CSeq`, `cseq` and
    # `CSEQ` are one header.
    test "header names are read in one case whatever case they arrived in" do
      raw = message(["GET / RTSP/1.0", "CSEQ: 3", "Content-Type: text/plain"])

      assert {:ok, request, ""} = Rtsp.parse(raw)
      assert Rtsp.header(request, "CSeq") == {:ok, "3"}
      assert Rtsp.header(request, "cseq") == {:ok, "3"}
      assert Rtsp.header(request, "content-type") == {:ok, "text/plain"}
    end

    test "a header value keeps its own colons" do
      raw = message(["GET / RTSP/1.0", "Date: Mon, 22 Sep 2026 10:30:00 GMT"])

      assert {:ok, request, ""} = Rtsp.parse(raw)
      assert Rtsp.header(request, "date") == {:ok, "Mon, 22 Sep 2026 10:30:00 GMT"}
    end
  end

  # A socket hands over whatever arrived, which is not always one whole message.
  describe "reading from a stream" do
    test "a message that has not all arrived" do
      assert {:more, _buffer} = Rtsp.parse("GET / RTSP/1.0\r\nCSeq: 1\r\n")
    end

    test "headers complete but the body still coming" do
      raw = message(["POST / HTTP/1.1", "Content-Length: 10"], "half")

      assert {:more, ^raw} = Rtsp.parse(raw)
    end

    # Two requests can turn up in one read, so what is left over has to come back.
    test "two requests in one read" do
      raw =
        message(["OPTIONS * RTSP/1.0", "CSeq: 1"]) <> message(["GET /info RTSP/1.0", "CSeq: 2"])

      assert {:ok, first, rest} = Rtsp.parse(raw)
      assert first.method == "OPTIONS"

      assert {:ok, second, ""} = Rtsp.parse(rest)
      assert second.method == "GET"
    end

    test "a body followed by the start of the next request" do
      raw = message(["POST / HTTP/1.1", "Content-Length: 2"], "hi") <> "GET / RTSP/1.0\r\n"

      assert {:ok, %Request{body: "hi"}, "GET / RTSP/1.0\r\n"} = Rtsp.parse(raw)
    end
  end

  # **Every byte of this arrives before anything has been authenticated.**
  describe "what it refuses" do
    test "a request line that is not three words" do
      assert {:error, {:bad_request_line, _}} = Rtsp.parse(message(["GET /only-two"]))
    end

    test "a header with no colon" do
      assert {:error, {:bad_header, _}} = Rtsp.parse(message(["GET / RTSP/1.0", "nonsense"]))
    end

    test "a content length that is not a number" do
      assert {:error, {:bad_content_length, "soon"}} =
               Rtsp.parse(message(["POST / HTTP/1.1", "Content-Length: soon"]))
    end

    # A sender that claimed a gigabyte would otherwise have this device wait for one.
    test "a body larger than this device will hold" do
      assert {:error, {:body_too_large, _}} =
               Rtsp.parse(message(["POST / HTTP/1.1", "Content-Length: 99999999"]))
    end

    test "a negative content length" do
      assert {:error, {:bad_content_length, "-1"}} =
               Rtsp.parse(message(["POST / HTTP/1.1", "Content-Length: -1"]))
    end
  end

  describe "writing a reply" do
    test "it carries the length of the body" do
      raw = Rtsp.response(200, %{}, "four")

      assert raw =~ "content-length: 4"
      assert String.ends_with?(raw, "\r\n\r\nfour")
    end

    test "an empty body still says so" do
      assert Rtsp.response(200, %{}) =~ "content-length: 0"
    end

    # **A sender matches replies to requests by CSeq and by nothing else**, so a reply
    # without it is one the telephone never sees.
    test "a reply carries the CSeq of the request it answers" do
      {:ok, request, ""} = Rtsp.parse(message(["GET / RTSP/1.0", "CSeq: 42"]))

      assert Rtsp.reply_to(request, 200) =~ "cseq: 42"
    end

    test "a reply uses the version of the request" do
      {:ok, rtsp, ""} = Rtsp.parse(message(["GET / RTSP/1.0", "CSeq: 1"]))
      {:ok, http, ""} = Rtsp.parse(message(["POST / HTTP/1.1", "CSeq: 1"]))

      assert Rtsp.reply_to(rtsp, 200) =~ "RTSP/1.0 200"
      assert Rtsp.reply_to(http, 200) =~ "HTTP/1.1 200"
    end

    test "a request with no CSeq gets a reply with none" do
      {:ok, request, ""} = Rtsp.parse(message(["GET / RTSP/1.0"]))

      refute Rtsp.reply_to(request, 200) =~ "cseq"
    end

    # The round trip is what proves a reply is shaped like something that can be read.
    test "a reply reads back as a message with the body it was given" do
      {:ok, request, ""} = Rtsp.parse(message(["GET / RTSP/1.0", "CSeq: 9"]))
      raw = Rtsp.reply_to(request, 200, %{}, "the body")

      assert [head, body] = :binary.split(raw, "\r\n\r\n")
      assert body == "the body"
      assert head =~ "content-length: 8"
    end
  end
end
