defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    subscribe_dashboard()
  end

  @spec subscribe_dashboard() :: :ok | {:error, term()}
  def subscribe_dashboard do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec update_message() :: :observability_updated
  def update_message, do: @update_message

  @spec broadcast_update() :: :ok
  def broadcast_update do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end
end
