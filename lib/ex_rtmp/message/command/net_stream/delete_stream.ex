defmodule ExRTMP.Message.Command.NetStream.DeleteStream do
  @moduledoc false

  @type t :: %__MODULE__{
          transaction_id: number(),
          stream_id: number()
        }

  defstruct [:stream_id, transaction_id: 0.0]

  @spec new(number()) :: t()
  def new(stream_id) do
    %__MODULE__{stream_id: stream_id}
  end

  defimpl ExRTMP.Message.Serializer do
    alias ExRTMP.AMF0

    def serialize(delete_stream) do
      [
        AMF0.serialize("deleteStream"),
        AMF0.serialize(0),
        AMF0.serialize(nil),
        AMF0.serialize(delete_stream.stream_id)
      ]
    end
  end
end
