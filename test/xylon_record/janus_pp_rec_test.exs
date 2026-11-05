defmodule XylonRecord.JanusPpRecTest do
  @moduledoc false
  use ExUnit.Case, async: false

  # Always part of the suite. Skipped only when the Phase 2 exit tool is absent.
  if is_nil(System.find_executable("janus-pp-rec")) do
    @moduletag skip: "janus-pp-rec not on PATH"
  end

  alias XMediaLib.Rtp
  alias Xylon.Recording.Ctx
  alias XylonRecord.Handler

  setup do
    dir = Path.join(System.tmp_dir!(), "xylon_record_pp_#{System.unique_integer([:positive])}")
    Application.put_env(:xylon, :recording, handler: Handler, dir: dir, queue_max: 2000)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      File.rm_rf(dir)
    end)

    %{dir: dir}
  end

  test "janus-pp-rec accepts Opus and VP8 stems" do
    recording_ctx = %Ctx{
      tenant_id: "t1",
      session_id: "s1",
      recording_id: "pp#{System.unique_integer([:positive])}",
      sequence: 1,
      preceded_by: nil,
      mode: :tracks,
      edge_node: Node.self()
    }

    assert {:ok, state} = Handler.on_start(recording_ctx, %{})

    opus = %{publisher_id: "a", mid: "0", kind: :audio, ssrc: 10, codec: "opus"}
    vp8 = %{publisher_id: "a", mid: "1", kind: :video, ssrc: 20, codec: "vp8"}

    rtp = fn ssrc, pt, payload ->
      %Rtp{
        padding: 0,
        marker: 1,
        payload_type: pt,
        sequence_number: 1,
        timestamp: 0,
        ssrc: ssrc,
        csrcs: [],
        extension: nil,
        payload: payload
      }
    end

    assert {:ok, state} =
             Handler.on_publisher_rtp(recording_ctx, state, opus, rtp.(10, 111, <<0, 0>>))

    assert {:ok, state} =
             Handler.on_publisher_rtp(recording_ctx, state, vp8, rtp.(20, 96, <<0x10, 0, 0>>))

    assert {:ok, manifest} = Handler.on_stop(recording_ctx, state)
    assert length(manifest.artifacts) == 2

    Enum.each(manifest.artifacts, fn %{path: path} ->
      {out, status} = System.cmd("janus-pp-rec", ["--json", path], stderr_to_stdout: true)
      assert status == 0, "janus-pp-rec failed for #{path}: #{out}"
      assert out =~ "\"c\""
      assert out =~ ~s("t")
    end)
  end
end
