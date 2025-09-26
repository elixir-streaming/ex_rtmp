defmodule ExRTMP.Client do
  @moduledoc """
  RTMP Client implementation.
  """

  use GenServer

  require Logger

  alias __MODULE__.State
  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection.{Connect, CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{DeleteStream, OnStatus, Play}

  @default_buffer_size 2_000_000

  @doc """
  Starts and links a new RTMP client.

  ## Options
    * `:uri` - The RTMP server URI to connect to. This option is required.

    * `:stream_key` - The stream key to use when publishing a stream. This option is required.

    * `:name` - The name to register the client process. This option is optional.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Connects to the RTMP server.
  """
  @spec connect(GenServer.name() | pid()) :: :ok | {:error, any()}
  def connect(client) do
    GenServer.call(client, :connect)
  end

  @doc """
  Creates a new stream on the RTMP server.
  """
  @spec create_stream(GenServer.name() | pid()) :: {:ok, Message.stream_id()} | {:error, any()}
  def create_stream(client) do
    GenServer.call(client, :create_stream)
  end

  @doc """
  Plays a stream on the RTMP server.
  """
  @spec play(GenServer.name() | pid(), Message.stream_id()) :: :ok | {:error, any()}
  def play(client, stream_id) do
    GenServer.call(client, {:play, stream_id})
  end

  @doc """
  Deletes a stream on the RTMP server.
  """
  @spec delete_stream(GenServer.name() | pid(), Message.stream_id()) :: :ok
  def delete_stream(client, stream_id) do
    GenServer.call(client, {:delete_stream, stream_id})
  end

  @impl true
  def init(opts) do
    uri = URI.parse(opts[:uri])
    uri = %URI{uri | port: uri.port || 1935}
    state = %State{uri: uri, stream_key: opts[:stream_key]}
    {:ok, state}
  end

  @impl true
  def handle_call(:connect, from, %{uri: uri} = state) do
    tcp_options = [:binary, active: false]

    case :gen_tcp.connect(String.to_charlist(uri.host), uri.port, tcp_options) do
      {:ok, socket} ->
        :inet.setopts(socket, buffer: @default_buffer_size, recvbuf: @default_buffer_size)
        do_connect(%{state | socket: socket}, from)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:create_stream, from, state) do
    ts_id = state.next_ts_id
    send_messages(state.socket, [Message.command(%CreateStream{transaction_id: ts_id})])

    {:noreply,
     %{state | pending_peer: from, pending_action: :create_stream, next_ts_id: ts_id + 1}}
  end

  @impl true
  def handle_call({:play, stream_id}, from, state) do
    play = Play.new(state.next_ts_id, state.stream_key)
    send_messages(state.socket, [Message.command(play, stream_id)])
    state = State.set_stream_pending_action(state, stream_id, :play, from)
    {:noreply, %{state | next_ts_id: state.next_ts_id + 1}}
  end

  @impl true
  def handle_call({:delete_stream, stream_id}, _from, state) do
    delete = DeleteStream.new(0, stream_id)
    send_messages(state.socket, [Message.command(delete, stream_id)] |> IO.inspect())
    {:reply, :ok, State.delete_stream(state, stream_id)}
  end

  @impl true
  def handle_info({:tcp, _port, data}, state) do
    {messages, parser} = ChunkParser.process(data, state.chunk_parser)
    {:noreply, Enum.reduce(messages, %{state | chunk_parser: parser}, &do_handle_message/2)}
  end

  defp do_connect(state, from) do
    case handshake(state) do
      :ok ->
        :ok = :inet.setopts(state.socket, active: true)

        connect =
          %Connect{
            transaction_id: 1,
            properties: %{
              "app" => String.trim_leading(to_string(state.uri.path), "/"),
              "type" => "nonprivate",
              "flashVer" => "FMLE/3.0 (compatible; FMSc/1.0)",
              "tcUrl" => URI.to_string(state.uri),
              "objectEncoding" => 0
            }
          }

        send_messages(state.socket, [Message.command(connect)])
        {:noreply, %{state | pending_peer: from, pending_action: :connect}}

      error ->
        :gen_tcp.close(state.socket)
        {:reply, error, %{state | socket: nil}}
    end
  end

  defp handshake(%{socket: socket} = _state) do
    rand_bytes = :crypto.strong_rand_bytes(1528)

    with :ok <- :gen_tcp.send(socket, [3]),
         :ok <- :gen_tcp.send(socket, [<<0::32>>, <<0::32>>, rand_bytes]),
         {:ok, <<0x03::8>>} <- :gen_tcp.recv(socket, 1),
         {:ok, <<timestamp::32, 0::32, r::binary-size(1528)>>} <- :gen_tcp.recv(socket, 1536),
         :ok <- :gen_tcp.send(socket, <<timestamp::32, 0::32, r::binary>>),
         {:ok, <<0::32, _::32, ^rand_bytes::binary>>} <- :gen_tcp.recv(socket, 1536) do
      :ok
    else
      _error ->
        Logger.error("RTMP handshake failed")
        {:error, :handshake_failed}
    end
  end

  defp do_handle_message(%{type: 5, payload: win_size}, state) do
    Logger.debug("Received window acknowledgement size: #{win_size}")
    %{state | window_ack_size: win_size}
  end

  defp do_handle_message(%{type: 6, payload: {win_size, limit}}, state) do
    Logger.debug("Received peer bandwidth message: window size=#{win_size} limit=#{limit}")
    state
  end

  defp do_handle_message(%{type: 9}, state) do
    state
  end

  defp do_handle_message(%{type: 18, payload: metadata}, state) do
    Logger.info("Received metadata: #{inspect(metadata)}")
    state
  end

  defp do_handle_message(%{type: 20, payload: %Response{} = response}, state) do
    command = state.pending_action
    from = state.pending_peer

    state =
      cond do
        not Response.ok?(response) ->
          GenServer.reply(from, {:error, response.data["description"]})
          state

        command == :connect ->
          GenServer.reply(from, :ok)
          state

        command == :create_stream ->
          stream_id = trunc(response.data)
          GenServer.reply(from, {:ok, stream_id})
          State.add_stream(state, stream_id)
      end

    %{state | pending_peer: nil, pending_action: nil}
  end

  defp do_handle_message(%{type: 20, payload: %OnStatus{info: info}} = msg, state) do
    stream_ctx = Map.fetch!(state.streams, msg.stream_id)

    case stream_ctx.pending_action do
      :play ->
        handle_play_response(info, stream_ctx, state)

      _other ->
        state
    end
  end

  defp do_handle_message(%{type: type} = message, state) do
    Logger.warning("Ignored message of type #{type}: #{inspect(message)}")
    state
  end

  defp handle_play_response(info, stream_ctx, state) do
    reply =
      case info["code"] do
        "NetStream.Play.Start" ->
          :ok

        "NetStream.Play.Reset" ->
          :ignore

        "NetStream.Play.StreamNotFound" ->
          {:error, "Stream not found"}

        "NetStream.Play.Failed" ->
          {:error, "Play failed"}

        other ->
          Logger.warning("Unhandled play response code: #{other}")
          :ignore
      end

    case reply do
      :ignore ->
        state

      other ->
        GenServer.reply(stream_ctx.pending_peer, other)
        State.clear_stream_pending_action(state, stream_ctx.id)
    end
  end

  defp send_messages(socket, messages) do
    :ok = :gen_tcp.send(socket, Enum.map(messages, &Message.serialize/1))
  end
end
