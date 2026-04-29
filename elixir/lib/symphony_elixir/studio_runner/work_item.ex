defmodule SymphonyElixir.StudioRunner.WorkItem do
  @moduledoc """
  Normalized Studio Runner work accepted from signed OpenSpec Studio events.
  """

  defstruct [
    :event_id,
    :run_id,
    :event_type,
    :source,
    :occurred_at,
    :repo_path,
    :repo_name,
    :repo_remote,
    :git_ref,
    :change,
    :requested_by,
    artifact_paths: [],
    validation: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          run_id: String.t() | nil,
          event_type: String.t(),
          source: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          repo_path: String.t(),
          repo_name: String.t() | nil,
          repo_remote: String.t() | nil,
          git_ref: String.t() | nil,
          change: String.t(),
          requested_by: String.t() | nil,
          artifact_paths: [String.t()],
          validation: map(),
          metadata: map()
        }

  @spec repo_change_key(t()) :: String.t()
  def repo_change_key(%__MODULE__{repo_path: repo_path, change: change}) do
    repo_path <> "::" <> change
  end

  @spec response_payload(t()) :: map()
  def response_payload(%__MODULE__{} = work_item) do
    %{
      status: "accepted",
      eventId: work_item.event_id,
      runId: work_item.run_id,
      repoPath: work_item.repo_path,
      repoName: work_item.repo_name,
      change: work_item.change
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
