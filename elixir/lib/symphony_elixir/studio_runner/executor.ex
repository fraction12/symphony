defmodule SymphonyElixir.StudioRunner.Executor do
  @moduledoc """
  Executes accepted Studio Runner OpenSpec work.

  The signed ingress path owns verification, idempotency, and async dispatch. This
  module turns the accepted work item into a Symphony-managed workspace plus a
  Codex app-server run. Studio Runner work stays OpenSpec-native: it does not
  require Linear credentials or tracker state.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety, Workspace}
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.StudioRunner.WorkItem

  @required_artifacts ["proposal.md", "tasks.md"]
  @max_artifact_bytes 64_000
  @git_command_timeout_ms 15_000

  @type execution_context :: %{
          event_id: String.t(),
          run_id: String.t() | nil,
          repo_path: Path.t(),
          workspace_path: Path.t(),
          change: String.t(),
          branch_name: String.t(),
          artifacts: map(),
          validation: map(),
          git_ref: String.t() | nil,
          base_commit_sha: String.t() | nil
        }

  @spec run(WorkItem.t()) :: {:ok, map()} | {:error, term()}
  def run(%WorkItem{} = work_item) do
    Logger.info("Starting Studio Runner execution event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} repo_path=#{work_item.repo_path} change=#{work_item.change}")

    case execute(work_item) do
      {:ok, context, result} ->
        metadata = execution_metadata(context, result)

        Logger.info(
          "Studio Runner execution completed event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} workspace=#{context.workspace_path} session_id=#{metadata[:session_id] || "n/a"} status=#{metadata[:status]}"
        )

        {:ok, metadata}

      {:error, reason} ->
        Logger.error("Studio Runner execution failed event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} reason=#{inspect(reason)}")

        {:error, reason}
    end
  end

  @spec execute(WorkItem.t(), keyword()) :: {:ok, execution_context(), map()} | {:error, term()}
  def execute(%WorkItem{} = work_item, opts \\ []) do
    with {:ok, source_repo} <- canonical_source_repo(work_item.repo_path),
         :ok <- validate_change_name(work_item.change),
         {:ok, workspace} <- create_workspace(work_item, opts),
         :ok <- prepare_workspace(source_repo, workspace, opts),
         :ok <- Workspace.run_before_run_hook(workspace, hook_context(work_item), nil),
         {:ok, artifacts} <- load_change_artifacts(workspace, work_item.change),
         context <- build_context(work_item, source_repo, workspace, artifacts),
         prompt <- build_prompt(context) do
      try do
        with {:ok, codex_result} <- run_codex(workspace, prompt, work_item, opts),
             {:ok, publish_metadata} <- inspect_published_work(workspace, context, opts) do
          {:ok, context, Map.merge(codex_result, publish_metadata)}
        end
      after
        Workspace.run_after_run_hook(workspace, hook_context(work_item), nil)
      end
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec canonical_source_repo(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonical_source_repo(repo_path) when is_binary(repo_path) do
    with true <-
           Path.type(repo_path) == :absolute || {:error, {:invalid_repo_path, :not_absolute}},
         true <- File.dir?(repo_path) || {:error, {:invalid_repo_path, :missing_directory}},
         {:ok, canonical_repo} <- PathSafety.canonicalize(repo_path),
         true <-
           File.dir?(Path.join(canonical_repo, ".git")) ||
             {:error, {:invalid_repo_path, :missing_git_dir}} do
      {:ok, canonical_repo}
    end
  end

  def canonical_source_repo(_repo_path), do: {:error, {:invalid_repo_path, :not_string}}

  defp validate_change_name(change) when is_binary(change) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, change) do
      :ok
    else
      {:error, {:invalid_change_name, change}}
    end
  end

  defp validate_change_name(change), do: {:error, {:invalid_change_name, change}}

  defp create_workspace(%WorkItem{} = work_item, opts) do
    workspace_id = workspace_identifier(work_item)
    create_workspace_fun = Keyword.get(opts, :create_workspace, &Workspace.create_for_issue/1)
    create_workspace_fun.(%{id: work_item.event_id, identifier: workspace_id})
  end

  defp workspace_identifier(%WorkItem{} = work_item) do
    [
      "studio-runner",
      safe_identifier(work_item.repo_name || Path.basename(work_item.repo_path)),
      safe_identifier(work_item.change),
      safe_identifier(work_item.run_id || work_item.event_id)
    ]
    |> Enum.join("-")
  end

  defp prepare_workspace(source_repo, workspace, opts) do
    prepare_fun = Keyword.get(opts, :prepare_workspace, &copy_repo_to_workspace/2)
    prepare_fun.(source_repo, workspace)
  end

  @spec copy_repo_to_workspace(Path.t(), Path.t()) :: :ok | {:error, term()}
  def copy_repo_to_workspace(source_repo, workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(Path.dirname(workspace))

    case System.cmd("git", ["clone", "--no-hardlinks", source_repo, workspace], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:workspace_clone_failed, status, bounded_output(output)}}
    end
  end

  @spec load_change_artifacts(Path.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_change_artifacts(workspace, change) when is_binary(workspace) and is_binary(change) do
    change_root = Path.join([workspace, "openspec", "changes", change])

    with :ok <- ensure_inside_workspace(workspace, change_root),
         true <- File.dir?(change_root) || {:error, {:missing_change, change}} do
      artifacts = %{
        proposal: read_optional_artifact(change_root, "proposal.md"),
        design: read_optional_artifact(change_root, "design.md"),
        tasks: read_optional_artifact(change_root, "tasks.md"),
        specs: read_spec_artifacts(change_root)
      }

      missing_required =
        @required_artifacts
        |> Enum.filter(fn artifact ->
          match?({:error, _}, read_optional_artifact(change_root, artifact))
        end)

      case missing_required do
        [] -> {:ok, normalize_artifacts(artifacts)}
        missing -> {:error, {:missing_required_artifacts, missing}}
      end
    end
  end

  defp read_optional_artifact(change_root, relative_path) do
    path = Path.join(change_root, relative_path)

    cond do
      !File.exists?(path) ->
        {:error, :missing}

      File.dir?(path) ->
        {:error, :directory}

      true ->
        case File.read(path) do
          {:ok, content} -> {:ok, truncate_artifact(content)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_spec_artifacts(change_root) do
    spec_root = Path.join(change_root, "specs")

    if File.dir?(spec_root) do
      spec_root
      |> Path.join("**/spec.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, change_root)
        {relative, File.read!(path) |> truncate_artifact()}
      end)
    else
      []
    end
  end

  defp normalize_artifacts(artifacts) do
    %{
      proposal: unwrap_artifact(artifacts.proposal),
      design: unwrap_artifact(artifacts.design),
      tasks: unwrap_artifact(artifacts.tasks),
      specs: artifacts.specs
    }
  end

  defp unwrap_artifact({:ok, content}), do: content
  defp unwrap_artifact({:error, _reason}), do: nil

  defp build_context(%WorkItem{} = work_item, source_repo, workspace, artifacts) do
    %{
      event_id: work_item.event_id,
      run_id: work_item.run_id,
      repo_path: source_repo,
      repo_name: work_item.repo_name || Path.basename(source_repo),
      repo_remote: work_item.repo_remote,
      workspace_path: workspace,
      change: work_item.change,
      branch_name: branch_name(work_item),
      artifacts: artifacts,
      validation: work_item.validation || %{},
      git_ref: work_item.git_ref,
      base_commit_sha: current_commit(workspace),
      requested_by: work_item.requested_by
    }
  end

  @spec build_prompt(execution_context()) :: String.t()
  def build_prompt(context) when is_map(context) do
    spec_sections =
      context.artifacts.specs
      |> Enum.map_join("\n\n", fn {path, content} -> "### #{path}\n\n#{content}" end)

    """
    You are Symphony Studio Runner working on an OpenSpec change.

    This is an unattended orchestration session. Do not ask a human to do follow-up actions.
    Work only in the Symphony-managed workspace below. Do not modify the original source repo path.

    Repository:
    - Name: #{context.repo_name}
    - Original repo path: #{context.repo_path}
    - Workspace path: #{context.workspace_path}
    - Remote: #{context.repo_remote || "unknown"}
    - Git ref at dispatch: #{context.git_ref || "unknown"}

    Studio Runner work:
    - Event ID: #{context.event_id}
    - Run ID: #{context.run_id || "unknown"}
    - Change: #{context.change}
    - Branch to create/use: #{context.branch_name}
    - Requested by: #{context.requested_by || "unknown"}
    - Validation at dispatch: #{inspect(context.validation)}

    Required workflow:
    1. Inspect the OpenSpec change artifacts below and the repository state.
    2. Create or switch to branch `#{context.branch_name}` from the repo default branch when possible.
    3. Implement the selected OpenSpec change.
    4. Update `openspec/changes/#{context.change}/tasks.md` only for work actually completed.
    5. Run targeted validation/tests and record the evidence.
    6. Commit completed work on `#{context.branch_name}`.
    7. Push the branch and open a pull request using normal repo/GitHub tooling when auth/tools permit.
    8. If push or PR creation is blocked by missing auth/tooling, stop as blocked. Do not call local-only changes complete.
    9. Final response must include status, validation evidence, commit SHA when available, and PR URL when available.

    OpenSpec proposal:
    #{context.artifacts.proposal || "No proposal.md found."}

    OpenSpec design:
    #{context.artifacts.design || "No design.md found."}

    OpenSpec tasks:
    #{context.artifacts.tasks || "No tasks.md found."}

    OpenSpec spec deltas:
    #{if spec_sections == "", do: "No spec deltas found.", else: spec_sections}
    """
  end

  defp run_codex(workspace, prompt, %WorkItem{} = work_item, opts) do
    codex_runner = Keyword.get(opts, :codex_runner, &default_codex_runner/4)
    codex_runner.(workspace, prompt, work_item, opts)
  end

  defp default_codex_runner(workspace, prompt, work_item, opts) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    with {:ok, session} <- AppServer.start_session(workspace) do
      try do
        run_codex_turns(session, workspace, prompt, work_item, 1, max_turns)
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp run_codex_turns(session, workspace, prompt, work_item, turn_number, max_turns) do
    turn_prompt =
      if turn_number == 1, do: prompt, else: continuation_prompt(turn_number, max_turns)

    case AppServer.run_turn(session, turn_prompt, issue_like_context(work_item), []) do
      {:ok, result} ->
        if turn_number < max_turns do
          # Studio Runner has no tracker state to poll yet. One successful turn is the
          # first safe slice; later status extraction can decide whether to continue.
          {:ok, Map.put(result, :workspace_path, workspace)}
        else
          {:ok, Map.put(result, :workspace_path, workspace)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execution_metadata(context, result) when is_map(context) and is_map(result) do
    pr_url = result[:pr_url]
    commit_sha = result[:commit_sha]
    status = result[:status] || terminal_status(pr_url)

    %{
      status: status,
      workspacePath: context.workspace_path,
      sessionId: result[:session_id],
      branchName: result[:branch_name] || context.branch_name,
      commitSha: commit_sha,
      prUrl: pr_url,
      error: result[:error]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp terminal_status(pr_url) when is_binary(pr_url) and pr_url != "", do: "completed"
  defp terminal_status(_pr_url), do: "blocked"

  defp inspect_published_work(workspace, context, opts) do
    inspector = Keyword.get(opts, :publish_inspector, &inspect_workspace_publication/2)
    inspector.(workspace, context)
  end

  @spec inspect_workspace_publication(Path.t(), execution_context()) :: {:ok, map()}
  def inspect_workspace_publication(workspace, context) when is_binary(workspace) and is_map(context) do
    expected_branch = context.branch_name
    actual_branch = current_branch(workspace)
    branch_name = actual_branch || expected_branch
    head_commit = current_commit(workspace)
    commit_sha = published_commit_sha(head_commit, context)

    pr_url =
      if actual_branch == expected_branch and commit_sha do
        pull_request_url(workspace, actual_branch)
      end

    metadata = %{
      branch_name: branch_name,
      commit_sha: commit_sha,
      pr_url: pr_url,
      status: terminal_status(pr_url),
      expected_branch: expected_branch,
      actual_branch: actual_branch,
      head_commit: head_commit
    }

    error = publication_blocker(metadata, workspace)

    metadata =
      if error do
        Map.put(metadata, :error, error)
      else
        metadata
      end

    {:ok, metadata}
  end

  defp published_commit_sha(nil, _context), do: nil

  defp published_commit_sha(head_commit, context) do
    base_commits =
      [Map.get(context, :base_commit_sha), Map.get(context, :git_ref)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if head_commit in base_commits do
      nil
    else
      head_commit
    end
  end

  defp current_branch(workspace) do
    case run_workspace_command(workspace, "git", ["branch", "--show-current"]) do
      {:ok, branch} -> blank_to_nil(branch)
      {:error, _reason} -> nil
    end
  end

  defp current_commit(workspace) do
    case run_workspace_command(workspace, "git", ["rev-parse", "HEAD"]) do
      {:ok, sha} -> blank_to_nil(sha)
      {:error, _reason} -> nil
    end
  end

  defp pull_request_url(workspace, branch_name) when is_binary(branch_name) do
    case run_workspace_command(workspace, "gh", ["pr", "view", branch_name, "--json", "url", "--jq", ".url"]) do
      {:ok, url} -> blank_to_nil(url)
      {:error, _reason} -> nil
    end
  end

  defp pull_request_url(_workspace, _branch_name), do: nil

  defp publication_blocker(%{status: "completed"}, _workspace), do: nil

  defp publication_blocker(%{actual_branch: actual, expected_branch: expected}, _workspace)
       when is_binary(actual) and is_binary(expected) and actual != expected do
    "Studio Runner finished on branch `#{actual}` instead of expected branch `#{expected}`."
  end

  defp publication_blocker(%{commit_sha: nil}, _workspace),
    do: "Studio Runner finished without a new workspace commit."

  defp publication_blocker(%{branch_name: nil}, _workspace),
    do: "Studio Runner finished without a detectable branch."

  defp publication_blocker(%{branch_name: branch_name}, workspace) do
    if branch_pushed?(workspace, branch_name) do
      "Studio Runner created/pushed branch `#{branch_name}` but no pull request URL was available."
    else
      "Studio Runner created local workspace changes but no pushed branch or pull request was available."
    end
  end

  defp branch_pushed?(workspace, branch_name) when is_binary(branch_name) do
    case run_workspace_command(workspace, "git", ["rev-parse", "--verify", "@{u}"]) do
      {:ok, _upstream} ->
        true

      {:error, _reason} ->
        case run_workspace_command(workspace, "git", ["ls-remote", "--heads", "origin", branch_name]) do
          {:ok, output} -> blank_to_nil(output) != nil
          {:error, _reason} -> false
        end
    end
  end

  defp branch_pushed?(_workspace, _branch_name), do: false

  defp run_workspace_command(workspace, command, args) do
    task =
      Task.async(fn ->
        try do
          System.cmd(command, args, cd: workspace, stderr_to_stdout: true)
        rescue
          error in ErlangError -> {:__command_error__, error.original}
        end
      end)

    case Task.yield(task, @git_command_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {:__command_error__, reason}} -> {:error, {command, reason}}
      {:ok, {output, status}} -> {:error, {command, status, bounded_output(output)}}
      nil -> {:error, {command, :timeout}}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp continuation_prompt(turn_number, max_turns) do
    """
    Continuation guidance:

    - This is continuation turn #{turn_number} of #{max_turns} for the current Studio Runner OpenSpec run.
    - Resume from the current workspace and continue the selected OpenSpec change.
    - Do not restart from scratch. Focus only on remaining implementation, validation, branch, commit, push, and PR work.
    """
  end

  defp issue_like_context(%WorkItem{} = work_item) do
    %{
      id: work_item.event_id,
      identifier: work_item.change,
      title: "OpenSpec change #{work_item.change}",
      state: "In Progress"
    }
  end

  defp branch_name(%WorkItem{} = work_item) do
    "studio-runner/#{safe_identifier(work_item.change)}/#{short_event_id(work_item.event_id)}"
  end

  defp short_event_id(event_id) when is_binary(event_id) do
    event_id
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 10)
    |> case do
      "" -> "event"
      value -> value
    end
  end

  defp safe_identifier(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "-")
    |> String.trim("-")
    |> case do
      "" -> "work"
      value -> value
    end
  end

  defp safe_identifier(_identifier), do: "work"

  defp hook_context(%WorkItem{} = work_item) do
    %{id: work_item.event_id, identifier: workspace_identifier(work_item)}
  end

  defp ensure_inside_workspace(workspace, path) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(path) do
      prefix = canonical_workspace <> "/"

      if canonical_path == canonical_workspace or String.starts_with?(canonical_path, prefix) do
        :ok
      else
        {:error, {:path_outside_workspace, canonical_path}}
      end
    end
  end

  defp truncate_artifact(content) when is_binary(content) do
    if byte_size(content) > @max_artifact_bytes do
      binary_part(content, 0, @max_artifact_bytes) <> "\n\n[truncated]"
    else
      content
    end
  end

  defp bounded_output(output, max_bytes \\ 4_096) when is_binary(output) do
    if byte_size(output) > max_bytes do
      binary_part(output, 0, max_bytes) <> "... (truncated)"
    else
      output
    end
  end
end
