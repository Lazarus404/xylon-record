defmodule XylonRecord.VideoPolicy do
  @moduledoc """
  Selects which video RTP packets belong in a recording stem.

  ## What problem this solves

  Simulcast publishers send multiple SSRCs per mid; one-SSRC SVC embeds spatial
  and temporal layers in one stream. Recording must keep the SaaS default
  (highest layer with media) or an explicit `video_layer` / `rid` override, and
  never silently fall back to a lower layer.

  ## RFCs

  No STUN/TURN/SIP RFC; uses VP8/VP9 payload descriptors, AV1 Dependency
  Descriptor via `XMediaLib.Rtp.DependencyDescriptor`, and Plan layer maps.
  """

  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.{DependencyDescriptor, HeaderExtension}
  alias XylonRecord.Keyframe

  @type override :: %{optional(:video_layer) => integer(), optional(:rid) => binary()}

  @doc """
  Layer gate before keyframe check.

  Returns:
  - `{:write, layer_info}` -- SIM or plain video accepted for this SSRC
  - `{:svc, layer_info}` -- one-SSRC SVC; caller must run `svc_accept?/4`
  - `:wrong_layer` -- not the chosen SIM SSRC / unlearned chosen layer
  - `:skip` -- not video
  """
  @spec decide(map(), override()) :: {:write, map()} | {:svc, map()} | :wrong_layer | :skip
  def decide(meta, override \\ %{}) when is_map(meta) and is_map(override) do
    kind = Map.get(meta, :kind) || Map.get(meta, "kind")

    if kind != :video do
      :skip
    else
      layers = Map.get(meta, :layers) || Map.get(meta, "layers")
      codec = Map.get(meta, :codec) || Map.get(meta, "codec")
      ssrc = Map.get(meta, :ssrc) || Map.get(meta, "ssrc")

      cond do
        sim_layers?(layers) ->
          decide_sim(layers, ssrc, override)

        svc_codec?(codec) ->
          {:svc,
           %{
             layer: Map.get(meta, :substream),
             rid: Map.get(meta, :rid),
             ssrc: ssrc,
             codec: codec
           }}

        true ->
          {:write,
           %{
             layer: Map.get(meta, :substream) || Map.get(meta, "substream"),
             rid: Map.get(meta, :rid) || Map.get(meta, "rid"),
             ssrc: ssrc
           }}
      end
    end
  end

  @doc "Keyframe gate: `{:ok, true}` when stem already open on keyframe or packet is keyframe."
  @spec keyframe_ok?(boolean(), term(), String.t() | atom() | nil) ::
          {:ok, true} | :wait_keyframe
  def keyframe_ok?(true, _rtp, _codec), do: {:ok, true}

  def keyframe_ok?(false, rtp, codec) do
    if Keyframe.keyframe?(rtp, codec), do: {:ok, true}, else: :wait_keyframe
  end

  @doc "Chosen SIM layer from layers list + override (`rid` wins over `video_layer`)."
  @spec choose_sim_layer(list(), override()) :: map() | nil
  def choose_sim_layer(layers, override) when is_list(layers) and is_map(override) do
    rid = Map.get(override, :rid) || Map.get(override, "rid")
    video_layer = Map.get(override, :video_layer) || Map.get(override, "video_layer")

    cond do
      is_binary(rid) and rid != "" ->
        Enum.find(layers, fn l -> Map.get(l, :rid) == rid or Map.get(l, "rid") == rid end) ||
          choose_highest(layers)

      is_integer(video_layer) ->
        Enum.find(layers, fn l ->
          Map.get(l, :substream) == video_layer or Map.get(l, "substream") == video_layer
        end) || choose_highest(layers)

      true ->
        choose_highest(layers)
    end
  end

  @doc """
  Sticky SVC filter: keep max spatial then max temporal on that spatial.

  `override.video_layer` when set pins spatial index; temporal still max on that spatial.
  VP9 uses the payload descriptor. AV1 uses Dependency Descriptor when present;
  without DD there is no SVC claim and the packet is kept. Unparseable VP9
  (or malformed AV1 DD) drops -- never silently keeps as "any layer".
  """
  @spec svc_accept?(map(), term(), String.t() | atom() | nil, override()) ::
          {:keep, map(), map()} | {:drop, map()}
  def svc_accept?(obs, rtp, codec, override) when is_map(obs) and is_map(override) do
    spatial_override =
      case Map.get(override, :video_layer) || Map.get(override, "video_layer") do
        n when is_integer(n) -> n
        _ -> nil
      end

    case extract_layers(rtp, codec, obs) do
      {:ok, s, t, obs2} ->
        obs3 = update_svc_obs(obs2, s, t, spatial_override)
        want_s = spatial_override || Map.fetch!(obs3, :max_spatial)
        want_t = Map.get(obs3, {:max_temporal, want_s}, t)
        info = %{layer: s, rid: nil, ssrc: nil, spatial: s, temporal: t}

        if s == want_s and t == want_t do
          {:keep, obs3, info}
        else
          {:drop, obs3}
        end

      :no_svc_claim ->
        {:keep, obs, %{layer: nil, rid: nil, ssrc: nil}}

      :error ->
        {:drop, obs}
    end
  end

  defp extract_layers(rtp, codec, obs) do
    case normalize_codec(codec) do
      "vp9" ->
        case vp9_layers(payload_bin(rtp)) do
          {:ok, %{spatial: s, temporal: t}} -> {:ok, s, t, obs}
          _ -> :error
        end

      "av1" ->
        extract_av1_layers(rtp, obs)

      _ ->
        :error
    end
  end

  defp extract_av1_layers(%Rtp{} = rtp, obs) do
    structure = Map.get(obs, :dd_structure)

    case find_dd(rtp, structure) do
      {:ok, %{spatial: s, temporal: t}, struct2} ->
        {:ok, s, t, Map.put(obs, :dd_structure, struct2)}

      {:ok, %{spatial: s, temporal: t}} ->
        {:ok, s, t, obs}

      :none ->
        :no_svc_claim

      :error ->
        :error
    end
  end

  defp extract_av1_layers(_rtp, _obs), do: :no_svc_claim

  defp find_dd(%Rtp{extension: %{type: type, payload: payload}}, structure)
       when is_binary(payload) do
    elements = HeaderExtension.decode_elements(type, payload)

    Enum.reduce_while(elements, :none, fn
      {_id, data}, acc when is_binary(data) ->
        case DependencyDescriptor.parse(data) do
          {:ok, desc} ->
            {:halt, {:ok, desc}}

          :error ->
            case DependencyDescriptor.parse_chrome(data, structure) do
              {:ok, desc, struct2} -> {:halt, {:ok, desc, struct2}}
              :error -> {:cont, acc}
            end
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp find_dd(_, _), do: :none

  defp update_svc_obs(obs, s, t, spatial_override) do
    obs =
      if is_nil(spatial_override) do
        Map.update(obs, :max_spatial, s, &max(&1, s))
      else
        Map.put(obs, :max_spatial, spatial_override)
      end

    want_s = Map.fetch!(obs, :max_spatial)

    if s == want_s do
      Map.update(obs, {:max_temporal, want_s}, t, &max(&1, t))
    else
      obs
    end
  end

  defp decide_sim(layers, ssrc, override) do
    case choose_sim_layer(layers, override) do
      nil ->
        :wrong_layer

      chosen ->
        chosen_ssrc = Map.get(chosen, :ssrc) || Map.get(chosen, "ssrc")

        cond do
          not is_integer(chosen_ssrc) or chosen_ssrc == 0 ->
            :wrong_layer

          chosen_ssrc != ssrc ->
            :wrong_layer

          true ->
            {:write,
             %{
               layer: Map.get(chosen, :substream) || Map.get(chosen, "substream"),
               rid: Map.get(chosen, :rid) || Map.get(chosen, "rid"),
               ssrc: chosen_ssrc
             }}
        end
    end
  end

  defp choose_highest(layers) do
    Enum.max_by(
      layers,
      fn l -> Map.get(l, :substream) || Map.get(l, "substream") || -1 end,
      fn -> nil end
    )
  end

  defp sim_layers?(layers) when is_list(layers) and length(layers) > 1, do: true
  defp sim_layers?(_), do: false

  defp svc_codec?(c) when is_binary(c), do: String.downcase(c) in ["vp9", "av1"]
  defp svc_codec?(c) when is_atom(c), do: svc_codec?(Atom.to_string(c))
  defp svc_codec?(_), do: false

  defp normalize_codec(c) when is_atom(c), do: normalize_codec(Atom.to_string(c))
  defp normalize_codec(c) when is_binary(c), do: String.downcase(c)
  defp normalize_codec(_), do: ""

  defp vp9_layers(<<_i::1, _p::1, 1::1, _f::1, _b::1, _e::1, _v::1, _z::1, rest::binary>>) do
    case rest do
      <<t::3, _u::1, s::3, _d::1, _::binary>> -> {:ok, %{spatial: s, temporal: t}}
      _ -> :error
    end
  end

  defp vp9_layers(<<_i::1, _p::1, 0::1, _::bitstring>>), do: {:ok, %{spatial: 0, temporal: 0}}
  defp vp9_layers(_), do: :error

  defp payload_bin(%Rtp{payload: p}) when is_binary(p), do: p
  defp payload_bin(bin) when is_binary(bin), do: bin
  defp payload_bin(_), do: <<>>
end
