defmodule XylonRecord.Keyframe do
  @moduledoc """
  Codec-specific keyframe detection for recording video stems.

  ## What problem this solves

  Phase 5 must skip video RTP until the first keyframe on the chosen layer so
  remuxers see a clean start. This module inspects VP8, VP9, H.264, and AV1
  (Dependency Descriptor structure flag or sequence-header OBU) without
  depending on the conference SFU filter modules.

  ## RFCs

  - [RFC 7741](https://www.rfc-editor.org/rfc/rfc7741) (VP8)
  - [RFC 7742](https://www.rfc-editor.org/rfc/rfc7742) / VP9 payload draft (VP9)
  - [RFC 6184](https://www.rfc-editor.org/rfc/rfc6184) (H.264)
  - [AV1 RTP](https://aomediacodec.github.io/av1-rtp-spec/) (AV1 + DD)
  """

  alias XMediaLib.Rtp
  alias XMediaLib.Rtp.{DependencyDescriptor, HeaderExtension}

  @doc "True when `rtp_or_payload` is a keyframe for `codec`."
  @spec keyframe?(Rtp.t() | binary(), String.t() | atom() | nil) :: boolean()
  def keyframe?(rtp_or_payload, codec) do
    case normalize_codec(codec) do
      "vp8" -> vp8_keyframe?(payload_bin(rtp_or_payload))
      "vp9" -> vp9_keyframe?(payload_bin(rtp_or_payload))
      "h264" -> h264_keyframe?(payload_bin(rtp_or_payload))
      "av1" -> av1_keyframe?(rtp_or_payload)
      _ -> false
    end
  end

  defp vp8_keyframe?(<<>>), do: false

  defp vp8_keyframe?(<<x::1, _r::1, _n::1, _s::1, _r2::1, _pid::3, rest::binary>>) do
    after_desc = skip_vp8_descriptor(x, rest)

    case after_desc do
      <<p::1, _::bitstring>> -> p == 0
      _ -> false
    end
  end

  defp vp8_keyframe?(_), do: false

  defp skip_vp8_descriptor(0, rest), do: rest

  defp skip_vp8_descriptor(1, <<i::1, l::1, t::1, k::1, _::4, rest::binary>>) do
    rest
    |> maybe_skip(i == 1, 1)
    |> maybe_skip(l == 1, 1)
    |> maybe_skip(t == 1 or k == 1, 1)
  end

  defp skip_vp8_descriptor(_, _), do: <<>>

  defp maybe_skip(bin, false, _), do: bin

  defp maybe_skip(bin, true, n) when is_binary(bin) and is_integer(n) and byte_size(bin) >= n do
    binary_part(bin, n, byte_size(bin) - n)
  end

  defp maybe_skip(_, true, _), do: <<>>

  # VP9: P bit in first octet; P=0 means key frame (intra-only).
  defp vp9_keyframe?(<<_i::1, p::1, _::bitstring>>), do: p == 0
  defp vp9_keyframe?(_), do: false

  defp h264_keyframe?(<<0::1, _nri::2, 5::5, _::binary>>), do: true
  defp h264_keyframe?(<<0::1, _nri::2, 28::5, _s::1, _e::1, _r::1, 5::5, _::binary>>), do: true
  defp h264_keyframe?(_), do: false

  defp av1_keyframe?(%Rtp{} = rtp) do
    dd_structure_key?(rtp) or av1_obu_keyframe?(payload_bin(rtp))
  end

  defp av1_keyframe?(bin) when is_binary(bin), do: av1_obu_keyframe?(bin)
  defp av1_keyframe?(_), do: false

  defp dd_structure_key?(%Rtp{extension: %{type: type, payload: payload}})
       when is_binary(payload) do
    Enum.any?(HeaderExtension.decode_elements(type, payload), fn
      {_id, data} when is_binary(data) ->
        case DependencyDescriptor.parse(data) do
          {:ok, %{structure?: true}} -> true
          _ ->
            case DependencyDescriptor.parse_chrome(data, nil) do
              {:ok, %{structure?: true}, _} -> true
              _ -> false
            end
        end

      _ ->
        false
    end)
  end

  defp dd_structure_key?(_), do: false

  # AV1 RTP: optional 1-byte aggregation header, then OBUs. Type 1 = SEQUENCE_HEADER.
  defp av1_obu_keyframe?(<<>>), do: false

  defp av1_obu_keyframe?(bin) when is_binary(bin) do
    has_sequence_header_obu?(bin) or
      (byte_size(bin) > 1 and has_sequence_header_obu?(binary_part(bin, 1, byte_size(bin) - 1)))
  end

  defp has_sequence_header_obu?(<<0::1, 1::4, _ext::1, _has_size::1, _::1, _rest::binary>>), do: true
  defp has_sequence_header_obu?(_), do: false

  defp normalize_codec(c) when is_atom(c), do: normalize_codec(Atom.to_string(c))

  defp normalize_codec(c) when is_binary(c) do
    case String.downcase(c) do
      "h264" -> "h264"
      "avc1" -> "h264"
      other -> other
    end
  end

  defp normalize_codec(_), do: ""

  defp payload_bin(%Rtp{payload: p}) when is_binary(p), do: p
  defp payload_bin(bin) when is_binary(bin), do: bin
  defp payload_bin(_), do: <<>>
end
