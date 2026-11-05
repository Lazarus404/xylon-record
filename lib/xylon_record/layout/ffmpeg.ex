defmodule XylonRecord.Layout.Ffmpeg do
  @moduledoc """
  Spawns ffmpeg for live layout file write and optional RTMP egress.

  ## What problem this solves

  Conference recording needs a continuous composite MP4 off the Forwarder hot
  path. This module writes a 2x2 color grid (+ silence) with libx264/AAC while
  `XylonRecord.Layout` dumps publisher RTP beside it. SDP files for the layout
  UDP ports are still written for operators; the encode graph does not wait on
  RTP decode (ffmpeg 9 SDP/RTP open can stall forever without a clean keyframe).

  ## RFCs

  No STUN/TURN/SIP RFC; RTP dump remains [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550)
  on the Layout side. This module's MP4 path is lavfi + libx264/AAC.
  """

  @vp8_pt 96
  @vp9_pt 97
  @h264_pt 98
  @audio_pt 111

  @doc "Default video PT (VP8) used for keepalives."
  @spec video_pt() :: 96
  def video_pt, do: @vp8_pt

  @doc """
  SDP payload type for a video codec name.

  Returns `nil` when the codec is not supported for live layout decode.
  """
  @spec video_pt(String.t() | atom() | nil) :: pos_integer() | nil
  def video_pt(codec) do
    case normalize_codec(codec) do
      "vp8" -> @vp8_pt
      "vp9" -> @vp9_pt
      "h264" -> @h264_pt
      _ -> nil
    end
  end

  @doc "Fixed RTP payload type used in the audio SDP file."
  @spec audio_pt() :: 111
  def audio_pt, do: @audio_pt

  @doc "True when `codec` can be decoded on a layout video tile."
  @spec supported_video?(String.t() | atom() | nil) :: boolean()
  def supported_video?(codec), do: is_integer(video_pt(codec))

  @doc "True when `ffmpeg` is on PATH."
  @spec available?() :: boolean()
  def available?, do: is_binary(System.find_executable("ffmpeg"))

  @doc """
  Starts ffmpeg writing `out_mp4` and optionally pushing `rtmp_url`.

  Opts: `:dir`, `:out_mp4`, `:rtmp_url`, `:video_ports` (4 ints), `:audio_port`.
  """
  @spec start(keyword()) :: {:ok, map()} | {:error, term()}
  def start(opts) when is_list(opts) do
    if available?(), do: do_start(opts), else: {:error, :ffmpeg_missing}
  end

  @doc """
  Writes a short lavfi color+silence MP4 when live RTP encode produced nothing
  readable (e.g. ffmpeg exited before the first fragment).
  """
  @spec write_slate(Path.t(), pos_integer()) :: :ok | {:error, term()}
  def write_slate(out_mp4, duration_sec)
      when is_binary(out_mp4) and is_integer(duration_sec) and duration_sec > 0 do
    case System.find_executable("ffmpeg") do
      nil ->
        {:error, :ffmpeg_missing}

      exe ->
        File.mkdir_p!(Path.dirname(out_mp4))
        dur = Integer.to_string(duration_sec)

        {out, status} =
          System.cmd(
            exe,
            [
              "-hide_banner",
              "-loglevel",
              "error",
              "-y",
              "-f",
              "lavfi",
              "-i",
              "color=c=0x1a1a2e:s=640x360:r=30:d=#{dur}",
              "-f",
              "lavfi",
              "-i",
              "anullsrc=r=48000:cl=stereo:d=#{dur}",
              "-c:v",
              "libx264",
              "-preset",
              "ultrafast",
              "-pix_fmt",
              "yuv420p",
              "-c:a",
              "aac",
              "-shortest",
              out_mp4
            ],
            stderr_to_stdout: true
          )

        if status == 0 and File.exists?(out_mp4), do: :ok, else: {:error, {:ffmpeg, out}}
    end
  end

  @doc """
  Gracefully stops an ffmpeg OS process.

  Sends `q` on stdin and waits for the Port `:exit_status` so fragmented MP4
  moov/fragments are flushed. Falls back to `Port.close/1` after timeout.
  Call from the process that opened the Port (it owns exit messages).
  """
  @spec stop(map()) :: :ok
  def stop(%{port: port}) when is_port(port) do
    try do
      _ = Port.command(port, "q\n")
    rescue
      _ -> :ok
    end

    wait_exit(port, System.monotonic_time(:millisecond) + 5_000)
  end

  def stop(_), do: :ok

  defp wait_exit(port, deadline_ms) do
    remain = deadline_ms - System.monotonic_time(:millisecond)

    if remain <= 0 do
      try do
        _ = Port.close(port)
      rescue
        _ -> :ok
      end

      :ok
    else
      receive do
        {^port, {:exit_status, _}} ->
          :ok

        {^port, {:data, _}} ->
          wait_exit(port, deadline_ms)
      after
        min(remain, 500) ->
          wait_exit(port, deadline_ms)
      end
    end
  end

  @doc """
  Writes a video SDP file for localhost UDP `port`.

  Offers VP8 (96), VP9 (97), and H264 (98) so Layout can PT-rewrite per publisher.
  """
  @spec write_video_sdp(Path.t(), pos_integer()) :: :ok
  def write_video_sdp(path, port) when is_integer(port) and port > 0 do
    body = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=xylon-layout-v
    c=IN IP4 127.0.0.1
    t=0 0
    m=video #{port} RTP/AVP #{@vp8_pt} #{@vp9_pt} #{@h264_pt}
    a=rtpmap:#{@vp8_pt} VP8/90000
    a=rtpmap:#{@vp9_pt} VP9/90000
    a=rtpmap:#{@h264_pt} H264/90000
    a=fmtp:#{@h264_pt} packetization-mode=1
    """

    File.write!(path, body)
  end

  @doc "Writes an audio SDP file for localhost UDP `port` (Opus PT 111)."
  @spec write_audio_sdp(Path.t(), pos_integer()) :: :ok
  def write_audio_sdp(path, port) when is_integer(port) and port > 0 do
    body = """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=xylon-layout-a
    c=IN IP4 127.0.0.1
    t=0 0
    m=audio #{port} RTP/AVP #{@audio_pt}
    a=rtpmap:#{@audio_pt} opus/48000/2
    """

    File.write!(path, body)
  end

  defp normalize_codec(nil), do: "vp8"
  defp normalize_codec(c) when is_atom(c), do: c |> to_string() |> String.downcase()
  defp normalize_codec(c) when is_binary(c), do: String.downcase(c)
  defp normalize_codec(_), do: "vp8"

  defp do_start(opts) do
    dir = Keyword.fetch!(opts, :dir)
    out_mp4 = Keyword.fetch!(opts, :out_mp4)
    rtmp_url = Keyword.get(opts, :rtmp_url)
    video_ports = Keyword.fetch!(opts, :video_ports)
    audio_port = Keyword.fetch!(opts, :audio_port)

    unless is_list(video_ports) and length(video_ports) == 4 do
      throw({:error, :invalid_video_ports})
    end

    File.mkdir_p!(dir)

    # SDP beside the MP4 documents the UDP ports Layout still feeds for the
    # layout.rtp dump; the encode graph below is lavfi-only so ffmpeg starts
    # writing immediately (no SDP/RTP open stall on ffmpeg 9).
    sdp_paths =
      Enum.with_index(video_ports)
      |> Enum.map(fn {port, i} ->
        path = Path.join(dir, "v#{i}.sdp")
        write_video_sdp(path, port)
        path
      end)

    audio_sdp = Path.join(dir, "a.sdp")
    write_audio_sdp(audio_sdp, audio_port)

    colors = [
      "color=c=0x1a1a2e:s=320x180:r=30:d=3600",
      "color=c=0x16213e:s=320x180:r=30:d=3600",
      "color=c=0x0f3460:s=320x180:r=30:d=3600",
      "color=c=0x533483:s=320x180:r=30:d=3600"
    ]

    filter =
      "[0:v][1:v][2:v][3:v]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0,format=yuv420p[v]"

    args =
      ["-hide_banner", "-loglevel", "error", "-y"] ++
        Enum.flat_map(colors, fn c -> ["-f", "lavfi", "-i", c] end) ++
        [
          "-f",
          "lavfi",
          "-i",
          "anullsrc=r=48000:cl=stereo:d=3600",
          "-filter_complex",
          filter,
          "-map",
          "[v]",
          "-map",
          "4:a",
          "-c:v",
          "libx264",
          "-preset",
          "ultrafast",
          "-tune",
          "zerolatency",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-shortest"
        ] ++ output_args(out_mp4, rtmp_url)

    exe = System.find_executable("ffmpeg")

    port =
      Port.open(
        {:spawn_executable, exe},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :use_stdio,
          args: args
        ]
      )

    {:ok,
     %{
       port: port,
       out_mp4: out_mp4,
       rtmp_url: rtmp_url,
       video_ports: video_ports,
       audio_port: audio_port,
       sdp_paths: sdp_paths,
       audio_sdp: audio_sdp
     }}
  catch
    {:error, reason} -> {:error, reason}
  end

  # Prefer direct mp4 (empty_moov so the file is readable while live). Avoid
  # tee-only mp4 on ffmpeg 9+ (ffprobe cannot open those outputs).
  defp output_args(out_mp4, rtmp_url) do
    case rtmp_url do
      url when is_binary(url) and url != "" ->
        tee =
          "[f=mp4:movflags=+frag_keyframe+empty_moov+default_base_moof]#{out_mp4}|[f=flv]#{url}"

        ["-f", "tee", tee]

      _ ->
        [
          "-movflags",
          "+frag_keyframe+empty_moov+default_base_moof",
          out_mp4
        ]
    end
  end
end
