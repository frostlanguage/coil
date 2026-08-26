<!--
SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
SPDX-License-Identifier: GPL-3.0-only
-->

# Coil CI cache plane

The Coil CI can use a cache plane located on the same low-latency network as
self-hosted runners. The cache plane is optional; GitHub-hosted runners remain
the fallback and require no private infrastructure.

## Runner selection

Set the repository variable `COIL_CI_RUNNER` to the custom label assigned to
the trusted self-hosted runner pool. Leave the variable unset to use
`ubuntu-24.04`.

All `pull_request` jobs use GitHub-hosted runners. Push, merge-group, and
manual jobs may use the private runner label. This keeps pull-request code
off the private runner network by default.

Workflow routing is defense in depth, not the cache-plane security boundary.
Enforce write access with runner identity, service authentication, and network
policy. Do not give pull-request or general lint runners registry-push or Bazel
cache-write credentials.

## Runner environment

Provision cache endpoints as environment variables on the runner service, not
as repository variables or committed files:

```text
COIL_CI_CACHE_PLANE_MODE=optional
COIL_CI_TOOL_CACHE_DIR=/var/cache/coil/tools
HTTPS_PROXY=http://squid.ci.internal:3128
HTTP_PROXY=http://squid.ci.internal:3128
NO_PROXY=registry.ci.internal,bazel-cache.ci.internal
COIL_CI_OCI_REGISTRY=registry.ci.internal:5000
COIL_CI_BAZEL_REMOTE_CACHE=grpc://bazel-cache.ci.internal:9092
```

`COIL_CI_CACHE_PLANE_MODE` accepts `disabled`, `optional`, or `required`.
Required mode fails the cache-plane preflight unless the proxy, OCI registry,
and Bazel remote cache are all configured.

`COIL_CI_TOOL_CACHE_DIR` is an optional persistent local directory. Immutable
tool downloads are stored below this directory by version and SHA-256. The
download action writes through a temporary file and atomically renames verified
content, so concurrent jobs can safely share the directory.

## Squid

Use Squid as the runner egress proxy and apply an LRU disk replacement policy
when the deployed Squid version supports that configuration. Do not enable TLS
interception only to improve CI cache hit rate. Normal HTTPS `CONNECT` traffic
remains end-to-end encrypted and is not an object cache.

The pipeline automatically honors standard `HTTP_PROXY`, `HTTPS_PROXY`, and
`NO_PROXY` variables inherited from the runner service.

## OCI registry

Provision the Docker or container runtime with the local OCI registry or
registry mirror before the runner service starts. The workflow does not mutate
the host daemon because that would require privileged job access.

Keep registry authentication in the runner credential store. Apply retention
before garbage collection and run Distribution garbage collection with writes
blocked, or use a registry implementation that provides safe online retention
and garbage collection.

## Bazel remote cache

The cache-plane action generates a temporary Bazel rc file whenever
`COIL_CI_BAZEL_REMOTE_CACHE` is present. Supported URI schemes are `http`,
`https`, `grpc`, and `grpcs`.

Only trusted pushes to the default branch, merge-group builds, and manual runs
on the default branch may upload local Bazel results. Pull requests and tags
are read-only. Bazel download verification remains enabled.

The repository lint workflow runs `bazel test //...` automatically when a
Bazel workspace marker is present. Until Coil adopts Bazel, the job validates
the cache-plane integration and exits without building.

For `bazel-remote`, use bounded disk storage with its automatic LRU eviction
and zstd storage. NVMe close to the runners is preferred.

## Cache hierarchy

The intended hierarchy is:

```text
L0  persistent runner-local immutable tool cache
L1  Squid egress + OCI registry + Bazel remote cache on the runner LAN
L2  GitHub Actions cache for immutable tool downloads on hosted runners
L3  upstream origin
```

Pull requests restore the GitHub tool cache but never publish new entries.
Only default-branch pushes and default-branch manual runs publish immutable tool
cache entries. This keeps untrusted pull-request jobs restore-only.

Release and tag tool downloads do not restore or save GitHub Actions cache.
Every immutable tool artifact is SHA-256 verified even after a cache hit.
