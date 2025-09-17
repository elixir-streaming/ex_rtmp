defmodule ExRTMP.Message.Command.NetConnection.Connect do
  @moduledoc """
  Module describing Connect command.
  """

  @type t :: %__MODULE__{
          transaction_id: number(),
          properties: map(),
          user_arguments: map() | nil
        }

  defstruct [:transaction_id, :properties, :user_arguments]
end
