defmodule XylonRecord.Layout.FromStemsTest do
  use ExUnit.Case, async: false

  alias XylonRecord.Layout.FromStems

  test "available? matches tools on PATH" do
    have_pp =
      is_binary(System.find_executable("janus-pp-rec")) or
        (is_binary(System.get_env("JANUS_PP_REC")) and File.exists?(System.get_env("JANUS_PP_REC")))

    have_ff = is_binary(System.find_executable("ffmpeg"))
    assert FromStems.available?() == (have_pp and have_ff)
  end

  test "build returns error when recording dir has no video stems" do
    dir = Path.join(System.tmp_dir!(), "from_stems_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    out = Path.join(dir, "layout.mp4")

    if FromStems.available?() do
      assert {:error, :no_video_stems} = FromStems.build(dir, out)
    else
      assert {:error, _} = FromStems.build(dir, out)
    end
  end
end
