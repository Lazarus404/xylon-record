defmodule XylonRecord.Mjr do
  @moduledoc """
  Janus MJR00002 binary framing for one media stem.

  ## What problem this solves

  Compose tools (`janus-pp-rec`) expect Meetecho `.mjr` files: an 8-byte magic,
  a length-prefixed JSON header, then `MEET` frames with relative receive time
  and raw RTP. This module builds those bytes; Xylon metadata lives in the JSON
  header alongside Janus `t`/`c`/`s`/`u`.

  ## RFCs

  No STUN/TURN/SIP RFC. Format is Janus Meetecho recordings (MJR00002), not an IETF RFC.
  """

  @magic "MJR00002"
  @frame "MEET"

  @typedoc """
  Fields for the JSON info header.

  ## Fields

  - `:kind` - `:audio` or `:video` (maps to Janus `t` `a`/`v`).
  - `:codec` - Lowercase codec name for Janus `c` (e.g. `opus`, `vp8`).
  - `:created_us` - Unix microseconds for `s`.
  - `:written_us` - Unix microseconds for `u` (first frame write time).
  - `:xylon` - Map of Xylon string keys merged into the JSON object.
  """
  @type header_info :: %{
          required(:kind) => :audio | :video,
          required(:codec) => binary(),
          required(:created_us) => non_neg_integer(),
          required(:written_us) => non_neg_integer(),
          optional(:xylon) => map()
        }

  @doc "Returns the 8-byte `MJR00002` magic."
  @spec magic() :: binary()
  def magic, do: @magic

  @doc """
  Builds magic + JSON header block (without any MEET frames).

  Call once when opening a stem, before the first `frame/2`.
  """
  @spec header(header_info()) :: binary()
  def header(%{kind: kind, codec: codec, created_us: created, written_us: written} = info)
      when kind in [:audio, :video] and is_binary(codec) and is_integer(created) and
             is_integer(written) do
    t = if kind == :audio, do: "a", else: "v"

    base = %{
      "t" => t,
      "c" => String.downcase(codec),
      "s" => created,
      "u" => written
    }

    json =
      info
      |> Map.get(:xylon, %{})
      |> Enum.reduce(base, fn
        {k, v}, acc when is_atom(k) -> Map.put(acc, Atom.to_string(k), json_value(v))
        {k, v}, acc when is_binary(k) -> Map.put(acc, k, json_value(v))
      end)
      |> Jason.encode!()

    <<@magic::binary, byte_size(json)::16-big, json::binary>>
  end

  @doc """
  Builds one `MEET` frame: relative recv time (ms) + RTP packet bytes.
  """
  @spec frame(non_neg_integer(), binary()) :: binary()
  def frame(recv_ms, rtp_bin)
      when is_integer(recv_ms) and recv_ms >= 0 and is_binary(rtp_bin) do
    len = byte_size(rtp_bin)
    <<@frame::binary, recv_ms::32-big, len::16-big, rtp_bin::binary>>
  end

  @doc """
  Parses magic + JSON header from the start of an `.mjr` binary.

  Returns `{:ok, json_map, rest}` or `{:error, reason}`.
  """
  @spec parse_header(binary()) :: {:ok, map(), binary()} | {:error, term()}
  def parse_header(<<@magic::binary, len::16-big, rest::binary>>) when byte_size(rest) >= len do
    <<json::binary-size(^len), rest2::binary>> = rest

    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map, rest2}
      other -> {:error, {:bad_json, other}}
    end
  end

  def parse_header(_), do: {:error, :bad_header}

  defp json_value(nil), do: nil
  defp json_value(v) when is_atom(v), do: Atom.to_string(v)
  defp json_value(v), do: v
end
