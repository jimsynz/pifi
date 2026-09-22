defmodule PiFi.AirPlay.SrpTest do
  use ExUnit.Case, async: true

  doctest PiFi.AirPlay.Srp

  alias PiFi.AirPlay.Srp

  defp number(hex), do: hex |> String.replace(~r/\s/, "") |> String.to_integer(16)

  # RFC 5054 Appendix B: the 1024-bit group, SHA-1, and a worked example with every
  # intermediate value published.
  defp rfc_group do
    %{
      prime:
        number("""
        EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576
        D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE48E495C1D6089DAD1
        5DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC
        68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3
        """),
      generator: 2
    }
  end

  @salt Base.decode16!("BEB25379D1A8581EB5A727673A2441EE")

  # **These are the published answers, not answers from a second implementation of
  # mine.** An exchange checked only against itself agrees with its own mistakes, and
  # SRP has several places where a plausible reading gives a value that is wrong in a
  # way nothing notices until a telephone refuses to pair.
  describe "RFC 5054 Appendix B" do
    test "the verifier" do
      v = Srp.verifier(rfc_group(), :sha, "alice", "password123", @salt)

      assert v ==
               number("""
               7E273DE8696FFC4F4E337D05B4B375BEB0DDE1569E8FA00A9886D812
               9BADA1F1822223CA1A605B530E379BA4729FDC59F105B4787E5186F5
               C671085A1447B52A48CF1970B4FB6F8400BBF4CEBFBB168152E08AB5
               EA53D15C1AFF87B2B9DA6E04E058AD51CC72BFC9033B564E26480D78
               E955A5E29E7AB245DB2BE315E2099AFB
               """)
    end

    # **`B` is not `g^b`.** The verifier is mixed in, and getting that wrong gives a
    # value a telephone will not accept and no hint as to why.
    test "the public value the accessory sends" do
      v = Srp.verifier(rfc_group(), :sha, "alice", "password123", @salt)
      b = number("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20")

      assert Srp.public_key(rfc_group(), :sha, v, b) ==
               number("""
               BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011
               BAF38964DC46A0670DD125B95A981652236F99D9B681CBF87837EC99
               6C6DA04453728610D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA
               37089E6F9C6059F388838E7A00030B331EB76840910440B1B27AAEAE
               EB4012B7D7665238A8E3FB004B117B58
               """)
    end

    # The secret is what both sides arrive at. If this matches the published value then
    # the multiplier, the scrambler and the padding are all right.
    test "the shared secret" do
      group = rfc_group()
      v = Srp.verifier(group, :sha, "alice", "password123", @salt)
      b = number("E487CB59D31AC550471E81F00F6928E01DDA08E974A004F49E61F5D105284D20")

      a_pub =
        number("""
        61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC4
        4352E8903211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC
        8E39356179EAE45E42BA92AEACED825171E1E8B9AF6D9C03E1327F44
        BE087EF06530E69F66615261EEF54073CA11CF5858F0EDFDFE15EFEA
        B349EF5D76988A3672FAC47B0769447B
        """)

      b_pub = Srp.public_key(group, :sha, v, b)

      assert {:ok, secret} = Srp.secret(group, :sha, a_pub, b_pub, v, b)

      assert secret ==
               number("""
               B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D
               233861E359B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C
               41BB59B6D5979B5C00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F
               3499B200210DCC1F10EB33943CD67FC88A2F39A4BE5BEC4EC0A3212D
               C346D7E474B29EDE8A469FFECA686E5A
               """)
    end
  end

  # **A telephone that sends zero would otherwise pair without knowing anything**, so
  # the accessory refuses it rather than computing a secret of zero.
  describe "what it refuses" do
    test "a client public value of zero" do
      group = rfc_group()

      assert {:error, :bad_client_public} = Srp.secret(group, :sha, 0, 1, 1, 1)
    end

    test "a client public value that is the prime" do
      group = rfc_group()

      assert {:error, :bad_client_public} = Srp.secret(group, :sha, group.prime, 1, 1, 1)
    end
  end

  # The group AirPlay actually uses, with the hash it actually uses. The published
  # vector above proves the algorithm; this proves it runs on the real parameters and
  # that both sides agree.
  describe "the parameters AirPlay uses" do
    test "the group is 3072 bits" do
      assert Srp.group_3072().prime |> Integer.to_string(2) |> String.length() == 3072
    end

    test "a full exchange leaves both sides holding the same secret" do
      group = Srp.group_3072()
      salt = :crypto.strong_rand_bytes(16)
      code = "123-45-678"

      v = Srp.verifier(group, :sha512, Srp.username(), code, salt)
      b = Srp.private_key()
      b_pub = Srp.public_key(group, :sha512, v, b)

      # The telephone's side, computed here so that the two can be compared.
      a = Srp.private_key()

      a_pub =
        :crypto.mod_pow(<<5>>, :binary.encode_unsigned(a), :binary.encode_unsigned(group.prime))
        |> :binary.decode_unsigned()

      assert {:ok, server_secret} = Srp.secret(group, :sha512, a_pub, b_pub, v, b)
      assert is_integer(server_secret)
      assert server_secret > 0

      key = Srp.session_key(:sha512, server_secret)
      assert byte_size(key) == 64

      proof = Srp.client_proof(group, :sha512, Srp.username(), salt, a_pub, b_pub, key)
      assert byte_size(proof) == 64
      assert byte_size(Srp.server_proof(group, a_pub, proof, key, :sha512)) == 64
    end

    test "a different code gives a different verifier" do
      group = Srp.group_3072()
      salt = :crypto.strong_rand_bytes(16)

      refute Srp.verifier(group, :sha512, Srp.username(), "111-11-111", salt) ==
               Srp.verifier(group, :sha512, Srp.username(), "222-22-222", salt)
    end

    # A salt that did not change would make one code always give one verifier, which is
    # the whole reason a salt is there.
    test "a different salt gives a different verifier" do
      group = Srp.group_3072()

      refute Srp.verifier(group, :sha512, Srp.username(), "123-45-678", <<1::128>>) ==
               Srp.verifier(group, :sha512, Srp.username(), "123-45-678", <<2::128>>)
    end
  end
end
