defmodule XylonRecord do
  @moduledoc """
  Reference room recording tap for Xylon (Janus `.mjr` stems).

  ## What problem this solves

  Xylon Control starts and stops recordings; Conference taps publisher RTP.
  This package implements `Xylon.Recording.Handler` and writes MJR00002 stems
  to a replaceable storage backend (local disk by default), keeping disk I/O
  off the SFU hot path via a per-recording Writer GenServer.

  ## RFCs

  No STUN/TURN/SIP RFC. Stem format is Janus MJR00002 (Meetecho recordings).
  """

  @default_queue_max 2000

  @doc """
  Recording root directory for stem files.

  Order: `config :xylon, :recording, dir: ...`, else `XYLON_RECORD_DIR`,
  else `System.tmp_dir!() <> "/xylon_record"`.
  """
  @spec dir() :: binary()
  def dir do
    case Keyword.get(recording_config(), :dir) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        case System.get_env("XYLON_RECORD_DIR") do
          path when is_binary(path) and path != "" -> path
          _ -> Path.join(System.tmp_dir!(), "xylon_record")
        end
    end
  end

  @doc """
  Max Writer mailbox length before `on_publisher_rtp` drops frames.

  Reads `config :xylon, :recording, queue_max: N` (default 2000).
  """
  @spec queue_max() :: pos_integer()
  def queue_max do
    case Keyword.get(recording_config(), :queue_max, @default_queue_max) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_queue_max
    end
  end

  @doc "Storage module (default `XylonRecord.Storage.Local`)."
  @spec storage() :: module()
  def storage do
    Keyword.get(recording_config(), :storage, XylonRecord.Storage.Local)
  end

  @doc false
  @spec recording_config() :: keyword()
  def recording_config do
    case Application.get_env(:xylon, :recording, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
