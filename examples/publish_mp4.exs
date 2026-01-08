Mix.install([:ex_mp4, :media_codecs, :ex_rtmp])

defmodule Publisher do
  use GenServer

  import ExMP4.Helper, only: [timescalify: 3]

  alias ExFLV.Tag.{AudioData, ExAudioData, ExVideoData, VideoData}
  alias ExMP4.Reader

  def start_link(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    reader = Reader.new!(opts[:path])
    {:ok, client} = ExRTMP.Client.start_link(uri: opts[:uri], stream_key: opts[:stream_key])

    state = %{
      reader: reader,
      rtmp_client: client,
      video_track: Reader.track(reader, :video),
      audio_track: Reader.track(reader, :audio)
    }

    {:ok, state, {:continue, :start_publishing}}
  end

  @impl true
  def handle_continue(:start_publishing, state) do
    state = start_publishing(state)

    video_init_tag = init_tag(state.video_track)
    audio_init_tag = init_tag(state.audio_track)

    :ok = ExRTMP.Client.send_tag(state.rtmp_client, 0, audio_init_tag)
    :ok = ExRTMP.Client.send_tag(state.rtmp_client, 0, video_init_tag)

    Process.send_after(self(), :send_video, 0)
    Process.send_after(self(), :send_audio, 0)

    {:noreply, state}
  end

  @impl true
  def handle_info(:send_video, state) do
    {metadata, video_track} = ExMP4.Track.next_sample(state.video_track)
    timeout = timescalify(metadata.duration, video_track.timescale, 1000)
    Process.send_after(self(), :send_video, timeout - 1)

    sample = Reader.read_sample(state.reader, metadata)
    ct = timescalify(sample.pts - sample.dts, video_track.timescale, 1000)
    timestamp = timescalify(sample.dts, video_track.timescale, 1000)

    tag = video_tag(video_track.media, sample, ct)
    :ok = ExRTMP.Client.send_tag(state.rtmp_client, timestamp, tag)

    {:noreply, %{state | video_track: video_track}}
  end

  @impl true
  def handle_info(:send_audio, state) do
    {metadata, audio_track} = ExMP4.Track.next_sample(state.audio_track)
    timeout = timescalify(metadata.duration, audio_track.timescale, 1000)
    Process.send_after(self(), :send_audio, timeout - 1)

    timestamp = timescalify(metadata.pts, audio_track.timescale, 1000)
    sample = Reader.read_sample(state.reader, metadata)

    tag =
      sample.payload
      |> AudioData.AAC.new(:raw)
      |> AudioData.new(:aac, 3, 1, :stereo)

    :ok = ExRTMP.Client.send_tag(state.rtmp_client, timestamp, tag)

    {:noreply, %{state | audio_track: audio_track}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp start_publishing(state) do
    :ok = ExRTMP.Client.connect(state.rtmp_client)
    :ok = ExRTMP.Client.publish(state.rtmp_client)
    state
  end

  defp init_tag(%{media: :h264} = track) do
    <<_::binary-size(8), dcr::binary>> = ExMP4.Box.serialize(track.priv_data)
    VideoData.AVC.new(dcr, :sequence_header, 0) |> VideoData.new(:h264, :keyframe)
  end

  defp init_tag(%{media: :h265} = track) do
    <<_::binary-size(8), dcr::binary>> = ExMP4.Box.serialize(track.priv_data)

    %ExVideoData{
      frame_type: :keyframe,
      packet_type: :sequence_start,
      fourcc: :hvc1,
      data: dcr
    }
  end

  defp init_tag(%{media: :aac} = track) do
    [es_descriptor] = MediaCodecs.MPEG4.parse_descriptors(track.priv_data.es_descriptor)
    audio_specific_config = es_descriptor.dec_config_descr.decoder_specific_info

    AudioData.AAC.new(audio_specific_config, :sequence_header)
    |> AudioData.new(:aac, 3, 1, :stereo)
  end

  defp video_tag(:h264, sample, ct) do
    sample.payload
    |> VideoData.AVC.new(:nalu, ct)
    |> VideoData.new(:h264, if(sample.sync?, do: :keyframe, else: :interframe))
  end

  defp video_tag(:h265, sample, ct) do
    keyframe? = sample.sync?

    %ExVideoData{
      frame_type: if(keyframe?, do: :keyframe, else: :interframe),
      packet_type: :coded_frames,
      fourcc: :hvc1,
      composition_time_offset: ct,
      data: sample.payload
    }
  end
end

{:ok, pid} =
  Publisher.start_link(
    uri: "rtmp://localhost/app",
    stream_key: "test",
    path: List.first(System.argv())
  )

Process.monitor(pid)

receive do
  {:EXIT, _ref, ^pid, _reason} ->
    :ok
end
