defmodule ExRTMP.Command.NetStream.DeleteStream do
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
end
