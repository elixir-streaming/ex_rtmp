defmodule ExRTMP.Command.NetStream.Publish do
  @moduledoc false

  @type publishing_type :: :live | :record | :append

  @type t :: %__MODULE__{
          transaction_id: number(),
          name: String.t(),
          type: publishing_type()
        }

  defstruct [:transaction_id, :name, :type]

  @spec new(number(), String.t(), String.t()) :: t()
  def new(transaction_id, name, type) do
    %__MODULE__{
      transaction_id: transaction_id,
      name: name,
      type: String.to_existing_atom(type)
    }
  end
end
