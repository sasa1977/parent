defmodule Parent.PublicTypes do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      @type child_spec :: %{
              :id => id,
              :start => start,
              optional(:type) => :worker | :supervisor,
              optional(:meta) => child_meta,
              optional(:shutdown) => shutdown,
              optional(:timeout) => pos_integer | :infinity
            }

      @type id :: term
      @type child_meta :: term

      @type start :: (() -> on_start_child) | {module, atom, [term]}
      @type on_start_child :: on_start_child

      @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

      @type child :: {id, pid, child_meta}
    end
  end
end
