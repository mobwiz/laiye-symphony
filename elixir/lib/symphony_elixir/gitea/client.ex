defmodule SymphonyElixir.Gitea.Client do
  @moduledoc "Thin Gitea REST client for repository issue polling."

  alias SymphonyElixir.Config

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
      %URI{scheme: scheme, host: host, path: path} when scheme in ["http", "https"] and is_binary(host) ->
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
