defmodule ExRTMP.ChunkParserTest do
  use ExUnit.Case, async: true

  alias ExRTMP.ChunkParser
  alias ExRTMP.Message
  alias ExRTMP.Message.Command.NetStream.Publish
  alias ExRTMP.Message.Command.NetConnection.CreateStream
  alias ExRTMP.Message.Command.NetConnection.Connect

  test "Parse a stream of chunks into messages" do
    {messages, parser} =
      "test/fixtures/chunk_stream.bin"
      |> File.stream!(1024)
      |> Enum.reduce({[], ChunkParser.new()}, fn chunk, {messges, parser} ->
        {new_messages, parser} = ChunkParser.process(chunk, parser)
        {messges ++ new_messages, parser}
      end)

    assert length(messages) == 5
    assert parser.unprocessed_data == <<>>

    assert [
             %Message{payload: %Connect{transaction_id: 1.0}, type: 20},
             %Message{payload: %CreateStream{transaction_id: 2.0}, type: 20},
             %Message{payload: %Publish{name: "test", type: :record}, type: 20},
             %Message{payload: [<<1, 2, 3>>], type: 8},
             %Message{payload: [<<4, 5>>], type: 9}
           ] = messages
  end
end
