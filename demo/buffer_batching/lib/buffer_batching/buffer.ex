defmodule BufferBatching.Buffer do
  alias BufferBatching.Buffer

  defstruct size: 0, queue: :queue.new()

  def new(), do: %Buffer{}

  def add(buffer, item),
    do: %Buffer{buffer | queue: :queue.in(item, buffer.queue), size: buffer.size + 1}

  def pop(%Buffer{size: 0}), do: :error

  def pop(buffer) do
    {{:value, item}, queue} = :queue.out(buffer.queue)
    {item, %Buffer{buffer | queue: queue, size: buffer.size - 1}}
  end

  defimpl Enumerable do
    def count(buffer), do: {:ok, buffer.size}

    def member?(_buffer, _element), do: {:error, __MODULE__}
    def slice(_buffer), do: {:error, __MODULE__}

    def reduce(_, {:halt, acc}, _fun), do: {:halted, acc}
    def reduce(buffer, {:suspend, acc}, fun), do: {:suspended, acc, &reduce(buffer, &1, fun)}

    def reduce(buffer, {:cont, acc}, fun) do
      case Buffer.pop(buffer) do
        {item, buffer} -> reduce(buffer, fun.(item, acc), fun)
        :error -> {:done, acc}
      end
    end
  end
end
