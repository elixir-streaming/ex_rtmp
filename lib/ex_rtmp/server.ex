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
  def init(opts) do
    {:ok, server_socket} =
      :gen_tcp.listen(@default_port, [:binary, packet: :raw, active: false, reuseaddr: true])

    state = %{
      socket: server_socket,
      pid: self(),
      handler: opts[:handler] || raise("Handler module is required"),
      handler_options: opts[:handler_options]
    }

    pid = spawn_link(fn -> accept_client_connection(state) end)

    {:ok, %{socket: server_socket, pid: pid}}
  end

  @impl true
  def handle_info({:new_client, pid}, state) do
    _ref = Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received an unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp accept_client_connection(state) do
    case :gen_tcp.accept(state.socket) do
      {:ok, client_socket} ->
        Logger.debug("New client connected")

        {:ok, pid} =
          ClientSession.start(
            socket: client_socket,
            handler: state.handler,
            handler_options: state.handler_options
          )

        :ok = :gen_tcp.controlling_process(client_socket, pid)
        send(state.pid, {:new_client, pid})
        accept_client_connection(state)

      {:error, reason} ->
        Logger.error("Failed to accept client connection: #{inspect(reason)}")
    end
  end
end
