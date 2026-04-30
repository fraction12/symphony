defmodule SymphonyElixir.StudioRunner.Payload do
  @moduledoc """
  Normalizes signed Studio Runner ingress payloads into work items.
  """

  alias SymphonyElixir.StudioRunner.WorkItem

  @spec normalize(map(), String.t()) :: {:ok, WorkItem.t()} | {:error, term()}
  def normalize(payload, event_id) when is_map(payload) and is_binary(event_id) do
    with {:ok, event_type} <- fetch_required_string(payload, "type"),
         :ok <- validate_event_type(event_type),
         {:ok, data} <- fetch_required_map(payload, "data"),
         {:ok, repo_path} <- fetch_absolute_repo_path(data),
         {:ok, change} <- fetch_required_string(data, "change") do
      {:ok,
       %WorkItem{
         event_id: event_id,
         event_type: event_type,
         source: optional_string(payload, "source"),
         occurred_at: optional_datetime(payload, "time"),
         repo_path: repo_path,
         repo_name: optional_string(data, "repoName"),
         repo_remote: optional_string(data, "repoRemote"),
         git_ref: optional_string(data, "gitRef"),
         change: change,
         requested_by: optional_string(data, "requestedBy"),
         artifact_paths: optional_string_list(data, "artifactPaths"),
         validation: normalize_validation(Map.get(data, "validation")),
         metadata: normalize_metadata(payload, data)
       }}
    end
  end

  def normalize(_payload, _event_id), do: {:error, :invalid_payload}

  defp validate_event_type("build.requested"), do: :ok
  defp validate_event_type(_event_type), do: {:error, :unsupported_event_type}

  defp fetch_required_string(map, key) when is_map(map) and is_binary(key) do
    case optional_string(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> {:ok, value}
    end
  end

  defp fetch_required_map(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      %{} = value -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_absolute_repo_path(data) do
    with {:ok, repo_path} <- fetch_required_string(data, "repoPath"),
         :ok <- require_absolute_path(repo_path) do
      expand_existing_directory(repo_path)
    end
  end

  defp require_absolute_path(repo_path) do
    if Path.type(repo_path) == :absolute do
      :ok
    else
      {:error, {:invalid_field, "data.repoPath"}}
    end
  end

  defp expand_existing_directory(repo_path) do
    expanded_path = Path.expand(repo_path)

    if File.dir?(expanded_path) do
      {:ok, expanded_path}
    else
      {:error, {:invalid_field, "data.repoPath"}}
    end
  end

  defp optional_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp optional_string_list(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp optional_datetime(map, key) when is_map(map) and is_binary(key) do
    with value when is_binary(value) <- Map.get(map, key),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      datetime
    else
      _ -> nil
    end
  end

  defp normalize_validation(%{} = validation) do
    %{}
    |> maybe_put(:state, optional_string(validation, "state"))
    |> maybe_put(:checked_at, optional_datetime(validation, "checkedAt"))
  end

  defp normalize_validation(_validation), do: %{}

  defp normalize_metadata(payload, data) do
    %{}
    |> maybe_put(:payload_id, optional_string(payload, "id"))
    |> maybe_put(:runner, optional_string(data, "runner"))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
