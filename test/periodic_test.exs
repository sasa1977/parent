defmodule PeriodicTest do
  # using async false to reduce the chance of flaky failures
  use ExUnit.Case, async: false

  test "period" do
    Periodic.start_link(every: 100, run: pinger())

    refute_receive :running, 50
    assert_receive :running, 100

    refute_receive :running, 50
    assert_receive :running, 100
  end

  test "overlap" do
    Periodic.start_link(
      every: 100,
      run: pinger(fn -> :timer.sleep(:infinity) end),
      overlap?: true
    )

    assert_receive :running, 200
    assert_receive :running, 200
  end

  test "no overlap" do
    Periodic.start_link(
      every: 100,
      run: pinger(fn -> :timer.sleep(300) end),
      overlap?: false
    )

    assert_receive :running, 200
    refute_receive :running, 200
    assert_receive :running, 200
  end

  defp pinger(extra \\ fn -> :ok end) do
    owner = self()

    fn ->
      send(owner, :running)
      extra.()
    end
  end
end
