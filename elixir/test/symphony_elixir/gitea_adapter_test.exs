defmodule SymphonyElixir.Gitea.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Gitea.Adapter, as: GiteaAdapter
  alias SymphonyElixir.Gitea.AgentTool, as: GiteaAgentTool
  alias SymphonyElixir.Gitea.Client, as: GiteaClient
  alias SymphonyElixir.{Config, Tracker, Workflow}

  defmodule FakeGiteaClient do
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issues_by_ids(ids), do: {:ok, ids}
  end

  setup do
    gitea_client_module = Application.get_env(:symphony_elixir, :gitea_client_module)

    on_exit(fn ->
      if is_nil(gitea_client_module) do
        Application.delete_env(:symphony_elixir, :gitea_client_module)
      else
        Application.put_env(:symphony_elixir, :gitea_client_module, gitea_client_module)
      end
    end)

    :ok
  end

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
    first_page =
      Enum.map(1..48, &raw_issue/1) ++
        [Map.put(raw_issue(49), "state", "closed"), Map.put(raw_issue(50), "title", "")]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
      send(self(), {:gitea_page, params})
      body = if params["page"] == 1, do: first_page, else: [raw_issue(51)]
      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GiteaClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert Enum.map(issues, & &1.id) == Enum.map(1..48, &Integer.to_string/1) ++ ["51"]
      end)

    assert log =~ "Dropping malformed Gitea issue records count=1"
    assert_receive {:gitea_page, %{"state" => "open", "type" => "issues", "page" => 1, "limit" => 50}}
    assert_receive {:gitea_page, %{"page" => 2}}

    assert {:ok, []} =
             GiteaClient.fetch_issues_by_states_for_test(
               ["todo"],
               tracker_settings(),
               fn _, _, _, _, _ -> flunk("unsupported states must not request Gitea") end
             )
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
             GiteaClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]

    assert {:error, :invalid_gitea_issue_id} =
             GiteaClient.fetch_issues_by_ids_for_test(["x"], tracker_settings(), request_fun)

    assert {:error, :gitea_unknown_payload} =
             GiteaClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _, _, _, _, _ ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "state", "")}}
               end
             )
  end

  test "client refreshes no IDs without resolving settings" do
    assert {:ok, []} =
             GiteaClient.fetch_issues_by_ids_for_test([], %{kind: "gitea", provider: %{}}, fn _, _, _, _, _ ->
               flunk("empty IDs must not request Gitea")
             end)
  end

  test "client refreshes no IDs without global settings" do
    workflow_file = Workflow.workflow_file_path()
    missing_workflow_file = Path.join(Path.dirname(workflow_file), "missing-workflow.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(workflow_file)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end)

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(missing_workflow_file)

    assert {:ok, []} = GiteaClient.fetch_issues_by_ids([])
  end

  test "client validates Gitea settings and declares token environments" do
    assert :ok = GiteaClient.validate_settings(tracker_settings())

    assert {:error, :missing_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => 123}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "git.laiye.com/api/v1"}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "https://gitea.test"}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "https://gitea.test/foo/api/v1/bar"}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "https://gitea.test/api/v1?x=1"}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "https://gitea.test/api/v1#fragment"}))

    assert :ok =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "http://gitea.test/api/v1/"}))

    assert {:error, :missing_gitea_repo} =
             GiteaClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_gitea_repo} =
             GiteaClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_gitea_token} =
             GiteaClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert GiteaClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITEA_TOKEN"})) == ["GITEA_TOKEN", "SYMPHONY_GITEA_TOKEN"]
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

    assert_received {:gitea_request, "POST", "/repos/octo/repo/issues/1/comments", %{"page" => 1}, %{"body" => "done"}, %{api_url: "https://gitea.test/api/v1", repo: "octo/repo", token: "secret"}}

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

    assert_received {:gitea_tool, "POST", "/repos/octo/repo/issues/42/comments", %{}, %{"body" => "done"}, [tracker_settings: _]}
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}

    failure =
      GiteaAgentTool.execute(
        "gitea_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        gitea_client: fn _, _, _, _, _ ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }
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
        GiteaAgentTool.execute("gitea_api", arguments, gitea_client: fn _, _, _, _, _ -> flunk("invalid call reached client") end)

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
end
