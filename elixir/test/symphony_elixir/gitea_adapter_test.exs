defmodule SymphonyElixir.Gitea.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, Tracker, Workflow}
  alias SymphonyElixir.Gitea.Adapter, as: GiteaAdapter
  alias SymphonyElixir.Gitea.AgentTool, as: GiteaAgentTool
  alias SymphonyElixir.Gitea.Client, as: GiteaClient

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
             GiteaAdapter.validate_config(%{settings | active_states: ["open"]})

    assert {:error, :invalid_gitea_states} =
             GiteaAdapter.validate_config(%{settings | active_states: ["state/done"]})

    assert {:error, :invalid_gitea_states} =
             GiteaAdapter.validate_config(%{settings | terminal_states: ["state/todo"]})

    assert :ok =
             GiteaAdapter.validate_config(%{
               settings
               | active_states: [" STATE/HUMAN-REVIEW "],
                 terminal_states: [" STATE/DONE "]
             })

    Application.put_env(:symphony_elixir, :gitea_client_module, FakeGiteaClient)
    assert {:ok, ["state/todo"]} = GiteaAdapter.fetch_issues_by_states(["state/todo"])
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
    assert issue.state == "state/backlog"

    assert issue.url == "https://gitea.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    assert GiteaClient.normalize_issue_for_test(Map.put(raw_issue(43), "title", " "), "octo/repo") == nil
  end

  test "client derives canonical workflow state from scoped labels" do
    states = [
      "state/backlog",
      "state/todo",
      "state/in-progress",
      "state/human-review",
      "state/rework",
      "state/merging",
      "state/canceled",
      "state/duplicated",
      "state/done"
    ]

    for {state, index} <- Enum.with_index(states, 1) do
      issue =
        raw_issue(index)
        |> with_state_labels([" #{String.upcase(state)} "])
        |> GiteaClient.normalize_issue_for_test("octo/repo")

      assert issue.state == state
      assert state in issue.labels
    end
  end

  test "client defaults missing and unknown state labels to backlog" do
    missing = GiteaClient.normalize_issue_for_test(raw_issue(20), "octo/repo")

    unknown =
      raw_issue(21)
      |> with_state_labels(["state/future"])
      |> GiteaClient.normalize_issue_for_test("octo/repo")

    assert missing.state == "state/backlog"
    assert unknown.state == "state/backlog"
  end

  test "client warns and uses the first recognized state label" do
    log =
      capture_log(fn ->
        issue =
          raw_issue(22)
          |> with_state_labels(["state/todo", "state/rework"])
          |> GiteaClient.normalize_issue_for_test("octo/repo")

        assert issue.state == "state/todo"
      end)

    assert log =~ "Multiple Gitea state labels issue_index=22 count=2"
  end

  test "closed issues with nonterminal labels are not dispatchable" do
    issue =
      raw_issue(23)
      |> Map.put("state", "closed")
      |> with_state_labels(["state/in-progress"])
      |> GiteaClient.normalize_issue_for_test("octo/repo")

    assert issue.state == "state/in-progress"
    refute issue.dispatchable

    terminal =
      raw_issue(24)
      |> Map.put("state", "closed")
      |> with_state_labels(["state/done"])
      |> GiteaClient.normalize_issue_for_test("octo/repo")

    assert terminal.state == "state/done"
  end

  test "client safely selects the first nonblank assignee login" do
    assert GiteaClient.normalize_issue_for_test(
             raw_issue(1)
             |> Map.put("assignee", %{"login" => " primary "})
             |> Map.put("assignees", [%{"login" => "backup"}]),
             "octo/repo"
           ).assignee_id == "primary"

    assert GiteaClient.normalize_issue_for_test(
             raw_issue(2)
             |> Map.put("assignee", %{"login" => " "})
             |> Map.put("assignees", [%{}, %{"login" => " backup "}]),
             "octo/repo"
           ).assignee_id == "backup"

    assert GiteaClient.normalize_issue_for_test(
             raw_issue(3)
             |> Map.put("assignee", "malformed")
             |> Map.put("assignees", [nil, %{"login" => ""}, %{"login" => 123}]),
             "octo/repo"
           ).assignee_id == nil
  end

  test "client pages candidate issues with Gitea query parameters" do
    first_page = [
      raw_issue(1) |> with_state_labels(["state/todo"]),
      raw_issue(2)
      |> Map.put("state", "closed")
      |> with_state_labels(["state/done"]),
      Map.put(raw_issue(3), "title", "")
    ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
      send(self(), {:gitea_page, params})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(4) |> with_state_labels(["state/todo"])]
          3 -> []
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GiteaClient.fetch_issues_by_states_for_test(
                   [" STATE/TODO "],
                   tracker_settings(),
                   request_fun
                 )

        assert Enum.map(issues, & &1.id) == ["1", "4"]
      end)

    assert log =~ "Dropping malformed Gitea issue records count=1"
    assert_receive {:gitea_page, %{"state" => "open", "type" => "issues", "page" => 1, "limit" => 50}}
    assert_receive {:gitea_page, %{"page" => 2}}
    assert_receive {:gitea_page, %{"page" => 3}}

    assert {:ok, []} =
             GiteaClient.fetch_issues_by_states_for_test(
               ["state/future"],
               tracker_settings(),
               fn _, _, _, _, _ -> flunk("unsupported states must not request Gitea") end
             )
  end

  test "client rejects repeated nonempty pagination pages" do
    page = Enum.map(1..50, &(raw_issue(&1) |> with_state_labels(["state/todo"])))

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
      send(self(), {:gitea_page, params["page"]})

      case params["page"] do
        page_number when page_number in [1, 2] -> {:ok, %{status: 200, body: page}}
        _ -> {:error, :unexpected_third_page}
      end
    end

    assert {:error, :gitea_unknown_payload} =
             GiteaClient.fetch_issues_by_states_for_test(
               ["state/todo"],
               tracker_settings(),
               request_fun
             )

    assert_receive {:gitea_page, 1}
    assert_receive {:gitea_page, 2}
    refute_receive {:gitea_page, 3}
  end

  test "client maps requested label states to native Gitea query states" do
    for {states, query, expected_ids} <- [
          {["state/todo"], "open", ["1"]},
          {["state/done"], "closed", ["2"]},
          {["state/todo", "state/done"], "all", ["1", "2"]}
        ] do
      request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
        send(self(), {:gitea_state_page, query, params})

        body =
          if params["page"] == 1,
            do: [
              raw_issue(1) |> with_state_labels(["state/todo"]),
              raw_issue(2) |> Map.put("state", "closed") |> with_state_labels(["state/done"]),
              raw_issue(3) |> with_state_labels(["state/rework"])
            ],
            else: []

        {:ok, %{status: 200, body: body}}
      end

      assert {:ok, issues} =
               GiteaClient.fetch_issues_by_states_for_test(
                 states,
                 tracker_settings(),
                 request_fun
               )

      assert Enum.map(issues, & &1.id) == expected_ids
      assert_receive {:gitea_state_page, ^query, %{"state" => ^query, "type" => "issues", "page" => 1, "limit" => 50}}
      assert_receive {:gitea_state_page, ^query, %{"page" => 2}}
    end
  end

  test "client fetches backlog from open unlabeled issues" do
    request_fun = fn "GET", _path, params, nil, _settings ->
      body =
        if params["page"] == 1,
          do: [raw_issue(30), raw_issue(31) |> with_state_labels(["state/todo"])],
          else: []

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, [issue]} =
             GiteaClient.fetch_issues_by_states_for_test(
               ["state/backlog"],
               tracker_settings(),
               request_fun
             )

    assert issue.id == "30"
    assert issue.state == "state/backlog"
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

  test "ID refresh observes label transitions independently of native query polling" do
    response =
      raw_issue(40)
      |> Map.put("state", "closed")
      |> with_state_labels(["state/done"])

    assert {:ok, [issue]} =
             GiteaClient.fetch_issues_by_ids_for_test(
               ["40"],
               tracker_settings(),
               fn "GET", "/repos/octo/repo/issues/40", %{}, nil, _settings ->
                 {:ok, %{status: 200, body: response}}
               end
             )

    assert issue.state == "state/done"
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

  test "client fetches no states without global settings" do
    workflow_file = Workflow.workflow_file_path()
    missing_workflow_file = Path.join(Path.dirname(workflow_file), "missing-workflow.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(workflow_file)
      {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    end)

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Workflow.set_workflow_file_path(missing_workflow_file)

    assert {:ok, []} = GiteaClient.fetch_issues_by_states([])
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

  test "request disables Req retries and logs only non-success request metadata" do
    calls = start_supervised!({Agent, fn -> 0 end})

    plug = fn conn ->
      Agent.update(calls, &(&1 + 1))

      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"secret" => "response-body-secret"})
    end

    log =
      capture_log(fn ->
        assert {:ok, %{status: 503}} =
                 GiteaClient.request(
                   "GET",
                   "/version",
                   %{},
                   nil,
                   tracker_settings:
                     tracker_settings(%{
                       "api_url" => "http://127.0.0.1:1/api/v1",
                       "token" => "request-token-secret"
                     }),
                   req_options: [plug: plug, retry_delay: 0]
                 )
      end)

    assert Agent.get(calls, & &1) == 1
    assert log =~ "Gitea API request failed status=503 method=GET path=/version"
    refute log =~ "response-body-secret"
    refute log =~ "request-token-secret"
  end

  test "client resolves a referenced token environment" do
    token_env = "SYMPHONY_GITEA_RESOLUTION_TOKEN"
    previous = System.get_env(token_env)
    System.put_env(token_env, "resolved-secret")

    on_exit(fn ->
      if previous, do: System.put_env(token_env, previous), else: System.delete_env(token_env)
    end)

    assert {:ok, %{status: 200}} =
             GiteaClient.request(
               "GET",
               "/version",
               %{},
               nil,
               tracker_settings: tracker_settings(%{"token" => "$#{token_env}"}),
               request_fun: fn _, _, _, _, settings ->
                 assert settings.token == "resolved-secret"
                 {:ok, %{status: 200, body: %{}}}
               end
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

  test "gitea_api rejects non-JSON client response bodies" do
    response =
      GiteaAgentTool.execute(
        "gitea_api",
        %{"method" => "GET", "path" => "/version"},
        gitea_client: fn _, _, _, _, _ -> {:ok, %{status: 200, body: self()}} end
      )

    assert response["success"] == false
    assert %{"error" => %{"message" => message}} = Jason.decode!(response["output"])
    assert is_binary(message)
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
      active_states: [
        "state/backlog",
        "state/todo",
        "state/in-progress",
        "state/rework",
        "state/merging"
      ],
      terminal_states: ["state/canceled", "state/duplicated", "state/done"]
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
        active_states: ["state/backlog", "state/todo", "state/in-progress", "state/rework", "state/merging"]
        terminal_states: ["state/canceled", "state/duplicated", "state/done"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end

  defp with_state_labels(issue, names) do
    labels =
      issue["labels"]
      |> Enum.reject(fn
        %{"name" => "state/" <> _} -> true
        _ -> false
      end)

    Map.put(issue, "labels", labels ++ Enum.map(names, &%{"name" => &1}))
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
