defmodule ExRTMP.Client do
  @moduledoc """
  RTMP Client implementation.

  This module provides functionality to connect to an RTMP server, publish and play streams.

  ## Media Handling

  When playing a stream, the client will demux the incoming RTMP
  streams into audio and video frames before passing them to the receiver process (the calling process by default).

  The format of the data received by the receiver is:
    * `{:video, client_pid, video_data}` - A video frame.
    * `{:audio, client_pid, audio_data}` - An audio frame.

  The `video_data` is in the following format:
    * `{:codec, atom(), init_data}` - The codec type and initialization data.
    * `{:sample, payload, dts, pts, keyframe?}` - A video sample, the payload depends on the codec type. In the case of `avc`,
      the payload is a list of NAL units, for other codecs, it is the raw video frame data.

  The `audio_data` is in the following format:
    * `{:codec, atom(), init_data}` - The codec type and initialization data.
    * `{:sample, payload, timestamp}` - An audio sample.

  ## Publishing Media

  When publishing a stream, the client can send FLV tags to the server using the `send_tag/3` function.
  The tags must be either `ExFLV.Tag.AudioData` or `ExFLV.Tag.VideoData` structs.

  """

  use GenServer

  require Logger

  alias __MODULE__.{Config, State}
  alias ExFLV.Tag.{AudioData, ExAudioData, ExVideoData, Serializer, VideoData}
  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection.{Connect, CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{DeleteStream, OnStatus, Play, Publish}
  alias ExRTMP.Message.UserControl.Event

  @default_buffer_size 2_000_000
  @audio_msg_type 8
  @video_msg_type 9

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
    opts = Keyword.put_new(opts, :receiver, self())
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
  Publishes a stream to the RTMP server.
  """
  @spec publish(GenServer.name() | pid()) :: :ok | {:error, any()}
  def publish(client) do
    GenServer.call(client, :publish)
  end

  @doc """
  Plays a stream on the RTMP server.
  """
  @spec play(GenServer.name() | pid()) :: :ok | {:error, any()}
  def play(client) do
    GenServer.call(client, :play)
  end

  @doc """
  Deletes a stream and close connection.
  """
  @spec close(GenServer.name() | pid()) :: :ok
  def close(client) do
    GenServer.call(client, :delete_stream)
  end

  @doc """
  Sends an FLV tag to the server.
  """
  @spec send_tag(
          GenServer.name() | pid(),
          non_neg_integer(),
          AudioData.t() | VideoData.t()
        ) :: :ok
  def send_tag(client, timestamp, tag) do
    GenServer.cast(client, {:send_tag, timestamp, tag})
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
  def handle_call(:connect, from, %{uri: uri, state: :init} = state) do
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
  def handle_call(:connect, _from, state) do
    {:reply, {:error, :already_connected}, state}
  end

  @impl true
  def handle_call(:play, from, %{state: :connected} = state) do
    state.stream_key
    |> Play.new()
    |> Message.command(state.stream_id)
    |> send_message(state.socket)

    {:noreply, %{state | pending_action: :play, pending_peer: from}}
  end

  @impl true
  def handle_call(:play, _from, state) do
    {:reply, {:error, :bad_state}, state}
  end

  @impl true
  def handle_call(:publish, from, %{state: :connected} = state) do
    state.stream_key
    |> Publish.new("live")
    |> Message.command(state.stream_id)
    |> send_message(state.socket)

    {:noreply, %{state | pending_action: :publish, pending_peer: from}}
  end

  @impl true
  def handle_call(:publish, _from, state) do
    {:reply, {:error, :bad_state}, state}
  end

  @impl true
  def handle_call(:delete_stream, _from, %{state: :init} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:delete_stream, _from, state) do
    {:reply, :ok, do_delete_stream(state.stream_id, state)}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if state.socket do
      {:stop, :normal, :ok, do_delete_stream(state.stream_id, state)}
    else
      {:stop, :normal, :ok, state}
    end
  end

  @impl true
  def handle_cast({:send_tag, timestamp, %VideoData{} = tag}, %{state: :publishing} = state) do
    do_send_tag(state, @video_msg_type, tag, timestamp)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_tag, timestamp, %ExVideoData{} = tag}, %{state: :publishing} = state) do
    do_send_tag(state, @video_msg_type, tag, timestamp)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_tag, timestamp, %AudioData{} = tag}, %{state: :publishing} = state) do
    do_send_tag(state, @audio_msg_type, tag, timestamp)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_tag, timestamp, %ExAudioData{} = tag}, %{state: :publishing} = state) do
    do_send_tag(state, @audio_msg_type, tag, timestamp)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_tag, _timestamp, tag}, state) do
    Logger.warning("Ignoring send_tag for non-publishing state or unknown tag: #{inspect(tag)}")
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

        send_message(Message.command(connect), state.socket)
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

  defp create_stream(state) do
    ts_id = state.next_ts_id
    %CreateStream{transaction_id: ts_id} |> Message.command() |> send_message(state.socket)
    %{state | pending_action: :create_stream, next_ts_id: ts_id + 1}
  end

  defp do_handle_message(%{type: 4, payload: user_event}, state) do
    Logger.debug("Received user control message: #{inspect(user_event)}")

    case user_event do
      %Event{type: :ping_request, data: timestamp} ->
        timestamp
        |> Message.ping_response()
        |> send_message(state.socket)

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

    state = %{state | pending_peer: nil, pending_action: nil}

    cond do
      not Response.ok?(response) ->
        GenServer.reply(from, {:error, response.data["description"]})
        state

      command == :connect ->
        state = create_stream(state)
        %{state | state: :connected, pending_peer: from}

      command == :create_stream ->
        GenServer.reply(from, :ok)
        %{state | stream_id: trunc(response.data)}
    end
  end

  defp do_handle_message(%{type: 20, payload: %OnStatus{info: info}}, state) do
    case state.pending_action do
      :play ->
        handle_play_response(info, state)

      :publish ->
        handle_publish_response(info, state)

      _other ->
        state
    end
  end

  defp do_handle_message(%{type: type} = message, state) do
    Logger.warning("Ignored message of type #{type}: #{inspect(message)}")
    state
  end

  defp do_handle_media_message(state, msg, media_type) do
    {data, state} = State.handle_media_message(state, msg)

    cond do
      is_nil(data) -> :ok
      is_list(data) -> Enum.each(data, &send(state.receiver, {media_type, self(), &1}))
      true -> send(state.receiver, {media_type, self(), data})
    end

    state
  end

  defp handle_play_response(info, state) do
    case handle_play_resp_code(info["code"]) do
      :ignore ->
        state

      :ok ->
        GenServer.reply(state.pending_peer, :ok)

        %{
          state
          | pending_peer: nil,
            pending_action: nil,
            state: :playing,
            media_processor: __MODULE__.MediaProcessor.new()
        }

      {:error, reason} ->
        GenServer.reply(state.pending_peer, {:error, Map.get(info, "description", reason)})
        %{state | pending_peer: nil, pending_action: nil}
    end
  end

  defp handle_publish_response(info, state) do
    case info["code"] do
      "NetStream.Publish.Start" ->
        GenServer.reply(state.pending_peer, :ok)
        %{state | pending_peer: nil, pending_action: nil, state: :publishing}

      other ->
        GenServer.reply(state.pending_peer, {:error, Map.get(info, "description", other)})
        %{state | pending_peer: nil, pending_action: nil}
    end
  end

  defp do_delete_stream(stream_id, state) do
    if stream_id do
      DeleteStream.new(stream_id) |> Message.command(stream_id) |> send_message(state.socket)
    end

    :ok = :gen_tcp.close(state.socket)
    State.reset(state)
  end

  defp do_send_tag(state, type, tag, timestamp) do
    message =
      Message.new(Serializer.serialize(tag),
        type: type,
        stream_id: state.stream_id,
        timestamp: timestamp
      )

    send_message(message, state.socket)
  end

  defp handle_play_resp_code("NetStream.Play.Start"), do: :ok
  defp handle_play_resp_code("NetStream.Play.Reset"), do: :ignore
  defp handle_play_resp_code("NetStream.Play.StreamNotFound"), do: {:error, "Stream not found"}
  defp handle_play_resp_code("NetStream.Play.Failed"), do: {:error, "Play failed"}

  defp send_message(message, socket) do
    :ok = :gen_tcp.send(socket, Message.serialize(message))
  end
end
