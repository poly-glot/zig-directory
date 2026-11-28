# Security policy

## Report a problem privately

Use GitHub's private vulnerability reporting: open
[Security advisories](https://github.com/poly-glot/zig-directory/security/advisories/new) on this repository and
choose "Report a vulnerability". Only the maintainer can see the report. Please do not open a public issue or a pull
request for a vulnerability.

If the form is not available, contact the maintainer through the [GitHub profile](https://github.com/poly-glot).
Ask for a private channel and leave the details out of that first message.

This is a one-person project. Reports are read as soon as the maintainer can, with no promised response time. A good
report names the version or commit, says what an attacker needs (network position, an account, a role), gives the
steps, and says what the attacker gets.

## Supported versions

Only the latest commit on `main` is supported, which is version 0.6.0 in `build.zig.zon`. There are no tagged
releases and no back-ported fixes. A fix lands on `main` and goes to the live site by the normal deployment.

## Threat model

The directory has three tiers, and they trust each other in different ways. Two of them face the internet.

**The website (`web/`) is the main public tier.** It serves the pages and `/api/v1`, signs people in, and decides who
may do what. Roles (user and admin) are checked there. Its user and session data lives in Deno KV, in a `denokv`
service that only the website talks to.

**The MCP server (`mcp/`) is the second public entry point.** It exposes the directory to AI clients through
`/mcp`. It does not speak the binary protocol and has no database access. It checks a caller's OAuth bearer token and
role, then calls the website's `/api/v1`, which checks them again.

**`dmozdb` trusts network position and checks nothing else.** The binary protocol has no authentication, no TLS and no
per-operation authorisation. Any client that can open a connection to its port can run every operation, including
`delete_category`, `bulk_delete_links`, `rebuild_index` and `snapshot`. That is a decision, explained under
[Protected mode](docs/architecture.md#protected-mode): a pre-shared key without TLS would not stop someone watching the
network, so network isolation is the control.

The controls that exist are these:

1. The server binds to `127.0.0.1` unless told otherwise.
2. `DMOZDB_TRUSTED` lists the IPv4 addresses and CIDR ranges that may connect. Loopback is always allowed.
3. If `DMOZDB_BIND=0.0.0.0` is set without `DMOZDB_TRUSTED`, the server starts in protected mode and rejects every
   non-loopback connection at accept time, before it allocates a buffer.
4. In the Kubernetes deployment, `dmozdb` sits behind a ClusterIP service, so nothing outside the cluster can reach it.

What this does not cover:

- A compromised host or pod on a trusted network. Anything inside `DMOZDB_TRUSTED` has full access. The live
  deployment trusts the whole pod CIDR and the node subnet, not only the website's pods.
- The `NetworkPolicy` objects in `deployment/base/networkpolicy.yaml` are written but not enforced. The cluster uses
  flannel, which does not enforce them.
- Traffic that crosses an untrusted network. Put an encrypted tunnel such as WireGuard around it and trust only the
  tunnel's peer address.

If you run `dmozdb` yourself, never publish its port to the internet and never trust a broad address range. Put the
website, or your own service that checks who is calling, in front of it.

## What counts as a vulnerability

These are in scope:

- Reaching `dmozdb` from outside the trusted set, or getting past protected mode.
- A malformed frame that crashes the server, corrupts the store or reads memory it should not.
- A way for an anonymous or ordinary user to do what only an admin can, through the website or the MCP server.
- Leaking another person's data, a password hash, a session or a token.
- Script injection through stored titles, URLs or descriptions.

These are not, because they are the stated design: a trusted client being able to run any operation, and the absence of
TLS on the binary protocol.
