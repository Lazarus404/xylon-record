defmodule XylonRecord.LayoutAudioPreferTest do
  use ExUnit.Case, async: false

  alias XMediaLib.Rtp
  alias Xylon.Recording.LayoutSink
  alias XylonRecord.Layout

  setup do
    :ok = LayoutSink.ensure_table!()
    dir = Path.join(System.tmp_dir!(), "lay_aud_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp rtp(ssrc) do
    %Rtp{
      padding: 0,
      marker: 0,
      payload_type: 111,
      sequence_number: 1,
      timestamp: 0,
      ssrc: ssrc,
      csrcs: [],
      extension: nil,
      payload: <<1, 2, 3>>
    }
  end

  test "prefers __mcu_mix__ over first publisher audio", %{dir: dir} do
    plan_ref = self()

    assert {:ok, pid} =
             Layout.start(%{recording_id: "aud-prefer"},
               plan_ref: plan_ref,
               dir: dir
             )

    LayoutSink.ingest(
      %{
        type: :record,
        plan_ref: plan_ref,
        publisher_id: "alice",
        mid: "0",
        kind: :audio,
        codec: "opus"
      },
      rtp(1)
    )

    LayoutSink.ingest(
      %{
        type: :record,
        plan_ref: plan_ref,
        publisher_id: "__mcu_mix__",
        mid: "0",
        kind: :audio,
        codec: "opus"
      },
      rtp(2)
    )

    Process.sleep(50)
    assert {:ok, %{counters: counters}} = Layout.finalize(pid)
    assert counters.layout_audio_pub == "__mcu_mix__"
  end

  test "unsupported video codec increments counter", %{dir: dir} do
    plan_ref = self()

    assert {:ok, pid} =
             Layout.start(%{recording_id: "bad-codec"}, plan_ref: plan_ref, dir: dir)

    LayoutSink.ingest(
      %{
        type: :record,
        plan_ref: plan_ref,
        publisher_id: "cam",
        mid: "1",
        kind: :video,
        codec: "av1"
      },
      %Rtp{
        padding: 0,
        marker: 1,
        payload_type: 96,
        sequence_number: 1,
        timestamp: 0,
        ssrc: 9,
        csrcs: [],
        extension: nil,
        payload: <<0x10, 0, 0>>
      }
    )

    Process.sleep(30)
    assert {:ok, %{counters: c}} = Layout.finalize(pid)
    assert c.layout_unsupported_codec >= 1
  end

  test "vp9 is a supported layout video codec", %{dir: dir} do
    plan_ref = self()

    assert {:ok, pid} =
             Layout.start(%{recording_id: "vp9-ok"}, plan_ref: plan_ref, dir: dir)

    # VP9 keyframe: I bit set in first octet after descriptor (P=0).
    LayoutSink.ingest(
      %{
        type: :record,
        plan_ref: plan_ref,
        publisher_id: "cam",
        mid: "1",
        kind: :video,
        codec: "vp9"
      },
      %Rtp{
        padding: 0,
        marker: 1,
        payload_type: 97,
        sequence_number: 1,
        timestamp: 0,
        ssrc: 9,
        csrcs: [],
        extension: nil,
        payload: <<0x80, 0x00, 0x00>>
      }
    )

    Process.sleep(30)
    assert {:ok, %{counters: c}} = Layout.finalize(pid)
    assert c.layout_unsupported_codec == 0
  end
end
