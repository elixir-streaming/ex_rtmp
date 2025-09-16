defmodule ExRTMP.Server do
  @moduledoc """
  RTMP server implentation
  """

  use GenServer

  require Logger

  alias ExRTMP.Server.ClientSession

  @default_port 1935

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, server_socket} =
      :gen_tcp.listen(@default_port, [:binary, packet: :raw, active: false, reuseaddr: true])

    server_pid = self()
    pid = spawn_link(fn -> accept_client_connection(server_socket, server_pid) end)

    {:ok, %{socket: server_socket, pid: pid}}
  end

  @impl true
  def handle_info({:new_client, pid}, state) do
    Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received an unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp accept_client_connection(server_socket, server_pid) do
    {:ok, client_socket} = :gen_tcp.accept(server_socket)
    {:ok, pid} = ClientSession.start(client_socket)
    :ok = :gen_tcp.controlling_process(client_socket, pid)
    send(server_pid, {:new_client, pid})
    accept_client_connection(server_socket, server_pid)
  end
end
