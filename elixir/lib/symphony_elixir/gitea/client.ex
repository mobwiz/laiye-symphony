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
    req_options = Keyword.get(opts, :req_options, [])

    request_fun =
      Keyword.get(opts, :request_fun, fn method, path, params, body, settings ->
        perform_request(method, path, params, body, settings, req_options)
      end)

    with {:ok, _request_method} <- request_method(method),
         {:ok, gitea_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, gitea_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}
  def fetch_issues_by_states(states), do: fetch_by_states(states, Config.settings!().tracker, &perform_request/5)
  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}
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
      query -> with {:ok, settings} <- settings(tracker), do: pages(settings, query, requested, 1, fun, [], nil)
    end
  end

  defp pages(settings, query, requested, page, fun, acc, previous_payload) do
    params = %{"state" => query, "type" => "issues", "page" => page, "limit" => @page_size}

    with {:ok, payload} <-
           request_result(fun.("GET", path(settings), params, nil, settings), false),
         true <- is_list(payload) or {:error, :gitea_unknown_payload} do
      continue_pages(payload, previous_payload, settings, query, requested, page, fun, acc)
    end
  end

  defp continue_pages([], _previous, _settings, _query, _requested, _page, _fun, acc),
    do: {:ok, acc |> Enum.reverse() |> List.flatten()}

  defp continue_pages(payload, payload, _settings, _query, _requested, _page, _fun, _acc),
    do: {:error, :gitea_unknown_payload}

  defp continue_pages(payload, _previous, settings, query, requested, page, fun, acc) do
    normalized = Enum.map(payload, &normalize_issue(&1, settings.repo))
    issues = normalized |> Enum.reject(&is_nil/1) |> Enum.filter(&MapSet.member?(requested, state(&1.state)))
    malformed = Enum.count(normalized, &is_nil/1)
    if malformed > 0, do: Logger.warning("Dropping malformed Gitea issue records count=#{malformed}")

    if length(payload) < @page_size,
      do: {:ok, [issues | acc] |> Enum.reverse() |> List.flatten()},
      else: pages(settings, query, requested, page + 1, fun, [issues | acc], payload)
  end

  defp fetch_by_ids(ids, tracker, fun) do
    case Enum.uniq(ids) do
      [] -> {:ok, []}
      ids -> with {:ok, settings} <- settings(tracker), do: ids(ids, settings, fun, [])
    end
  end

  defp ids([], _, _, acc), do: {:ok, Enum.reverse(acc)}

  defp ids([id | rest], settings, fun, acc) do
    with {:ok, index} <- index(id), {:ok, payload} <- request_result(fun.("GET", "#{path(settings)}/#{index}", %{}, nil, settings), true) do
      case payload do
        :not_found ->
          ids(rest, settings, fun, acc)

        %{} ->
          continue_ids(normalize_issue(payload, settings.repo), rest, settings, fun, acc)

        _ ->
          {:error, :gitea_unknown_payload}
      end
    end
  end

  defp continue_ids(%Issue{} = issue, rest, settings, fun, acc),
    do: ids(rest, settings, fun, [issue | acc])

  defp continue_ids(nil, _rest, _settings, _fun, _acc), do: {:error, :gitea_unknown_payload}

  defp request_result({:ok, %{status: status, body: body}}, _) when status in 200..299, do: {:ok, body}
  defp request_result({:ok, %{status: 404}}, true), do: {:ok, :not_found}
  defp request_result({:ok, %{status: status}}, _) when is_integer(status), do: {:error, {:gitea_api_status, status}}
  defp request_result({:error, reason}, _), do: {:error, reason}
  defp request_result(_, _), do: {:error, :gitea_unknown_payload}

  defp normalize_issue(issue, repo) when is_map(issue) do
    index = issue["number"] || issue["index"]

    if is_integer(index) and index > 0 and present_string?(issue["title"]) and present_string?(issue["state"]) do
      labels = labels(issue)

      %Issue{
        id: Integer.to_string(index),
        native_ref: %{"id" => issue["id"], "index" => index, "repo" => repo} |> Enum.reject(fn {_, value} -> is_nil(value) end) |> Map.new(),
        identifier: "GT-#{index}",
        title: issue["title"],
        description: issue["body"],
        state: issue["state"],
        url: issue["html_url"],
        assignee_id: assignee_id(issue),
        labels: labels,
        blocked_by: [],
        dispatchable: dispatchable_labels?(labels, repo, index),
        created_at: datetime(issue["created_at"]),
        updated_at: datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_, _), do: nil

  defp assignee_id(issue) do
    candidates = [issue["assignee"] | if(is_list(issue["assignees"]), do: issue["assignees"], else: [])]

    Enum.find_value(candidates, fn
      %{"login" => login} -> normalize_string(login)
      _ -> nil
    end)
  end

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

  defp dispatchable_labels?(labels, repo, index) do
    status_labels = Enum.filter(labels, &String.starts_with?(&1, "status/"))

    if length(status_labels) > 1 do
      Logger.warning("Rejecting Gitea issue with conflicting status labels",
        repository: repo,
        issue_index: index,
        status_labels: inspect(status_labels)
      )

      false
    else
      true
    end
  end

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

  defp perform_request(method, path, params, body, settings),
    do: perform_request(method, path, params, body, settings, [])

  defp perform_request(method, path, params, body, settings, req_options) do
    with {:ok, request_method} <- request_method(method) do
      opts =
        Keyword.merge(req_options,
          method: request_method,
          url: settings.api_url <> path,
          headers: [
            {"Accept", "application/json"},
            {"Authorization", "token #{settings.token}"}
          ],
          params: params,
          connect_options: [timeout: 30_000],
          retry: false
        )

      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      opts |> Req.request() |> request_response(method, path)
    end
  end

  defp request_response({:ok, response}, method, path) do
    if response.status not in 200..299,
      do: Logger.error("Gitea API request failed status=#{response.status} method=#{method} path=#{path}")

    {:ok, %{status: response.status, body: response.body}}
  end

  defp request_response({:error, reason}, _method, _path),
    do: {:error, {:gitea_api_request, reason}}

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
      %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
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
