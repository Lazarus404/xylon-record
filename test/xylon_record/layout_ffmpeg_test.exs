defmodule XylonRecord.Layout.FfmpegTest do
  use ExUnit.Case, async: false

  alias XylonRecord.Layout.Ffmpeg

  test "write_video_sdp and write_audio_sdp contain rtpmap and port" do
    dir = Path.join(System.tmp_dir!(), "sdp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    v = Path.join(dir, "v0.sdp")
    a = Path.join(dir, "a.sdp")
    :ok = Ffmpeg.write_video_sdp(v, 5004)
    :ok = Ffmpeg.write_audio_sdp(a, 5006)

    body = File.read!(v)
    assert body =~ "m=video 5004 RTP/AVP 96 97 98"
    assert body =~ "a=rtpmap:96 VP8/90000"
    assert body =~ "a=rtpmap:97 VP9/90000"
    assert body =~ "a=rtpmap:98 H264/90000"
    assert File.read!(a) =~ "m=audio 5006 RTP/AVP 111"
    assert File.read!(a) =~ "a=rtpmap:111 opus/48000/2"
  end

  test "video_pt maps vp8 vp9 h264" do
    assert Ffmpeg.video_pt() == 96
    assert Ffmpeg.video_pt("vp8") == 96
    assert Ffmpeg.video_pt("vp9") == 97
    assert Ffmpeg.video_pt("h264") == 98
    assert Ffmpeg.video_pt("av1") == nil
    assert Ffmpeg.supported_video?("vp9")
    refute Ffmpeg.supported_video?("av1")
  end

  test "write_slate produces probeable A/V mp4" do
    if is_nil(System.find_executable("ffmpeg")) do
      :ok
    else
      dir = Path.join(System.tmp_dir!(), "slate_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      out = Path.join(dir, "slate.mp4")
      assert :ok = Ffmpeg.write_slate(out, 2)
      assert File.stat!(out).size > 500

      if System.find_executable("ffprobe") do
        {json, 0} =
          System.cmd(
            "ffprobe",
            ["-v", "error", "-show_entries", "stream=codec_type", "-of", "json", out],
            stderr_to_stdout: true
          )

        assert json =~ "video"
        assert json =~ "audio"
      end
    end
  end

  test "start writes SDP files and non-zero MP4 when ffmpeg is present" do
    if is_nil(System.find_executable("ffmpeg")) do
      :ok
    else
      dir = Path.join(System.tmp_dir!(), "ff_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      video_ports = Enum.map(1..4, fn _ -> ephemeral() end)
      audio_port = ephemeral()
      out = Path.join(dir, "layout.mp4")

      assert {:ok, info} =
               Ffmpeg.start(
                 dir: dir,
                 out_mp4: out,
                 video_ports: video_ports,
                 audio_port: audio_port
               )

      for i <- 0..3 do
        assert File.exists?(Path.join(dir, "v#{i}.sdp"))
      end

      assert File.exists?(Path.join(dir, "a.sdp"))

      # Lavfi graph writes without RTP; give ffmpeg a beat then stop cleanly.
      Process.sleep(1_500)
      :ok = Ffmpeg.stop(info)
      Process.sleep(500)

      assert File.exists?(out)
      assert File.stat!(out).size > 500

      if System.find_executable("ffprobe") do
        {json, 0} =
          System.cmd(
            "ffprobe",
            [
              "-v",
              "error",
              "-show_entries",
              "stream=codec_type",
              "-of",
              "json",
              out
            ],
            stderr_to_stdout: true
          )

        assert json =~ "video"
        assert json =~ "audio"
      end
    end
  end

  defp ephemeral do
    {:ok, s} = :gen_udp.open(0, [:binary, active: false])
    {:ok, p} = :inet.port(s)
    :ok = :gen_udp.close(s)
    p
  end
end
