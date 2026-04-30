defmodule SymphonyElixirWeb.StudioRunnerController do
  @moduledoc """
  Signed ingress and health surface for OpenSpec Studio Runner push dispatch.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.StudioRunner.{IngressVerifier, Payload, WorkItem}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @spec health(Conn.t(), map()) :: Conn.t()
  def health(conn, _params) do
    settings = Config.settings!()
    configured? = signing_secret_configured?(settings)

    json(conn, %{
      status: if(configured?, do: "ok", else: "degraded"),
      ingress: %{
        configured: configured?,
        acceptingSignedDispatch: configured?,
        replayWindowSeconds: settings.studio_runner.replay_window_seconds
      }
    })
  end

  @spec events(Conn.t(), map()) :: Conn.t()
  def events(conn, params) do
    settings = Config.settings!()

    with {:ok, signing_secret} <- fetch_signing_secret(settings),
         raw_body <- raw_body(conn),
         {:ok, %{event_id: event_id}} <-
           IngressVerifier.verify(
             conn,
             raw_body,
             signing_secret,
             settings.studio_runner.replay_window_seconds
           ),
         {:ok, work_item} <- Payload.normalize(params, event_id),
         {:ok, payload} <- dispatch(work_item) do
      conn
      |> put_status(202)
      |> json(payload)
    else
      {:error, {:duplicate_repo_change, payload}} ->
        conn
        |> put_status(409)
        |> json(Map.put(payload, :status, "conflict"))

      {:error, :missing_signing_secret} ->
        error_response(conn, 503, "signing_secret_missing", "Studio Runner signing secret is not configured")

      {:error, :missing_headers} ->
        error_response(conn, 401, "missing_webhook_headers", "Missing required webhook headers")

      {:error, :invalid_timestamp} ->
        error_response(conn, 401, "invalid_webhook_timestamp", "Invalid webhook timestamp")

      {:error, :stale_timestamp} ->
        error_response(conn, 401, "stale_webhook_timestamp", "Webhook timestamp is outside the replay window")

      {:error, :unsupported_signature_version} ->
        error_response(conn, 401, "unsupported_signature_version", "Unsupported webhook signature version")

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_webhook_signature", "Webhook signature verification failed")

      {:error, :unsupported_event_type} ->
        error_response(conn, 422, "unsupported_event_type", "Unsupported event type")

      {:error, {:missing_field, field}} ->
        error_response(conn, 400, "invalid_payload", "Missing required payload field: #{field}")

      {:error, {:invalid_field, field}} ->
        error_response(conn, 400, "invalid_payload", "Invalid payload field: #{field}")

      {:error, :invalid_payload} ->
        error_response(conn, 400, "invalid_payload", "Invalid payload")

      {:error, :capacity_exhausted} ->
        error_response(conn, 409, "capacity_exhausted", "Runner capacity is currently exhausted")

      {:error, :orchestrator_unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

      {:error, {:dispatch_failed, _reason}} ->
        error_response(conn, 503, "dispatch_failed", "Runner could not dispatch accepted work")
    end
  end

  @spec event_stream(Conn.t(), map()) :: Conn.t()
  def event_stream(conn, params) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    limit = stream_limit(params)

    with {:ok, conn, emitted} <- stream_studio_runner_snapshot(conn, "runner.snapshot") do
      if stream_limit_reached?(limit, emitted) do
        conn
      else
        stream_updates(conn, limit, emitted)
      end
    else
      {:error, _reason} -> conn
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp stream_updates(conn, limit, emitted) do
    case ObservabilityPubSub.subscribe_dashboard() do
      :ok -> stream_update_loop(conn, limit, emitted)
      {:error, _reason} -> conn
    end
  end

  defp stream_update_loop(conn, limit, emitted) do
    update_message = ObservabilityPubSub.update_message()

    receive do
      ^update_message ->
        case stream_studio_runner_snapshot(conn, "runner.update") do
          {:ok, conn, emitted_now} ->
            emitted = emitted + emitted_now

            if stream_limit_reached?(limit, emitted) do
              conn
            else
              stream_update_loop(conn, limit, emitted)
            end

          {:error, _reason} ->
            conn
        end

      _other ->
        stream_update_loop(conn, limit, emitted)
    after
      15_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> stream_update_loop(conn, limit, emitted)
          {:error, _reason} -> conn
        end
    end
  end

  defp stream_studio_runner_snapshot(conn, event_name) do
    events =
      case Presenter.state_payload(orchestrator(), 1_000) do
        %{studio_runner: %{events: events}} when is_list(events) -> events
        %{"studio_runner" => %{"events" => events}} when is_list(events) -> events
        _ -> []
      end

    Enum.reduce_while(events, {:ok, conn, 0}, fn event, {:ok, conn, count} ->
      case chunk(conn, sse_frame(event_name_for(event, event_name), stream_event_payload(event))) do
        {:ok, conn} -> {:cont, {:ok, conn, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stream_limit(%{"limit" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> limit
      _ -> nil
    end
  end

  defp stream_limit(_params), do: nil

  defp stream_limit_reached?(limit, emitted) when is_integer(limit), do: emitted >= limit
  defp stream_limit_reached?(_limit, _emitted), do: false

  defp event_name_for(_event, fallback) when fallback != "runner.update", do: fallback

  defp event_name_for(event, _fallback) do
    case event_status(event) do
      "running" -> "runner.running"
      "completed" -> "runner.completed"
      "blocked" -> "runner.blocked"
      "failed" -> "runner.failed"
      "accepted" -> "runner.accepted"
      _ -> "runner.update"
    end
  end

  defp event_status(event) when is_map(event), do: Map.get(event, :status) || Map.get(event, "status")
  defp event_status(_event), do: nil

  defp stream_event_payload(event) when is_map(event) do
    %{
      eventId: Map.get(event, :event_id) || Map.get(event, "event_id"),
      runId: Map.get(event, :run_id) || Map.get(event, "run_id"),
      repoChangeKey: Map.get(event, :repo_change_key) || Map.get(event, "repo_change_key"),
      recordedAt: Map.get(event, :recorded_at) || Map.get(event, "recorded_at"),
      status: event_status(event),
      workspacePath: Map.get(event, :workspacePath) || Map.get(event, "workspacePath"),
      sessionId: Map.get(event, :sessionId) || Map.get(event, "sessionId"),
      branchName: Map.get(event, :branchName) || Map.get(event, "branchName"),
      commitSha: Map.get(event, :commitSha) || Map.get(event, "commitSha"),
      prUrl: Map.get(event, :prUrl) || Map.get(event, "prUrl"),
      error: Map.get(event, :error) || Map.get(event, "error")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sse_frame(event_name, payload) when is_map(payload) do
    data = Jason.encode!(payload)
    "event: " <> event_name <> "\n" <> "data: " <> data <> "\n\n"
  end

  defp dispatch(%WorkItem{} = work_item) do
    case Orchestrator.dispatch_external_work(orchestrator(), work_item, executor: executor()) do
      {:ok, payload} -> {:ok, payload}
      {:error, :unavailable} -> {:error, :orchestrator_unavailable}
      {:error, other} -> {:error, other}
    end
  end

  defp fetch_signing_secret(settings) do
    case settings.studio_runner.signing_secret do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_signing_secret}
    end
  end

  defp signing_secret_configured?(settings) do
    match?({:ok, _secret}, fetch_signing_secret(settings))
  end

  defp raw_body(conn) do
    conn.assigns[:raw_body]
    |> List.wrap()
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Orchestrator
  end

  defp executor do
    Endpoint.config(:studio_runner_executor) || (&SymphonyElixir.StudioRunner.Executor.run/1)
  end
end
