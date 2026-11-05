defmodule XylonRecord.HandlerTest do
  use ExUnit.Case, async: false

  alias XMediaLib.Rtp
  alias Xylon.Recording.Ctx
  alias XylonRecord.{Handler, Mjr}

  setup do
    dir = Path.join(System.tmp_dir!(), "xylon_record_test_#{System.unique_integer([:positive])}")
    Application.put_env(:xylon, :recording, handler: Handler, dir: dir, queue_max: 2000)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  defp ctx do
    %Ctx{
      tenant_id: "t1",
      session_id: "s1",
      recording_id: "rec#{System.unique_integer([:positive])}",
      sequence: 1,
      preceded_by: nil,
      mode: :tracks,
      edge_node: Node.self()
    }
  end

  defp rtp(ssrc, seq \\ 1) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: seq,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: nil,
      payload: "hi"
    }
  end

  # VP8 keyframe (P=0 after descriptor) so Phase 5 gate accepts the packet.
  defp vp8_key_rtp(ssrc, seq \\ 1) do
    %{rtp(ssrc, seq) | payload_type: 96, payload: <<0x10, 0x00, 0x01, 0x02>>}
  end

  test "writes audio and video stems and finalizes under recording_id", %{dir: dir} do
    c = ctx()
    assert {:ok, state} = Handler.on_start(c, %{})

    meta_a = %{publisher_id: "alice", mid: "0", kind: :audio, ssrc: 111, codec: "opus"}
    meta_v = %{publisher_id: "alice", mid: "1", kind: :video, ssrc: 222, codec: "vp8"}

    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta_a, rtp(111))
    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta_v, vp8_key_rtp(222))
    # Unknown mid/kind skipped
    assert {:ok, state} =
             Handler.on_publisher_rtp(c, state, %{publisher_id: "x", ssrc: 1, kind: :unknown}, rtp(1))

    assert {:ok, manifest} = Handler.on_stop(c, state)
    assert length(manifest.artifacts) == 2
    assert manifest.counters.packets == 2
    assert state.skipped_unknown >= 1 or manifest.skipped_unknown_hot >= 1

    rec_dir = Path.join(dir, c.recording_id)
    files = File.ls!(rec_dir)
    assert Enum.any?(files, &String.ends_with?(&1, ".a.mjr"))
    assert Enum.any?(files, &String.ends_with?(&1, ".v.mjr"))

    Enum.each(files, fn name ->
      bin = File.read!(Path.join(rec_dir, name))
      assert {:ok, map, rest} = Mjr.parse_header(bin)
      assert map["recording_id"] == c.recording_id
      assert <<"MEET", _::binary>> = rest
    end)
  end

  test "on_mix_rtp writes __mcu_mix__ audio stem" do
    c = %{ctx() | mode: :tracks_and_mix}
    assert {:ok, state} = Handler.on_start(c, %{})

    meta = %{
      publisher_id: "__mcu_mix__",
      mid: "0",
      kind: :audio,
      ssrc: 999,
      codec: "opus"
    }

    assert {:ok, state} = Handler.on_mix_rtp(c, state, meta, rtp(999))
    assert {:ok, manifest} = Handler.on_stop(c, state)
    assert length(manifest.artifacts) == 1
    assert String.contains?(hd(manifest.artifacts).path, "__mcu_mix__")
    assert String.ends_with?(hd(manifest.artifacts).path, ".a.mjr")
  end

  test "on_mix_rtp skips incomplete meta" do
    c = ctx()
    assert {:ok, state} = Handler.on_start(c, %{})
    assert {:ok, state2} = Handler.on_mix_rtp(c, state, %{kind: :audio}, rtp(1))
    assert state2.skipped_unknown >= 1
    assert {:ok, _} = Handler.on_stop(c, state2)
  end

  test "Opus and VP8 stems are always Janus-shaped (Phase 2 codec exit without tool)" do
    c = ctx()
    assert {:ok, state} = Handler.on_start(c, %{})

    assert {:ok, state} =
             Handler.on_publisher_rtp(
               c,
               state,
               %{publisher_id: "a", mid: "0", kind: :audio, ssrc: 10, codec: "opus"},
               rtp(10)
             )

    vp8 = %Rtp{
      padding: 0,
      marker: 1,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 20,
      csrcs: [],
      extension: nil,
      payload: <<0x10, 0, 0>>
    }

    assert {:ok, state} =
             Handler.on_publisher_rtp(
               c,
               state,
               %{publisher_id: "a", mid: "1", kind: :video, ssrc: 20, codec: "vp8"},
               vp8
             )

    assert {:ok, manifest} = Handler.on_stop(c, state)
    by_c =
      Map.new(manifest.artifacts, fn %{path: path} ->
        bin = File.read!(path)
        assert {:ok, map, rest} = Mjr.parse_header(bin)
        assert <<"MEET", _::binary>> = rest
        {map["c"], map["t"]}
      end)

    assert by_c["opus"] == "a"
    assert by_c["vp8"] == "v"
  end

  @layers [
    %{ssrc: 100, substream: 0, rid: "q"},
    %{ssrc: 200, substream: 1, rid: "h"}
  ]

  test "SIM keeps one video stem for highest layer; skips wrong layer and pre-keyframe" do
    c = ctx()
    assert {:ok, state} = Handler.on_start(c, %{})

    meta = fn ssrc ->
      %{
        publisher_id: "a",
        mid: "1",
        kind: :video,
        ssrc: ssrc,
        codec: "vp8",
        layers: @layers
      }
    end

    delta = %{rtp(100) | payload_type: 96, payload: <<0x10, 0x80>>}
    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta.(100), delta)
    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta.(200), delta)
    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta.(200), vp8_key_rtp(200))

    assert {:ok, manifest} = Handler.on_stop(c, state)
    assert length(manifest.artifacts) == 1
    [art] = manifest.artifacts
    assert art.kind == :video
    assert String.contains?(art.path, "_200.v.mjr")
    assert manifest.counters.skipped_wrong_layer >= 1
    assert manifest.counters.skipped_before_keyframe >= 1
  end

  test "rid override selects lower SIM stem" do
    c = ctx()
    assert {:ok, state} = Handler.on_start(c, %{"rid" => "q"})

    meta = %{
      publisher_id: "a",
      mid: "1",
      kind: :video,
      ssrc: 100,
      codec: "vp8",
      layers: @layers
    }

    assert {:ok, state} = Handler.on_publisher_rtp(c, state, meta, vp8_key_rtp(100))
    hi = %{meta | ssrc: 200}
    assert {:ok, state} = Handler.on_publisher_rtp(c, state, hi, vp8_key_rtp(200))

    assert {:ok, manifest} = Handler.on_stop(c, state)
    assert length(manifest.artifacts) == 1
    assert String.contains?(hd(manifest.artifacts).path, "_100.v.mjr")
    assert manifest.counters.skipped_wrong_layer >= 1
  end
end
