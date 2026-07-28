# Gitea Adapter Design

## Goal

Add Gitea 1.25-compatible issue tracking as a first-class alternative to the
existing GitHub Issues adapter, including host-authenticated REST access for
coding-agent workflows.

## Scope

The adapter implements the `SPEC.md` tracker read boundary:

- fetch candidate issues by provider-native state;
- refresh issues by stable ID;
- normalize Gitea payloads into `SymphonyElixir.Tracker.Issue`;
- validate adapter-owned configuration;
- declare tracker-token environment variables that must not reach Codex; and
- expose a provider-native `gitea_api` tool.

Webhook dispatch, a generic forge abstraction, generic tracker write
callbacks, and a live end-to-end suite are outside this change.

## Configuration

Select the adapter with `tracker.kind: gitea`.

```yaml
tracker:
  kind: gitea
  provider:
    api_url: https://git.laiye.com/api/v1
    repo: owner/repo
    token: $GITEA_TOKEN
  active_states:
    - open
  terminal_states:
    - closed
```

Provider fields:

- `api_url` is required, must be an HTTP or HTTPS URL, and is normalized by
  removing trailing slashes. It includes the Gitea `/api/v1` base path.
- `repo` is required in exact `owner/repo` form.
- `token` defaults to `GITEA_TOKEN`, accepts `$VAR_NAME`, and is required.

The adapter accepts only `open` as an active state and `closed` as a terminal
state. State comparison is case-insensitive after trimming, while normalized
issues preserve Gitea's spelling.

`GITEA_TOKEN` and any environment variable referenced by `provider.token` are
removed from local and remote Codex child environments.

## Architecture

Add three provider-specific modules:

- `SymphonyElixir.Gitea.Adapter` implements the tracker callbacks and delegates
  HTTP work to the client.
- `SymphonyElixir.Gitea.Client` owns configuration resolution, Gitea REST
  requests, pagination, and issue normalization.
- `SymphonyElixir.Gitea.AgentTool` advertises and executes `gitea_api`.

Register `gitea` in `SymphonyElixir.Tracker`. No core orchestrator changes and
no new dependency are required. The implementation follows the established
GitHub/GitLab module shape without introducing a shared forge abstraction;
provider behavior is similar today but not identical enough to justify another
configuration layer.

## Scheduler Read Flow

### Candidate issues

For requested states:

1. Trim, lowercase, and deduplicate the state names.
2. Return `{:ok, []}` without an HTTP request when none map to Gitea's `open`
   or `closed` states.
3. Select `open`, `closed`, or `all` for Gitea's `state` query.
4. Request
   `GET /repos/{owner}/{repo}/issues?state=...&type=issues&page=N&limit=50`.
5. Continue until a response page contains fewer than 50 records.
6. Normalize records and retain only the exact requested states when the API
   query used `all`.

The explicit `type=issues` filter prevents pull requests from entering the
scheduler.

### ID refresh

Issue IDs are repository-local positive issue indexes encoded as strings.
Deduplicate requested IDs while preserving order, then request each with
`GET /repos/{owner}/{repo}/issues/{index}`. Omit `404` responses because the
issue may have been deleted or become inaccessible. Other non-success
responses fail the refresh.

## Issue Normalization

A record is valid only when it has a positive integer `number` or `index` and
nonblank `title` and `state`.

Map valid records as follows:

- `id`: decimal repository-local issue index;
- `native_ref`: available Gitea database ID, issue index, and repository path;
- `identifier`: `GT-<index>`;
- `title`: Gitea `title`;
- `description`: Gitea `body`;
- `priority`: `nil`;
- `state`: Gitea `state`;
- `branch_name`: `nil`;
- `url`: Gitea `html_url`;
- `assignee_id`: the first available assignee login, preferring `assignee`;
- `labels`: label names trimmed, lowercased, deduplicated, with blanks removed;
- `blocked_by`: `[]`;
- `dispatchable`: `true`;
- `created_at`: parsed Gitea `created_at`;
- `updated_at`: parsed Gitea `updated_at`.

Unusable optional values become `nil` or empty lists. Malformed records in a
candidate page are logged and dropped. A malformed direct-ID response fails
the refresh because the requested issue cannot be reconciled safely.

## Provider-Native Agent Tool

Advertise one dynamic tool:

```text
gitea_api(method, path, params?, body?)
```

- `method` accepts `GET`, `POST`, `PATCH`, `PUT`, or `DELETE`.
- `path` must be a relative path beginning with `/` and must not contain a URL
  scheme, newlines, carriage returns, or NUL.
- `params` is an optional JSON object.
- `body` is optional JSON passed through unchanged.

The client prefixes the configured `api_url` and sends
`Authorization: token <token>`, `Accept: application/json`, and
`Content-Type: application/json` as appropriate. The tool can read or mutate
anything allowed by the configured Gitea token; scheduler repository scope
does not constrain raw tool paths.

Successful 2xx responses return `"success": true`. Non-2xx responses preserve
the status and decoded response body with `"success": false`. Invalid
arguments, missing configuration, malformed responses, and transport failures
return a structured JSON error and do not crash or stall the Codex session.
The tool adds no retries or idempotency keys; workflows own safe mutation and
rate-limit handling.

## Error Handling

Use Gitea-specific errors consistent with existing adapters:

- missing or invalid settings:
  `:missing_gitea_api_url`, `:invalid_gitea_api_url`,
  `:missing_gitea_repo`, `:invalid_gitea_repo`, `:missing_gitea_token`;
- invalid state or ID:
  `:invalid_gitea_states`, `:invalid_gitea_issue_id`;
- transport:
  `{:gitea_api_request, reason}`;
- HTTP status:
  `{:gitea_api_status, status}`;
- malformed response:
  `:gitea_unknown_payload`.

The client logs provider status failures without logging credentials or
response bodies that may contain sensitive data.

## Testing

Add focused ExUnit coverage for:

- adapter registration and accepted/rejected state configuration;
- required and `$VAR`-resolved provider settings;
- secret environment name declaration;
- empty and unsupported state/ID lists avoiding HTTP requests;
- `open`, `closed`, and combined-state candidate reads;
- 50-record pagination and exact post-filtering;
- normalization, label cleanup, timestamps, and malformed candidate dropping;
- ordered ID refresh, duplicate removal, `404` omission, and malformed refresh
  failure;
- request path, query, JSON body, and `Authorization: token` header;
- `gitea_api` read/write success, non-2xx preservation, unsafe argument
  rejection, unsupported tools, and transport errors; and
- session-bound tool advertisement/execution and token stripping through
  existing tracker tests where registration changes affect shared behavior.

Run the focused Gitea tests during development, then `make all` from `elixir/`.
A live test is deferred until a disposable Gitea repository and suitably
scoped credential are available for repeatable cleanup.

## Documentation

Update `elixir/README.md` to list Gitea among included adapters and document:

- the exact provider configuration and `git.laiye.com` example;
- polling scope, pagination, identity, and normalization;
- `gitea_api` schema and mutation capability;
- token environment isolation and token permission scope; and
- error, retry, idempotency, and rate-limit responsibilities.

The design conforms to `SPEC.md`; no language-neutral specification change is
needed.
