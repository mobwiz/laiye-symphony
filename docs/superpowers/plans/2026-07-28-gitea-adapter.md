# Gitea Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Gitea 1.25 as a first-class Symphony issue tracker with repository-scoped polling, reconciliation, and a host-authenticated writable `gitea_api` tool.

**Architecture:** Implement a provider-specific adapter, REST client, and dynamic agent tool behind the existing `SymphonyElixir.Tracker` boundary. Follow the GitHub/GitLab adapter shape, but keep Gitea paths, `Authorization: token` authentication, payload normalization, errors, and tool naming explicit; do not add a generic forge layer.

**Tech Stack:** Elixir 1.19/OTP 28, Req, Jason, ExUnit, Ecto-backed existing workflow configuration.

## Global Constraints

- Follow `SPEC.md`; the orchestrator consumes only normalized issues and never branches on Gitea semantics.
- `tracker.kind` is exactly `gitea`.
- `tracker.provider.api_url` is required and includes `/api/v1`; accept HTTP or HTTPS and trim trailing `/`.
- `tracker.provider.repo` is required in exact `owner/repo` form.
- `tracker.provider.token` defaults to `GITEA_TOKEN`, accepts `$VAR_NAME`, and is required.
- Active states accept only `open`; terminal states accept only `closed`.
- Candidate requests use `type=issues`, `page`, and `limit=50`.
- Issue identifiers are `GT-<index>`.
- Expose exactly one provider-native tool, `gitea_api`, supporting GET, POST, PATCH, PUT, and DELETE.
- Remove `GITEA_TOKEN` and a referenced token environment variable from Codex children.
- Add no dependency and no generic forge abstraction.
- Every public `def` in `elixir/lib/` has an adjacent `@spec`.

---

## File Structure

- Create `elixir/lib/symphony_elixir/gitea/client.ex`: settings, auth, HTTP requests, pagination, refresh, and issue normalization.
- Create `elixir/lib/symphony_elixir/gitea/adapter.ex`: tracker behavior, state validation, delegation, and optional agent-tool callbacks.
- Create `elixir/lib/symphony_elixir/gitea/agent_tool.ex`: `gitea_api` schema, argument validation, execution, and structured results.
- Create `elixir/test/symphony_elixir/gitea_adapter_test.exs`: focused config, read, normalization, tool, and session-binding coverage.
- Modify `elixir/lib/symphony_elixir/tracker.ex`: register `tracker.kind: gitea`.
- Modify `elixir/README.md`: list and document Gitea configuration, reads, tool scope, and auth isolation.

### Task 1: Gitea Settings and Authenticated REST Request

**Files:**

- Create: `elixir/lib/symphony_elixir/gitea/client.ex`
- Create: `elixir/test/symphony_elixir/gitea_adapter_test.exs`

**Interfaces:**

- Produces: `Gitea.Client.validate_settings(map()) :: :ok | {:error, term()}`
- Produces: `Gitea.Client.secret_environment_names(map()) :: [String.t()]`
- Produces: `Gitea.Client.request(String.t(), String.t(), map(), term(), keyword()) :: {:ok, %{status: integer(), body: term()}} | {:error, term()}`
- Internal request callback: `(method, path, params, body, %{api_url:, repo:, token:}) -> {:ok, %{status:, body:}} | {:error, term()}`

- [ ] **Step 1: Write failing settings and request tests**

Create the test module with a settings helper and tests that lock down required
configuration, `$VAR` resolution, secret declaration, request option passing,
and method validation:

```elixir
defmodule SymphonyElixir.Gitea.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Gitea.Client, as: GiteaClient

  test "client validates Gitea settings and declares token environments" do
    assert :ok = GiteaClient.validate_settings(tracker_settings())

    assert {:error, :missing_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => 123}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "git.laiye.com/api/v1"}))

    assert :ok =
             GiteaClient.validate_settings(
               tracker_settings(%{"api_url" => "http://gitea.test/api/v1/"})
             )

    assert {:error, :missing_gitea_repo} =
             GiteaClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_gitea_repo} =
             GiteaClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_gitea_token} =
             GiteaClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert GiteaClient.secret_environment_names(
             tracker_settings(%{"token" => "$SYMPHONY_GITEA_TOKEN"})
           ) == ["GITEA_TOKEN", "SYMPHONY_GITEA_TOKEN"]
  end

  test "request binds normalized settings and rejects unsupported methods" do
    test_pid = self()

    request_fun = fn method, path, params, body, settings ->
      send(test_pid, {:gitea_request, method, path, params, body, settings})
      {:ok, %{status: 201, body: %{"id" => 7}}}
    end

    assert {:ok, %{status: 201, body: %{"id" => 7}}} =
             GiteaClient.request(
               "POST",
               "/repos/octo/repo/issues/1/comments",
               %{"page" => 1},
               %{"body" => "done"},
               tracker_settings: tracker_settings(%{"api_url" => "https://gitea.test/api/v1/"}),
               request_fun: request_fun
             )

    assert_received {:gitea_request, "POST", "/repos/octo/repo/issues/1/comments",
                     %{"page" => 1}, %{"body" => "done"},
                     %{api_url: "https://gitea.test/api/v1", repo: "octo/repo", token: "secret"}}

    assert {:error, :invalid_gitea_method} =
             GiteaClient.request(
               "OPTIONS",
               "/version",
               %{},
               nil,
               tracker_settings: tracker_settings(),
               request_fun: request_fun
             )
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "gitea",
      provider:
        Map.merge(
          %{
            "api_url" => "https://git.laiye.com/api/v1",
            "repo" => "octo/repo",
            "token" => "secret"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end
end
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
```

Expected: compilation fails because `SymphonyElixir.Gitea.Client` does not
exist.

- [ ] **Step 3: Implement the minimal client settings and request boundary**

Create `Gitea.Client` with these public functions and private helpers:

```elixir
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
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> true
      _ -> false
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
```

Keep the settings helpers private; later tasks extend this same module rather
than creating a configuration abstraction.

- [ ] **Step 4: Run the focused tests**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
mix specs.check
```

Expected: both commands pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/gitea/client.ex \
  elixir/test/symphony_elixir/gitea_adapter_test.exs
git commit -m "feat(gitea): add authenticated REST client"
```

### Task 2: Repository Issue Reads and Tracker Registration

**Files:**

- Create: `elixir/lib/symphony_elixir/gitea/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/gitea/client.ex`
- Modify: `elixir/lib/symphony_elixir/tracker.ex:13`
- Modify: `elixir/test/symphony_elixir/gitea_adapter_test.exs`

**Interfaces:**

- Consumes: Task 1 settings and request callback shape.
- Produces: `Gitea.Client.fetch_issues_by_states/1`
- Produces: `Gitea.Client.fetch_issues_by_ids/1`
- Produces test seams `fetch_issues_by_states_for_test/3`, `fetch_issues_by_ids_for_test/3`, and `normalize_issue_for_test/2`.
- Produces: complete tracker read adapter available from `Tracker.adapter_for_kind("gitea")`.

- [ ] **Step 1: Add failing adapter, normalization, pagination, and refresh tests**

Extend the test aliases and add a fake client:

```elixir
alias SymphonyElixir.Gitea.Adapter, as: GiteaAdapter
alias SymphonyElixir.Gitea.Client, as: GiteaClient
alias SymphonyElixir.Tracker

defmodule FakeGiteaClient do
  def fetch_issues_by_states(states), do: {:ok, states}
  def fetch_issues_by_ids(ids), do: {:ok, ids}
end
```

Add setup that restores `:gitea_client_module`, then add these assertions:

```elixir
test "adapter validates states, delegates reads, and is registered" do
  settings = tracker_settings()
  assert :ok = GiteaAdapter.validate_config(settings)
  assert {:error, :missing_gitea_active_states} =
           GiteaAdapter.validate_config(%{settings | active_states: nil})
  assert {:error, :missing_gitea_terminal_states} =
           GiteaAdapter.validate_config(%{settings | terminal_states: nil})
  assert {:error, :invalid_gitea_states} =
           GiteaAdapter.validate_config(%{settings | active_states: ["todo"]})
  assert {:error, :invalid_gitea_states} =
           GiteaAdapter.validate_config(%{settings | terminal_states: ["open"]})

  Application.put_env(:symphony_elixir, :gitea_client_module, FakeGiteaClient)
  assert {:ok, ["open"]} = GiteaAdapter.fetch_issues_by_states(["open"])
  assert {:ok, ["42"]} = GiteaAdapter.fetch_issues_by_ids(["42"])
  assert {:ok, GiteaAdapter} = Tracker.adapter_for_kind("gitea")
end

test "client normalizes Gitea issues" do
  issue = GiteaClient.normalize_issue_for_test(raw_issue(42), "octo/repo")
  assert issue.id == "42"
  assert issue.identifier == "GT-42"
  assert issue.native_ref == %{"id" => 1_042, "index" => 42, "repo" => "octo/repo"}
  assert issue.title == "Issue 42"
  assert issue.description == "Body 42"
  assert issue.state == "open"
  assert issue.url == "https://gitea.test/octo/repo/issues/42"
  assert issue.assignee_id == "octocat"
  assert issue.labels == ["bug", "platform"]
  assert issue.blocked_by == []
  assert issue.dispatchable
  assert %DateTime{} = issue.created_at
  assert %DateTime{} = issue.updated_at
  assert GiteaClient.normalize_issue_for_test(Map.put(raw_issue(43), "title", " "), "octo/repo") == nil
end

test "client pages candidate issues with Gitea query parameters" do
  first_page = Enum.map(1..48, &raw_issue/1) ++
    [Map.put(raw_issue(49), "state", "closed"), Map.put(raw_issue(50), "title", "")]

  request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
    send(self(), {:gitea_page, params})
    body = if params["page"] == 1, do: first_page, else: [raw_issue(51)]
    {:ok, %{status: 200, body: body}}
  end

  log =
    capture_log(fn ->
      assert {:ok, issues} =
               GiteaClient.fetch_issues_by_states_for_test([" OPEN "], tracker_settings(), request_fun)
      assert Enum.map(issues, & &1.id) == Enum.map(1..48, &Integer.to_string/1) ++ ["51"]
    end)

  assert log =~ "Dropping malformed Gitea issue records count=1"
  assert_receive {:gitea_page, %{"state" => "open", "type" => "issues", "page" => 1, "limit" => 50}}
  assert_receive {:gitea_page, %{"page" => 2}}

  assert {:ok, []} =
           GiteaClient.fetch_issues_by_states_for_test(["todo"], tracker_settings(), fn _, _, _, _, _ ->
             flunk("unsupported states must not request Gitea")
           end)
end

test "client refreshes ordered IDs, omits 404s, and rejects malformed records" do
  request_fun = fn "GET", path, %{}, nil, _settings ->
    case path do
      "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
      "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
      "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{}}}
    end
  end

  assert {:ok, issues} =
           GiteaClient.fetch_issues_by_ids_for_test(["2", "1", "404", "2"], tracker_settings(), request_fun)
  assert Enum.map(issues, & &1.id) == ["2", "1"]
  assert {:error, :invalid_gitea_issue_id} =
           GiteaClient.fetch_issues_by_ids_for_test(["x"], tracker_settings(), request_fun)

  assert {:error, :gitea_unknown_payload} =
           GiteaClient.fetch_issues_by_ids_for_test(["3"], tracker_settings(), fn _, _, _, _, _ ->
             {:ok, %{status: 200, body: Map.put(raw_issue(3), "state", "")}}
           end)
end
```

Use this fixture:

```elixir
defp raw_issue(index) do
  %{
    "id" => 1_000 + index,
    "number" => index,
    "title" => "Issue #{index}",
    "body" => "Body #{index}",
    "state" => "open",
    "html_url" => "https://gitea.test/octo/repo/issues/#{index}",
    "assignee" => %{"login" => "octocat"},
    "labels" => [%{"name" => " Bug "}, %{"name" => "platform"}, %{"name" => "bug"}],
    "created_at" => "2026-07-28T00:00:00Z",
    "updated_at" => "2026-07-28T01:00:00Z"
  }
end
```

- [ ] **Step 2: Run the test and verify the new read cases fail**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
```

Expected: failures report missing `Gitea.Adapter`, read functions, and
normalization functions.

- [ ] **Step 3: Implement the adapter and register it**

Create `Gitea.Adapter`:

```elixir
defmodule SymphonyElixir.Gitea.Adapter do
  @moduledoc "Gitea Issues-backed tracker adapter."

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Gitea.Client
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

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(settings), do: Client.secret_environment_names(settings)

  defp client_module, do: Application.get_env(:symphony_elixir, :gitea_client_module, Client)

  defp validate_states(states, allowed, _missing) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed)),
      do: :ok,
      else: {:error, :invalid_gitea_states}
  end

  defp validate_states(_states, _allowed, missing), do: {:error, missing}
  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
```

Add the map entry in `Tracker`:

```elixir
"gitea" => SymphonyElixir.Gitea.Adapter,
```

- [ ] **Step 4: Implement reads and normalization in the client**

Add the public functions and test seams:

```elixir
@spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
def fetch_issues_by_states(states),
  do: fetch_issues_by_states(states, Config.settings!().tracker, &perform_request/5)

@spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
def fetch_issues_by_ids(ids),
  do: fetch_issues_by_ids(ids, Config.settings!().tracker, &perform_request/5)

@doc false
@spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
def normalize_issue_for_test(issue, repo), do: normalize_issue(issue, repo)

@doc false
@spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
        {:ok, [Issue.t()]} | {:error, term()}
def fetch_issues_by_states_for_test(states, settings, request_fun),
  do: fetch_issues_by_states(states, settings, request_fun)

@doc false
@spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
        {:ok, [Issue.t()]} | {:error, term()}
def fetch_issues_by_ids_for_test(ids, settings, request_fun),
  do: fetch_issues_by_ids(ids, settings, request_fun)
```

Implement the private flow with:

```elixir
params = %{"state" => state_query, "type" => "issues", "page" => page, "limit" => 50}
path = "/repos/#{encoded_repo(settings.repo)}/issues"
```

Use `all` only when both `open` and `closed` are requested, post-filter every
normalized record against the requested state set, and stop when
`length(payload) < 50`. For refresh, `Enum.uniq/1` IDs, parse positive decimal
indexes, request `#{path}/#{index}`, omit `404`, and fail malformed records.

Normalize with:

```elixir
%Issue{
  id: Integer.to_string(index),
  native_ref: %{"id" => issue["id"], "index" => index, "repo" => repo},
  identifier: "GT-#{index}",
  title: issue["title"],
  description: issue["body"],
  state: issue["state"],
  url: issue["html_url"],
  assignee_id: get_in(issue, ["assignee", "login"]),
  labels: extract_labels(issue),
  blocked_by: [],
  dispatchable: true,
  created_at: parse_datetime(issue["created_at"]),
  updated_at: parse_datetime(issue["updated_at"])
}
```

Accept either integer `number` or integer `index` as the issue index, preferring
`number`. Build `native_ref` by removing nil values so an absent database ID
does not invalidate the record. Reuse Elixir `URI`, `DateTime`, `MapSet`, and
`Logger`; add no helper dependency.

- [ ] **Step 5: Run focused read tests and specs**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
mix specs.check
```

Expected: all Gitea tests and the public-spec check pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/gitea/adapter.ex \
  elixir/lib/symphony_elixir/gitea/client.ex \
  elixir/lib/symphony_elixir/tracker.ex \
  elixir/test/symphony_elixir/gitea_adapter_test.exs
git commit -m "feat(gitea): poll repository issues"
```

### Task 3: Writable `gitea_api` Agent Tool and Session Binding

**Files:**

- Create: `elixir/lib/symphony_elixir/gitea/agent_tool.ex`
- Modify: `elixir/lib/symphony_elixir/gitea/adapter.ex`
- Modify: `elixir/test/symphony_elixir/gitea_adapter_test.exs`

**Interfaces:**

- Consumes: `Gitea.Client.request/5` from Task 1.
- Produces: `Gitea.AgentTool.tool_specs/0 :: [map()]`
- Produces: `Gitea.AgentTool.execute/3 :: map()`
- Produces: adapter callbacks `agent_tool_specs/0` and `execute_agent_tool/3`.

- [ ] **Step 1: Write failing tool and session-binding tests**

Add the agent-tool alias and tests:

```elixir
alias SymphonyElixir.Gitea.AgentTool, as: GiteaAgentTool
alias SymphonyElixir.{Config, Tracker, Workflow}

test "gitea_api forwards writable REST calls and preserves status and body" do
  response =
    GiteaAgentTool.execute(
      "gitea_api",
      %{
        "method" => "post",
        "path" => " /repos/octo/repo/issues/42/comments ",
        "params" => %{},
        "body" => %{"body" => "done"}
      },
      tracker_settings: tracker_settings(),
      gitea_client: fn method, path, params, body, opts ->
        send(self(), {:gitea_tool, method, path, params, body, opts})
        {:ok, %{status: 201, body: %{"id" => 9}}}
      end
    )

  assert_received {:gitea_tool, "POST", "/repos/octo/repo/issues/42/comments", %{},
                   %{"body" => "done"}, [tracker_settings: _]}
  assert response["success"] == true
  assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}

  failure =
    GiteaAgentTool.execute(
      "gitea_api",
      %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
      gitea_client: fn _, _, _, _, _ -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}} end
    )

  assert failure["success"] == false
  assert Jason.decode!(failure["output"]) == %{"status" => 404, "body" => %{"message" => "Not Found"}}
end

test "gitea_api rejects unsafe calls and reports supported tools" do
  for arguments <- [
        %{"method" => "GET", "path" => "https://gitea.test/api/v1/version"},
        %{"method" => "OPTIONS", "path" => "/version"},
        %{"method" => "GET", "path" => "/version", "params" => false},
        %{"path" => "/version"},
        "not-an-object"
      ] do
    response =
      GiteaAgentTool.execute("gitea_api", arguments,
        gitea_client: fn _, _, _, _, _ -> flunk("invalid call reached client") end
      )

    assert response["success"] == false
  end

  unsupported = GiteaAgentTool.execute("other", %{}, [])
  assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["gitea_api"]
end

test "tracker binds Gitea tool and token environment to one session" do
  token_env = "SYMPHONY_GITEA_BINDING_TOKEN"
  previous = System.get_env(token_env)
  System.put_env(token_env, "bound-secret")

  on_exit(fn ->
    if previous, do: System.put_env(token_env, previous), else: System.delete_env(token_env)
  end)

  write_gitea_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

  binding = Tracker.bind_agent_tools()
  assert binding.adapter == GiteaAdapter
  assert binding.secret_environment_names == ["GITEA_TOKEN", token_env]
  assert [%{"name" => "gitea_api"}] = binding.tool_specs
  assert :ok = Config.validate!()
end
```

Add this helper beside `tracker_settings/1`:

```elixir
defp write_gitea_workflow!(path, token) do
  File.write!(
    path,
    """
    ---
    tracker:
      kind: gitea
      provider:
        api_url: "https://git.laiye.com/api/v1"
        repo: "octo/repo"
        token: #{Jason.encode!(token)}
      active_states: ["open"]
      terminal_states: ["closed"]
    ---

    You are working on {{ issue.identifier }}.
    """
  )

  if Process.whereis(SymphonyElixir.WorkflowStore) do
    assert :ok = SymphonyElixir.WorkflowStore.force_reload()
  end
end
```

- [ ] **Step 2: Run the tests and verify tool cases fail**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
```

Expected: compilation or assertions fail because `Gitea.AgentTool` and adapter
tool callbacks do not exist.

- [ ] **Step 3: Implement `Gitea.AgentTool`**

Create a provider-specific module with this schema:

```elixir
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
```

Expose:

```elixir
@spec tool_specs() :: [map()]
def tool_specs do
  [%{
    "name" => @tool,
    "description" => "Execute a Gitea REST API request using Symphony's configured auth.",
    "inputSchema" => @input_schema
  }]
end

@spec execute(String.t() | nil, term(), keyword()) :: map()
def execute(@tool, arguments, opts), do: execute_gitea_api(arguments, opts)
def execute(tool, _arguments, _opts), do: unsupported_tool_response(tool)
```

Normalize method case, trim the path, require a leading `/`, reject `://`,
newline, carriage return, and NUL, accept only map-or-nil params, and pass the
body unchanged. Read the injected callback from `:gitea_client`, passing only
`:tracker_settings` to `Client.request/5`.

Return the established dynamic-tool shape:

```elixir
%{
  "success" => status in 200..299,
  "output" => Jason.encode!(%{"status" => status, "body" => body}, pretty: true),
  "contentItems" => [%{"type" => "inputText", "text" => output}]
}
```

For invalid arguments, missing token, `{:gitea_api_request, reason}`, malformed
client responses, and unsupported tools, return the same shape with
`"success" => false` and a JSON `error.message`. Do not retry mutations.

- [ ] **Step 4: Add adapter tool delegation**

Add:

```elixir
alias SymphonyElixir.Gitea.{AgentTool, Client}

@spec agent_tool_specs() :: [map()]
def agent_tool_specs, do: AgentTool.tool_specs()

@spec execute_agent_tool(String.t(), term(), keyword()) :: map()
def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)
```

- [ ] **Step 5: Run focused and adjacent integration tests**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs \
  test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: all tests and the public-spec check pass.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/gitea/agent_tool.ex \
  elixir/lib/symphony_elixir/gitea/adapter.ex \
  elixir/test/symphony_elixir/gitea_adapter_test.exs
git commit -m "feat(gitea): expose provider REST tool"
```

### Task 4: Adapter Documentation and Full Verification

**Files:**

- Modify: `elixir/README.md:16`
- Modify: `elixir/README.md:24`
- Modify: `elixir/README.md:245`

**Interfaces:**

- Consumes: all adapter behavior from Tasks 1–3.
- Produces: documented workflow contract for operators.

- [ ] **Step 1: Update the adapter inventory and tool list**

Change the included-adapter sentence to include `Gitea`, and change the
provider-tool sentence to include:

```markdown
Gitea serves `gitea_api`
```

- [ ] **Step 2: Add the Gitea adapter profile**

Insert after the GitHub profile:

```markdown
### Gitea adapter

- Config: use `tracker.kind: gitea` with required `tracker.provider.api_url`
  including `/api/v1`, required `repo` in `owner/repo` form, and `token`
  (defaults to `GITEA_TOKEN` and accepts `$VAR`). For
  `https://git.laiye.com`, set `api_url: https://git.laiye.com/api/v1`.
  Set explicit `active_states: [open]` and `terminal_states: [closed]`.
- Reads and identity: Symphony polls
  `/repos/{owner}/{repo}/issues` with `type=issues` in pages of 50, refreshes
  issues individually by repository-local index, omits inaccessible `404`
  records, and exposes route-safe `GT-<index>` identifiers.
- Tool and auth: `gitea_api` accepts GET, POST, PATCH, PUT, and DELETE with a
  relative REST `path`, optional query `params`, and optional JSON `body`.
  Symphony executes calls host-side with `Authorization: token`, strips
  `GITEA_TOKEN` and configured `$VAR` token names from the Codex child, and
  leaves raw tool access limited only by the Gitea token's permissions.
- Responsibility and errors: the tool may mutate issues, comments, and pull
  requests. It adds no retries or idempotency keys, so workflows own safe
  mutation and rate-limit handling. Configuration, transport, HTTP-status, and
  malformed-payload failures use the Gitea-specific errors documented by the
  implementation.
```

- [ ] **Step 3: Run formatting and the complete quality gate**

Run:

```bash
cd elixir
mix format
make all
```

Expected: formatter, compilation, tests, coverage, Credo, public specs, and
Dialyzer all pass.

- [ ] **Step 4: Inspect the final diff for scope**

Run:

```bash
git status --short
git diff --check
git diff --stat
```

Expected: only the three Gitea modules, one Gitea test, tracker registration,
and README changes are present. `SPEC.md`, dependencies, core orchestrator,
and unrelated adapters remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add elixir/README.md \
  elixir/lib/symphony_elixir/gitea \
  elixir/lib/symphony_elixir/tracker.ex \
  elixir/test/symphony_elixir/gitea_adapter_test.exs
git commit -m "docs(gitea): document tracker adapter"
```
