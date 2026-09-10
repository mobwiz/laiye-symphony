defmodule SymphonyElixir.PresetPool do
  @moduledoc "Persistent local preset assignments; never deletes environment directories."
  require Logger
  alias SymphonyElixir.{Config, PathSafety, Workflow}

  @spec enabled?() :: boolean()
  def enabled?, do: Config.settings!().workspace.mode == "preset"

  @spec records() :: map()
  def records do
    case File.read(ledger()) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise File.Error, reason: reason, action: "read preset ledger", path: ledger()
    end
  end

  @spec reserve(map() | String.t()) :: {:ok, Path.t()} | {:error, term()}
  def reserve(issue) do
    locked(fn -> reserve_entry(records(), identity(issue), issue) end)
  rescue
    error -> {:error, {:preset_pool_error, Exception.message(error)}}
  end

  defp reserve_entry(entries, key, issue) do
    case entries[key] do
      %{"path" => path, "root" => root} ->
        with :ok <- validate(path, root), do: {:ok, path}

      nil ->
        allocate(entries, key, issue)
    end
  end

  @spec assigned?(map() | String.t() | nil) :: boolean()
  def assigned?(issue), do: not is_nil(issue) and Map.has_key?(records(), identity(issue))

  @spec protected?(Path.t()) :: boolean()
  def protected?(path) do
    File.exists?(Path.join(path, ".environment/runtime.env")) or
      Enum.any?(records(), fn {_, entry} -> entry["path"] == Path.expand(path) end)
  end

  @spec prepare(Path.t(), map() | String.t()) :: :ok | {:error, term()}
  def prepare(path, issue) do
    case records()[identity(issue)] do
      %{"path" => ^path} = entry ->
        change_phase(issue, "preparing")
        result = action(entry, "prepare")
        change_phase(issue, if(result == :ok, do: "ready", else: "prepare_failed"))
        result

      _ ->
        {:error, :preset_assignment_mismatch}
    end
  end

  defp change_phase(issue, phase) do
    locked(fn ->
      entries = records()
      key = identity(issue)
      entry = Map.put(Map.fetch!(entries, key), "phase", phase)
      persist(Map.put(entries, key, entry))
    end)
  end

  @spec release(Path.t()) :: {:ok, list()} | {:error, term(), String.t()}
  def release(path) do
    locked(fn ->
      entries = records()

      case find_path(entries, path) do
        {key, entry} ->
          finish_release(entries, key, entry, path)

        nil ->
          {:error, :unowned_preset_environment, path}
      end
    end)
  rescue
    error -> {:error, {:preset_pool_error, Exception.message(error)}, path}
  end

  defp find_path(entries, path), do: Enum.find(entries, fn {_, entry} -> entry["path"] == Path.expand(path) end)

  defp finish_release(entries, key, entry, path) do
    case cleanup(entry) do
      :ok ->
        persist(Map.delete(entries, key))
        {:ok, []}

      {:error, reason} ->
        Logger.warning("Preset cleanup retained ownership path=#{path} reason=#{inspect(reason)}")
        persist(Map.put(entries, key, Map.put(entry, "phase", "cleanup_failed")))
        {:error, reason, path}
    end
  end

  @spec release_issue(map() | String.t()) :: :ok
  def release_issue(issue) do
    case records()[identity(issue)] do
      %{"path" => path} -> release(path)
      nil -> :ok
    end

    :ok
  end

  defp allocate(entries, key, issue) do
    config = Config.settings!()
    root = Config.local_workspace_root()

    cond do
      not enabled?() ->
        {:error, :preset_pool_disabled}

      Enum.any?(entries, fn {_, entry} -> entry["scope"] != scope() end) ->
        {:error, :preset_tracker_scope_changed}

      config.worker.ssh_hosts != [] ->
        {:error, :preset_pool_requires_local_worker}

      true ->
        candidates = Enum.map(config.workspace.environments, &Path.join(root, &1))

        with :ok <- validate_all(candidates, root) do
          allocate_available(candidates, entries, key, issue, root)
        end
    end
  end

  defp allocate_available(candidates, entries, key, issue, root) do
    occupied = MapSet.new(entries, fn {_, entry} -> entry["path"] end)

    case Enum.find(candidates, &(not MapSet.member?(occupied, &1) and free?(&1))) do
      nil ->
        {:error, :preset_pool_full}

      path ->
        entry = %{
          "path" => path,
          "root" => root,
          "issue_id" => issue_id(issue),
          "identifier" => identifier(issue),
          "job_id" => "symphony-" <> key,
          "phase" => "reserved",
          "scope" => scope()
        }

        persist(Map.put(entries, key, entry))
        {:ok, path}
    end
  end

  defp validate_all(paths, root) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case validate(path, root) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate(path, root) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      required = ["dev/job.sh", ".environment/runtime.env", ".environment/repositories.json", ".environment/provisioned.json"]

      if canonical == Path.expand(path) and Path.dirname(canonical) == canonical_root and
           Enum.all?(required, &File.regular?(Path.join(path, &1))) do
        :ok
      else
        {:error, {:invalid_preset_environment, path}}
      end
    end
  end

  defp free?(path) do
    case File.read(Path.join(path, ".environment/job.json")) do
      {:error, :enoent} -> true
      {:ok, json} -> match?({:ok, %{"phase" => "released"}}, Jason.decode(json))
      _ -> false
    end
  end

  defp action(entry, command) do
    with true <- entry["scope"] == scope(),
         :ok <- validate(entry["path"], entry["root"]) do
      args = [command, entry["job_id"]] ++ if(command == "cleanup", do: ["--terminal"], else: [])
      task = Task.async(fn -> System.cmd(Path.join(entry["path"], "dev/job.sh"), args, cd: entry["path"], stderr_to_stdout: true) end)

      case Task.yield(task, Config.settings!().hooks.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, 0}} -> verify_job_state(entry, command)
        {:ok, {_output, code}} -> {:error, {:preset_job_failed, command, code}}
        _ -> {:error, {:preset_job_timeout, command}}
      end
    else
      false -> {:error, :preset_tracker_scope_changed}
      error -> error
    end
  end

  defp cleanup(%{"phase" => "reserved"} = entry) do
    if entry["scope"] == scope() and free?(entry["path"]), do: :ok, else: action(entry, "cleanup")
  end

  defp cleanup(entry), do: action(entry, "cleanup")

  defp verify_job_state(entry, command) do
    expected = if command == "prepare", do: "ready", else: "released"

    with {:ok, json} <- File.read(Path.join(entry["path"], ".environment/job.json")),
         {:ok, %{"job_id" => owner, "phase" => phase}} <- Jason.decode(json),
         true <- owner == entry["job_id"] and phase == expected do
      :ok
    else
      _ -> {:error, :preset_job_state_mismatch}
    end
  end

  defp identity(issue), do: :crypto.hash(:sha256, scope() <> "\0" <> issue_id(issue)) |> Base.encode16(case: :lower)

  defp scope do
    tracker = Config.settings!().tracker
    fields = ["endpoint", "api_url", "repo", "project_slug", "project_id", "owner", "team_id"]

    :crypto.hash(:sha256, :erlang.term_to_binary({tracker.kind, Enum.sort(Map.take(tracker.provider, fields))}))
    |> Base.encode16(case: :lower)
  end

  defp issue_id(%{id: id}) when is_binary(id), do: id
  defp issue_id(issue), do: identifier(issue)
  defp identifier(%{identifier: id}) when is_binary(id), do: id
  defp identifier(id) when is_binary(id), do: id
  defp ledger, do: Path.join(Path.dirname(Workflow.workflow_file_path()), ".symphony-preset-pool.json")
  # ponytail: one local Symphony instance; use an OS-wide lease before sharing a pool across instances.
  defp locked(fun), do: :global.trans({{__MODULE__, ledger()}, self()}, fun)

  defp persist(entries) do
    path = ledger()
    File.write!(path <> ".new", Jason.encode!(entries))
    File.chmod!(path <> ".new", 0o600)
    File.rename!(path <> ".new", path)
  end
end
