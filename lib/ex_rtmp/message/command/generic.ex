defmodule ExRTMP.Message.Command.Generic do
  @moduledoc false

  # This module describe OPTIONAL command message that can be safely ignored. If
  # some service requires to handle/send these messages, we'll implement them.

  @type t :: %__MODULE__{
          name: String.t(),
          transaction_id: number(),
          params: term()
        }

  defstruct [:name, :transaction_id, :params]

  @spec new(String.t(), number(), term()) :: t()
  def new(name, transaction_id, params) do
    %__MODULE__{transaction_id: transaction_id, name: name, params: params}
  end
end
