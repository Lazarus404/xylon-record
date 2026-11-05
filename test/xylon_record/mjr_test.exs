defmodule XylonRecord.MjrTest do
  use ExUnit.Case, async: true

  alias XMediaLib.Rtp
  alias XylonRecord.Mjr

  test "header is MJR00002 + BE length + JSON with Janus and Xylon fields" do
    bin =
      Mjr.header(%{
        kind: :audio,
        codec: "opus",
        created_us: 1_000,
        written_us: 2_000,
        xylon: %{
          tenant_id: "t1",
          session_id: "s1",
          recording_id: "r1",
          sequence: 1,
          publisher_id: "a",
          mid: "0",
          ssrc: 42,
          edge_node: :nonode@nohost
        }
      })

    assert <<"MJR00002", len::16-big, rest::binary>> = bin
    <<json::binary-size(^len), "">> = rest
    map = Jason.decode!(json)
    assert map["t"] == "a"
    assert map["c"] == "opus"
    assert map["s"] == 1_000
    assert map["u"] == 2_000
    assert map["tenant_id"] == "t1"
    assert map["publisher_id"] == "a"
    assert map["ssrc"] == 42

    assert {:ok, ^map, ""} = Mjr.parse_header(bin)
  end

  test "frame wraps RTP with MEET + relative ms + length" do
    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 42,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }

    encoded = Rtp.encode(rtp)
    frame = Mjr.frame(15, encoded)
    assert <<"MEET", 15::32-big, len::16-big, body::binary>> = frame
    assert len == byte_size(encoded)
    assert body == encoded
    assert {:ok, decoded} = Rtp.decode(body)
    assert decoded.ssrc == 42
    assert decoded.payload == "hi"
  end

  test "video header uses t=v and lowercases codec" do
    bin =
      Mjr.header(%{
        kind: :video,
        codec: "VP8",
        created_us: 1,
        written_us: 1,
        xylon: %{}
      })

    assert {:ok, map, _} = Mjr.parse_header(bin)
    assert map["t"] == "v"
    assert map["c"] == "vp8"
  end
end
