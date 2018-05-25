defmodule Parent.PublicTypes do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      @type in_child_spec ::
              %{
                :id => name,
                :start => start,
                optional(:meta) => child_meta,
                optional(:shutdown) => shutdown
              }
              | module
              | {module, term}

      @type name :: term
      @type child_meta :: term

      @type start :: (() -> on_start_child) | {module, atom, [term]}
      @type on_start_child :: {:ok, pid()} | term()

      @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

      @type child :: {name, pid, child_meta}
    end
  end
end
