# Gitea Label States Design

## Goal

Use Gitea scoped `state/*` labels as Symphony's issue state machine while
retaining Gitea's native open/closed state as an efficient polling boundary.

## State Model

The Gitea adapter recognizes exactly these canonical lowercase states:

- `state/backlog`
- `state/todo`
- `state/in-progress`
- `state/human-review`
- `state/rework`
- `state/merging`
- `state/canceled`
- `state/duplicated`
- `state/done`

`Issue.state` contains the full scoped-label name. Label matching trims
surrounding whitespace and ignores case. Existing normalized issue labels
remain available in `Issue.labels`.

Gitea scoped-label exclusivity guarantees at most one `state/*` label. An
issue without a recognized state label defaults to `state/backlog`. If
malformed provider data nevertheless contains multiple recognized state
labels, the adapter uses the first returned label and logs a warning.

## Native Open/Closed Invariant

The label is authoritative for workflow state. Gitea's native state limits
polling and provides a consistency check:

- nonterminal label states belong on open Gitea issues;
- terminal labels `state/canceled`, `state/duplicated`, and `state/done`
  belong on closed Gitea issues;
- applying a verified terminal label and closing the issue completes it;
- reopening requires changing the label to a nonterminal state.

An issue with native state `closed` and a nonterminal label is normalized but
marked non-dispatchable. This stops active work during reconciliation even if
the label and native state were updated out of order. An open issue carrying a
terminal label is already stopped by the generic terminal-state check.

`state/human-review` is nonterminal, but the recommended configuration leaves
it out of both active and terminal lists. Moving an issue there stops the agent
without deleting its workspace.

## Configuration

`tracker.active_states` and `tracker.terminal_states` use full state-label
names and may contain only recognized states.

Recommended configuration:

```yaml
tracker:
  kind: gitea
  provider:
    api_url: https://git.laiye.com/api/v1
    repo: owner/repository
    token: $GITEA_TOKEN
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

The adapter rejects unknown state names with
`{:error, :invalid_gitea_states}`. It also rejects terminal labels in
`active_states` and nonterminal labels in `terminal_states`.

## Polling

The requested label states determine Gitea's native `state` query:

- only nonterminal labels: `state=open`;
- only terminal labels: `state=closed`;
- a mixed set: `state=all`;
- no recognized states: return `{:ok, []}` without a request.

Every request retains `type=issues`, `page`, and `limit=50`. Pagination
continues until Gitea returns an empty page, preserving the existing protection
against repeated adjacent pages.

Each returned issue is normalized, then filtered by its derived label state.
This keeps provider requests efficient without depending on Gitea label-query
semantics or requiring a special query for unlabeled backlog issues.

## ID Refresh and Reconciliation

ID refresh keeps using
`GET /repos/{owner}/{repo}/issues/{index}` regardless of native state. The
adapter derives the label state and native-state consistency on every refresh,
so running agents notice label transitions and closed-active inconsistencies
immediately.

No orchestrator changes are required. Existing generic behavior handles:

- active label state: continue when dispatchable;
- terminal label state: stop and clean the workspace;
- `state/human-review`: stop without cleanup;
- closed issue with active label: stop because it is non-dispatchable.

## State Transitions

State changes remain provider-native operations through `gitea_api`. Workflows
replace the issue's scoped state label using Gitea's issue-label endpoint. A
terminal transition also closes the issue after verification. No generic
tracker write API or adapter-specific state-transition callback is added.

The raw tool retains its existing token permissions, no-retry behavior, and
session-bound authentication.

## Error Handling

- Missing state labels are valid and map to `state/backlog`.
- Unknown `state/*` labels are ignored when deriving state; if no recognized
  state remains, the issue maps to `state/backlog`.
- Multiple recognized state labels use the first provider result and emit a
  warning containing the issue index and count, without logging credentials or
  issue body.
- Malformed required issue fields retain the existing candidate-drop and
  direct-refresh failure behavior.

## Testing

Focused tests cover:

- all nine recognized label states;
- whitespace and case normalization;
- missing-label fallback to `state/backlog`;
- unknown scoped labels falling back to backlog;
- defensive multiple-state selection and warning;
- adapter validation for active, terminal, unknown, and cross-category states;
- native query selection for nonterminal, terminal, and mixed requests;
- exact post-filtering of derived states;
- open and closed issues with the same label deriving the same `Issue.state`;
- a closed issue with a nonterminal label becoming non-dispatchable;
- ID refresh observing label transitions; and
- existing empty-input, pagination, tool, and auth behavior remaining green.

Run focused Gitea and extension tests, public-spec checks, formatting, and the
repository quality gate. Existing unrelated baseline failures remain separate
from this feature.

## Documentation

Update `elixir/README.md` to replace the native open/closed Gitea state example
with the label-state configuration and document:

- the nine recognized labels and backlog fallback;
- native open/closed polling behavior;
- terminal close and reopen conventions;
- `state/human-review` handoff behavior; and
- label replacement through `gitea_api`.

The generic `SPEC.md` already permits provider-derived state and
dispatchability, so no language-neutral specification change is required.
