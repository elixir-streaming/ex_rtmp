defmodule ExRTMP.Client do
  @moduledoc """
  RTMP Client implementation.
  """

  use GenServer

  require Logger

  alias __MODULE__.{Config, State}
  alias ExFLV.Tag.{AudioData, VideoData}
  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection.{Connect, CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{DeleteStream, OnStatus, Play, Publish}
  alias ExRTMP.Message.UserControl.Event

  @default_buffer_size 2_000_000

  @type start_options :: [
          {:uri, String.t()},
          {:stream_key, String.t()},
          {:name, GenServer.name()},
          {:receiver, Process.dest()}
        ]

  @doc """
  Starts and links a new RTMP client.

  ## Options
    * `:uri` - The RTMP server URI to connect to. This option is required.

    * `:stream_key` - The stream key. This option is required.

    * `:name` - The name to register the client process. This option is optional.
  """
  @spec start_link(start_options()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :receiver, self())
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Starts a new RTMP client.

  For available options see `start_link/1`.
  """
  @spec start(start_options()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts, name: opts[:name])
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
  Publishes a stream to the RTMP server.
  """
  @spec publish(GenServer.name() | pid(), Message.stream_id()) :: :ok | {:error, any()}
  def publish(client, stream_id) do
    GenServer.call(client, {:publish, stream_id})
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

  @doc """
  Sends an FLV tag to the server.
  """
  @spec send_tag(
          GenServer.name() | pid(),
          non_neg_integer(),
          non_neg_integer(),
          AudioData.t() | VideoData.t()
        ) :: :ok
  def send_tag(client, stream_id, timestamp, tag) do
    GenServer.cast(client, {:send_tag, stream_id, timestamp, tag})
  end

  @doc """
  Stops the RTMP client.
  """
  @spec stop(GenServer.name() | pid()) :: :ok
  def stop(client) do
    GenServer.call(client, :stop)
  end

  @impl true
  def init(opts) do
    opts = Config.validate!(opts)
    state = %State{uri: opts[:uri], stream_key: opts[:stream_key], receiver: opts[:receiver]}
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
    play = Play.new(state.stream_key)
    send_messages(state.socket, [Message.command(play, stream_id)])
    state = State.set_stream_pending_action(state, stream_id, :play, from)
    {:noreply, state}
  end

  @impl true
  def handle_call({:publish, stream_id}, from, state) do
    publish = Publish.new(state.stream_key, "live")
    send_messages(state.socket, Message.command(publish, stream_id))
    state = State.set_stream_pending_action(state, stream_id, :publish, from)
    {:noreply, state}
  end

  @impl true
  def handle_call({:delete_stream, stream_id}, _from, state) do
    delete = DeleteStream.new(0, stream_id)
    send_messages(state.socket, [Message.command(delete, stream_id)])
    {:reply, :ok, do_delete_stream(stream_id, state)}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if state.socket do
      state =
        state.streams
        |> Map.keys()
        |> Enum.reduce(state, &do_delete_stream/2)

      :ok = :gen_tcp.close(state.socket)
      {:stop, :normal, :ok, %{state | socket: nil}}
    else
      {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def handle_cast({:send_tag, stream_id, timestamp, tag}, state) do
    type =
      case tag do
        %VideoData{} -> 9
        %AudioData{} -> 8
      end

    message = %Message{
      type: type,
      stream_id: stream_id,
      timestamp: timestamp,
      payload: ExFLV.Tag.Serializer.serialize(tag)
    }

    send_messages(state.socket, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _port, data}, state) do
    {messages, parser} = ChunkParser.process(data, state.chunk_parser)
    {:noreply, Enum.reduce(messages, %{state | chunk_parser: parser}, &do_handle_message/2)}
  end

  @impl true
  def handle_info({:tcp_closed, _port}, state) do
    send(state.receiver, {:disconnected, self()})
    {:noreply, State.reset(state)}
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
         {:ok, <<timestamp::32, _::32, r::binary-size(1528)>>} <- :gen_tcp.recv(socket, 1536),
         :ok <- :gen_tcp.send(socket, <<timestamp::32, 0::32, r::binary>>),
         {:ok, <<0::32, _::32, ^rand_bytes::binary>>} <- :gen_tcp.recv(socket, 1536) do
      :ok
    else
      _error ->
        Logger.error("RTMP handshake failed")
        {:error, :handshake_failed}
    end
  end

  defp do_handle_message(%{type: 4, payload: user_event}, state) do
    Logger.debug("Received user control message: #{inspect(user_event)}")

    case user_event do
      %Event{type: :ping_request, data: timestamp} ->
        send_messages(state.socket, [Message.ping_response(timestamp)])
        state

      _event ->
        state
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

  defp do_handle_message(%{type: 8} = msg, state) do
    Logger.debug("Received audio message on stream: #{msg.stream_id}")
    do_handle_media_message(state, msg, :audio)
  end

  defp do_handle_message(%{type: 9} = msg, state) do
    Logger.debug("Received video message on stream: #{msg.stream_id}")
    do_handle_media_message(state, msg, :video)
  end

  defp do_handle_message(%{type: 18} = msg, state) do
    Logger.debug("Received metadata on stream #{msg.stream_id}: #{inspect(msg.payload)}")
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

      :publish ->
        handle_publish_response(info, stream_ctx, state)

      _other ->
        state
    end
  end

  defp do_handle_message(%{type: type} = message, state) do
    Logger.warning("Ignored message of type #{type}: #{inspect(message)}")
    state
  end

  defp do_handle_media_message(state, msg, media_type) do
    case State.handle_media_message(state, msg) do
      {nil, state} ->
        state

      {data, state} when is_list(data) ->
        Enum.each(data, &send(state.receiver, {media_type, self(), msg.stream_id, &1}))
        state

      {data, state} ->
        send(state.receiver, {media_type, self(), msg.stream_id, data})
        state
    end
  end

  defp handle_play_response(info, stream_ctx, state) do
    case handle_play_resp_code(info["code"]) do
      :ignore ->
        state

      :ok ->
        GenServer.reply(stream_ctx.pending_peer, :ok)
        stream_ctx = %{stream_ctx | pending_peer: nil, pending_action: nil, state: :playing}
        %{state | streams: Map.put(state.streams, stream_ctx.id, stream_ctx)}

      {:error, reason} ->
        GenServer.reply(stream_ctx.pending_peer, {:error, Map.get(info, "description", reason)})
        stream_ctx = %{stream_ctx | pending_peer: nil, pending_action: nil}
        %{state | streams: Map.put(state.streams, stream_ctx.id, stream_ctx)}
    end
  end

  defp handle_publish_response(info, stream_ctx, state) do
    case info["code"] do
      "NetStream.Publish.Start" ->
        GenServer.reply(stream_ctx.pending_peer, :ok)
        stream_ctx = %{stream_ctx | pending_peer: nil, pending_action: nil, state: :publishing}
        %{state | streams: Map.put(state.streams, stream_ctx.id, stream_ctx)}

      other ->
        GenServer.reply(stream_ctx.pending_peer, {:error, Map.get(info, "description", other)})
        stream_ctx = %{stream_ctx | pending_peer: nil, pending_action: nil}
        %{state | streams: Map.put(state.streams, stream_ctx.id, stream_ctx)}
    end
  end

  defp do_delete_stream(stream_id, state) do
    delete = DeleteStream.new(0, stream_id)
    send_messages(state.socket, [Message.command(delete, stream_id)])
    State.delete_stream(state, stream_id)
  end

  defp handle_play_resp_code("NetStream.Play.Start"), do: :ok
  defp handle_play_resp_code("NetStream.Play.Reset"), do: :ignore
  defp handle_play_resp_code("NetStream.Play.StreamNotFound"), do: {:error, "Stream not found"}
  defp handle_play_resp_code("NetStream.Play.Failed"), do: {:error, "Play failed"}

  defp send_messages(socket, messages) when is_list(messages) do
    :ok = :gen_tcp.send(socket, Enum.map(messages, &Message.serialize/1))
  end

  defp send_messages(socket, message) do
    :ok = :gen_tcp.send(socket, Message.serialize(message))
  end
end
