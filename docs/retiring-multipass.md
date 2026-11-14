# Retiring MultiPass (design)

MultiPass, a private repository, is the agents' and containers' proxy, the
servers' front door and sign-in. It is retired: each of its jobs moves to
the program it belongs to, and nothing is removed before its replacement
works. Nothing here is built until this design is approved.

The split:

1. **Signing people in with GitHub moves to Shireworks' server**: the
   owner signs in through the owner's GitHub App, as an administrator.
2. **The container's network and proxy move here**, beside agent-wrapper:
   - `agent-network`: the container's only network, inside it;
   - `agent-proxy`: outside it, on the Linux or macOS host. It proxies the
     container's requests, adding the agents' GitHub App's auth to GitHub's
     and to Shireworks' MCP.
3. **Shireworks tells identities apart**: a client signed in through the
   owner's App is an administrator; one through the agents' App is an
   agent, which may lease CI machines and does nothing administrative.
4. **Visor's server authenticates its agents** with a token it mints
   (a JWT), carried server → runner → agent → proxy → server: for their
   message stream and for Visor's own MCP.
5. **Visor's server authenticates its clients** in the way it is set to:
   none (behind a front of one's own), SSH, a password, or (the enterprise
   fork's) Okta.

## Where each of MultiPass's jobs goes

| MultiPass today | Goes to |
|---|---|
| `multipass-client`: the container's network (DNS with fake addresses, every TCP connection as a CONNECT over the relay socket) | `agent-network` (agent_protocol), the same code moved |
| The relay listener: a container's streams, named by Shireworks' relay header | `agent-proxy` |
| Dial-ins (`visor.multipass.internal:7434` to the host's Visor server) | `agent-proxy`, configured by name as now |
| DNS over HTTPS for containers | `agent-proxy` |
| The egress proxy: anything else passed through, logged, limited per container | `agent-proxy` |
| The GitHub proxy: the agents' App's installation token added, the gate rules | `agent-proxy` (the App's key on the host, outside every container) |
| `/mcp/<name>`: MCP servers' keys added (Shireworks' MCP) | `agent-proxy` |
| The forward to Shireworks' API (`shireworks.multipass.internal`, the per-computer key) | `agent-proxy`, with an `agent`-scope key Shireworks issues it (3) |
| The sign-in on 7443: password, pairing code, GitHub; sessions; servers by path | **gone**: each server signs in its own clients (5), and Shireworks signs in with GitHub (1) |
| HTTPS with the tailnet's certificate, renewed (`--tailscale`, multipass#32–#34) | each server's own listener: the renewal code moves to Visor's server and Shireworks' |
| Path switching (localhost, LAN, tailnet) | the clients, which already try a computer's addresses in turn |
| The APNs proxy: pushes signed with a key no container sees | each server signs its own pushes again: both servers run on the Mac, outside every container |
| Fronts and the server watch (a container's server reached and restarted) | gone: no server runs in a container |

## 1. Signing in with GitHub: Shireworks' server

Agreed with Shireworks.

- **A new auth mode, `auth: github`**, beside `none | password | ssh`
  (`none`, a trusted front's headers, stays for Okta-style fronts). It
  names the owner's App (`appID`, `clientID`), `people` (the allow-list,
  `github:<id>`) and `admins` (ids; the owner is one by default). A person
  signed in is Shireworks' `Access.person`, their `github:<id>` the holder
  of what they lease and store.
- **Two device flows, apart.** Shireworks' server already runs one as the
  owner (publishing, approving, merging). Signing people in is another
  use: proving who a client is, MultiPass's `GitHubSignIn` moved whole,
  `GET /user` checked against `people`. Neither token is ever the other's.
  Nor is an agent's key a reader of `/v1/github` (`github.readers`) unless
  an admin names it there; by default none is.
- **The web flow takes the App's client secret** (GitHub's code exchange
  needs it; the device flow doesn't): kept in the server's Keychain, set
  through an admin route as the App's key is. The owner adds the server's
  callback, `https://<the Mac's tailnet name>/v1/auth/github/callback`, to
  the App: a change to the App's settings, made only on the owner's word.
- **Sessions are the server's own**: random tokens kept hashed, as API
  keys are; a bearer for apps, a cookie for browsers (HttpOnly, Secure,
  SameSite=Lax; state and PKCE on the web flow); 30 days, sliding; revoked
  by an admin in Settings, or when an id leaves `people`.
- **HTTPS**: a TLS listener of its own with the tailnet's certificate,
  renewed (the code of multipass#32–#34). Its plain HTTP listener stays for
  loopback and its own containers; off loopback, plain HTTP takes no
  person's session, only keys, grants and its token, as now.

## 2. `agent-network` and `agent-proxy`

- **`agent-network`** is `multipass-client` renamed and moved: run as the
  container's first process (`agent-network run -- <command>`), it gives
  the container a loopback interface, DNS with fake addresses, and one
  rule redirecting every TCP connection to itself; each goes out as a
  `CONNECT name:port` over the relay socket Shireworks provides
  (`/run/agent/relay.sock`). No secrets inside.
- **`agent-proxy`** runs on the host (a LaunchAgent on the Mac, a systemd
  unit on Linux), from one configuration file and one secrets file:
  - the relay listener (PROXY v2 header: which container);
  - dial-ins by name (`visor.agent.internal:7434`);
  - DNS over HTTPS;
  - egress, passed through and logged, limited per container if set;
  - GitHub: the agents' App's key, its installation token, the gate;
  - MCP servers by name, with their keys;
  - Shireworks' API (`shireworks.agent.internal`), with its `agent`-scope
    key and the agent's id.
- **What it never does**: sign people in, front servers, or touch Visor's
  agent tokens (4), which pass through it unchanged.
- Names move from `*.multipass.internal` to `*.agent.internal`; both are
  answered during the move.

## 3. Identities in Shireworks

Agreed with Shireworks.

- **Administrators**: people in `auth.admins`, signed in through the
  owner's App; and the admin key and the server's token on its own Mac,
  as now.
- **Agents**: an API key of a new scope, `agent`, which Shireworks issues
  to `agent-proxy` for its host (replacing today's per-computer key).
  `agent-proxy` sends it with the agent's id (`Shireworks-Client-ID`); the
  holder stays `<agent id>@<key name>`. A key, not the agents' App's
  installation token: that proves the App, not which agent, so
  `agent-proxy` names the agent either way; and the key is checked
  locally, works when GitHub is down, doesn't rotate hourly, and is
  revoked in Settings.

  | `agent` scope may | may not |
  |---|---|
  | lease, renew, release machines | keys, restarts, served files, volumes |
  | exec, run, files, screenshots, record, xctest on its own leases | signing |
  | storage put and get, of its own holder | `/v1/github`'s reads and verbs |
  | `fresh-app` on its own Mac slots (its own apps' ids), for a Mac proof | another holder's leases |
- **Machines**: CI grants and the local `sw` with its token, unchanged.

## 4. Visor's agents: a token from the server

- **Minted** by Visor's server when it hands out a job (a move's resume, a
  new session): a JWT, ES256, signed with a key the server keeps.
  - Claims: `iss` the server's id; `sub` the agent's id (UUID); `sid` the
    session's id; `aud` `visor`; `scope` `["stream", "mcp"]`; `iat`, `exp`.
  - Lifetime: one hour. The server sends a fresh one down the agent's
    driver stream every half hour; a stream that drops renews on reconnect
    with the one it holds, if still valid.
  - Revoked by the session ending or moving back (the server refuses that
    `sub` from then on).
- **Carried**: in the Job (a new field, `token`), from the dispatcher to the
  runner, to agent-wrapper (`AGENT_TOKEN`), to Claude's MCP configuration
  (an `Authorization: Bearer` header). `agent-proxy` passes it through.
- **Checked** by the server on the driver stream and on its MCP endpoint
  (`/api/v2/mcp`, streamable HTTP), which offers what native sessions
  have: `list_sessions`, `read_messages`, `send_message`, `read_inbox`,
  `read_outbox`, `message_status`. A container session gets Visor's tools
  back with its next start; its mail goes to its inbox again.
- Co-tenant sessions see each other, as native sessions on one server do.

## 5. Visor's clients: auth as set

Visor's server takes `auth: none | password | ssh` (and Okta in the
enterprise fork), as visor's docs/server-proxy.md has it:

- **none**, behind a front with a sign-in of its own: the generic mode of
  visor#405 (`VISOR_TRUST`, the identity headers), kept as it is.
- **password** and **ssh**: what Visor has now, kept.
- **HTTPS**: the server's own listener with the tailnet's certificate,
  asked of Tailscale and renewed (the code copied into each server, about
  a hundred lines, rather than a package tying two release lines; from
  multipass#32–#34: standard output,
  a login shell's environment, the last copy or the server's own
  certificate if Tailscale can't be asked, never down).

## Migration, in order

1. **agent-proxy and agent-network** built here, tested in a VM.
2. **The mini's primary container switched over**, in one remake once
   `agent-proxy`'s relay listener is live: Shireworks' `containerRelay`
   pointed at it (the PROXY v2 header and relay token unchanged), the
   container's first process `agent-network run --`, and
   `SHIREWORKS_SERVERS` at `http://shireworks.agent.internal`; both names
   answered meanwhile. MultiPass's relay off. Known: a Shireworks restart
   still ends the container's agents until its relay and their execs live
   in the container helper.
3. **Visor's agent tokens** (4) and its MCP endpoint; agent-wrapper and the
   Job carry the token.
4. **Sign-ins moved**: Shireworks' GitHub sign-in (1, 3); Visor's server's
   own HTTPS (5). Clients repointed at each server's address.
5. **MultiPass stopped** on both Macs, and its repository archived, once
   nothing has reached it for a week.
