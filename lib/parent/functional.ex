defmodule Parent.Functional do
  alias Parent.Registry

  def initialize() do
    Process.flag(:trap_exit, true)
    Registry.new()
  end

  def start_child(registry, child_spec) do
    full_child_spec = expand_child_spec(child_spec)

    with {:ok, pid} <- start_child_process(full_child_spec.start),
         do: {:ok, pid, Registry.register(registry, full_child_spec.id, pid)}
  end

  def shutdown_child(registry, child_id, shutdown \\ :timer.seconds(5)) do
    case Registry.pid(registry, child_id) do
      :error ->
        raise "trying to terminate an unknown child"

      {:ok, pid} ->
        Process.exit(pid, :shutdown)

        receive do
          {:EXIT, ^pid, _reason} -> :ok
        after
          shutdown ->
            Process.exit(pid, :kill)

            receive do
              {:EXIT, ^pid, _reason} -> :ok
            end
        end

        {:ok, _name, registry} = Registry.pop(registry, pid)
        registry
    end
  end

  def handle_message(registry, {:EXIT, pid, reason}) do
    with {:ok, name, registry} <- Registry.pop(registry, pid),
         do: {{:EXIT, pid, name, reason}, registry}
  end

  def handle_message(_registry, _other), do: :error

  defp expand_child_spec(mod) when is_atom(mod), do: expand_child_spec({mod, nil})
  defp expand_child_spec({mod, arg}), do: expand_child_spec(mod.child_spec(arg))
  defp expand_child_spec(%{} = child_spec), do: child_spec
  defp expand_child_spec(_other), do: raise("invalid child_spec")

  defp start_child_process({mod, fun, args}), do: apply(mod, fun, args)
  defp start_child_process(fun) when is_function(fun, 0), do: fun.()
end
