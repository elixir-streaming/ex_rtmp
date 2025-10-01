defmodule ExRTMP.Message.Command.NetStream.DeleteStream do
  @moduledoc false

  @type t :: %__MODULE__{
          transaction_id: number(),
          stream_id: number()
        }

  defstruct [:transaction_id, :stream_id]

  @spec new(number(), number()) :: t()
  def new(transaction_id, stream_id) do
    %__MODULE__{transaction_id: transaction_id, stream_id: stream_id}
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
