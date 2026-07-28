defmodule SymphonyElixir.Gitea.AgentTool do
  @moduledoc "Provider-native Gitea REST tool exposed to Codex app-server turns."

  alias SymphonyElixir.Gitea.Client

  @tool "gitea_api"
  @methods ["GET", "POST", "PATCH", "PUT", "DELETE"]
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{"type" => "string", "enum" => @methods},
      "path" => %{"type" => "string"},
      "params" => %{"type" => ["object", "null"], "additionalProperties" => true},
      "body" => %{"description" => "Optional JSON request body."}
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tool,
        "description" => "Execute a Gitea REST API request using Symphony's configured auth.",
        "inputSchema" => @input_schema
      }
    ]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(@tool, arguments, opts), do: execute_gitea_api(arguments, opts)
  def execute(tool, _arguments, _opts), do: unsupported_tool_response(tool)

  defp execute_gitea_api(arguments, opts) do
    gitea_client = Keyword.get(opts, :gitea_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           gitea_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:gitea_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    method = method |> String.trim() |> String.upcase()
    if method in @methods, do: {:ok, method}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    path = String.trim(path)

    if String.starts_with?(path, "/") and not String.contains?(path, ["://", "\n", "\r", <<0>>]) do
      {:ok, path}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    case encode_payload(%{"status" => status, "body" => body}) do
      {:ok, output} -> dynamic_tool_response(status in 200..299, output)
      :error -> failure_response(tool_error_payload(:gitea_unknown_payload))
    end
  end

  defp failure_response(payload), do: dynamic_tool_response(false, Jason.encode!(payload, pretty: true))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> {:ok, output}
      {:error, _reason} -> :error
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => Enum.map(tool_specs(), & &1["name"])
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "gitea_api expects an object with method and path."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "gitea_api.method must be GET, POST, PATCH, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "gitea_api.path must be a relative Gitea REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "gitea_api.params must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_gitea_token) do
    %{"error" => %{"message" => "Symphony is missing Gitea auth. Set tracker.provider.token or export GITEA_TOKEN."}}
  end

  defp tool_error_payload({:gitea_api_request, reason}) do
    %{"error" => %{"message" => "Gitea API request failed before receiving a successful response.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "Gitea REST tool execution failed.", "reason" => inspect(reason)}}
  end
end
