defmodule ExRTMP.Server.Handler do
  @moduledoc """
  Behaviour describing RTMP server handler.
  """

  alias ExRTMP.Message.Command.NetConnection.Connect
  alias ExRTMP.Message.Command.NetStream.Play

  @type state :: any()
  @type stream_id :: non_neg_integer()
  @type timestamp :: non_neg_integer()
  @type reason :: any()
  @type return :: {:ok, state()} | {:error, reason()}

  @doc """
  Initializes the handler state.
  """
  @callback init(opts :: any()) :: state()

  @doc """
  Called when a client send a `connect` command message.
  """
  @callback handle_connect(Connect.t(), state()) :: return()

  @doc """
  Called when a client send a `createStream` command message.
  """
  @callback handle_create_stream(state()) :: return()

  @doc """
  Called when a client send a `publish` net stream command.
  """
  @callback handle_publish(stream_id :: non_neg_integer(), stream_key :: String.t(), state()) ::
              return()

  @callback handle_play(stream_id :: non_neg_integer(), Play.t(), state()) :: return()

  @doc """
  Called when a client send a `deleteStream` net stream command.
  """
  @callback handle_delete_stream(stream_id :: non_neg_integer(), state()) :: state()

  @doc """
  Called when `onMetaData` message is received.
  """
  @callback handle_metadata(stream_id(), metadata :: any(), state()) :: state()

  @doc """
  Called when video data is received.
  """
  @callback handle_video_data(stream_id(), timestamp(), iodata(), state()) :: state()

  @doc """
  Called when audio data is received.
  """
  @callback handle_audio_data(stream_id(), timestamp(), iodata(), state()) :: state()

  @optional_callbacks init: 1,
                      handle_connect: 2,
                      handle_create_stream: 1,
                      handle_publish: 3,
                      handle_delete_stream: 2,
                      handle_video_data: 4,
                      handle_audio_data: 4

  defmacro __using__(_opts) do
    quote do
      @behaviour ExRTMP.Server.Handler

      @impl true
      def init(opts), do: opts

      @impl true
      def handle_connect(_connect, state), do: {:ok, state}

      @impl true
      def handle_create_stream(state), do: {:ok, state}

      @impl true
      def handle_publish(_stream_id, _stream_key, state), do: {:ok, state}

      @impl true
      def handle_play(_stream_id, _play, state), do: {:ok, state}

      @impl true
      def handle_delete_stream(_stream_id, state), do: state

      @impl true
      def handle_metadata(_stream_id, _metadata, state), do: state

      @impl true
      def handle_video_data(_stream_id, _timestamp, _data, state), do: state

      @impl true
      def handle_audio_data(_stream_id, _timestamp, _data, state), do: state

      defoverridable init: 1,
                     handle_connect: 2,
                     handle_create_stream: 1,
                     handle_publish: 3,
                     handle_play: 3,
                     handle_delete_stream: 2,
                     handle_metadata: 3,
                     handle_video_data: 4,
                     handle_audio_data: 4
    end
  end
end
