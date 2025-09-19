defmodule ExRTMP.Message.Command.NetStream.Play do
  @moduledoc """
  Module representing a `NetStream.Play` command message.
  """

  @type t :: %__MODULE__{
          transaction_id: float(),
          name: String.t(),
          start: integer(),
          duration: integer(),
          reset: boolean()
        }

  defstruct [:transaction_id, :name, start: -2, duration: -1, reset: true]

  @spec new(float(), String.t(), keyword()) :: t()
  def new(transaction_id, name, opts \\ []) do
    struct(%__MODULE__{transaction_id: transaction_id, name: name}, opts)
  end
end
