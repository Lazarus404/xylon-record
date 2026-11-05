defmodule XylonRecord.Storage.Local do
  @moduledoc """
  Local filesystem storage for recording stems.

  ## What problem this solves

  Lab and single-node deploys need stems on disk under a configured root.
  This module implements `XylonRecord.Storage` with Erlang file I/O.

  ## RFCs

  No STUN/TURN/SIP RFC; local disk storage.
  """

  @behaviour XylonRecord.Storage

  @impl true
  @doc "Creates `path` and parents (`File.mkdir_p!/1`)."
  @spec mkdir!(binary()) :: :ok
  def mkdir!(path) when is_binary(path) do
    File.mkdir_p!(path)
    :ok
  end

  @impl true
  @doc "Opens `path` for raw append/write (`[:write, :binary, :raw]`)."
  @spec open(binary(), keyword()) :: {:ok, :file.io_device()} | {:error, term()}
  def open(path, _opts \\ []) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :file.open(path, [:write, :binary, :raw])
  end

  @impl true
  @doc "Writes `iodata` to the open device."
  @spec write(:file.io_device(), iodata()) :: :ok | {:error, term()}
  def write(device, iodata) do
    :file.write(device, iodata)
  end

  @impl true
  @doc "Closes the open device."
  @spec close(:file.io_device()) :: :ok | {:error, term()}
  def close(device), do: :file.close(device)
end
