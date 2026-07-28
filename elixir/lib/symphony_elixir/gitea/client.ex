defmodule SymphonyElixir.Gitea.Client do
  @moduledoc "Thin Gitea REST client for repository issue polling."

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @page_size 50

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)
    ["GITEA_TOKEN" | env_reference_names([provider["token"]])] |> Enum.uniq()
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, _request_method} <- request_method(method),
         {:ok, gitea_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, gitea_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: fetch_by_states(states, Config.settings!().tracker, &perform_request/5)
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids), do: fetch_by_ids(ids, Config.settings!().tracker, &perform_request/5)
  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo), do: normalize_issue(issue, repo)
  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, settings, fun), do: fetch_by_states(states, settings, fun)
  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(ids, settings, fun), do: fetch_by_ids(ids, settings, fun)

  defp fetch_by_states(states, tracker, fun) do
    requested = states |> Enum.map(&state/1) |> MapSet.new()

    case query_state(requested) do
      nil -> {:ok, []}
      query -> with {:ok, settings} <- settings(tracker), do: pages(settings, query, requested, 1, fun, [])
    end
  end

  defp pages(settings, query, requested, page, fun, acc) do
    params = %{"state" => query, "type" => "issues", "page" => page, "limit" => @page_size}

    with {:ok, payload} <- request_result(fun.("GET", path(settings), params, nil, settings), false), true <- is_list(payload) or {:error, :gitea_unknown_payload} do
      issues = payload |> Enum.map(&normalize_issue(&1, settings.repo)) |> Enum.reject(&is_nil/1) |> Enum.filter(&MapSet.member?(requested, state(&1.state)))
      malformed = Enum.count(payload, &is_nil(normalize_issue(&1, settings.repo)))
      if malformed > 0, do: Logger.warning("Dropping malformed Gitea issue records count=#{malformed}")
      acc = [issues | acc]
      if length(payload) < @page_size, do: {:ok, acc |> Enum.reverse() |> List.flatten()}, else: pages(settings, query, requested, page + 1, fun, acc)
    end
  end

  defp fetch_by_ids(ids, tracker, fun) do
    with {:ok, settings} <- settings(tracker), do: ids(Enum.uniq(ids), settings, fun, [])
  end

  defp ids([], _, _, acc), do: {:ok, Enum.reverse(acc)}

  defp ids([id | rest], settings, fun, acc) do
    with {:ok, index} <- index(id), {:ok, payload} <- request_result(fun.("GET", "#{path(settings)}/#{index}", %{}, nil, settings), true) do
      case payload do
        :not_found ->
          ids(rest, settings, fun, acc)

        %{} ->
          case normalize_issue(payload, settings.repo) do
            %Issue{} = issue -> ids(rest, settings, fun, [issue | acc])
            nil -> {:error, :gitea_unknown_payload}
          end

        _ ->
          {:error, :gitea_unknown_payload}
      end
    end
  end

  defp request_result({:ok, %{status: status, body: body}}, _) when status in 200..299, do: {:ok, body}
  defp request_result({:ok, %{status: 404}}, true), do: {:ok, :not_found}
  defp request_result({:ok, %{status: status}}, _) when is_integer(status), do: {:error, {:gitea_api_status, status}}
  defp request_result({:error, reason}, _), do: {:error, reason}
  defp request_result(_, _), do: {:error, :gitea_unknown_payload}

  defp normalize_issue(issue, repo) when is_map(issue) do
    index = issue["number"] || issue["index"]

    if is_integer(index) and index > 0 and present_string?(issue["title"]) and present_string?(issue["state"]),
      do: %Issue{
        id: Integer.to_string(index),
        native_ref: %{"id" => issue["id"], "index" => index, "repo" => repo} |> Enum.reject(fn {_, value} -> is_nil(value) end) |> Map.new(),
        identifier: "GT-#{index}",
        title: issue["title"],
        description: issue["body"],
        state: issue["state"],
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        labels: labels(issue),
        blocked_by: [],
        dispatchable: true,
        created_at: datetime(issue["created_at"]),
        updated_at: datetime(issue["updated_at"])
      }
  end

  defp normalize_issue(_, _), do: nil

  defp labels(%{"labels" => labels}) when is_list(labels),
    do:
      labels
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        _ -> []
      end)
      |> Enum.map(&(String.trim(&1) |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp labels(_), do: []

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> nil
    end
  end

  defp datetime(_), do: nil

  defp path(settings) do
    repo = settings.repo |> String.split("/", parts: 2) |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
    "/repos/#{repo}/issues"
  end

  defp query_state(states) do
    cond do
      MapSet.member?(states, "open") and MapSet.member?(states, "closed") -> "all"
      MapSet.member?(states, "open") -> "open"
      MapSet.member?(states, "closed") -> "closed"
      true -> nil
    end
  end

  defp index(value) when is_binary(value) do
    case Integer.parse(value) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_gitea_issue_id}
    end
  end

  defp index(_), do: {:error, :invalid_gitea_issue_id}
  defp state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp state(_), do: ""

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = normalize_string(provider["api_url"])
    repo = resolve_setting(provider["repo"], nil)
    token = resolve_setting(provider["token"], System.get_env("GITEA_TOKEN"))

    cond do
      is_nil(api_url) -> {:error, :missing_gitea_api_url}
      not valid_api_url?(api_url) -> {:error, :invalid_gitea_api_url}
      not present_string?(repo) -> {:error, :missing_gitea_repo}
      not valid_repo?(repo) -> {:error, :invalid_gitea_repo}
      not present_string?(token) -> {:error, :missing_gitea_token}
      true -> {:ok, %{api_url: String.trim_trailing(api_url, "/"), repo: repo, token: token}}
    end
  end

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: [
          {"Accept", "application/json"},
          {"Authorization", "token #{settings.token}"}
        ],
        params: params,
        connect_options: [timeout: 30_000]
      ]

      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      case Req.request(opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:gitea_api_request, reason}}
      end
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name),
      do: normalize_string(System.get_env(env_name) || fallback),
      else: nil
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)
  defp normalize_string(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp normalize_string(_value), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> name -> if valid_env_name?(name), do: [name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil} when scheme in ["http", "https"] and is_binary(host) ->
        String.ends_with?(String.trim_trailing(path || "", "/"), "/api/v1")

      _ ->
        false
    end
  end

  defp valid_repo?(repo), do: String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_gitea_method}
end
