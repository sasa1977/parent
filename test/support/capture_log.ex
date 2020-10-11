defmodule Parent.CaptureLog do
  def capture_log(opts \\ [], fun) do
    :global.trans({:capture_log, self()}, fn ->
      ExUnit.CaptureLog.capture_log(opts, fun)
    end)
  end
end
