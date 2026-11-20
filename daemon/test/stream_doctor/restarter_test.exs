defmodule StreamDoctor.RestarterTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Restarter

  @moduletag :capture_log

  test "a crashing child is started again up to the limit, then its reason ends the restarter" do
    test = self()

    crash = fn ->
      send(test, {:started, self()})
      receive(do: (:go -> exit(:boom)))
    end

    restarter =
      start_supervised!({Restarter, child: {Task, crash}, max_restarts: 2, delay_ms: 10})

    Process.monitor(restarter)

    for _start <- 1..3 do
      assert_receive {:started, child}
      send(child, :go)
    end

    assert_receive {:DOWN, _ref, :process, ^restarter, :boom}
    refute_receive {:started, _child}
  end

  test "a child that ends normally is not started again" do
    test = self()

    finish = fn ->
      send(test, {:started, self()})
      receive(do: (:go -> :ok))
    end

    restarter =
      start_supervised!({Restarter, child: {Task, finish}, max_restarts: 2, delay_ms: 10})

    Process.monitor(restarter)
    assert_receive {:started, child}
    send(child, :go)

    assert_receive {:DOWN, _ref, :process, ^restarter, :normal}
    refute_receive {:started, _child}
  end
end
