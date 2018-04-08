defmodule Parent.PublicTypes do
  @moduledoc false

  defmacro __using__(_) do
    quote do
      @type in_child_spec ::
              full_child_spec
              | %{id: name, start: start}
              | module
              | {module, term}

      @type full_child_spec :: %{id: name, start: start, shutdown: shutdown}
      @type name :: term

      @type start :: (() -> on_start_child) | {module, atom, [term]}
      @type on_start_child :: {:ok, pid()} | term()

      @type shutdown :: non_neg_integer() | :infinity | :brutal_kill

      @type entries :: %{name => pid}
    end
  end
end
