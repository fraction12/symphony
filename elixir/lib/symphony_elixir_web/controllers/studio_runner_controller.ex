defmodule SymphonyElixirWeb.StudioRunnerController do
  @moduledoc """
  Signed ingress and health surface for OpenSpec Studio Runner push dispatch.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixir.StudioRunner.{IngressVerifier, Payload, WorkItem}
  alias SymphonyElixirWeb.Endpoint

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

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
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
