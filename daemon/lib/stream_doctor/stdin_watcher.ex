defmodule StreamDoctor.StdinWatcher do
  @moduledoc false

  # stdin is a pipe from the SDK, so EOF means the SDK's process is gone.
  # Opt-in, because stdin on /dev/null is EOF right away.
  use Task, restart: :temporary

  @env "STREAM_DOCTOR_EXIT_ON_STDIN_EOF"

  def child_specs do
    if System.get_env(@env), do: [__MODULE__], else: []
  end

  def start_link(_), do: Task.start_link(&run/0)

  defp run do
    case IO.read(:stdio, :line) do
      data when is_binary(data) -> run()
      _eof_or_error -> shutdown()
    end
  end

  # we try to gracefully kill the BEAM process and
  # if it doesn't happen within 5s we forcefully kill it
  @dialyzer {:nowarn_function, shutdown: 0}
  defp shutdown do
    spawn(fn ->
      Process.sleep(5_000)
      System.halt(1)
    end)

    System.stop(0)
  end
end
