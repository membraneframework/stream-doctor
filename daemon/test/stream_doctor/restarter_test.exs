defmodule StreamDoctor.RestarterTest do
  use ExUnit.Case, async: true

  alias StreamDoctor.Restarter

  @moduletag :capture_log

  test "a crashing child is started again up to the limit, then its reason ends the restarter" do
    test = self()

    crash = fn ->
      send(test, :started)
      exit(:boom)
    end

    restarter =
      start_supervised!({Restarter, child: {Task, crash}, max_restarts: 2, delay_ms: 10})

    Process.monitor(restarter)

    for _start <- 1..3, do: assert_receive(:started)
    assert_receive {:DOWN, _ref, :process, ^restarter, :boom}
    refute_receive :started
  end

  test "a child that ends normally is not started again" do
    test = self()

    finish = fn ->
      send(test, :started)
      receive(do: (:go -> :ok))
    end

    restarter =
      start_supervised!({Restarter, child: {Task, finish}, max_restarts: 2, delay_ms: 10})

    Process.monitor(restarter)
    restarter |> Restarter.child() |> send(:go)

    assert_receive {:DOWN, _ref, :process, ^restarter, :normal}
    assert_receive :started
    refute_receive :started
  end

  test "without restarts a crashing child ends the restarter right away" do
    crash = fn -> receive(do: (:go -> exit(:boom))) end
    restarter = start_supervised!({Restarter, child: {Task, crash}})
    Process.monitor(restarter)
    restarter |> Restarter.child() |> send(:go)

    assert_receive {:DOWN, _ref, :process, ^restarter, :boom}
  end

  test "the running child can be reached" do
    restarter = start_supervised!({Restarter, child: {Agent, fn -> :held end}})

    assert restarter |> Restarter.child() |> Agent.get(& &1) == :held
  end
end
