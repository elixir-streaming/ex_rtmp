defmodule ExRTMP.Client.StreamContext do
  @moduledoc false

  @type state :: :created | :playing | :publishing
  @type action :: :play | :publish | :delete

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          state: state(),
          pending_action: action() | nil,
          pending_peer: GenServer.from() | nil
        }

  defstruct [:id, :pending_action, :pending_peer, state: :created]
end
