# Gitea Label States Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Gitea scoped `state/*` labels Symphony's workflow states while using native open/closed status to limit provider polling.

**Architecture:** Keep the change inside `Gitea.Adapter` and `Gitea.Client`. The client derives one canonical label state during normalization and selects native `open`, `closed`, or `all` only as a query optimization; the generic orchestrator continues consuming `Issue.state` and `dispatchable` without provider-specific branches.

**Tech Stack:** Elixir 1.19/OTP 28, Req, Jason, ExUnit, existing Symphony tracker boundary.

## Global Constraints

- Recognize exactly `state/backlog`, `state/todo`, `state/in-progress`, `state/human-review`, `state/rework`, `state/merging`, `state/canceled`, `state/duplicated`, and `state/done`.
- Missing or unrecognized state labels map to `state/backlog`.
- Scoped-label exclusivity is trusted; multiple recognized labels use the first provider result and log a warning.
- `Issue.state` is the canonical lowercase full label name.
- Native Gitea state limits polling: nonterminal requests use `open`, terminal requests use `closed`, and mixed requests use `all`.
- Terminal labels are exactly `state/canceled`, `state/duplicated`, and `state/done`.
- A closed issue with a nonterminal label is non-dispatchable.
- `state/human-review` is recognized but the recommended configuration leaves it outside active and terminal lists.
- State transitions remain raw `gitea_api` label operations; add no generic write callback.
- Keep existing pagination, no-retry HTTP behavior, auth isolation, tool behavior, and issue identity unchanged.
- Add no dependency, config schema field, generic label-state abstraction, or orchestrator branch.
- Every public `def` in `elixir/lib/` has an adjacent `@spec`.

---

## File Structure

- Modify `elixir/lib/symphony_elixir/gitea/client.ex`: state vocabulary, label derivation, native query selection, state filtering, warning, and dispatchability.
- Modify `elixir/lib/symphony_elixir/gitea/adapter.ex`: validate active and terminal label-state categories.
- Modify `elixir/test/symphony_elixir/gitea_adapter_test.exs`: focused normalization, validation, query, filtering, and refresh regressions.
- Modify `elixir/README.md`: replace native open/closed configuration with the label-state workflow contract.

### Task 1: Label-Derived State Machine

**Files:**

- Modify: `elixir/lib/symphony_elixir/gitea/client.ex:9-201`
- Modify: `elixir/lib/symphony_elixir/gitea/adapter.ex:9-42`
- Modify: `elixir/test/symphony_elixir/gitea_adapter_test.exs`

**Interfaces:**

- Preserve: `Gitea.Client.fetch_issues_by_states/1`
- Preserve: `Gitea.Client.fetch_issues_by_ids/1`
- Preserve: existing test seams and `Gitea.Adapter` tracker callbacks.
- Produce internally: `issue_state([String.t()], integer()) :: String.t()`
- Produce internally: `query_state(MapSet.t(String.t())) :: "open" | "closed" | "all" | nil`
- `Issue.state` changes from native `"open" | "closed"` to a recognized full `state/*` label.

- [ ] **Step 1: Write failing label normalization tests**

Replace the existing normalization assertion `issue.state == "open"` with
label-derived cases. Add a helper that replaces only the state labels:

```elixir
defp with_state_labels(issue, names) do
  labels =
    issue["labels"]
    |> Enum.reject(fn
      %{"name" => "state/" <> _} -> true
      _ -> false
    end)

  Map.put(issue, "labels", labels ++ Enum.map(names, &%{"name" => &1}))
end
```

Add:

```elixir
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
```

Name the production behavior before running: removing label-state derivation
must make these assertions fail.

- [ ] **Step 2: Write failing adapter validation tests**

Change `tracker_settings/1` and the workflow helper to use:

```elixir
active_states: [
  "state/backlog",
  "state/todo",
  "state/in-progress",
  "state/rework",
  "state/merging"
],
terminal_states: ["state/canceled", "state/duplicated", "state/done"]
```

Update the fake delegation assertions to pass label names. Replace the old
native-state rejection assertions with:

```elixir
assert :ok = GiteaAdapter.validate_config(settings)

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
```

Keep the existing missing-list cases for `nil`.

- [ ] **Step 3: Write failing native-query and exact-filter tests**

Replace the native open/closed query matrix with label-state cases:

```elixir
test "client maps requested label states to native Gitea query states" do
  cases = [
    {["state/todo"], "open", ["1"]},
    {["state/done"], "closed", ["2"]},
    {["state/todo", "state/done"], "all", ["1", "2"]}
  ]

  for {states, query, expected_ids} <- cases do
    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
      send(self(), {:gitea_label_page, query, params})

      body =
        if params["page"] == 1 do
          [
            raw_issue(1) |> with_state_labels(["state/todo"]),
            raw_issue(2)
            |> Map.put("state", "closed")
            |> with_state_labels(["state/done"]),
            raw_issue(3) |> with_state_labels(["state/rework"])
          ]
        else
          []
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:ok, issues} =
             GiteaClient.fetch_issues_by_states_for_test(
               states,
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == expected_ids

    assert_receive {:gitea_label_page, ^query,
                    %{
                      "state" => ^query,
                      "type" => "issues",
                      "page" => 1,
                      "limit" => 50
                    }}
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
```

Keep the existing empty-page pagination and repeated-page integrity tests,
changing their fixtures and requested states to recognized labels.

- [ ] **Step 4: Write a failing ID-refresh transition test**

Add:

```elixir
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
```

- [ ] **Step 5: Run focused tests and verify RED**

Run:

```bash
cd elixir
mix test test/symphony_elixir/gitea_adapter_test.exs
```

Expected: failures show native `open/closed` states, rejected label
configuration, incorrect native query selection, and missing warning/default
behavior. Fix test syntax or harness errors until failures are caused only by
the missing label-state feature.

- [ ] **Step 6: Implement the minimal state vocabulary and validation**

In `Gitea.Adapter`, replace the native constants with:

```elixir
@active_states [
  "state/backlog",
  "state/todo",
  "state/in-progress",
  "state/human-review",
  "state/rework",
  "state/merging"
]
@terminal_states ["state/canceled", "state/duplicated", "state/done"]
```

Keep `validate_states/3`, but validate active values only against
`@active_states` and terminal values only against `@terminal_states`.
Normalization remains trim plus lowercase.

In `Gitea.Client`, define the same vocabulary once for client-owned state
derivation:

```elixir
@nonterminal_states MapSet.new([
  "state/backlog",
  "state/todo",
  "state/in-progress",
  "state/human-review",
  "state/rework",
  "state/merging"
])
@terminal_states MapSet.new([
  "state/canceled",
  "state/duplicated",
  "state/done"
])
@states MapSet.union(@nonterminal_states, @terminal_states)
@default_state "state/backlog"
```

No new shared module is needed; the two small constant lists have different
owners—adapter configuration validation and client payload interpretation.

- [ ] **Step 7: Implement label derivation and dispatchability**

Normalize labels once before building the issue:

```elixir
normalized_labels = labels(issue)
workflow_state = issue_state(normalized_labels, index)
native_state = state(issue["state"])
```

Set:

```elixir
state: workflow_state,
labels: normalized_labels,
dispatchable: native_state == "open" or MapSet.member?(@terminal_states, workflow_state),
```

Implement:

```elixir
defp issue_state(labels, index) do
  states = Enum.filter(labels, &MapSet.member?(@states, &1))

  if length(states) > 1 do
    Logger.warning("Multiple Gitea state labels issue_index=#{index} count=#{length(states)}")
  end

  List.first(states, @default_state)
end
```

This uses the first provider-returned recognized label. Unknown `state/*`
labels remain in `Issue.labels` but do not become workflow state.

- [ ] **Step 8: Implement native query selection from requested labels**

Replace native-name membership with category membership:

```elixir
defp query_state(states) do
  terminal? = Enum.any?(states, &MapSet.member?(@terminal_states, &1))
  nonterminal? = Enum.any?(states, &MapSet.member?(@nonterminal_states, &1))

  cond do
    terminal? and nonterminal? -> "all"
    terminal? -> "closed"
    nonterminal? -> "open"
    true -> nil
  end
end
```

Keep exact post-filtering:

```elixir
Enum.filter(issues, &MapSet.member?(requested, state(&1.state)))
```

This ensures unknown requested values return `{:ok, []}` without a provider
request and makes backlog include unlabeled open issues.

- [ ] **Step 9: Run focused and adjacent tests GREEN**

Run:

```bash
cd elixir
mix format
mix test test/symphony_elixir/gitea_adapter_test.exs \
  test/symphony_elixir/extensions_test.exs
mix specs.check
```

Expected: all commands pass with no warnings attributable to Gitea.

- [ ] **Step 10: Commit**

```bash
git add elixir/lib/symphony_elixir/gitea/client.ex \
  elixir/lib/symphony_elixir/gitea/adapter.ex \
  elixir/test/symphony_elixir/gitea_adapter_test.exs
git commit -m "feat(gitea): derive states from scoped labels"
```

### Task 2: Label-State Documentation and Verification

**Files:**

- Modify: `elixir/README.md:259-280`

**Interfaces:**

- Consumes: Task 1's exact state vocabulary and native-query behavior.
- Produces: operator-facing workflow configuration and transition contract.

- [ ] **Step 1: Replace the Gitea configuration example**

Document this exact recommended state split:

```yaml
active_states:
  - state/backlog
  - state/todo
  - state/in-progress
  - state/rework
  - state/merging
terminal_states:
  - state/canceled
  - state/duplicated
  - state/done
```

State that `state/human-review` is recognized but intentionally outside both
lists so agents stop without workspace cleanup.

- [ ] **Step 2: Document derivation, polling, and transitions**

Replace the native open/closed description with:

```markdown
- State model: Symphony derives `issue.state` from the exclusive scoped labels
  `state/backlog`, `state/todo`, `state/in-progress`, `state/human-review`,
  `state/rework`, `state/merging`, `state/canceled`, `state/duplicated`, and
  `state/done`. Missing or unknown state labels default to `state/backlog`.
- Polling: nonterminal state reads query open Gitea issues, terminal state
  reads query closed issues, and mixed reads query all issues before exact
  label-state filtering. A closed issue carrying a nonterminal label is not
  dispatchable.
- Transitions: workflows replace the scoped state label through `gitea_api`.
  After verification, apply `state/canceled`, `state/duplicated`, or
  `state/done` and close the Gitea issue. Reopening also requires changing to a
  nonterminal label.
```

Preserve the existing identity, pagination, auth, raw-tool scope, no-retry,
and error documentation.

- [ ] **Step 3: Run complete verification**

Run:

```bash
cd elixir
mix format
mix test test/symphony_elixir/gitea_adapter_test.exs \
  test/symphony_elixir/extensions_test.exs
mix specs.check
make all
```

Expected Gitea-specific result: focused tests, formatting, specs, and all Gitea
lint/type checks pass. Record the existing unrelated repository baseline
failures separately; do not change `config/schema.ex`, Core retry timing tests,
Linear client code, dependencies, or coverage policy in this task.

- [ ] **Step 4: Inspect final scope**

Run:

```bash
git status --short
git diff --check
git diff --stat
```

Expected changed implementation files:

```text
elixir/lib/symphony_elixir/gitea/adapter.ex
elixir/lib/symphony_elixir/gitea/client.ex
elixir/test/symphony_elixir/gitea_adapter_test.exs
elixir/README.md
```

The already committed design and plan documents remain part of branch history;
no unrelated production file changes.

- [ ] **Step 5: Commit**

```bash
git add elixir/README.md
git commit -m "docs(gitea): document label-backed states"
```
