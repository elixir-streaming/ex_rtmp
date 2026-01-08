Mix.install([:ex_rtmp, :ex_flv, :ex_mp4, :media_codecs])

defmodule Publisher do
  use GenServer

  import ExMP4.Helper, only: [timescalify: 3]

  alias ExFLV.Tag.{AACAudioData, AVCVideoPacket, AudioData, VideoData}
  alias ExRTMP.Server.ClientSession
  alias MediaCodecs.MPEG4

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    reader = ExMP4.Reader.new!(opts[:file])
    video_track = ExMP4.Reader.track(reader, :video)
    audio_track = ExMP4.Reader.track(reader, :audio)

    video_reducer = &Enumerable.reduce(video_track, &1, fn elem, _acc -> {:suspend, elem} end)
    audio_reducer = &Enumerable.reduce(audio_track, &1, fn elem, _acc -> {:suspend, elem} end)

    {:ok,
     %{
       reader: reader,
       rtmp_sender: opts[:rtmp_sender],
       video_track: video_track,
       video_reducer: video_reducer,
       audio_track: audio_track,
       audio_reducer: audio_reducer,
       stream_id: opts[:stream_id]
     }, {:continue, :send_init_data}}
  end

  @impl true
  def handle_continue(:send_init_data, state) do
    ClientSession.send_metadata(state.rtmp_sender, state.stream_id, %{
      "width" => state.video_track.width,
      "height" => state.video_track.height,
      "videocodecid" => 7,
      "audiocodecid" => 10,
      "audiosamplerate" => state.audio_track.timescale,
      "stereo" => true,
      "filesize" => 0
    })

    Process.send_after(self(), :send_video, 0)
    Process.send_after(self(), :send_audio, 0)

    <<_header::binary-size(8), dcr::binary>> = ExMP4.Box.serialize(state.video_track.priv_data)
    [descriptor | _rest] = MPEG4.parse_descriptors(state.audio_track.priv_data.es_descriptor)
    asc = descriptor.dec_config_descr.decoder_specific_info

    dcr
    |> AVCVideoPacket.new(:sequence_header, 0)
    |> VideoData.new(:h264, :keyframe)
    |> ExFLV.Tag.Serializer.serialize()
    |> then(&ClientSession.send_video_data(state.rtmp_sender, state.stream_id, 0, &1))

    asc
    |> AACAudioData.new(:sequence_header)
    |> AudioData.new(:aac, 3, 1, :stereo)
    |> ExFLV.Tag.Serializer.serialize()
    |> then(&ClientSession.send_audio_data(state.rtmp_sender, state.stream_id, 0, &1))

    {:noreply, state}
  end

  @impl true
  def handle_info(:send_video, state) do
    case state.video_reducer.({:cont, nil}) do
      {:suspended, metadata, video_reducer} ->
        frame_type = if(metadata.sync?, do: :keyframe, else: :interframe)

        dur = timescalify(metadata.duration, state.video_track.timescale, :millisecond)
        Process.send_after(self(), :send_video, dur)

        sample = ExMP4.Reader.read_sample(state.reader, metadata)
        timestamp = timescalify(sample.dts, state.video_track.timescale, :millisecond)

        data =
          sample.payload
          |> AVCVideoPacket.new(:nalu, sample.pts - sample.dts)
          |> VideoData.new(:h264, frame_type)
          |> ExFLV.Tag.Serializer.serialize()

        ClientSession.send_video_data(state.rtmp_sender, state.stream_id, timestamp, data)

        {:noreply, %{state | video_reducer: video_reducer}}

      :done ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:send_audio, state) do
    case state.audio_reducer.({:cont, nil}) do
      {:suspended, metadata, audio_reducer} ->
        dur = timescalify(metadata.duration, state.audio_track.timescale, :millisecond)
        Process.send_after(self(), :send_audio, dur)

        sample = ExMP4.Reader.read_sample(state.reader, metadata)
        timestamp = timescalify(sample.dts, state.audio_track.timescale, :millisecond)

        data =
          sample.payload
          |> AACAudioData.new(:raw)
          |> AudioData.new(:aac, 3, 1, :stereo)
          |> ExFLV.Tag.Serializer.serialize()

        ClientSession.send_audio_data(state.rtmp_sender, state.stream_id, timestamp, data)

        {:noreply, %{state | audio_reducer: audio_reducer}}

      :done ->
        {:noreply, state}
    end
  end
end

defmodule Handler do
  use ExRTMP.Server.Handler

  @impl true
  def init(file) do
    %{publisher: nil, file: file}
  end

  @impl true
  def handle_play(stream_id, _play_command, state) do
    {:ok, pid} = Publisher.start_link(file: state.file, rtmp_sender: self(), stream_id: stream_id)
    {:ok, %{state | publisher: pid}}
  end

  @impl true
  def handle_delete_stream(_stream_id, state) do
    GenServer.stop(state.publisher)
    %{state | publisher: nil}
  end
end

{:ok, pid} =
  ExRTMP.Server.start(
    handler: Handler,
    handler_options: List.first(System.argv())
  )

Process.monitor(pid)

IO.puts("Server started...")

receive do
  {:EXIT, _ref, ^pid, :process, _reason} -> :ok
end
