defmodule XylonRecord.Handler do
  @moduledoc """
  `Xylon.Recording.Handler` that writes publisher stems as Janus `.mjr` files.

  ## What problem this solves

  Phase 1 hooks deliver plaintext publisher RTP while a Session is recording.
  This handler starts a monitored Writer GenServer, enqueues frames with
  backpressure drops when the Writer mailbox is full, and finalizes stem files
  on stop. `on_start/2` opts may include `video_layer` / `rid` (Phase 5 layer
  pin). When `Ctx.mode` is `:tracks_and_mix`, `on_mix_rtp/4` writes the MCU
  full-mix stem (`publisher_id` `__mcu_mix__`). With `layout: true` and a
  `plan_ref`, starts `XylonRecord.Layout` for the Phase 8 live composite
  (MCU mix audio is preferred on that sink when Conference injects it).

  ## RFCs

  No STUN/TURN/SIP RFC; Janus MJR00002 via `XylonRecord.Writer`.
  """

  @behaviour Xylon.Recording.Handler

  alias Xylon.Recording.Ctx
  alias XylonRecord.{Layout, Writer}

  @impl true
  @doc "Starts a monitored Writer under the configured storage root."
  @spec on_start(Ctx.t(), map()) :: {:ok, map()} | {:error, term()}
  def on_start(%Ctx{} = ctx, opts) when is_map(opts) do
    writer_opts =
      []
      |> maybe_kw(:dir, Map.get(opts, :dir) || Map.get(opts, "dir"))
      |> maybe_kw(:storage, Map.get(opts, :storage) || Map.get(opts, "storage"))
      |> maybe_kw(
        :video_layer,
        coerce_video_layer(Map.get(opts, :video_layer) || Map.get(opts, "video_layer"))
      )
      |> maybe_kw(:rid, coerce_rid(Map.get(opts, :rid) || Map.get(opts, "rid")))

    case Writer.start(ctx, writer_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state = %{
          writer: pid,
          monitor: ref,
          dropped_backpressure: 0,
          skipped_unknown: 0,
          queue_max: XylonRecord.queue_max(),
          layout: nil,
          layout_monitor: nil
        }

        case maybe_start_layout(ctx, opts, writer_opts) do
          {:ok, layout_pid} ->
            lref = Process.monitor(layout_pid)
            {:ok, %{state | layout: layout_pid, layout_monitor: lref}}

          :skip ->
            {:ok, state}

          {:error, reason} ->
            # Layout arm failure must not abort stem capture.
            {:ok, Map.put(state, :layout_error, recording_error_string(reason))}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  @doc "Finalizes stems (and layout when present) and stops workers."
  @spec on_stop(Ctx.t(), map()) :: {:ok, map()} | {:error, term()}
  def on_stop(%Ctx{}, %{writer: pid, monitor: ref} = state) when is_pid(pid) do
    Process.demonitor(ref, [:flush])

    # Finalize stems first so layout can remux real .mjr into layout.mp4.
    result =
      if Process.alive?(pid) do
        case Writer.finalize(pid) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _} = err -> err
        end
      else
        {:ok,
         %{
           artifacts: [],
           counters: %{},
           dropped_backpressure: Map.get(state, :dropped_backpressure, 0)
         }}
      end

    layout_part = finalize_layout(state)

    case result do
      {:ok, manifest} ->
        {:ok, merge_layout_manifest(manifest, layout_part, state)}

      {:error, _} = err ->
        err
    end
  end

  def on_stop(%Ctx{}, state), do: {:ok, %{artifacts: [], state: state}}

  @impl true
  @doc """
  Enqueues publisher RTP when mid/kind are known; drops under backpressure.
  """
  @spec on_publisher_rtp(Ctx.t(), map(), map(), term()) :: {:ok, map()}
  def on_publisher_rtp(%Ctx{} = ctx, state, meta, rtp) when is_map(state) and is_map(meta) do
    enqueue_frame(ctx, state, meta, rtp)
  end

  @impl true
  @doc "Enqueues MCU full-mix RTP when mid/kind are known; drops under backpressure."
  @spec on_mix_rtp(Ctx.t(), map(), map(), term()) :: {:ok, map()}
  def on_mix_rtp(%Ctx{} = ctx, state, meta, rtp) when is_map(state) and is_map(meta) do
    enqueue_frame(ctx, state, meta, rtp)
  end

  defp enqueue_frame(%Ctx{}, state, meta, rtp) do
    cond do
      not usable_meta?(meta) ->
        {:ok, %{state | skipped_unknown: Map.get(state, :skipped_unknown, 0) + 1}}

      true ->
        pid = Map.fetch!(state, :writer)
        max = Map.get(state, :queue_max, XylonRecord.queue_max())

        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} when is_integer(n) and n >= max ->
            {:ok, %{state | dropped_backpressure: state.dropped_backpressure + 1}}

          {:message_queue_len, _} ->
            Writer.enqueue(pid, meta, rtp, System.monotonic_time(:millisecond))
            {:ok, state}

          nil ->
            {:ok, %{state | dropped_backpressure: state.dropped_backpressure + 1}}
        end
    end
  end

  defp usable_meta?(meta) do
    mid = Map.get(meta, :mid) || Map.get(meta, "mid")
    kind = Map.get(meta, :kind) || Map.get(meta, "kind")
    is_binary(mid) and mid != "" and kind in [:audio, :video]
  end

  defp maybe_kw(opts, _key, nil), do: opts
  defp maybe_kw(opts, key, value), do: Keyword.put(opts, key, value)

  defp coerce_video_layer(n) when is_integer(n) and n >= 0, do: n

  defp coerce_video_layer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp coerce_video_layer(_), do: nil

  defp coerce_rid(rid) when is_binary(rid) and rid != "", do: rid
  defp coerce_rid(_), do: nil

  defp maybe_start_layout(ctx, opts, writer_opts) do
    layout? = truthy?(Map.get(opts, :layout) || Map.get(opts, "layout"))
    plan_ref = Map.get(opts, :plan_ref) || Map.get(opts, "plan_ref")

    if layout? and plan_ref != nil do
      layout_opts =
        writer_opts
        |> Keyword.put(:plan_ref, plan_ref)
        |> maybe_kw(:rtmp_url, Map.get(opts, :rtmp_url) || Map.get(opts, "rtmp_url"))

      case Layout.start(ctx, layout_opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = err -> err
      end
    else
      :skip
    end
  end

  defp finalize_layout(%{layout: pid, layout_monitor: ref}) when is_pid(pid) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    if Process.alive?(pid) do
      case Layout.finalize(pid) do
        {:ok, part} -> part
        _ -> %{artifacts: [], counters: %{}}
      end
    else
      %{artifacts: [], counters: %{}}
    end
  end

  defp finalize_layout(_), do: %{artifacts: [], counters: %{}}

  defp merge_layout_manifest(manifest, layout_part, state) do
    arts = List.wrap(Map.get(manifest, :artifacts) || []) ++ List.wrap(Map.get(layout_part, :artifacts) || [])

    counters =
      Map.merge(Map.get(manifest, :counters) || %{}, Map.get(layout_part, :counters) || %{})
      |> Map.put(:dropped_backpressure, Map.get(state, :dropped_backpressure, 0))
      |> then(fn c ->
        case Map.get(state, :layout_error) do
          nil -> c
          err -> Map.put(c, :layout_error, err)
        end
      end)

    Map.merge(manifest, %{
      artifacts: arts,
      counters: counters,
      dropped_backpressure: Map.get(state, :dropped_backpressure, 0),
      skipped_unknown_hot: Map.get(state, :skipped_unknown, 0)
    })
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp recording_error_string(reason) when is_binary(reason), do: reason
  defp recording_error_string(reason), do: inspect(reason)
end
