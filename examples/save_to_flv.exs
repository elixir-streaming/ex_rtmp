Mix.install([:ex_rtmp])

defmodule Handler do
  use ExRTMP.Server.Handler

  @impl true
  def init(_options), do: %{app: nil, file: nil}

  @impl true
  def handle_connect(%{properties: props}, state) do
    app = Map.fetch!(props, "app")
    {:ok, %{state | app: app}}
  end

  @impl true
  def handle_publish(stream_key, state) do
    file = File.open!("output_#{state.app}_#{stream_key}.flv", [:write, :binary, :raw])
    IO.binwrite(file, [ExFLV.Header.serialize(ExFLV.Header.new(1, true, true)), <<0::32>>])
    {:ok, %{state | file: file}}
  end

  @impl true
  def handle_audio_data(timestamp, payload, state) do
    tag = %ExFLV.Tag{type: :audio, timestamp: timestamp, data: payload}
    write_tag(tag, state)
  end

  @impl true
  def handle_video_data(timestamp, iodata, state) do
    tag = %ExFLV.Tag{type: :video, timestamp: timestamp, data: iodata}
    write_tag(tag, state)
  end

  @impl true
  def handle_delete_stream(state) do
    File.close(state.file)
    :close
  end

  defp write_tag(tag, state) do
    data = ExFLV.Tag.serialize(tag)
    :ok = IO.binwrite(state.file, [data, <<IO.iodata_length(data)::32>>])
    state
  end
end

{:ok, pid} = ExRTMP.Server.start_link(port: 1935, handler: Handler, demux: false)
Process.monitor(pid)

receive do
  {:DOWN, _ref, :process, ^pid, _reason} ->
    :ok
end
