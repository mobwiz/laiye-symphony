defmodule SymphonyElixir.Gitea.Adapter do
  @moduledoc "Gitea Issues-backed tracker adapter."

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Gitea.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @active_states ["open"]
  @terminal_states ["closed"]

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(settings) do
    with :ok <- validate_states(settings.active_states, @active_states, :missing_gitea_active_states),
         :ok <- validate_states(settings.terminal_states, @terminal_states, :missing_gitea_terminal_states) do
      Client.validate_settings(settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids), do: client_module().fetch_issues_by_ids(ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)
  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings), do: Client.secret_environment_names(settings)

  defp client_module, do: Application.get_env(:symphony_elixir, :gitea_client_module, Client)

  defp validate_states(states, allowed, _missing) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed)), do: :ok, else: {:error, :invalid_gitea_states}
  end

  defp validate_states(_states, _allowed, missing), do: {:error, missing}
  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
