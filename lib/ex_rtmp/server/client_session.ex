defmodule ExRTMP.Server.ClientSession do
  @moduledoc false

  use GenServer

  require Logger

  alias ExRTMP.Command.NetConnection.{CreateStream, Response}
  alias ExRTMP.Command.NetConnection
  alias ExRTMP.Command.NetStream.{DeleteStream, Publish, OnStatus}
  alias ExRTMP.Message
  alias ExRTMP.Server.ChunkParser

  defmodule State do
    @moduledoc false

    @type state :: :init | :connected
    @type stream_state :: :created | :publishing | :playing

    @type t :: %__MODULE__{
            socket: :inet.socket(),
            app_name: String.t() | nil,
            chunk_parser: ChunkParser.t(),
            state: state()
          }

    @enforce_keys [:socket]
    defstruct @enforce_keys ++ [:app_name, chunk_parser: ChunkParser.new(), state: :init]
  end

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(socket) do
    {:ok, %State{socket: socket}, {:continue, :handshake}}
  end

  @impl true
  def handle_continue(:handshake, state) do
    case do_handle_handshake(state.socket) do
      :ok ->
        Logger.info("RTMP Handshake successful")
        {:ok, data} = :gen_tcp.recv(state.socket, 0)
        :ok = :inet.setopts(state.socket, active: true)
        {:noreply, do_handle_data(state, data)}

      :error ->
        {:stop, :handshake_failed, state}
    end
  end

  @impl true
  def handle_info({:tcp, _port, data}, state) do
    {:noreply, do_handle_data(state, data)}
  end

  @impl true
  def handle_info({:tcp_closed, _port}, state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Received an unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp do_handle_handshake(socket) do
    s1_rand = :crypto.strong_rand_bytes(1528)

    with {:ok, _version} <- :gen_tcp.recv(socket, 1),
         :ok <- :gen_tcp.send(socket, <<3>>),
         :ok <- :gen_tcp.send(socket, <<0::64, s1_rand::binary>>),
         {:ok, <<c::64, client_random::binary-size(1528)>>} <- :gen_tcp.recv(socket, 1536),
         :ok <- :gen_tcp.send(socket, <<c::64, client_random::binary>>),
         {:ok, <<0::32, _::32, ^s1_rand::binary>>} <- :gen_tcp.recv(socket, 1536) do
      :ok
    else
      _res -> :error
    end
  end

  defp do_handle_data(state, data) do
    {messages, parser} = ChunkParser.process(data, state.chunk_parser)
    Enum.reduce(messages, %{state | chunk_parser: parser}, &handle_message/2)
  end

  defp handle_message(%{type: 20} = message, state) do
    case message.payload do
      %NetConnection.Connect{properties: props} ->
        send_messages(state, [Message.command(Response.ok(1))])
        %{state | state: :connected, app_name: Map.get(props, "app")}

      %CreateStream{} = cmd ->
        response_message = Message.command(Response.ok(cmd.transaction_id, data: 1))
        send_messages(state, [response_message])
        state

      %Publish{name: _stream_key} ->
        response_message = Message.command(OnStatus.publish_ok(), message.stream_id)
        send_messages(state, [Message.stream_begin(message.stream_id), response_message])
        state

      %DeleteStream{} ->
        state

      _other ->
        state
    end
  end

  defp handle_message(%{type: 8} = _message, state) do
    state
  end

  defp handle_message(%{type: 9} = _message, state) do
    state
  end

  defp handle_message(msg, state) do
    Logger.warning("Unhandled message: #{inspect(msg)}")
    state
  end

  defp send_messages(state, messages) do
    :ok = :gen_tcp.send(state.socket, Enum.map(messages, &Message.serialize/1))
  end
end
