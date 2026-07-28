defmodule SymphonyElixir.Gitea.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Gitea.Client, as: GiteaClient

  test "client validates Gitea settings and declares token environments" do
    assert :ok = GiteaClient.validate_settings(tracker_settings())

    assert {:error, :missing_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => 123}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "git.laiye.com/api/v1"}))

    assert {:error, :invalid_gitea_api_url} =
             GiteaClient.validate_settings(tracker_settings(%{"api_url" => "https://gitea.test"}))

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
