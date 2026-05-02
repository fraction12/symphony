defmodule SymphonyElixir.StudioRunnerIngressTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.Orchestrator

  @endpoint SymphonyElixirWeb.Endpoint

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "health endpoint reports configured signed ingress" do
    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")
    start_test_endpoint([])

    assert json_response(get(build_conn(), "/api/v1/studio-runner/health"), 200) == %{
             "status" => "ok",
             "ingress" => %{
               "configured" => true,
               "acceptingSignedDispatch" => true,
               "replayWindowSeconds" => 300
             }
           }
  end

  test "health endpoint reports degraded signed ingress when secret is missing" do
    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: nil)
    start_test_endpoint([])

    assert json_response(get(build_conn(), "/api/v1/studio-runner/health"), 200) == %{
             "status" => "degraded",
             "ingress" => %{
               "configured" => false,
               "acceptingSignedDispatch" => false,
               "replayWindowSeconds" => 300
             }
           }
  end

  test "valid signed build request is accepted without Linear credentials" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      studio_runner_signing_secret: "studio-secret"
    )

    orchestrator_name = Module.concat(__MODULE__, :LinearlessOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    executor = fn work_item ->
      send(parent, {:executor_started, self(), work_item})

      receive do
        :release_run -> :ok
      end
    end

    start_test_endpoint(orchestrator: orchestrator_name, studio_runner_executor: executor)

    payload = studio_payload("evt-valid", repo_path)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", payload, "studio-secret")

    response = json_response(conn, 202)

    assert response["status"] == "accepted"
    assert response["eventId"] == "evt-valid"
    assert response["repoPath"] == repo_path
    assert response["change"] == "introduce-studio-runner"
    assert is_binary(response["runId"])

    assert_receive {:executor_started, executor_pid, work_item}, 500
    assert work_item.event_id == "evt-valid"
    assert work_item.change == "introduce-studio-runner"
    assert work_item.repo_path == repo_path
    send(executor_pid, :release_run)
  end

  test "valid signed build request preserves runner execution defaults" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :ExecutionDefaultsOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      studio_runner_executor: fn work_item -> send(parent, {:executor_started, work_item}) end
    )

    payload =
      "evt-execution-defaults"
      |> studio_payload(repo_path)
      |> put_in(["data", "execution"], %{"model" => "gpt-custom", "effort" => "high"})

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", payload, "studio-secret")

    response = json_response(conn, 202)

    assert response["status"] == "accepted"
    assert response["runnerModel"] == "gpt-custom"
    assert response["runnerEffort"] == "high"

    assert_receive {:executor_started, work_item}, 500
    assert work_item.runner_model == "gpt-custom"
    assert work_item.runner_effort == "high"
    assert work_item.metadata.runner_model == "gpt-custom"
    assert work_item.metadata.runner_effort == "high"
  end

  test "invalid signature is rejected before dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :InvalidSignatureOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      studio_runner_executor: fn work_item -> send(parent, {:unexpected_dispatch, work_item}) end
    )

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("webhook-id", "evt-invalid")
      |> put_req_header("webhook-timestamp", Integer.to_string(System.system_time(:second)))
      |> put_req_header("webhook-signature", "v1,totally-wrong")
      |> post("/api/v1/studio-runner/events", Jason.encode!(studio_payload("evt-invalid")))

    assert json_response(conn, 401) == %{
             "error" => %{
               "code" => "invalid_webhook_signature",
               "message" => "Webhook signature verification failed"
             }
           }

    refute_receive {:unexpected_dispatch, _work_item}, 100
  end

  test "stale timestamps are rejected before dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      studio_runner_signing_secret: "studio-secret",
      studio_runner_replay_window_seconds: 1
    )

    orchestrator_name = Module.concat(__MODULE__, :StaleTimestampOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      studio_runner_executor: fn work_item -> send(parent, {:unexpected_dispatch, work_item}) end
    )

    payload = studio_payload("evt-stale")
    raw_body = Jason.encode!(payload)
    timestamp = Integer.to_string(System.system_time(:second) - 10)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("webhook-id", "evt-stale")
      |> put_req_header("webhook-timestamp", timestamp)
      |> put_req_header("webhook-signature", signature_header("studio-secret", "evt-stale", timestamp, raw_body))
      |> post("/api/v1/studio-runner/events", raw_body)

    assert json_response(conn, 401) == %{
             "error" => %{
               "code" => "stale_webhook_timestamp",
               "message" => "Webhook timestamp is outside the replay window"
             }
           }

    refute_receive {:unexpected_dispatch, _work_item}, 100
  end

  test "unsupported event type is rejected before dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :UnsupportedEventOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      studio_runner_executor: fn work_item -> send(parent, {:unexpected_dispatch, work_item}) end
    )

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post(
        "/api/v1/studio-runner/events",
        Map.put(studio_payload("evt-other"), "type", "build.completed"),
        "studio-secret"
      )

    assert json_response(conn, 422) == %{
             "error" => %{
               "code" => "unsupported_event_type",
               "message" => "Unsupported event type"
             }
           }

    refute_receive {:unexpected_dispatch, _work_item}, 100
  end

  test "unknown repo paths are rejected before dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :UnknownRepoPathOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    start_test_endpoint(
      orchestrator: orchestrator_name,
      studio_runner_executor: fn work_item -> send(parent, {:unexpected_dispatch, work_item}) end
    )

    missing_repo_path = Path.join(System.tmp_dir!(), "missing-openspec-studio-#{System.unique_integer([:positive])}")

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", studio_payload("evt-missing-repo", missing_repo_path), "studio-secret")

    assert json_response(conn, 400) == %{
             "error" => %{
               "code" => "invalid_payload",
               "message" => "Invalid payload field: data.repoPath"
             }
           }

    refute_receive {:unexpected_dispatch, _work_item}, 100
  end

  test "duplicate event ids do not start a second run" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :DuplicateEventIdOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    executor = fn work_item ->
      send(parent, {:executor_started, self(), work_item})

      receive do
        :release_run -> :ok
      end
    end

    start_test_endpoint(orchestrator: orchestrator_name, studio_runner_executor: executor)
    payload = studio_payload("evt-duplicate", repo_path)

    first_response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", payload, "studio-secret")
      |> json_response(202)

    assert_receive {:executor_started, executor_pid, work_item}, 500
    assert work_item.event_id == "evt-duplicate"

    second_response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", payload, "studio-secret")
      |> json_response(202)

    assert second_response == first_response
    refute_receive {:executor_started, _other_pid, _other_work_item}, 100
    send(executor_pid, :release_run)
  end

  test "duplicate repo/change pairs return a conflict without starting another run" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :DuplicateRepoChangeOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    executor = fn work_item ->
      send(parent, {:executor_started, self(), work_item})

      receive do
        :release_run -> :ok
      end
    end

    start_test_endpoint(orchestrator: orchestrator_name, studio_runner_executor: executor)

    first_payload = studio_payload("evt-one", repo_path)
    second_payload = studio_payload("evt-two", repo_path)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> signed_post("/api/v1/studio-runner/events", first_payload, "studio-secret")
    |> json_response(202)

    assert_receive {:executor_started, executor_pid, work_item}, 500
    assert work_item.event_id == "evt-one"

    conflict_response =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> signed_post("/api/v1/studio-runner/events", second_payload, "studio-secret")
      |> json_response(409)

    assert conflict_response["status"] == "conflict"
    assert conflict_response["eventId"] == "evt-two"
    assert conflict_response["runId"] == work_item.run_id
    assert conflict_response["repoPath"] == repo_path
    assert conflict_response["change"] == "introduce-studio-runner"

    assert conflict_response["error"] == %{
             "code" => "duplicate_repo_change",
             "message" => "Work already running for repository/change"
           }

    refute_receive {:executor_started, _other_pid, _other_work_item}, 100
    send(executor_pid, :release_run)
  end

  test "event stream emits current Studio Runner metadata as SSE" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :EventStreamSnapshotOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    executor = fn work_item ->
      send(parent, {:executor_started, self(), work_item})

      {:ok,
       %{
         status: "completed",
         workspacePath: "/workspace/run-demo",
         sessionId: "session-demo",
         branchName: "studio-runner/introduce-studio-runner",
         commitSha: "abc1234",
         prUrl: "https://github.com/fraction12/openspec-studio/pull/1",
         sourceRepoPath: repo_path,
         baseCommitSha: "base1234",
         workspaceStatus: "published",
         cleanupEligible: true,
         cleanupReason: "published"
       }}
    end

    start_test_endpoint(orchestrator: orchestrator_name, studio_runner_executor: executor)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> signed_post("/api/v1/studio-runner/events", studio_payload("evt-stream", repo_path), "studio-secret")
    |> json_response(202)

    assert_receive {:executor_started, _executor_pid, _work_item}, 500

    assert_eventually(fn ->
      payload = Orchestrator.snapshot(orchestrator_name, 1_000).studio_runner.events
      Enum.any?(payload, &(&1.status == "completed"))
    end)

    conn = get(build_conn(), "/api/v1/studio-runner/events/stream?limit=1", %{})

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/event-stream; charset=utf-8"]
    assert conn.resp_body =~ "event: runner.snapshot"
    assert conn.resp_body =~ "evt-stream"
    assert conn.resp_body =~ "session-demo"
    assert conn.resp_body =~ "abc1234"
    assert conn.resp_body =~ "https://github.com/fraction12/openspec-studio/pull/1"
    assert conn.resp_body =~ "base1234"
    assert conn.resp_body =~ "cleanupEligible"
    refute conn.resp_body =~ "proposal.md contents"
  end

  test "event stream emits live updates after client connects" do
    repo_path = Path.join(System.tmp_dir!(), "openspec-studio-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_path)

    write_workflow_file!(Workflow.workflow_file_path(), studio_runner_signing_secret: "studio-secret")

    orchestrator_name = Module.concat(__MODULE__, :EventStreamLiveOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})
    parent = self()

    executor = fn work_item ->
      send(parent, {:executor_started, self(), work_item})
      {:ok, %{status: "blocked", error: "PR URL was not found"}}
    end

    start_test_endpoint(orchestrator: orchestrator_name, studio_runner_executor: executor)

    stream_task =
      Task.async(fn ->
        get(build_conn(), "/api/v1/studio-runner/events/stream?limit=2", %{})
      end)

    :timer.sleep(50)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> signed_post("/api/v1/studio-runner/events", studio_payload("evt-live-stream", repo_path), "studio-secret")
    |> json_response(202)

    assert_receive {:executor_started, _executor_pid, _work_item}, 500
    conn = Task.await(stream_task, 1_000)

    assert conn.resp_body =~ "event: runner.blocked"
    assert conn.resp_body =~ "evt-live-stream"
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      :timer.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp signed_post(conn, path, payload, signing_secret) do
    raw_body = Jason.encode!(payload)
    event_id = payload["id"]
    timestamp = Integer.to_string(System.system_time(:second))

    conn
    |> put_req_header("webhook-id", event_id)
    |> put_req_header("webhook-timestamp", timestamp)
    |> put_req_header("webhook-signature", signature_header(signing_secret, event_id, timestamp, raw_body))
    |> post(path, raw_body)
  end

  defp signature_header(signing_secret, event_id, timestamp, raw_body) do
    payload = event_id <> "." <> timestamp <> "." <> raw_body
    signature = :crypto.mac(:hmac, :sha256, signing_secret, payload) |> Base.encode64()
    "v1," <> signature
  end

  defp studio_payload(event_id, repo_path \\ "/tmp/openspec-studio") do
    %{
      "id" => event_id,
      "type" => "build.requested",
      "source" => "openspec-studio",
      "time" => "2026-04-29T12:40:10Z",
      "data" => %{
        "runner" => "studio-runner",
        "repoPath" => repo_path,
        "repoName" => "openspec-studio",
        "repoRemote" => "git@github.com:fraction12/openspec-studio.git",
        "gitRef" => "main",
        "change" => "introduce-studio-runner",
        "artifactPaths" => [
          "openspec/changes/introduce-studio-runner/proposal.md",
          "openspec/changes/introduce-studio-runner/design.md",
          "openspec/changes/introduce-studio-runner/tasks.md"
        ],
        "validation" => %{
          "state" => "passed",
          "checkedAt" => "2026-04-29T12:40:00Z"
        },
        "requestedBy" => "local-user"
      }
    }
  end
end
