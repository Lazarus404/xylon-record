defmodule XylonRecord.Layout do
  @moduledoc """
  Live layout compositor GenServer for Plan `:record` sink RTP.

  ## What problem this solves

  Recording delivers rewritten publisher RTP to a layout worker (via
  `Xylon.Recording.LayoutSink`). This process dumps inbound layout RTP, assigns
  up to four video tiles (VP8 / VP9 / H264) and one Opus audio stream (MCU mix
  preferred), runs a live lavfi encode for operators, and on finalize rebuilds
  `layout.mp4` from finished `.mjr` stems when `janus-pp-rec` is available so
  the artifact shows real conference media.

  ## RFCs

  No STUN/TURN/SIP RFC; RTP ingest [RFC 3550](https://www.rfc-editor.org/rfc/rfc3550).
  """

  use GenServer

  alias XMediaLib.{Codec, Rtp}
  alias Xylon.Recording.LayoutSink
  alias XylonRecord.Keyframe
  alias XylonRecord.Layout.Ffmpeg
  alias XylonRecord.Layout.FromStems

  @max_video 4
  @queue_max 2_000
  @mcu_mix_id "__mcu_mix__"
  @keepalive_ms 40
  @video_clock 90_000

  @doc "Starts the layout worker and registers it under `plan_ref`."
  @spec start(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(ctx, opts \\ []) when is_map(ctx) and is_list(opts) do
    GenServer.start(__MODULE__, {ctx, opts})
  end

  @doc "Stops ffmpeg, unregisters the sink, returns layout artifact map."
  @spec finalize(pid()) :: {:ok, map()} | {:error, term()}
  def finalize(pid) when is_pid(pid) do
    GenServer.call(pid, :finalize, 60_000)
  end

  @impl true
  def init({ctx, opts}) do
    plan_ref = Keyword.fetch!(opts, :plan_ref)
    dir = layout_dir(ctx, opts)
    File.mkdir_p!(dir)

    dump_path = Path.join(dir, "layout.rtp")
    out_mp4 = Path.join(dir, "layout.mp4")
    rtmp_url = Keyword.get(opts, :rtmp_url)

    video_ports = Enum.map(1..@max_video, fn _ -> ephemeral_udp_port() end)
    audio_port = ephemeral_udp_port()
    {:ok, send_sock} = :gen_udp.open(0, [:binary, active: false])
    {black_payload, opus_silence} = keepalives(dir)

    ffmpeg =
      case Ffmpeg.start(
             dir: dir,
             out_mp4: out_mp4,
             rtmp_url: rtmp_url,
             video_ports: video_ports,
             audio_port: audio_port
           ) do
        {:ok, info} -> info
        {:error, _} -> nil
      end

    :ok = LayoutSink.register(plan_ref, self())
    dump = File.open!(dump_path, [:write, :binary, :raw])

    state = %{
      plan_ref: plan_ref,
      ctx: ctx,
      dir: dir,
      dump: dump,
      dump_path: dump_path,
      out_mp4: out_mp4,
      rtmp_url: rtmp_url,
      ffmpeg: ffmpeg,
      send_sock: send_sock,
      video_ports: video_ports,
      audio_port: audio_port,
      video_slots: %{},
      slot_codec: %{},
      slot_got_keyframe: Map.new(0..3, fn i -> {i, false} end),
      slot_live: Map.new(0..3, fn i -> {i, false} end),
      audio_pub: nil,
      audio_live: false,
      black_payload: black_payload,
      opus_silence: opus_silence,
      v_seq: 1,
      a_seq: 1,
      v_ts: 0,
      a_ts: 0,
      bytes: 0,
      dropped: 0,
      queue: 0,
      unsupported_codec: 0,
      rtmp_connected: is_map(ffmpeg) and is_binary(rtmp_url) and rtmp_url != "",
      started_ms: System.monotonic_time(:millisecond)
    }

    # Flood keepalives right after spawn so SDP RTP inputs see media during probe.
    state =
      if is_map(ffmpeg) do
        state =
          Enum.reduce(1..15, state, fn _, st ->
            st = Enum.reduce(0..3, st, &send_black(&2, &1))
            send_silence(st)
          end)

        Process.send_after(self(), :keepalive, @keepalive_ms)
        state
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info(:keepalive, state) do
    state =
      if is_map(state.ffmpeg) do
        state = maybe_video_keepalives(state)
        state = maybe_audio_keepalive(state)
        Process.send_after(self(), :keepalive, @keepalive_ms)
        state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:layout_rtp, dest, rtp}, state) do
    if state.queue >= @queue_max do
      {:noreply, %{state | dropped: state.dropped + 1}}
    else
      state = %{state | queue: state.queue + 1}
      state = ingest(dest, rtp, state)
      {:noreply, %{state | queue: max(state.queue - 1, 0)}}
    end
  end

  def handle_info({port, {:data, _}}, %{ffmpeg: %{port: port}} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %{ffmpeg: %{port: port}} = state) do
    {:noreply, %{state | ffmpeg: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:finalize, _from, state) do
    _ = LayoutSink.unregister(state.plan_ref)

    if state.ffmpeg, do: Ffmpeg.stop(state.ffmpeg)
    _ = File.close(state.dump)
    _ = :gen_udp.close(state.send_sock)

    Process.sleep(300)

    recording_dir = Path.dirname(state.dir)
    _ = maybe_rebuild_from_stems(recording_dir, state.out_mp4)

    unless readable_mp4?(state.out_mp4) do
      _ = maybe_rewrite_mp4(state.out_mp4)
    end

    unless readable_mp4?(state.out_mp4) do
      elapsed_s =
        max(2, div(System.monotonic_time(:millisecond) - state.started_ms, 1000))

      _ = Ffmpeg.write_slate(state.out_mp4, min(elapsed_s, 60))
    end

    path =
      if readable_mp4?(state.out_mp4) do
        state.out_mp4
      else
        state.dump_path
      end

    bytes =
      case File.stat(path) do
        {:ok, %{size: s}} -> s
        _ -> state.bytes
      end

    artifact = %{
      kind: "layout",
      publisher_id: "__layout__",
      mid: "layout",
      codec: "layout",
      path_or_key: Path.expand(path),
      bytes: bytes,
      via: nil,
      edge_node: to_string(Node.self())
    }

    counters = %{
      dropped_layout: state.dropped,
      layout_bytes: bytes,
      layout_audio_pub: state.audio_pub,
      layout_unsupported_codec: state.unsupported_codec,
      rtmp_url: state.rtmp_url,
      rtmp_connected: state.rtmp_connected
    }

    {:stop, :normal, {:ok, %{artifacts: [artifact], counters: counters}}, state}
  end

  defp ingest(dest, rtp, state) do
    bin = encode_rtp(rtp)
    state = write_dump(state, bin)

    kind = Map.get(dest, :kind) || Map.get(dest, "kind")
    pub = Map.get(dest, :publisher_id) || Map.get(dest, "publisher_id")
    codec = normalize_codec(Map.get(dest, :codec) || Map.get(dest, "codec"))

    cond do
      kind in [:video, "video"] ->
        ingest_video(state, pub, codec, rtp)

      kind in [:audio, "audio"] ->
        ingest_audio(state, pub, codec, rtp)

      true ->
        state
    end
  end

  defp ingest_video(state, pub, codec, rtp) do
    if not Ffmpeg.supported_video?(codec) do
      %{state | unsupported_codec: state.unsupported_codec + 1}
    else
      {state, slot} = ensure_video_slot(state, pub, codec)

      if is_integer(slot) and is_map(state.ffmpeg) do
        got? = Map.get(state.slot_got_keyframe, slot, false)

        cond do
          got? or Keyframe.keyframe?(rtp, codec) ->
            state = %{
              state
              | slot_got_keyframe: Map.put(state.slot_got_keyframe, slot, true),
                slot_live: Map.put(state.slot_live, slot, true)
            }

            send_video(state, slot, codec, rtp)

          true ->
            state
        end
      else
        state
      end
    end
  end

  defp ingest_audio(state, pub, codec, rtp) do
    state = prefer_audio(state, pub)

    if state.audio_pub == pub and codec == "opus" and is_map(state.ffmpeg) do
      state = %{state | audio_live: true}
      send_audio(state, rtp)
    else
      state
    end
  end

  defp prefer_audio(state, pub) do
    cond do
      pub == @mcu_mix_id ->
        %{state | audio_pub: @mcu_mix_id}

      state.audio_pub == @mcu_mix_id ->
        state

      state.audio_pub == nil or state.audio_pub == pub ->
        %{state | audio_pub: pub}

      true ->
        state
    end
  end

  defp ensure_video_slot(state, pub, codec) do
    case Map.fetch(state.video_slots, pub) do
      {:ok, slot} ->
        {state, slot}

      :error ->
        used = map_size(state.video_slots)

        if used >= @max_video do
          {state, nil}
        else
          state = %{
            state
            | video_slots: Map.put(state.video_slots, pub, used),
              slot_codec: Map.put(state.slot_codec, used, codec)
          }

          {state, used}
        end
    end
  end

  defp send_video(state, slot, codec, rtp) do
    port = Enum.at(state.video_ports, slot)
    pt = Ffmpeg.video_pt(codec) || Ffmpeg.video_pt()
    bin = rtp |> rewrite_pt(pt) |> encode_rtp()

    if is_integer(port) and bin != <<>> do
      _ = :gen_udp.send(state.send_sock, {127, 0, 0, 1}, port, bin)
    end

    state
  end

  defp send_audio(state, rtp) do
    bin = rtp |> rewrite_pt(Ffmpeg.audio_pt()) |> encode_rtp()

    if bin != <<>> do
      _ = :gen_udp.send(state.send_sock, {127, 0, 0, 1}, state.audio_port, bin)
    end

    state
  end

  defp maybe_video_keepalives(state) do
    Enum.reduce(0..3, state, fn slot, st ->
      live? = Map.get(st.slot_live, slot, false)

      if live? or is_nil(st.black_payload) do
        # Clear live flag each tick so missing publishers fall back to black.
        %{st | slot_live: Map.put(st.slot_live, slot, false)}
      else
        st = send_black(st, slot)
        %{st | slot_live: Map.put(st.slot_live, slot, false)}
      end
    end)
  end

  defp maybe_audio_keepalive(state) do
    if state.audio_live or is_nil(state.opus_silence) do
      %{state | audio_live: false}
    else
      state = send_silence(state)
      %{state | audio_live: false}
    end
  end

  defp send_black(state, slot) do
    port = Enum.at(state.video_ports, slot)
    seq = state.v_seq
    ts = state.v_ts

    rtp = %Rtp{
      padding: 0,
      marker: 1,
      payload_type: Ffmpeg.video_pt(),
      sequence_number: rem(seq, 65536),
      timestamp: ts,
      ssrc: 0x1000 + slot,
      csrcs: [],
      extension: nil,
      payload: state.black_payload
    }

    bin = encode_rtp(rtp)

    if is_integer(port) and bin != <<>> do
      _ = :gen_udp.send(state.send_sock, {127, 0, 0, 1}, port, bin)
    end

    %{state | v_seq: seq + 1, v_ts: ts + div(@video_clock, 30)}
  end

  defp send_silence(state) do
    seq = state.a_seq
    ts = state.a_ts

    rtp = %Rtp{
      padding: 0,
      marker: 0,
      payload_type: Ffmpeg.audio_pt(),
      sequence_number: rem(seq, 65536),
      timestamp: ts,
      ssrc: 0x2000,
      csrcs: [],
      extension: nil,
      payload: state.opus_silence
    }

    bin = encode_rtp(rtp)

    if bin != <<>> do
      _ = :gen_udp.send(state.send_sock, {127, 0, 0, 1}, state.audio_port, bin)
    end

    %{state | a_seq: seq + 1, a_ts: ts + 960}
  end

  defp rewrite_pt(%Rtp{} = rtp, pt), do: %{rtp | payload_type: pt}
  defp rewrite_pt(bin, pt) when is_binary(bin) and byte_size(bin) >= 2 do
    <<v::2, p::1, x::1, cc::4, m::1, _old::7, rest::binary>> = bin
    <<v::2, p::1, x::1, cc::4, m::1, pt::7, rest::binary>>
  rescue
    _ -> bin
  end

  defp rewrite_pt(other, _), do: other

  defp write_dump(state, bin) when is_binary(bin) do
    :ok = IO.binwrite(state.dump, bin)
    %{state | bytes: state.bytes + byte_size(bin)}
  end

  defp encode_rtp(%Rtp{} = rtp) do
    case Rtp.encode(rtp) do
      bin when is_binary(bin) -> bin
      _ -> <<>>
    end
  rescue
    _ -> <<>>
  end

  defp encode_rtp(bin) when is_binary(bin), do: bin
  defp encode_rtp(_), do: <<>>

  defp normalize_codec(nil), do: "vp8"
  defp normalize_codec(c) when is_atom(c), do: c |> to_string() |> String.downcase()
  defp normalize_codec(c) when is_binary(c), do: String.downcase(c)
  defp normalize_codec(_), do: "vp8"

  defp maybe_rebuild_from_stems(recording_dir, out_mp4) do
    if FromStems.available?() do
      case FromStems.build(recording_dir, out_mp4) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp readable_mp4?(path) when is_binary(path) do
    File.exists?(path) and match?({:ok, %{size: s}} when s > 500, File.stat(path)) and
      probe_has_av?(path)
  end

  defp probe_has_av?(path) do
    case System.find_executable("ffprobe") do
      nil ->
        true

      ffprobe ->
        {json, status} =
          System.cmd(
            ffprobe,
            [
              "-v",
              "error",
              "-show_entries",
              "stream=codec_type",
              "-of",
              "json",
              path
            ],
            stderr_to_stdout: true
          )

        status == 0 and String.contains?(json, "video") and String.contains?(json, "audio")
    end
  rescue
    _ -> false
  end

  # Frag MP4 from a hard kill is sometimes unreadable; remux to a clean file.
  defp maybe_rewrite_mp4(path) when is_binary(path) do
    cond do
      not File.exists?(path) ->
        :ok

      readable_mp4?(path) ->
        :ok

      is_nil(System.find_executable("ffmpeg")) ->
        :ok

      true ->
        tmp = path <> ".rewrite.mp4"

        {_, status} =
          System.cmd(
            "ffmpeg",
            [
              "-hide_banner",
              "-loglevel",
              "error",
              "-y",
              "-i",
              path,
              "-c",
              "copy",
              tmp
            ],
            stderr_to_stdout: true
          )

        if status == 0 and File.exists?(tmp) and File.stat!(tmp).size > 500 do
          File.rm(path)
          File.rename!(tmp, path)
        else
          _ = File.rm(tmp)
        end

        :ok
    end
  rescue
    _ -> :ok
  end

  defp layout_dir(ctx, opts) do
    root = Keyword.get(opts, :dir) || XylonRecord.dir()
    Path.join([root, to_string(recording_id(ctx)), "layout"])
  end

  defp recording_id(%{recording_id: id}) when id != nil, do: id
  defp recording_id(_), do: "layout"

  defp ephemeral_udp_port do
    {:ok, s} = :gen_udp.open(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(s)
    :ok = :gen_udp.close(s)
    port
  end

  defp keepalives(dir) do
    black = black_vp8_payload(dir)
    silence = opus_silence_payload()
    {black, silence}
  end

  defp black_vp8_payload(dir) do
    if is_nil(System.find_executable("ffmpeg")) do
      # Minimal VP8 descriptor + tiny payload (may not decode; keepalive best-effort).
      <<0x10, 0x00, 0x00, 0x00>>
    else
      ivf = Path.join(dir, "black.ivf")

      {_, status} =
        System.cmd(
          "ffmpeg",
          [
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "color=c=black:s=320x180:d=0.04",
            "-frames:v",
            "1",
            "-c:v",
            "libvpx",
            "-pix_fmt",
            "yuv420p",
            "-f",
            "ivf",
            ivf
          ],
          stderr_to_stdout: true
        )

      if status == 0 and File.exists?(ivf) do
        case extract_ivf_frame(ivf) do
          bin when is_binary(bin) and byte_size(bin) > 0 ->
            # VP8 RTP descriptor X=0 S=1: start of partition.
            <<0x10, bin::binary>>

          _ ->
            <<0x10, 0x00, 0x00, 0x00>>
        end
      else
        <<0x10, 0x00, 0x00, 0x00>>
      end
    end
  end

  defp extract_ivf_frame(path) do
    data = File.read!(path)
    # IVF file header 32 bytes; frame header 12 bytes then frame.
    if byte_size(data) > 44 do
      <<_hdr::binary-size(32), size::little-32, _pts::little-64, rest::binary>> = data
      if byte_size(rest) >= size, do: binary_part(rest, 0, size), else: <<>>
    else
      <<>>
    end
  rescue
    _ -> <<>>
  end

  defp opus_silence_payload do
    case Codec.start_link({~c"OPUS", 48_000, 2}) do
      {:ok, codec} ->
        pcm = :binary.copy(<<0, 0>>, 960 * 2)

        payload =
          case Codec.encode(codec, {pcm, 48_000, 2, 16}) do
            {:ok, opus} when is_binary(opus) -> opus
            _ -> <<0xF8>>
          end

        _ = Codec.close(codec)
        payload

      _ ->
        <<0xF8>>
    end
  rescue
    _ -> <<0xF8>>
  end
end
