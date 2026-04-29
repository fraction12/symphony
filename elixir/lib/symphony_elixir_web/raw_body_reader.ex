defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, put_raw_body(conn, body)}
      {:more, body, conn} -> {:more, body, put_raw_body(conn, body)}
    end
  end

  defp put_raw_body(conn, body) do
    Plug.Conn.assign(conn, :raw_body, [body | List.wrap(conn.assigns[:raw_body])])
  end
end
