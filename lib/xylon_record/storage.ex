defmodule XylonRecord.Storage do
  @moduledoc """
  Replaceable storage backend for `.mjr` stem bytes.

  ## What problem this solves

  Lab default is local disk, but customers may plug object stores later.
  Writers talk only to this behaviour so the MJR encoder stays storage-agnostic.

  ## RFCs

  No STUN/TURN/SIP RFC; Xylon recording storage contract.
  """

  @typedoc "Opaque handle returned by `open/2`."
  @type handle :: term()

  @doc "Creates directory `path` (and parents) if needed."
  @callback mkdir!(path :: binary()) :: :ok

  @doc "Opens `path` for writing (creates/truncates)."
  @callback open(path :: binary(), opts :: keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Appends `iodata` to an open handle."
  @callback write(handle(), iodata()) :: :ok | {:error, term()}

  @doc "Closes an open handle."
  @callback close(handle()) :: :ok | {:error, term()}
end
