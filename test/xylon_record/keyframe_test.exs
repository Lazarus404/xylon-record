defmodule XylonRecord.KeyframeTest do
  use ExUnit.Case, async: true

  alias XylonRecord.Keyframe

  test "vp8 keyframe when P bit clear after descriptor" do
    assert Keyframe.keyframe?(<<0x10, 0x00>>, "vp8")
    refute Keyframe.keyframe?(<<0x10, 0x80>>, "vp8")
  end

  test "vp9 keyframe when P bit clear" do
    assert Keyframe.keyframe?(<<0x00>>, "vp9")
    refute Keyframe.keyframe?(<<0x40>>, "vp9")
  end

  test "h264 IDR nal" do
    assert Keyframe.keyframe?(<<0x65, 0x00>>, "h264")
    refute Keyframe.keyframe?(<<0x61, 0x00>>, "h264")
  end

  test "av1 keyframe when DD structure flag set" do
    key = av1_rtp(structure?: true)
    delta = av1_rtp(structure?: false)
    assert Keyframe.keyframe?(key, "av1")
    refute Keyframe.keyframe?(delta, "av1")
  end

  test "av1 keyframe when payload has sequence header OBU" do
    # Aggregation header + OBU_SEQUENCE_HEADER (type 1)
    assert Keyframe.keyframe?(<<0x00, 0x08>>, "av1")
    refute Keyframe.keyframe?(<<0x00, 0x30>>, "av1")
  end

  defp av1_rtp(opts) do
    alias XMediaLib.Rtp
    alias XMediaLib.Rtp.{DependencyDescriptor, HeaderExtension}

    data =
      DependencyDescriptor.encode_structured_lab(%{
        spatial: 0,
        temporal: 0,
        end_of_frame?: true,
        frame_number: 1,
        active_decode_targets: 0xFF,
        dti_not_present?: false,
        structure?: Keyword.get(opts, :structure?, false)
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
