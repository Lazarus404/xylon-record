defmodule XylonRecord.Layout.FromStems do
  @moduledoc """
  Builds `layout.mp4` from finished `.mjr` stems beside the layout dir.

  ## What problem this solves

  Live RTP->ffmpeg layout decode is fragile on ffmpeg 9 (SDP/RTP open can stall).
  After stem writers finalize, this module remuxes up to four video stems (and
  one Opus audio stem, preferring `__mcu_mix__`) into a 2x2 H264+AAC MP4 so the
  layout artifact shows real conference media.

  ## RFCs

  No STUN/TURN/SIP RFC; input is Janus MJR / Opus / VP8 via `janus-pp-rec`.
  """

  @doc "True when `janus-pp-rec` and `ffmpeg` are on PATH (or `JANUS_PP_REC`)."
  @spec available?() :: boolean()
  def available? do
    is_binary(pp_rec()) and is_binary(System.find_executable("ffmpeg"))
  end

  @doc """
  Remuxes stems under `recording_dir` into `out_mp4`.

  Looks for `*.v.mjr` (up to 4) and prefers `*__mcu_mix__*.a.mjr` then any
  `*.a.mjr`. Returns `{:error, reason}` when tools or stems are missing.
  """
  @spec build(Path.t(), Path.t()) :: :ok | {:error, term()}
  def build(recording_dir, out_mp4)
      when is_binary(recording_dir) and is_binary(out_mp4) do
    with {:ok, pp} <- need(pp_rec(), :janus_pp_rec_missing),
         {:ok, ff} <- need(System.find_executable("ffmpeg"), :ffmpeg_missing),
         {:ok, videos} <- video_stems(recording_dir),
         {:ok, audio} <- audio_stem(recording_dir) do
      work = Path.join(recording_dir, "layout_work_#{System.unique_integer([:positive])}")
      File.mkdir_p!(work)

      try do
        video_inputs =
          videos
          |> Enum.with_index()
          |> Enum.map(fn {mjr, i} ->
            target = Path.join(work, "v#{i}.webm")
            case System.cmd(pp, [mjr, target], stderr_to_stdout: true) do
              {_, 0} ->
                if File.exists?(target), do: target, else: first_non_mjr(work, "v#{i}")

              {out, status} ->
                throw({:error, {:pp_rec_video, status, out}})
            end
          end)
          |> Enum.reject(&is_nil/1)

        audio_in =
          if is_binary(audio) do
            target = Path.join(work, "a.opus")

            case System.cmd(pp, [audio, target], stderr_to_stdout: true) do
              {_, 0} ->
                if File.exists?(target), do: target, else: first_non_mjr(work, "a")

              {out, status} ->
                throw({:error, {:pp_rec_audio, status, out}})
            end
          else
            nil
          end

        if video_inputs == [] do
          {:error, :no_video_elementary}
        else
          mux(ff, video_inputs, audio_in, out_mp4)
        end
      after
        File.rm_rf(work)
      end
    end
  catch
    {:error, reason} -> {:error, reason}
  end

  defp mux(ffmpeg, videos, audio_in, out_mp4) do
    n = length(videos)

    tiles =
      videos
      |> Enum.with_index()
      |> Enum.map_join("", fn {_p, i} ->
        "[#{i}:v]fps=30,scale=320:180:force_original_aspect_ratio=decrease," <>
          "pad=320:180:(ow-iw)/2:(oh-ih)/2,format=yuv420p,setpts=PTS-STARTPTS[t#{i}];"
      end)

    stack =
      case n do
        1 -> "[t0]format=yuv420p[v]"
        2 -> "[t0][t1]xstack=inputs=2:layout=0_0|w0_0[v]"
        3 -> "[t0][t1][t2]xstack=inputs=3:layout=0_0|w0_0|0_h0[v]"
        _ -> "[t0][t1][t2][t3]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0[v]"
      end

    filter = tiles <> stack <> audio_filter(audio_in, n)

    args =
      ["-hide_banner", "-loglevel", "error", "-y", "-fflags", "+genpts+discardcorrupt"] ++
        Enum.flat_map(videos, fn p -> ["-i", p] end) ++
        audio_args(audio_in, n) ++
        [
          "-filter_complex",
          filter,
          "-map",
          "[v]"
        ] ++
        audio_map(audio_in) ++
        [
          "-c:v",
          "libx264",
          "-preset",
          "veryfast",
          "-pix_fmt",
          "yuv420p",
          "-c:a",
          "aac",
          "-shortest",
          "-movflags",
          "+faststart",
          out_mp4
        ]

    {out, status} = System.cmd(ffmpeg, args, stderr_to_stdout: true)

    if status == 0 and File.exists?(out_mp4) and File.stat!(out_mp4).size > 500 do
      :ok
    else
      {:error, {:ffmpeg, status, out}}
    end
  end

  defp audio_args(nil, _n), do: ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=30"]
  defp audio_args(path, _n), do: ["-i", path]

  defp audio_filter(nil, n), do: ";[#{n}:a]aformat=sample_fmts=fltp:channel_layouts=stereo[a]"
  defp audio_filter(_path, n), do: ";[#{n}:a]aformat=sample_fmts=fltp:channel_layouts=stereo[a]"

  defp audio_map(_), do: ["-map", "[a]"]

  defp video_stems(dir) do
    files =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".v.mjr"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&(File.stat!(&1).size > 0))
      |> Enum.sort()
      |> Enum.take(4)

    if files == [], do: {:error, :no_video_stems}, else: {:ok, files}
  rescue
    _ -> {:error, :no_video_stems}
  end

  defp audio_stem(dir) do
    files =
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".a.mjr"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&(File.stat!(&1).size > 0))

    mix = Enum.find(files, &String.contains?(Path.basename(&1), "__mcu_mix__"))
    {:ok, mix || List.first(files)}
  rescue
    _ -> {:ok, nil}
  end

  defp first_non_mjr(work, prefix) do
    work
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.reject(&String.ends_with?(&1, ".mjr"))
    |> Enum.map(&Path.join(work, &1))
    |> Enum.find(&File.exists?/1)
  end

  defp pp_rec do
    cond do
      is_binary(System.get_env("JANUS_PP_REC")) and File.exists?(System.get_env("JANUS_PP_REC")) ->
        System.get_env("JANUS_PP_REC")

      true ->
        System.find_executable("janus-pp-rec")
    end
  end

  defp need(nil, reason), do: {:error, reason}
  defp need(path, _), do: {:ok, path}
end
