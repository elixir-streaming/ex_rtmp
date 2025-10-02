Mix.install([:ex_flv, :ex_rtmp])

defmodule StreamWriter do
  use GenServer

  alias ExFLV.Tag

  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  @impl true
  def init(opts) do
    {:ok, client} = ExRTMP.Client.start_link(uri: opts[:uri], stream_key: opts[:stream_key])
    writer = File.open!(opts[:dest], [:write, :binary])
    {:ok, %{client: client, writer: writer}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    :ok = ExRTMP.Client.connect(state.client)
    {:ok, stream_id} = ExRTMP.Client.create_stream(state.client)
    :ok = ExRTMP.Client.play(state.client, stream_id)

    IO.binwrite(state.writer, ExFLV.Header.new(1, true, true) |> ExFLV.Header.serialize())
    IO.binwrite(state.writer, <<0::32>>)
    {:noreply, Map.put(state, :stream_id, stream_id)}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    File.close(state.writer)
    :ok = ExRTMP.Client.delete_stream(state.client, state.stream_id)
    {:stop, :normal, :ok, %{state | writer: nil}}
  end

  @impl true
  def handle_info({:video, pid, _stream_id, {:codec, :avc, dcr}}, %{client: pid} = state) do
    payload =
      dcr
      |> Tag.AVCVideoPacket.new(:sequence_header, 0)
      |> Tag.VideoData.new(:avc, :keyframe)

    tag = Tag.serialize(%Tag{type: :video, data: payload, timestamp: 0})
    IO.binwrite(state.writer, [tag, <<IO.iodata_length(tag)::32>>])

    {:noreply, state}
  end

  @impl true
  def handle_info({:audio, pid, _stream_id, {:codec, :aac, dcr}}, %{client: pid} = state) do
    payload =
      dcr
      |> Tag.AACAudioData.new(:sequence_header)
      |> Tag.AudioData.new(:aac, 3, 1, :stereo)

    tag = Tag.serialize(%Tag{type: :audio, data: payload, timestamp: 0})
    IO.binwrite(state.writer, [tag, <<IO.iodata_length(tag)::32>>])

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:video, pid, _stream_id, {:sample, payload, dts, pts, sync?}},
        %{client: pid} = state
      ) do
    payload =
      payload
      |> Enum.map(&<<byte_size(&1)::32, &1::binary>>)
      |> Tag.AVCVideoPacket.new(:nalu, pts - dts)
      |> Tag.VideoData.new(:avc, if(sync?, do: :keyframe, else: :interframe))

    tag = Tag.serialize(%Tag{type: :video, data: payload, timestamp: dts})
    IO.binwrite(state.writer, [tag, <<IO.iodata_length(tag)::32>>])

    {:noreply, state}
  end

  @impl true
  def handle_info({:audio, pid, _stream_id, {:sample, payload, dts}}, %{client: pid} = state) do
    payload =
      payload
      |> Tag.AACAudioData.new(:raw)
      |> Tag.AudioData.new(:aac, 3, 1, :stereo)

    tag = Tag.serialize(%Tag{type: :audio, data: payload, timestamp: dts})
    IO.binwrite(state.writer, [tag, <<IO.iodata_length(tag)::32>>])

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

[stream_uri, stream_key, output] = System.argv()

{:ok, pid} = StreamWriter.start(uri: stream_uri, stream_key: stream_key, dest: output)

ref = Process.monitor(pid)

receive do
  {:EXIT, ^ref, :process, ^pid, _reason} ->
    :ok
after
  10_000 ->
    StreamWriter.stop(pid)
end
