defmodule BufferBatching.Producer do
  use Task
  alias BufferBatching.{Config, Consumer}

  def start_link(_arg), do: Task.start_link(&produce/0)

  defp produce() do
    Process.sleep(Config.produce_time())
    Consumer.add(:item)
    produce()
  end
end
