defmodule ExRTMP.Server.ClientSession do
  @moduledoc """
  Module describing an RTMP client session.
  """

  use GenServer

  require Logger

  alias ExRTMP.ChunkParser
  alias ExRTMP.Client.MediaProcessor
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection
  alias ExRTMP.Message.Command.NetConnection.{CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{DeleteStream, FCPublish, OnStatus, Play, Publish}
  alias ExRTMP.Message.Metadata

  @default_acknowledgement_size 3_000_000

  defmodule State do
    @moduledoc false

    @type state :: :init | :connected | :publishing | :playing

    @type t :: %__MODULE__{
            socket: :inet.socket(),
            chunk_parser: ChunkParser.t(),
            handler_mod: module(),
            handler_state: any(),
            state: state(),
            stream_id: non_neg_integer() | nil,
            media_processor: MediaProcessor.t() | nil
          }

    @enforce_keys [:socket]
    defstruct @enforce_keys ++
                [
                  :handler_mod,
                  :handler_state,
                  :media_processor,
                  chunk_parser: ChunkParser.new(),
                  state: :init,
                  stream_id: nil
                ]
  end

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Sends video data to the client.
  """
  @spec send_video_data(pid(), non_neg_integer(), iodata()) :: :ok
  def send_video_data(pid, timestamp, data) do
    GenServer.cast(pid, {:video_data, timestamp, data})
  end

  @doc """
  Sends audio data to the client.
  """
  @spec send_audio_data(pid(), non_neg_integer(), iodata()) :: :ok
  def send_audio_data(pid, timestamp, data) do
    GenServer.cast(pid, {:audio_data, timestamp, data})
  end

  @doc """
  Sends metadata about the media to the client.
  """
  @spec send_metadata(pid(), map()) :: :ok
  def send_metadata(pid, data) do
    GenServer.cast(pid, {:metadata, data})
  end

  @impl true
  def init(options) do
    handler_mod = Keyword.fetch!(options, :handler)

    state = %State{
      handler_mod: handler_mod,
      handler_state: handler_mod.init(options[:handler_options]),
      socket: options[:socket],
      media_processor: if(options[:demux], do: MediaProcessor.new())
    }

    :ok =
      :inet.setopts(state.socket,
        send_timeout: 10_000,
        send_timeout_close: true,
        nodelay: true
      )

    {:ok, state, {:continue, :handshake}}
  end

  @impl true
  def handle_continue(:handshake, state) do
    case do_handle_handshake(state.socket) do
      :ok ->
        Logger.debug("RTMP Handshake successful")
        {:ok, data} = :gen_tcp.recv(state.socket, 0)
        :ok = :inet.setopts(state.socket, active: true)
        {:noreply, do_handle_data(state, data)}

      :error ->
        {:stop, :handshake_failed, state}
    end
  end

  @impl true
  def handle_cast({:video_data, timestamp, data}, state) do
    case send_media(:video, state.socket, state.stream_id, timestamp, data) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_cast({:audio_data, timestamp, data}, state) do
    case send_media(:audio, state.socket, state.stream_id, timestamp, data) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_cast({:metadata, data}, state) do
    message = Message.metadata(data, state.stream_id)
    :ok = :gen_tcp.send(state.socket, Message.serialize(message))
    {:noreply, state}
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
  def handle_info(:exit, state) do
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

  defp handle_message(%{type: 3, payload: received_bytes}, state) do
    Logger.debug(
      "Received window acknowledgement size message, received_bytes: #{received_bytes}"
    )

    state
  end

  defp handle_message(%{type: 5, payload: win_size}, state) do
    Logger.debug("Received window size message, window_size: #{win_size}")
    state
  end

  defp handle_message(%{type: 4}, state) do
    # Ignore user control messages for now
    state
  end

  defp handle_message(%{type: 8} = message, %{state: :publishing, media_processor: nil} = state) do
    handler_state =
      state.handler_mod.handle_audio_data(
        message.timestamp,
        message.payload,
        state.handler_state
      )

    %{state | handler_state: handler_state}
  end

  defp handle_message(%{type: 8} = message, %{state: :publishing} = state) do
    {media, processor} = MediaProcessor.push_audio(message, state.media_processor)
    mod = state.handler_mod

    handler_state =
      Enum.reduce(List.wrap(media), state.handler_state, &mod.handle_audio_data(0, &1, &2))

    %{state | handler_state: handler_state, media_processor: processor}
  end

  defp handle_message(%{type: 9} = message, %{state: :publishing, media_processor: nil} = state) do
    handler_state =
      state.handler_mod.handle_video_data(
        message.timestamp,
        message.payload,
        state.handler_state
      )

    %{state | handler_state: handler_state}
  end

  defp handle_message(%{type: 9} = message, %{state: :publishing} = state) do
    {media, processor} = MediaProcessor.push_video(message, state.media_processor)
    mod = state.handler_mod

    handler_state =
      Enum.reduce(List.wrap(media), state.handler_state, &mod.handle_video_data(0, &1, &2))

    %{state | handler_state: handler_state, media_processor: processor}
  end

  defp handle_message(%{type: type}, state) when type == 8 or type == 9, do: state

  defp handle_message(%{type: 18, payload: %Metadata{data: data}}, state) do
    %{state | handler_state: state.handler_mod.handle_metadata(data, state.handler_state)}
  end

  defp handle_message(%{type: 20} = message, state) do
    {messages, state} =
      case message.payload do
        %NetConnection.Connect{} ->
          handle_connect_message(message.payload, state)

        %CreateStream{} ->
          handle_create_stream_message(message.payload, state)

        %FCPublish{transaction_id: id} ->
          send_messages(state, [Message.command(Response.ok(id))])
          {[], state}

        %Publish{} ->
          handle_publish_message(message.payload, message.stream_id, state)

        %DeleteStream{} ->
          handle_delete_stream(message.payload.stream_id, state)

        %Play{} ->
          handle_play_message(message.payload, message.stream_id, state)

        _other ->
          Logger.warning("Unknown command message: #{inspect(message.payload)}")
          {[], state}
      end

    send_messages(state, messages)
  end

  defp handle_message(msg, state) do
    Logger.warning("Unhandled message: #{inspect(msg)}")
    state
  end

  defp handle_connect_message(_connect, %{state: :connected} = state) do
    {[Message.command(Response.connect_failed("Already connected"))], state}
  end

  defp handle_connect_message(connect, state) do
    case state.handler_mod.handle_connect(connect, state.handler_state) do
      {:ok, handler_state} ->
        state = %{state | handler_state: handler_state, state: :connected}

        {[
           Message.window_acknowledgment_size(@default_acknowledgement_size),
           Message.command(Response.ok(1))
         ], state}

      {:error, reason} ->
        {[Message.command(Response.connect_failed(reason))], state}
    end
  end

  defp handle_create_stream_message(create_stream, %{state: :connected, stream_id: nil} = state) do
    message =
      create_stream.transaction_id
      |> Response.ok(data: 1)
      |> Message.command()

    {[message], %{state | stream_id: 1}}
  end

  defp handle_create_stream_message(%{transaction_id: id}, state) do
    reason = if state.state != :connected, do: "Not Connected", else: "Stream Already Created"
    {[Message.command(Response.create_stream_failed(id, reason))], state}
  end

  defp handle_publish_message(
         publish,
         stream_id,
         %{state: :connected, stream_id: stream_id} = state
       ) do
    Logger.debug("Received publish command for #{publish.name} on stream: #{stream_id}")

    case state.handler_mod.handle_publish(publish.name, state.handler_state) do
      {:ok, handler_state} ->
        state = %{state | handler_state: handler_state, state: :publishing}

        messages = [
          Message.stream_begin(stream_id),
          Message.command(OnStatus.publish_ok(), stream_id)
        ]

        {messages, state}

      {:error, reason} ->
        {[Message.command(OnStatus.publish_failed(reason), stream_id)], state}
    end
  end

  defp handle_publish_message(_publish, stream_id, state) do
    {[Message.command(OnStatus.publish_bad_stream(), stream_id)], state}
  end

  defp handle_play_message(play, stream_id, %{state: :connected, stream_id: stream_id} = state) do
    Logger.debug("Received play command for #{play.name} on stream: #{stream_id}")

    case state.handler_mod.handle_play(play, state.handler_state) do
      {:ok, handler_state} ->
        state = %{state | handler_state: handler_state, state: :playing}

        messages = [
          Message.stream_begin(stream_id),
          Message.command(OnStatus.play_ok(), stream_id)
        ]

        {messages, state}

      {:error, reason} ->
        {[Message.command(OnStatus.play_failed(reason), stream_id)], state}
    end
  end

  defp handle_play_message(_play, stream_id, state) do
    {[Message.command(OnStatus.play_bad_stream(), stream_id)], state}
  end

  defp handle_delete_stream(stream_id, state) do
    Logger.debug("Received delete stream command on stream: #{stream_id}")

    case state.handler_mod.handle_delete_stream(state.handler_state) do
      :close ->
        send(self(), :exit)
        {[], state}

      handler_state ->
        {[], %{state | stream_id: nil, handler_state: handler_state}}
    end
  end

  defp send_media(media, socket, stream_id, timestamp, data) do
    {type, chunk_stream_id} =
      case media do
        :audio -> {8, stream_id * 3}
        :video -> {9, stream_id * 3 + 1}
      end

    message = %Message{
      type: type,
      timestamp: timestamp,
      stream_id: stream_id,
      payload: data
    }

    :gen_tcp.send(socket, Message.serialize(message, chunk_stream_id: chunk_stream_id))
  end

  defp send_messages(state, []), do: state

  defp send_messages(state, messages) do
    :ok = :gen_tcp.send(state.socket, Enum.map(messages, &Message.serialize/1))
    state
  end
end
