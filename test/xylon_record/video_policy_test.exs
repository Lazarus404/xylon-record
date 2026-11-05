defmodule XylonRecord.VideoPolicyTest do
  use ExUnit.Case, async: true

  alias XylonRecord.VideoPolicy

  @layers [
    %{ssrc: 100, substream: 0, rid: "q"},
    %{ssrc: 200, substream: 1, rid: "h"},
    %{ssrc: 300, substream: 2, rid: "f"}
  ]

  test "choose_sim_layer defaults to highest substream with nonzero ssrc" do
    assert %{ssrc: 300, substream: 2} = VideoPolicy.choose_sim_layer(@layers, %{})
  end

  test "rid override wins over video_layer" do
    assert %{ssrc: 100} =
             VideoPolicy.choose_sim_layer(@layers, %{rid: "q", video_layer: 2})
  end

  test "video_layer override selects substream" do
    assert %{ssrc: 200} = VideoPolicy.choose_sim_layer(@layers, %{video_layer: 1})
  end

  test "decide accepts only chosen SIM ssrc" do
    meta_hi = %{kind: :video, mid: "1", ssrc: 300, layers: @layers, codec: "vp8"}
    meta_lo = %{kind: :video, mid: "1", ssrc: 100, layers: @layers, codec: "vp8"}

    assert {:write, %{ssrc: 300, layer: 2}} = VideoPolicy.decide(meta_hi, %{})
    assert :wrong_layer = VideoPolicy.decide(meta_lo, %{})
  end

  test "decide with video_layer override" do
    meta = %{kind: :video, mid: "1", ssrc: 100, layers: @layers, codec: "vp8"}
    assert {:write, %{ssrc: 100, layer: 0}} = VideoPolicy.decide(meta, %{video_layer: 0})
  end

  test "unlearned chosen ssrc is wrong_layer not fallback" do
    layers = [%{ssrc: 100, substream: 0}, %{ssrc: 0, substream: 1}]
    meta = %{kind: :video, mid: "1", ssrc: 100, layers: layers, codec: "vp8"}
    assert :wrong_layer = VideoPolicy.decide(meta, %{})
  end

  test "svc_accept keeps max spatial then max temporal" do
    # L=1: T=0 S=0, then T=1 S=0 (new max temporal), then T=0 S=1 (new max spatial)
    p00 = <<0x20, 0x00>>
    p10 = <<0x20, 0x20>>
    p01 = <<0x20, 0x02>>

    assert {:keep, obs1, _} = VideoPolicy.svc_accept?(%{}, p00, "vp9", %{})
    assert {:keep, obs2, _} = VideoPolicy.svc_accept?(obs1, p10, "vp9", %{})
    # lower temporal on same spatial drops after max is known
    assert {:drop, obs2b} = VideoPolicy.svc_accept?(obs2, p00, "vp9", %{})
    assert {:keep, obs3, %{spatial: 1}} = VideoPolicy.svc_accept?(obs2b, p01, "vp9", %{})
    # after seeing spatial 1, spatial 0 drops
    assert {:drop, _} = VideoPolicy.svc_accept?(obs3, p00, "vp9", %{})
  end

  test "keyframe_ok waits until keyframe" do
    assert :wait_keyframe = VideoPolicy.keyframe_ok?(false, <<0x10, 0x80>>, "vp8")
    assert {:ok, true} = VideoPolicy.keyframe_ok?(false, <<0x10, 0x00>>, "vp8")
    assert {:ok, true} = VideoPolicy.keyframe_ok?(true, <<0x10, 0x80>>, "vp8")
  end

  test "unknown rid falls back to highest SIM" do
    assert %{ssrc: 300} = VideoPolicy.choose_sim_layer(@layers, %{rid: "nope"})
  end

  test "svc video_layer pins spatial" do
    p00 = <<0x20, 0x00>>
    p01 = <<0x20, 0x02>>

    assert {:keep, obs1, _} = VideoPolicy.svc_accept?(%{}, p00, "vp9", %{video_layer: 0})
    assert {:drop, _} = VideoPolicy.svc_accept?(obs1, p01, "vp9", %{video_layer: 0})
  end

  test "vp9 unparseable payload drops (no silent keep)" do
    assert {:drop, _} = VideoPolicy.svc_accept?(%{}, <<>>, "vp9", %{})
  end

  test "av1 DD sticky spatial then temporal" do
    p00 = av1_dd_rtp(spatial: 0, temporal: 0)
    p10 = av1_dd_rtp(spatial: 0, temporal: 1)
    p01 = av1_dd_rtp(spatial: 1, temporal: 0)

    assert {:keep, obs1, _} = VideoPolicy.svc_accept?(%{}, p00, "av1", %{})
    assert {:keep, obs2, _} = VideoPolicy.svc_accept?(obs1, p10, "av1", %{})
    assert {:drop, obs2b} = VideoPolicy.svc_accept?(obs2, p00, "av1", %{})
    assert {:keep, obs3, %{spatial: 1}} = VideoPolicy.svc_accept?(obs2b, p01, "av1", %{})
    assert {:drop, _} = VideoPolicy.svc_accept?(obs3, p00, "av1", %{})
  end

  test "av1 without DD has no SVC claim and keeps" do
    rtp = %XMediaLib.Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: nil,
      payload: <<0>>
    }

    assert {:keep, _, _} = VideoPolicy.svc_accept?(%{}, rtp, "av1", %{})
  end

  defp av1_dd_rtp(opts) do
    alias XMediaLib.Rtp
    alias XMediaLib.Rtp.{DependencyDescriptor, HeaderExtension}

    data =
      DependencyDescriptor.encode_structured_lab(%{
        spatial: Keyword.fetch!(opts, :spatial),
        temporal: Keyword.fetch!(opts, :temporal),
        end_of_frame?: true,
        frame_number: 1,
        active_decode_targets: 0xFF,
        dti_not_present?: false,
        structure?: false
      })

    payload = HeaderExtension.encode_one_byte_elements([{5, data}])

    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 96,
      sequence_number: 1,
      timestamp: 0,
      ssrc: 1,
      csrcs: [],
      extension: %Rtp.Extension{type: 0xBEDE, payload: payload},
      payload: <<0>>
    }
  end
end
