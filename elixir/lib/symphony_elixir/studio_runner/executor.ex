defmodule SymphonyElixir.StudioRunner.Executor do
  @moduledoc """
  Executes accepted Studio Runner OpenSpec work.

  The signed ingress path owns verification, idempotency, and async dispatch. This
  module turns the accepted work item into a Symphony-managed Git worktree plus a
  Codex app-server run. Studio Runner work stays OpenSpec-native: it does not
  require Linear credentials or tracker state.
  """

  require Logger

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, PathSafety, Workspace}
  alias SymphonyElixir.StudioRunner.WorkItem

  @required_artifacts ["proposal.md", "tasks.md"]
  @max_artifact_bytes 64_000
  @git_command_timeout_ms 15_000
  @cleanup_error_max_bytes 1_024
  @debug_retention_seconds 7 * 24 * 60 * 60
  @closed_pr_retention_seconds 7 * 24 * 60 * 60
  @abandoned_retention_seconds 3 * 24 * 60 * 60

  @type execution_context :: %{
          event_id: String.t(),
          run_id: String.t() | nil,
          repo_path: Path.t(),
          repo_name: String.t(),
          repo_remote: String.t() | nil,
          workspace_path: Path.t(),
          change: String.t(),
          branch_name: String.t(),
          artifacts: map(),
          validation: map(),
          git_ref: String.t() | nil,
          base_commit_sha: String.t() | nil,
          requested_by: String.t() | nil,
          workspace_lifecycle: map()
        }

  @type cleanup_metadata :: %{
          required(:workspacePath) => Path.t(),
          optional(:status) => String.t(),
          optional(:cleanupEligible) => boolean(),
          optional(:cleanupReason) => String.t(),
          optional(:cleanupError) => String.t(),
          optional(:cleanupStatus) => String.t(),
          optional(:prState) => String.t(),
          optional(:prMergedAt) => String.t(),
          optional(:prClosedAt) => String.t()
        }

  @spec run(WorkItem.t()) :: {:ok, map()} | {:error, term()}
  def run(%WorkItem{} = work_item) do
    Logger.info("Starting Studio Runner execution event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} repo_path=#{work_item.repo_path} change=#{work_item.change}")

    case execute(work_item) do
      {:ok, context, result} ->
        metadata = execution_metadata(context, result)

        Logger.info(
          "Studio Runner execution completed event_id=#{work_item.event_id} run_id=#{work_item.run_id || "n/a"} workspace=#{context.workspace_path} session_id=#{metadata[:sessionId] || "n/a"} status=#{metadata[:status]}"
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
         {:ok, git_source} <- source_repo_git_metadata(source_repo, work_item, opts),
         {:ok, workspace_lifecycle} <-
           prepare_worktree_workspace(source_repo, git_source, work_item, opts),
         workspace <- workspace_lifecycle.workspace_path,
         :ok <- Workspace.run_before_run_hook(workspace, hook_context(work_item), nil),
         {:ok, artifacts} <- load_change_artifacts(workspace, work_item.change),
         context <- build_context(work_item, source_repo, workspace_lifecycle, artifacts),
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
           git_repo?(canonical_repo) ||
             {:error, {:invalid_repo_path, :missing_git_dir}} do
      {:ok, canonical_repo}
    end
  end

  def canonical_source_repo(_repo_path), do: {:error, {:invalid_repo_path, :not_string}}

  @spec source_repo_git_metadata(Path.t(), WorkItem.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def source_repo_git_metadata(source_repo, %WorkItem{} = work_item, opts \\ [])
      when is_binary(source_repo) do
    discover_fun = Keyword.get(opts, :discover_git_source, &discover_git_source/2)
    discover_fun.(source_repo, work_item)
  end

  @spec discover_git_source(Path.t(), WorkItem.t()) :: {:ok, map()} | {:error, term()}
  def discover_git_source(source_repo, %WorkItem{} = work_item) when is_binary(source_repo) do
    remote_name = "origin"

    with {:ok, repo_root} <- git_output(source_repo, ["rev-parse", "--show-toplevel"]),
         {:ok, canonical_root} <- PathSafety.canonicalize(repo_root),
         true <-
           canonical_root == source_repo ||
             {:error, {:repo_path_not_git_root, source_repo, canonical_root}},
         {:ok, remote_url} <- source_remote_url(source_repo, remote_name, work_item),
         {:ok, default_branch} <- source_default_branch(source_repo, remote_name) do
      {:ok,
       %{
         source_repo: source_repo,
         remote_name: remote_name,
         remote_url: remote_url,
         default_branch: default_branch,
         remote_ref: "#{remote_name}/#{default_branch}",
         current_commit: current_commit(source_repo)
       }}
    end
  end

  @spec fetch_source_remote(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def fetch_source_remote(source_repo, git_source, opts \\ [])
      when is_binary(source_repo) and is_map(git_source) do
    fetch_fun = Keyword.get(opts, :fetch_remote, &default_fetch_remote/2)
    fetch_fun.(source_repo, git_source)
  end

  @spec default_fetch_remote(Path.t(), map()) :: :ok | {:error, term()}
  def default_fetch_remote(source_repo, %{remote_name: remote_name})
      when is_binary(remote_name) do
    case run_git(source_repo, ["fetch", remote_name]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:source_fetch_failed, reason}}
    end
  end

  @spec prepare_worktree_workspace(Path.t(), map(), WorkItem.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_worktree_workspace(source_repo, git_source, %WorkItem{} = work_item, opts \\ []) do
    with :ok <- fetch_source_remote(source_repo, git_source, opts),
         {:ok, workspace_path} <- studio_runner_workspace_path(work_item),
         :ok <- validate_worktree_workspace_path(workspace_path, source_repo),
         {:ok, base_commit_sha} <- git_output(source_repo, ["rev-parse", git_source.remote_ref]),
         branch_name <- branch_name(work_item),
         lifecycle <- %{
           event_id: work_item.event_id,
           run_id: work_item.run_id,
           repo_path: source_repo,
           repo_name: work_item.repo_name || Path.basename(source_repo),
           change_name: work_item.change,
           workspace_path: workspace_path,
           branch_name: branch_name,
           base_ref: git_source.remote_ref,
           base_commit_sha: base_commit_sha,
           status: "active",
           created_at: DateTime.utc_now(),
           updated_at: DateTime.utc_now()
         },
         :ok <-
           create_or_reuse_worktree(
             source_repo,
             workspace_path,
             branch_name,
             git_source.remote_ref,
             work_item
           ),
         :ok <- write_worktree_marker(workspace_path, lifecycle),
         :ok <- copy_repo_codex_skills(source_repo, workspace_path) do
      {:ok, lifecycle}
    end
  end

  @spec remove_worktree(Path.t(), Path.t()) :: cleanup_metadata()
  def remove_worktree(source_repo, workspace_path)
      when is_binary(source_repo) and is_binary(workspace_path) do
    with {:ok, canonical_source} <- canonical_source_repo(source_repo),
         :ok <- validate_worktree_cleanup_path(canonical_source, workspace_path),
         :ok <- ensure_registered_worktree(canonical_source, workspace_path) do
      remove_registered_worktree(canonical_source, workspace_path)
    else
      {:error, reason} -> cleanup_error_metadata(workspace_path, reason)
    end
  end

  @spec cleanup_metadata(map(), DateTime.t()) :: cleanup_metadata()
  def cleanup_metadata(event_metadata, now \\ DateTime.utc_now()) when is_map(event_metadata) do
    workspace_path =
      Map.get(event_metadata, :workspacePath) || Map.get(event_metadata, "workspacePath")

    status = Map.get(event_metadata, :status) || Map.get(event_metadata, "status")
    pr_url = Map.get(event_metadata, :prUrl) || Map.get(event_metadata, "prUrl")
    pr_state = Map.get(event_metadata, :prState) || Map.get(event_metadata, "prState")
    pr_merged_at = Map.get(event_metadata, :prMergedAt) || Map.get(event_metadata, "prMergedAt")
    pr_closed_at = Map.get(event_metadata, :prClosedAt) || Map.get(event_metadata, "prClosedAt")

    updated_at =
      Map.get(event_metadata, :updatedAt) || Map.get(event_metadata, "updatedAt") || now

    {pr_metadata, refreshed?} =
      cleanup_pull_request_metadata(status, workspace_path, pr_url, %{
        state: pr_state,
        merged_at: pr_merged_at,
        closed_at: pr_closed_at
      })

    pr_state = pr_metadata[:state]
    pr_merged_at = pr_metadata[:merged_at]
    pr_closed_at = pr_metadata[:closed_at]

    {eligible?, reason} =
      cleanup_eligibility(
        status,
        pr_url,
        pr_state,
        pr_merged_at,
        pr_closed_at,
        updated_at,
        now,
        refreshed?
      )

    %{
      workspacePath: workspace_path,
      status: status,
      prState: pr_state,
      prMergedAt: pr_merged_at,
      prClosedAt: pr_closed_at,
      cleanupEligible: eligible?,
      cleanupReason: reason
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp copy_repo_codex_skills(source_repo, workspace_path) do
    source_skills = Path.join(source_repo, ".codex/skills")
    destination_skills = Path.join(workspace_path, ".codex/skills")

    if File.dir?(source_skills) do
      File.mkdir_p!(Path.dirname(destination_skills))
      File.rm_rf!(destination_skills)
      File.cp_r!(source_skills, destination_skills)
    end

    :ok
  end

  defp validate_change_name(change) when is_binary(change) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, change) do
      :ok
    else
      {:error, {:invalid_change_name, change}}
    end
  end

  defp validate_change_name(change), do: {:error, {:invalid_change_name, change}}

  defp git_repo?(repo_path) do
    File.dir?(Path.join(repo_path, ".git")) or File.exists?(Path.join(repo_path, ".git"))
  end

  defp source_remote_url(source_repo, remote_name, %WorkItem{repo_remote: repo_remote}) do
    case git_output(source_repo, ["remote", "get-url", remote_name]) do
      {:ok, remote_url} -> {:ok, remote_url}
      {:error, reason} -> fallback_remote_url(repo_remote, reason)
    end
  end

  defp fallback_remote_url(repo_remote, _reason) when is_binary(repo_remote) do
    case String.trim(repo_remote) do
      "" -> {:error, {:missing_remote, "origin"}}
      remote_url -> {:ok, remote_url}
    end
  end

  defp fallback_remote_url(_repo_remote, reason),
    do: {:error, {:missing_remote, "origin", reason}}

  defp source_default_branch(source_repo, remote_name) do
    case git_output(source_repo, [
           "symbolic-ref",
           "--quiet",
           "--short",
           "refs/remotes/#{remote_name}/HEAD"
         ]) do
      {:ok, remote_head} ->
        remote_prefix = remote_name <> "/"

        if String.starts_with?(remote_head, remote_prefix) do
          {:ok, String.replace_prefix(remote_head, remote_prefix, "")}
        else
          {:ok, remote_head}
        end

      {:error, _reason} ->
        case git_output(source_repo, ["remote", "show", remote_name]) do
          {:ok, output} -> parse_remote_show_head(output)
          {:error, reason} -> fallback_default_branch(source_repo, reason)
        end
    end
  end

  defp parse_remote_show_head(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case Regex.run(~r/HEAD branch:\s*(\S+)/, line) do
        [_, branch] -> branch
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :missing_remote_default_branch}
      branch -> {:ok, branch}
    end
  end

  defp fallback_default_branch(source_repo, reason) do
    cond do
      match?({:ok, _}, git_output(source_repo, ["rev-parse", "--verify", "origin/main"])) ->
        {:ok, "main"}

      match?({:ok, _}, git_output(source_repo, ["rev-parse", "--verify", "origin/master"])) ->
        {:ok, "master"}

      true ->
        {:error, {:missing_remote_default_branch, reason}}
    end
  end

  defp studio_runner_workspace_path(%WorkItem{} = work_item) do
    root = Config.settings!().workspace.root

    workspace =
      root
      |> Path.join("runs")
      |> Path.join(safe_identifier(work_item.repo_name || Path.basename(work_item.repo_path)))
      |> Path.join(safe_identifier(work_item.change))
      |> Path.join(safe_identifier(work_item.run_id || work_item.event_id))

    PathSafety.canonicalize(workspace)
  end

  defp validate_worktree_workspace_path(workspace_path, source_repo) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path),
         {:ok, canonical_root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         {:ok, canonical_source} <- PathSafety.canonicalize(source_repo) do
      root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace}}

        canonical_workspace == canonical_source ->
          {:error, {:workspace_equals_source_repo, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", root_prefix) ->
          :ok

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    end
  end

  defp validate_worktree_cleanup_path(source_repo, workspace_path) do
    with :ok <- validate_worktree_workspace_path(workspace_path, source_repo),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path),
         true <-
           File.dir?(canonical_workspace) || {:error, {:workspace_missing, canonical_workspace}} do
      ensure_inactive_worktree(canonical_workspace)
    end
  end

  defp ensure_inactive_worktree(workspace_path) do
    case read_worktree_marker(workspace_path) do
      {:ok, %{"status" => status}} when status in ["active", "running", "accepted"] ->
        {:error, {:workspace_active, workspace_path}}

      {:ok, _marker} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp create_or_reuse_worktree(
         source_repo,
         workspace_path,
         branch_name,
         remote_ref,
         %WorkItem{} = work_item
       ) do
    cond do
      File.dir?(workspace_path) ->
        validate_existing_retry_worktree(
          source_repo,
          workspace_path,
          branch_name,
          remote_ref,
          work_item
        )

      File.exists?(workspace_path) ->
        {:error, {:workspace_path_conflict, workspace_path}}

      branch_exists?(source_repo, branch_name) ->
        {:error, {:branch_already_exists, branch_name}}

      true ->
        File.mkdir_p!(Path.dirname(workspace_path))
        add_worktree(source_repo, workspace_path, branch_name, remote_ref)
    end
  end

  defp validate_existing_retry_worktree(
         source_repo,
         workspace_path,
         branch_name,
         remote_ref,
         %WorkItem{} = work_item
       ) do
    with :ok <- ensure_registered_worktree(source_repo, workspace_path),
         {:ok, actual_branch} <- git_output(workspace_path, ["branch", "--show-current"]),
         true <-
           actual_branch == branch_name ||
             {:error, {:workspace_branch_mismatch, actual_branch, branch_name}},
         {:ok, marker} <- read_worktree_marker(workspace_path),
         true <-
           Map.get(marker, "event_id") == work_item.event_id ||
             {:error, {:workspace_event_mismatch, workspace_path}},
         true <-
           Map.get(marker, "run_id") == work_item.run_id ||
             {:error, {:workspace_run_mismatch, workspace_path}} do
      ensure_worktree_base_available(workspace_path, remote_ref)
    end
  end

  defp add_worktree(source_repo, workspace_path, branch_name, remote_ref) do
    case run_git(source_repo, ["worktree", "add", workspace_path, "-b", branch_name, remote_ref]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:worktree_create_failed, reason}}
    end
  end

  defp ensure_worktree_base_available(workspace_path, remote_ref) do
    case run_git(workspace_path, ["rev-parse", "--verify", remote_ref]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:worktree_base_unavailable, remote_ref, reason}}
    end
  end

  defp write_worktree_marker(workspace_path, lifecycle) do
    marker_path = Path.join(workspace_path, ".symphony-studio-runner.json")

    payload = %{
      event_id: lifecycle.event_id,
      run_id: lifecycle.run_id,
      repo_path: lifecycle.repo_path,
      repo_name: lifecycle.repo_name,
      change_name: lifecycle.change_name,
      workspace_path: lifecycle.workspace_path,
      branch_name: lifecycle.branch_name,
      base_ref: lifecycle.base_ref,
      base_commit_sha: lifecycle.base_commit_sha,
      status: lifecycle.status,
      created_at: DateTime.to_iso8601(lifecycle.created_at),
      updated_at: DateTime.to_iso8601(lifecycle.updated_at)
    }

    File.write(marker_path, Jason.encode!(payload, pretty: true))
  end

  defp read_worktree_marker(workspace_path) do
    marker_path = Path.join(workspace_path, ".symphony-studio-runner.json")

    with {:ok, content} <- File.read(marker_path),
         {:ok, payload} when is_map(payload) <- Jason.decode(content) do
      {:ok, payload}
    else
      {:error, reason} -> {:error, {:workspace_marker_unreadable, reason}}
      _ -> {:error, :workspace_marker_invalid}
    end
  end

  defp ensure_registered_worktree(source_repo, workspace_path) do
    with {:ok, output} <- git_output(source_repo, ["worktree", "list", "--porcelain"]),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace_path) do
      if registered_worktree?(output, canonical_workspace) do
        :ok
      else
        {:error, {:unknown_worktree, workspace_path}}
      end
    end
  end

  defp registered_worktree?(output, canonical_workspace) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.any?(&worktree_path_matches?(&1, canonical_workspace))
  end

  defp worktree_path_matches?(path, canonical_workspace) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> canonical_path == canonical_workspace
      {:error, _reason} -> false
    end
  end

  defp branch_exists?(source_repo, branch_name) do
    match?(
      {:ok, _},
      git_output(source_repo, ["show-ref", "--verify", "refs/heads/#{branch_name}"])
    )
  end

  defp prune_worktrees(source_repo) do
    case run_git(source_repo, ["worktree", "prune"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:worktree_prune_failed, reason}}
    end
  end

  defp cleanup_error_metadata(workspace_path, reason) do
    %{
      workspacePath: workspace_path,
      cleanupStatus: "blocked",
      cleanupError: bounded_output(inspect(reason), @cleanup_error_max_bytes)
    }
  end

  defp remove_registered_worktree(canonical_source, workspace_path) do
    case run_git(canonical_source, ["worktree", "remove", workspace_path]) do
      {:ok, _output} ->
        prune_worktrees(canonical_source)
        %{workspacePath: workspace_path, cleanupStatus: "cleaned"}

      {:error, {_command, _status, output} = reason} ->
        metadata = cleanup_error_metadata(workspace_path, {:worktree_remove_failed, reason})

        if missing_worktree_output?(output) do
          prune_worktrees(canonical_source)
        end

        metadata

      {:error, reason} ->
        cleanup_error_metadata(workspace_path, {:worktree_remove_failed, reason})
    end
  end

  defp cleanup_pull_request_metadata(status, workspace_path, pr_url, stored_metadata) do
    if status == "completed" and nonblank_string?(pr_url) and is_binary(workspace_path) and
         File.dir?(workspace_path) do
      case pull_request_metadata(workspace_path, pr_url) do
        metadata when map_size(metadata) > 0 ->
          {Map.merge(stored_metadata, metadata), true}

        _ ->
          {stored_metadata, false}
      end
    else
      {stored_metadata, false}
    end
  end

  defp cleanup_eligibility(
         "completed",
         pr_url,
         pr_state,
         pr_merged_at,
         pr_closed_at,
         updated_at,
         now,
         refreshed?
       ) do
    completed_cleanup_eligibility(
      pr_url,
      pr_state,
      pr_merged_at,
      pr_closed_at,
      updated_at,
      now,
      refreshed?
    )
  end

  defp cleanup_eligibility(status, _pr_url, _pr_state, _pr_merged_at, _pr_closed_at, _updated_at, _now, _refreshed?)
       when status in ["running", "accepted"],
       do: {false, "active"}

  defp cleanup_eligibility(status, _pr_url, _pr_state, _pr_merged_at, _pr_closed_at, updated_at, now, _refreshed?)
       when status in ["blocked", "failed"] do
    if older_than?(updated_at, now, @debug_retention_seconds) do
      {true, "debug_ttl_expired"}
    else
      {false, "debug_ttl"}
    end
  end

  defp cleanup_eligibility("abandoned", _pr_url, _pr_state, _pr_merged_at, _pr_closed_at, updated_at, now, _refreshed?) do
    if older_than?(updated_at, now, @abandoned_retention_seconds) do
      {true, "abandoned_ttl_expired"}
    else
      {false, "abandoned_ttl"}
    end
  end

  defp cleanup_eligibility(_status, _pr_url, _pr_state, _pr_merged_at, _pr_closed_at, _updated_at, _now, _refreshed?) do
    {false, nil}
  end

  defp completed_cleanup_eligibility(
         pr_url,
         pr_state,
         pr_merged_at,
         pr_closed_at,
         updated_at,
         now,
         refreshed?
       ) do
    cond do
      pr_merged?(pr_state, pr_merged_at) ->
        {true, "pr_merged"}

      pr_closed?(pr_state) ->
        closed_pr_cleanup_eligibility(pr_closed_at || updated_at, now)

      pr_open?(pr_state) and refreshed? ->
        {false, "pr_open"}

      nonblank_string?(pr_url) ->
        {false, "pr_state_unavailable"}

      true ->
        {false, nil}
    end
  end

  defp closed_pr_cleanup_eligibility(closed_at, now) do
    if older_than?(closed_at, now, @closed_pr_retention_seconds) do
      {true, "pr_closed_ttl_expired"}
    else
      {false, "pr_closed_ttl"}
    end
  end

  defp pr_merged?(state, merged_at) do
    normalize_pr_state(state) == "MERGED" or nonblank_string?(merged_at)
  end

  defp pr_closed?(state), do: normalize_pr_state(state) == "CLOSED"
  defp pr_open?(state), do: normalize_pr_state(state) == "OPEN"

  defp normalize_pr_state(state) when is_binary(state), do: String.upcase(String.trim(state))
  defp normalize_pr_state(_state), do: nil

  defp nonblank_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_string?(_value), do: false

  defp older_than?(%DateTime{} = timestamp, %DateTime{} = now, seconds) do
    DateTime.diff(now, timestamp, :second) >= seconds
  end

  defp older_than?(timestamp, %DateTime{} = now, seconds) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> older_than?(datetime, now, seconds)
      _ -> false
    end
  end

  defp older_than?(_timestamp, _now, _seconds), do: false

  defp missing_worktree_output?(output) when is_binary(output) do
    output =~ "is not a working tree" or output =~ "is not a git repository" or
      output =~ "No such file"
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

  defp build_context(%WorkItem{} = work_item, source_repo, workspace_lifecycle, artifacts) do
    %{
      event_id: work_item.event_id,
      run_id: work_item.run_id,
      repo_path: source_repo,
      repo_name: work_item.repo_name || Path.basename(source_repo),
      repo_remote: work_item.repo_remote,
      workspace_path: workspace_lifecycle.workspace_path,
      change: work_item.change,
      branch_name: workspace_lifecycle.branch_name,
      artifacts: artifacts,
      validation: work_item.validation || %{},
      git_ref: work_item.git_ref,
      base_commit_sha: workspace_lifecycle.base_commit_sha,
      requested_by: work_item.requested_by,
      workspace_lifecycle: workspace_lifecycle
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
    Work only in the Symphony-managed Git worktree below. Do not modify the original source repo path.

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
    - Branch to use: #{context.branch_name}
    - Requested by: #{context.requested_by || "unknown"}
    - Validation at dispatch: #{inspect(context.validation)}

    Required workflow:
    1. Inspect the OpenSpec change artifacts below and the repository state.
    2. Stay on branch `#{context.branch_name}`. It has already been created from the fetched remote default branch.
    3. Implement the selected OpenSpec change.
    4. Update `openspec/changes/#{context.change}/tasks.md` only for work actually completed.
    5. Run targeted validation/tests and record the evidence.
    6. Commit completed work on `#{context.branch_name}`.
    7. Use the repo-local GitHub CLI skill when available, push the branch with `git`, and create the pull request with non-interactive `gh pr create`.
    8. Do not use GitHub connector/MCP tools for pull request creation; unattended connector elicitation can block the runner.
    9. If push or `gh` PR creation is blocked by missing auth/tooling/network, stop as blocked. Do not call local-only changes complete.
    10. Final response must include status, validation evidence, commit SHA when available, and PR URL when available.

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
    pr_state = result[:pr_state]
    pr_merged_at = result[:pr_merged_at]
    pr_closed_at = result[:pr_closed_at]
    commit_sha = result[:commit_sha]
    status = result[:status] || terminal_status(pr_url)
    now = DateTime.utc_now()

    %{
      status: status,
      workspacePath: context.workspace_path,
      workspaceStatus: terminal_workspace_status(status),
      workspaceCreatedAt: iso8601(context.workspace_lifecycle.created_at),
      workspaceUpdatedAt: iso8601(now),
      sourceRepoPath: context.repo_path,
      baseCommitSha: context.base_commit_sha,
      sessionId: result[:session_id],
      branchName: result[:branch_name] || context.branch_name,
      commitSha: commit_sha,
      prUrl: pr_url,
      prState: pr_state,
      prMergedAt: pr_merged_at,
      prClosedAt: pr_closed_at,
      error: result[:error]
    }
    |> Map.merge(
      cleanup_metadata(
        %{
          status: status,
          prUrl: pr_url,
          prState: pr_state,
          prMergedAt: pr_merged_at,
          prClosedAt: pr_closed_at,
          workspacePath: context.workspace_path,
          updatedAt: now
        },
        now
      )
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp terminal_workspace_status("completed"), do: "published"
  defp terminal_workspace_status("blocked"), do: "blocked"
  defp terminal_workspace_status("failed"), do: "failed"
  defp terminal_workspace_status(_status), do: "active"

  defp terminal_status(pr_url) when is_binary(pr_url) and pr_url != "", do: "completed"
  defp terminal_status(_pr_url), do: "blocked"

  defp inspect_published_work(workspace, context, opts) do
    inspector = Keyword.get(opts, :publish_inspector, &inspect_workspace_publication/2)
    inspector.(workspace, context)
  end

  @spec inspect_workspace_publication(Path.t(), execution_context()) :: {:ok, map()}
  def inspect_workspace_publication(workspace, context)
      when is_binary(workspace) and is_map(context) do
    expected_branch = context.branch_name
    actual_branch = current_branch(workspace)
    branch_name = actual_branch || expected_branch
    head_commit = current_commit(workspace)
    commit_sha = published_commit_sha(head_commit, context)

    pr_metadata =
      if actual_branch == expected_branch and commit_sha do
        pull_request_metadata(workspace, actual_branch)
      else
        %{}
      end

    metadata = %{
      branch_name: branch_name,
      commit_sha: commit_sha,
      pr_url: pr_metadata[:url],
      pr_state: pr_metadata[:state],
      pr_merged_at: pr_metadata[:merged_at],
      pr_closed_at: pr_metadata[:closed_at],
      status: terminal_status(pr_metadata[:url]),
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

  defp pull_request_metadata(workspace, branch_name) when is_binary(branch_name) do
    case run_workspace_command(workspace, "gh", [
           "pr",
           "view",
           branch_name,
           "--json",
           "url,state,mergedAt,closedAt"
         ]) do
      {:ok, output} -> parse_pull_request_metadata(output)
      {:error, _reason} -> %{}
    end
  end

  defp pull_request_metadata(_workspace, _branch_name), do: %{}

  defp parse_pull_request_metadata(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{} = payload} ->
        %{
          url: blank_to_nil(Map.get(payload, "url")),
          state: blank_to_nil(Map.get(payload, "state")),
          merged_at: blank_to_nil(Map.get(payload, "mergedAt")),
          closed_at: blank_to_nil(Map.get(payload, "closedAt"))
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _ ->
        %{url: blank_to_nil(output)}
    end
  end

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
        case run_workspace_command(workspace, "git", [
               "ls-remote",
               "--heads",
               "origin",
               branch_name
             ]) do
          {:ok, output} -> blank_to_nil(output) != nil
          {:error, _reason} -> false
        end
    end
  end

  defp branch_pushed?(_workspace, _branch_name), do: false

  defp git_output(repo, args) when is_binary(repo) and is_list(args) do
    run_git(repo, args)
  end

  defp run_git(repo, args) when is_binary(repo) and is_list(args) do
    run_workspace_command(repo, "git", args)
  end

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

  defp blank_to_nil(_value), do: nil

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
    |> String.replace(~r/^evt[-_]?/, "")
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 12)
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

  defp workspace_identifier(%WorkItem{} = work_item) do
    [
      "studio-runner",
      safe_identifier(work_item.repo_name || Path.basename(work_item.repo_path)),
      safe_identifier(work_item.change),
      safe_identifier(work_item.run_id || work_item.event_id)
    ]
    |> Enum.join("-")
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

  defp iso8601(%DateTime{} = datetime),
    do: DateTime.to_iso8601(DateTime.truncate(datetime, :second))

  defp iso8601(_datetime), do: nil
end
