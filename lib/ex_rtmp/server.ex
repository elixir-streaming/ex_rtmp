defmodule ExRTMP.Server do
  @moduledoc """
  Module describing an RTMP server.

  The server listens for incoming RTMP client connections and spawns a new
  `ExRTMP.Server.ClientSession` process for each connected client.
  """

  use GenServer

  require Logger

  alias ExRTMP.Server.ClientSession

  @type start_options :: [
          {:port, :inet.port_number()},
          {:handler, module()},
          {:handler_options, any()}
        ]

  @default_port 1935

  @doc """
  Starts a new RTMP server.

  Check `start_link/1` for available options.
  """
  @spec start(start_options()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Starts and link a new RTMP server.

  ## Options
    * `port` - The port number where the server should listen. Defaults to: `1935`.

    * `handler` - The module that will handle the RTMP commands and messages.
      This module must implement the `ExRTMP.Server.Handler` behaviour. This
      option is required.

    * `handler_options` - A keyword list of options that will be passed to the
      handler module when it is started. This option is optional.
  """
  @spec start_link(start_options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Gets the port number of the server.
  """
  @spec port(GenServer.name()) :: {:ok, port} | {:error, any()}
  def port(server) do
    GenServer.call(server, :get_port)
  end

  @doc """
  Stops the server.
  """
  @spec stop(GenServer.name()) :: :ok
  def stop(server) do
    GenServer.call(server, :stop)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    {:ok, server_socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])

    state = %{
      socket: server_socket,
      pid: self(),
      handler: opts[:handler] || raise("Handler module is required"),
      handler_options: opts[:handler_options]
    }

    listener = spawn_link(fn -> accept_client_connection(state) end)

    {:ok, %{socket: server_socket, listener: listener}}
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, :inet.port(state.socket), state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    Process.exit(state.listener, :normal)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:new_client, pid}, state) do
    _ref = Process.monitor(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
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

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to accept client connection: #{inspect(reason)}")
    end
  end
end
