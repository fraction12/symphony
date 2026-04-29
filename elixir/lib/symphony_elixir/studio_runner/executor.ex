defmodule SymphonyElixir.StudioRunner.Executor do
  @moduledoc """
  Minimal seam for asynchronously executing accepted Studio Runner work.

  The initial push-ingress vertical slice stops at verified acceptance, normalization,
  idempotent claiming, and asynchronous handoff. The long-running Codex lifecycle for
  OpenSpec work is intentionally deferred behind this executor boundary.
  """

  require Logger

  alias SymphonyElixir.StudioRunner.WorkItem

  @spec run(WorkItem.t()) :: :ok
  def run(%WorkItem{} = work_item) do
    Logger.info("Accepted Studio Runner work event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} repo_path=#{work_item.repo_path} change=#{work_item.change}")

    :ok
  end
end
