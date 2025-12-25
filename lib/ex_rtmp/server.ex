defmodule ExRTMP.Server do
  @moduledoc """
  Module describing an RTMP server.

  The server listens for incoming RTMP client connections and spawns a new
  `ExRTMP.Server.ClientSession` process for each connected client.

  ## Handling Media
    When `demux` is set to `true`, the server will demux the incoming RTMP
    streams into audio and video frames before passing them to the handler module.

    The format of the data received by the handler is:
    * `{:codec, codec_type, init_data}` - The codec type and initialization data.
    * `{:sample, payload, dts, pts, keyframe?}` - A video sample, the payload depends on the codec type. In the case of `avc`,
      the payload is a list of NAL units, for other codecs, it is the raw video frame data.
    * `{:sample, payload, timestamp}` - An audio sample.

    If `demux` is set to `false`, the handler module will receive the raw RTMP
    data as is.
  """

  use GenServer

  require Logger

  alias ExRTMP.Server.ClientSession

  @type start_options :: [
          {:port, :inet.port_number()},
          {:handler, module()},
          {:handler_options, any()},
          {:demux, boolean()}
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

    * `demux` - Whether the server will demux the incoming RTMP streams into
      audio and video frames. Defaults to `true`. See [Handling Media](#module-handling-media) below.
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

    Logger.info("RTMP Server listening on port #{port}")

    state = %{
      socket: server_socket,
      pid: self(),
      handler: opts[:handler] || raise("Handler module is required"),
      handler_options: opts[:handler_options],
      demux: Keyword.get(opts, :demux, true)
    }

    Process.flag(:trap_exit, true)
    listener = spawn_link(fn -> accept_client_connection(state) end)

    {:ok, %{socket: server_socket, listener: listener}}
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, :inet.port(state.socket), state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:stop, :shutdown, :ok, state}
  end

  @impl true
  def handle_info({:new_client, pid}, state) do
    _ref = Process.link(pid)
    {:noreply, state}
  end

  def handle_info({:EXIT, _from, _reason}, state) do
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
            handler_options: state.handler_options,
            demux: state.demux
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
