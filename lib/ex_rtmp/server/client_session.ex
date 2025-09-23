defmodule ExRTMP.Server.ClientSession do
  @moduledoc """
  Module describing an RTMP client session.
  """

  use GenServer

  require Logger

  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetConnection
  alias ExRTMP.Message.Command.NetConnection.{CreateStream, Response}
  alias ExRTMP.Message.Command.NetStream.{DeleteStream, Play, Publish, OnStatus}
  alias ExRTMP.Message.Metadata

  @default_acknowledgement_size 3_000_000

  defmodule State do
    @moduledoc false

    @type state :: :init | :connected
    @type stream_state :: :created | :publishing | :playing

    @type t :: %__MODULE__{
            socket: :inet.socket(),
            chunk_parser: ChunkParser.t(),
            handler_mod: module(),
            handler_state: any(),
            state: state(),
            streams_state: %{optional(non_neg_integer()) => stream_state()},
            next_stream_id: non_neg_integer()
          }

    @enforce_keys [:socket]
    defstruct @enforce_keys ++
                [
                  :handler_mod,
                  :handler_state,
                  chunk_parser: ChunkParser.new(),
                  state: :init,
                  streams_state: %{},
                  next_stream_id: 1
                ]
  end

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc """
  Sends video data to the client.
  """
  @spec send_video_data(pid(), non_neg_integer(), non_neg_integer(), iodata()) :: :ok
  def send_video_data(pid, stream_id, timestamp, data) do
    GenServer.cast(pid, {:video_data, stream_id, timestamp, data})
  end

  @doc """
  Sends audio data to the client.
  """
  @spec send_audio_data(pid(), non_neg_integer(), non_neg_integer(), iodata()) :: :ok
  def send_audio_data(pid, stream_id, timestamp, data) do
    GenServer.cast(pid, {:audio_data, stream_id, timestamp, data})
  end

  @doc """
  Sends metadata about the media to the client.
  """
  @spec send_metadata(pid(), non_neg_integer(), map()) :: :ok
  def send_metadata(pid, stream_id, data) do
    GenServer.cast(pid, {:metadata, stream_id, data})
  end

  @impl true
  def init(options) do
    handler_mod = Keyword.fetch!(options, :handler)

    state = %State{
      handler_mod: handler_mod,
      handler_state: handler_mod.init(options[:handler_options]),
      socket: options[:socket]
    }

    {:ok, state, {:continue, :handshake}}
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
  def handle_cast({:video_data, stream_id, timestamp, data}, state) do
    send_media(:video, state.socket, stream_id, timestamp, data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:audio_data, stream_id, timestamp, data}, state) do
    send_media(:audio, state.socket, stream_id, timestamp, data)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:metadata, stream_id, data}, state) do
    message = Message.metadata(data, stream_id)
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

  defp handle_message(%{type: 1, payload: chunk_size}, state) do
    %{state | chunk_parser: %{state.chunk_parser | chunk_size: chunk_size}}
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

  defp handle_message(%{type: 8} = message, state) do
    case state.streams_state[message.stream_id] do
      :publishing ->
        handler_state =
          state.handler_mod.handle_audio_data(
            message.stream_id,
            message.timestamp,
            message.payload,
            state.handler_state
          )

        %{state | handler_state: handler_state}

      _other ->
        state
    end
  end

  defp handle_message(%{type: 9} = message, state) do
    case state.streams_state[message.stream_id] do
      :publishing ->
        handler_state =
          state.handler_mod.handle_video_data(
            message.stream_id,
            message.timestamp,
            message.payload,
            state.handler_state
          )

        %{state | handler_state: handler_state}

      _other ->
        state
    end
  end

  defp handle_message(%{type: 18, payload: %Metadata{data: data}} = message, state) do
    %{
      state
      | handler_state:
          state.handler_mod.handle_metadata(
            message.stream_id,
            data,
            state.handler_state
          )
    }
  end

  defp handle_message(%{type: 20} = message, state) do
    {messages, state} =
      case message.payload do
        %NetConnection.Connect{} ->
          handle_connect_message(message.payload, state)

        %CreateStream{} ->
          handle_create_stream_message(message.payload, state)

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

  defp handle_create_stream_message(create_stream, %{state: :connected} = state) do
    transaction_id = create_stream.transaction_id

    case state.handler_mod.handle_create_stream(state.handler_state) do
      {:ok, handler_state} ->
        message =
          transaction_id
          |> Response.ok(data: state.next_stream_id)
          |> Message.command()

        state = %{
          state
          | handler_state: handler_state,
            next_stream_id: state.next_stream_id + 1,
            streams_state: Map.put(state.streams_state, state.next_stream_id, :created)
        }

        {[message], state}

      {:error, reason} ->
        {[Message.command(Response.create_stream_failed(transaction_id, reason))], state}
    end
  end

  defp handle_create_stream_message(create_stream, state) do
    transaction_id = create_stream.transaction_id
    {[Message.command(Response.create_stream_failed(transaction_id, "Not Connected"))], state}
  end

  defp handle_publish_message(publish, stream_id, state) do
    stream_state = Map.get(state.streams_state, stream_id)

    cond do
      is_nil(stream_state) ->
        {[Message.command(OnStatus.publish_bad_stream(), stream_id)], state}

      stream_state != :created ->
        message = Message.command(OnStatus.publish_failed("Stream is #{stream_state}"), stream_id)
        {[message], state}

      true ->
        case state.handler_mod.handle_publish(stream_id, publish.name, state.handler_state) do
          {:ok, handler_state} ->
            state = %{
              state
              | handler_state: handler_state,
                streams_state: Map.put(state.streams_state, stream_id, :publishing)
            }

            messages = [
              Message.stream_begin(stream_id),
              Message.command(OnStatus.publish_ok(), stream_id)
            ]

            {messages, state}

          {:error, reason} ->
            {[Message.command(OnStatus.publish_failed(reason), stream_id)], state}
        end
    end
  end

  defp handle_play_message(play, stream_id, state) do
    Logger.debug("Received play command for #{play.name} on stream: #{stream_id}")
    stream_state = Map.get(state.streams_state, stream_id)

    cond do
      is_nil(stream_state) ->
        {[Message.command(OnStatus.play_bad_stream(), stream_id)], state}

      stream_state != :created ->
        message = Message.command(OnStatus.play_failed("Stream is #{stream_state}"), stream_id)
        {[message], state}

      true ->
        case state.handler_mod.handle_play(stream_id, play, state.handler_state) do
          {:ok, handler_state} ->
            state = %{
              state
              | handler_state: handler_state,
                streams_state: Map.put(state.streams_state, stream_id, :playing)
            }

            messages = [
              Message.stream_begin(stream_id),
              Message.command(OnStatus.play_ok(), stream_id)
            ]

            {messages, state}

          {:error, reason} ->
            {[Message.command(OnStatus.play_failed(reason), stream_id)], state}
        end
    end
  end

  defp handle_delete_stream(stream_id, state) do
    Logger.debug("Received delete stream commad on stream: #{stream_id}")

    state = %{
      state
      | streams_state: Map.delete(state.streams_state, stream_id),
        handler_state: state.handler_mod.handle_delete_stream(stream_id, state.handler_state)
    }

    {[], state}
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

    :ok = :gen_tcp.send(socket, Message.serialize(message, chunk_stream_id: chunk_stream_id))
  end

  defp send_messages(state, []), do: state

  defp send_messages(state, messages) do
    :ok = :gen_tcp.send(state.socket, Enum.map(messages, &Message.serialize/1))
    state
  end
end
