defmodule XylonRecord.BackpressureTest do
  use ExUnit.Case, async: false

  alias XMediaLib.Rtp
  alias Xylon.Recording.Ctx
  alias XylonRecord.Handler

  setup do
    dir = Path.join(System.tmp_dir!(), "xylon_record_bp_#{System.unique_integer([:positive])}")
    Application.put_env(:xylon, :recording, handler: Handler, dir: dir, queue_max: 2)

    on_exit(fn ->
      Application.delete_env(:xylon, :recording)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "dropped_backpressure increases when Writer mailbox is full" do
    ctx = %Ctx{
      tenant_id: "t1",
      session_id: "s1",
      recording_id: "bp#{System.unique_integer([:positive])}",
      sequence: 1,
      preceded_by: nil,
      mode: :tracks,
      edge_node: Node.self()
    }

    assert {:ok, state} = Handler.on_start(ctx, %{})
    # Stall the Writer so casts pile up.
    :sys.suspend(state.writer)

    meta = %{publisher_id: "a", mid: "0", kind: :audio, ssrc: 1, codec: "opus"}

    rtp = fn seq ->
      %Rtp{
        padding: 0,
        marker: 0,
        payload_type: 111,
        sequence_number: seq,
        timestamp: 0,
        ssrc: 1,
        csrcs: [],
        extension: nil,
        payload: "x"
      }
    end

    state =
      Enum.reduce(1..20, state, fn seq, st ->
        {:ok, st2} = Handler.on_publisher_rtp(ctx, st, meta, rtp.(seq))
        st2
      end)

    assert state.dropped_backpressure > 0
    :sys.resume(state.writer)
    assert {:ok, manifest} = Handler.on_stop(ctx, state)
    assert manifest.dropped_backpressure > 0
  end
end
