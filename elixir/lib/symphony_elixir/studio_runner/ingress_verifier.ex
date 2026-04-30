defmodule SymphonyElixir.StudioRunner.IngressVerifier do
  @moduledoc """
  Verifies Standard Webhooks-style signatures for Studio Runner ingress.
  """

  @version "v1"

  @type verification_result ::
          {:ok, %{event_id: String.t(), timestamp: integer()}}
          | {:error,
             :missing_headers
             | :invalid_timestamp
             | :stale_timestamp
             | :unsupported_signature_version
             | :invalid_signature}

  @spec verify(Plug.Conn.t(), binary(), String.t(), pos_integer()) :: verification_result()
  def verify(conn, raw_body, signing_secret, replay_window_seconds)
      when is_binary(raw_body) and is_binary(signing_secret) and is_integer(replay_window_seconds) and
             replay_window_seconds > 0 do
    with {:ok, event_id, timestamp, signature_header} <- fetch_headers(conn),
         {:ok, timestamp_int} <- parse_timestamp(timestamp),
         :ok <- verify_timestamp(timestamp_int, replay_window_seconds),
         {:ok, signatures} <- parse_signatures(signature_header),
         :ok <- verify_signature(signatures, signing_secret, event_id, timestamp, raw_body) do
      {:ok, %{event_id: event_id, timestamp: timestamp_int}}
    end
  end

  defp fetch_headers(conn) do
    with [event_id] when event_id != "" <- Plug.Conn.get_req_header(conn, "webhook-id"),
         [timestamp] when timestamp != "" <- Plug.Conn.get_req_header(conn, "webhook-timestamp"),
         [signature_header] when signature_header != "" <- Plug.Conn.get_req_header(conn, "webhook-signature") do
      {:ok, event_id, timestamp, signature_header}
    else
      _ -> {:error, :missing_headers}
    end
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(String.trim(timestamp)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp verify_timestamp(timestamp, replay_window_seconds) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= replay_window_seconds do
      :ok
    else
      {:error, :stale_timestamp}
    end
  end

  defp parse_signatures(signature_header) when is_binary(signature_header) do
    signatures =
      signature_header
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(fn part ->
        case String.split(part, ",", parts: 2) do
          [version, signature] when version != "" and signature != "" -> [{version, signature}]
          _ -> []
        end
      end)

    cond do
      signatures == [] -> {:error, :invalid_signature}
      Enum.any?(signatures, fn {version, _signature} -> version == @version end) -> {:ok, signatures}
      true -> {:error, :unsupported_signature_version}
    end
  end

  defp verify_signature(signatures, signing_secret, event_id, timestamp, raw_body) do
    expected = expected_signatures(signing_secret, event_id, timestamp, raw_body)

    if Enum.any?(signatures, fn
         {@version, provided_signature} -> secure_compare_any?(provided_signature, expected)
         _ -> false
       end) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp expected_signatures(signing_secret, event_id, timestamp, raw_body) do
    signature_payload = event_id <> "." <> timestamp <> "." <> raw_body
    digest = :crypto.mac(:hmac, :sha256, signing_secret, signature_payload)

    [
      Base.encode64(digest),
      Base.encode64(digest, padding: false)
    ]
    |> Enum.uniq()
  end

  defp secure_compare_any?(provided_signature, candidates) when is_binary(provided_signature) do
    Enum.any?(candidates, fn candidate ->
      byte_size(provided_signature) == byte_size(candidate) and
        Plug.Crypto.secure_compare(provided_signature, candidate)
    end)
  end
end
