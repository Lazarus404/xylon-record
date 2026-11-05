defmodule XylonRecord.Writer do
  @moduledoc """
  Per-recording GenServer that writes `.mjr` stems to storage.

  ## What problem this solves

  Publisher RTP arrives on the SFU hot path and must not block on disk.
  `XylonRecord.Handler` casts frames here; this process encodes RTP, opens
  stems lazily, appends MJR00002 frames, and finalizes files on stop.
  Video stems apply Phase 5 layer + keyframe policy (one stem per mid).

  ## RFCs

  No STUN/TURN/SIP RFC; Janus MJR00002 writer process.
  """
  use GenServer

  require Logger

  alias XMediaLib.Rtp
  alias Xylon.Recording.Ctx
  alias XylonRecord.{Mjr, VideoPolicy}

  @doc "Starts a Writer for one recording context (not linked to the caller)."
  @spec start(Ctx.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%Ctx{} = ctx, opts \\ []) do
    GenServer.start(__MODULE__, {ctx, opts})
  end

  @doc "Enqueues one publisher RTP frame (non-blocking cast)."
  @spec enqueue(pid(), map(), term(), integer()) :: :ok
  def enqueue(pid, meta, rtp, recv_ms)
      when is_pid(pid) and is_map(meta) and is_integer(recv_ms) do
    GenServer.cast(pid, {:frame, meta, rtp, recv_ms})
  end

  @doc "Flushes and closes all stems; returns artifact manifest + counters."
  @spec finalize(pid()) :: {:ok, map()} | {:error, term()}
  def finalize(pid) when is_pid(pid) do
    GenServer.call(pid, :finalize, 30_000)
  end

  @impl true
  def init({%Ctx{} = ctx, opts}) do
    storage = Keyword.get(opts, :storage, XylonRecord.storage())
    root = Keyword.get(opts, :dir, XylonRecord.dir())
    rec_dir = Path.join(root, ctx.recording_id)
    storage.mkdir!(rec_dir)

    override = %{
      video_layer: Keyword.get(opts, :video_layer),
      rid: Keyword.get(opts, :rid)
    }

    {:ok,
     %{
       ctx: ctx,
       storage: storage,
       dir: rec_dir,
       stems: %{},
       created_us: System.system_time(:microsecond),
       packets: 0,
       bytes: 0,
       gaps: 0,
       skipped_unknown: 0,
       skipped_before_keyframe: 0,
       skipped_wrong_layer: 0,
       override: override,
       svc_obs: %{},
       keyframe_seen: %{}
     }}
  end

  @impl true
  def handle_cast({:frame, meta, rtp, recv_ms}, state) do
    kind = Map.get(meta, :kind) || Map.get(meta, "kind")

    case kind do
      :video ->
        handle_video_frame(meta, rtp, recv_ms, state)

      :audio ->
        handle_audio_frame(meta, rtp, recv_ms, state)

      _ ->
        {:noreply, %{state | skipped_unknown: state.skipped_unknown + 1}}
    end
  end

  @impl true
  def handle_call(:finalize, _from, state) do
    artifacts =
      Enum.map(state.stems, fn {_key, stem} ->
        _ = state.storage.close(stem.handle)
        path = Path.expand(stem.path)

        %{
          path: path,
          path_or_key: path,
          packets: stem.packets,
          bytes: stem.bytes,
          kind: stem.kind,
          publisher_id: stem.publisher_id,
          mid: stem.mid,
          codec: stem.codec,
          via: stem.via,
          edge_node: stem.edge_node,
          layer: Map.get(stem, :layer),
          rid: Map.get(stem, :rid)
        }
      end)

    manifest = %{
      artifacts: artifacts,
      counters: %{
        packets: state.packets,
        bytes: state.bytes,
        gaps: state.gaps,
        skipped_unknown: state.skipped_unknown,
        skipped_before_keyframe: state.skipped_before_keyframe,
        skipped_wrong_layer: state.skipped_wrong_layer
      },
      dir: state.dir,
      recording_id: state.ctx.recording_id
    }

    {:stop, :normal, {:ok, manifest}, %{state | stems: %{}}}
  end

  defp handle_audio_frame(meta, rtp, recv_ms, state) do
    case stem_key_audio(meta) do
      {:ok, key, codec} ->
        write_accepted(state, key, :audio, codec, meta, rtp, recv_ms, %{})

      :skip ->
        {:noreply, %{state | skipped_unknown: state.skipped_unknown + 1}}
    end
  end

  defp handle_video_frame(meta, rtp, recv_ms, state) do
    override = state.override || %{}
    codec = Map.get(meta, :codec) || Map.get(meta, "codec")

    case VideoPolicy.decide(meta, override) do
      :skip ->
        {:noreply, %{state | skipped_unknown: state.skipped_unknown + 1}}

      :wrong_layer ->
        {:noreply, %{state | skipped_wrong_layer: state.skipped_wrong_layer + 1}}

      {:write, info} ->
        maybe_write_video(state, meta, rtp, recv_ms, codec, info)

      {:svc, _info} ->
        mid = Map.get(meta, :mid) || Map.get(meta, "mid")
        pub = Map.get(meta, :publisher_id) || Map.get(meta, "publisher_id")
        obs_key = {pub, mid}
        obs = Map.get(state.svc_obs, obs_key, %{})

        case VideoPolicy.svc_accept?(obs, rtp, codec, override) do
          {:drop, obs2} ->
            {:noreply,
             %{
               state
               | svc_obs: Map.put(state.svc_obs, obs_key, obs2),
                 skipped_wrong_layer: state.skipped_wrong_layer + 1
             }}

          {:keep, obs2, info} ->
            state = %{state | svc_obs: Map.put(state.svc_obs, obs_key, obs2)}
            maybe_write_video(state, meta, rtp, recv_ms, codec, info)
        end
    end
  end

  defp maybe_write_video(state, meta, rtp, recv_ms, codec, info) do
    case stem_key_video(meta) do
      {:ok, key, norm_codec} ->
        seen? = Map.get(state.keyframe_seen, key, false)

        case VideoPolicy.keyframe_ok?(seen?, rtp, codec || norm_codec) do
          :wait_keyframe ->
            {:noreply, %{state | skipped_before_keyframe: state.skipped_before_keyframe + 1}}

          {:ok, true} ->
            state = %{state | keyframe_seen: Map.put(state.keyframe_seen, key, true)}
            write_accepted(state, key, :video, norm_codec, meta, rtp, recv_ms, info)
        end

      :skip ->
        {:noreply, %{state | skipped_unknown: state.skipped_unknown + 1}}
    end
  end

  defp write_accepted(state, key, kind, codec, meta, rtp, recv_ms, info) do
    case ensure_stem(state, key, kind, codec, meta, info) do
      {:ok, state2, stem} ->
        case write_frame(state2, key, stem, rtp, recv_ms) do
          {:ok, state3} ->
            {:noreply, state3}

          {:error, reason} ->
            Logger.warning("xylon_record write failed: #{inspect(reason)}")
            {:noreply, state2}
        end

      {:error, _} ->
        {:noreply, %{state | skipped_unknown: state.skipped_unknown + 1}}
    end
  end

  defp stem_key_audio(meta) do
    mid = Map.get(meta, :mid) || Map.get(meta, "mid")
    ssrc = Map.get(meta, :ssrc) || Map.get(meta, "ssrc")
    publisher_id = Map.get(meta, :publisher_id) || Map.get(meta, "publisher_id")
    codec = Map.get(meta, :codec) || Map.get(meta, "codec")

    cond do
      not is_binary(mid) or mid == "" -> :skip
      not is_integer(ssrc) -> :skip
      true -> {:ok, {publisher_id, mid, ssrc, :audio}, normalize_codec(codec, :audio)}
    end
  end

  defp stem_key_video(meta) do
    mid = Map.get(meta, :mid) || Map.get(meta, "mid")
    publisher_id = Map.get(meta, :publisher_id) || Map.get(meta, "publisher_id")
    codec = Map.get(meta, :codec) || Map.get(meta, "codec")

    cond do
      not is_binary(mid) or mid == "" -> :skip
      true -> {:ok, {publisher_id, mid, :video}, normalize_codec(codec, :video)}
    end
  end

  defp default_codec(:audio), do: "opus"
  defp default_codec(:video), do: "vp8"
  defp default_codec(_), do: "unknown"

  defp normalize_codec(codec, _kind) when is_binary(codec) and codec != "" do
    String.downcase(codec)
  end

  defp normalize_codec(_, kind), do: default_codec(kind)

  defp ensure_stem(%{stems: stems} = state, key, _kind, _codec, _meta, _info)
       when is_map_key(stems, key) do
    {:ok, state, Map.fetch!(stems, key)}
  end

  defp ensure_stem(state, {publisher_id, mid, ssrc, :audio} = key, :audio, codec, meta, _info) do
    open_stem(state, key, publisher_id, mid, ssrc, :audio, codec, meta, %{})
  end

  defp ensure_stem(state, {publisher_id, mid, :video} = key, :video, codec, meta, info) do
    ssrc = Map.get(info, :ssrc) || Map.get(meta, :ssrc) || Map.get(meta, "ssrc") || 0
    open_stem(state, key, publisher_id, mid, ssrc, :video, codec, meta, info)
  end

  defp open_stem(state, key, publisher_id, mid, ssrc, kind, codec, meta, info) do
    ext = if kind == :audio, do: "a", else: "v"
    filename = "#{sanitize(publisher_id)}_#{sanitize(mid)}_#{ssrc}.#{ext}.mjr"
    path = Path.join(state.dir, filename)

    with {:ok, handle} <- state.storage.open(path, []),
         written_us = System.system_time(:microsecond),
         header =
           Mjr.header(%{
             kind: kind,
             codec: codec,
             created_us: state.created_us,
             written_us: written_us,
             xylon: xylon_fields(state.ctx, meta, publisher_id, mid, ssrc, info)
           }),
         :ok <- state.storage.write(handle, header) do
      stem = %{
        path: path,
        handle: handle,
        started_ms: nil,
        packets: 0,
        bytes: 0,
        last_seq: nil,
        kind: kind,
        codec: codec,
        publisher_id: publisher_id,
        mid: mid,
        via: Map.get(meta, :via) || Map.get(meta, "via"),
        edge_node: to_string(Map.get(meta, :edge_node) || state.ctx.edge_node || "local"),
        layer: Map.get(info, :layer),
        rid: Map.get(info, :rid)
      }

      {:ok, %{state | stems: Map.put(state.stems, key, stem)}, stem}
    else
      {:error, _} = err -> err
      other -> {:error, other}
    end
  end

  defp xylon_fields(ctx, meta, publisher_id, mid, ssrc, info) do
    base = %{
      "tenant_id" => to_string(ctx.tenant_id),
      "session_id" => to_string(ctx.session_id),
      "recording_id" => ctx.recording_id,
      "sequence" => ctx.sequence,
      "publisher_id" => to_string(publisher_id),
      "mid" => mid,
      "ssrc" => ssrc,
      "edge_node" => to_string(Map.get(meta, :edge_node) || ctx.edge_node)
    }

    base =
      case Map.get(info, :layer) || Map.get(meta, :substream) do
        layer when not is_nil(layer) -> Map.put(base, "layer", layer)
        _ -> base
      end

    case Map.get(info, :rid) || Map.get(meta, :rid) do
      rid when is_binary(rid) and rid != "" -> Map.put(base, "rid", rid)
      _ -> base
    end
  end

  defp write_frame(state, key, stem, rtp, recv_ms) do
    bin =
      case rtp do
        %Rtp{} = packet -> Rtp.encode(packet)
        bin when is_binary(bin) -> bin
        _ -> nil
      end

    if is_nil(bin) do
      {:error, :bad_rtp}
    else
      started = stem.started_ms || recv_ms
      rel = max(recv_ms - started, 0)
      frame = Mjr.frame(rel, bin)

      case state.storage.write(stem.handle, frame) do
        :ok ->
          gaps = gap_count(state.gaps, stem.last_seq, rtp)

          last_seq =
            case rtp do
              %Rtp{sequence_number: sn} -> sn
              _ -> stem.last_seq
            end

          stem2 = %{
            stem
            | started_ms: started,
              packets: stem.packets + 1,
              bytes: stem.bytes + byte_size(bin),
              last_seq: last_seq
          }

          {:ok,
           %{
             state
             | stems: Map.put(state.stems, key, stem2),
               packets: state.packets + 1,
               bytes: state.bytes + byte_size(bin),
               gaps: gaps
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp gap_count(gaps, prev, %Rtp{sequence_number: sn}) when is_integer(prev) do
    expected = rem(prev + 1, 65_536)

    if sn == expected do
      gaps
    else
      gaps + 1
    end
  end

  defp gap_count(gaps, _prev, _rtp), do: gaps

  defp sanitize(id) when is_binary(id) do
    case String.replace(id, ~r/[^A-Za-z0-9._-]/, "_") do
      "" -> "x"
      other -> other
    end
  end

  defp sanitize(id), do: sanitize(to_string(id))
end
