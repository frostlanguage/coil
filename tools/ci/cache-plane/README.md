<!--
SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
SPDX-License-Identifier: GPL-3.0-only
-->

# Coil CI cache plane

The Coil CI can use a cache plane on the same low-latency network as trusted
self-hosted runners. GitHub-hosted runners remain the fallback and require no
private infrastructure.

The cache plane separates four concerns instead of treating every service as
one interchangeable cache:

```text
runner
  |-- L0 runner-local immutable tool cache
  |-- L1 S3-compatible shared object cache
  |-- specialized OCI registry / mirror
  |-- specialized Bazel remote cache
  `-- Squid egress proxy --> upstream origins
```

Squid controls egress and can cache eligible HTTP traffic. It is not a shared
object-cache tier for normal end-to-end HTTPS traffic.

## Runner selection

Set the repository variable `COIL_CI_RUNNER` to the custom label assigned to
the trusted self-hosted runner pool. Leave the variable unset to use
`ubuntu-24.04`.

All `pull_request` jobs use GitHub-hosted runners. Push, merge-group, and manual
jobs may use the private runner label. This keeps pull-request code off the
private runner network by default.

Workflow routing is defense in depth, not the cache-plane security boundary.
Enforce write access with runner identity, service authentication, and network
policy. Do not give pull-request runners private cache credentials.

## Runner environment

Provision cache endpoints and credentials on the runner service or through a
workload identity. Do not place object-store credentials in repository
variables or committed files.

A self-hosted runner can use this environment:

```text
COIL_CI_CACHE_PLANE_MODE=optional
COIL_CI_TOOL_CACHE_DIR=/var/cache/coil/tools
COIL_CI_S3_CACHE_ENDPOINT=https://silo.ci.internal
COIL_CI_S3_CACHE_BUCKET=coil-ci-cache
COIL_CI_S3_CACHE_PREFIX=coil/cache
COIL_CI_S3_CACHE_REGION=us-east-1
HTTPS_PROXY=http://squid.ci.internal:3128
HTTP_PROXY=http://squid.ci.internal:3128
NO_PROXY=silo.ci.internal,registry.ci.internal,bazel-cache.ci.internal
COIL_CI_OCI_REGISTRY=registry.ci.internal:5000
COIL_CI_BAZEL_REMOTE_CACHE=grpc://bazel-cache.ci.internal:9092
```

Use the standard AWS credential chain for the S3-compatible endpoint. A VM may
use its machine identity or credential store. A Kubernetes runner should prefer
workload identity or a service account over static credentials.

`COIL_CI_CACHE_PLANE_MODE` accepts `disabled`, `optional`, or `required`.
Required mode requires the S3-compatible shared object cache. OCI, Bazel, and
Squid remain specialized services and do not become mandatory when the build
does not need them.

## L0 runner-local cache

`COIL_CI_TOOL_CACHE_DIR` points to an optional persistent local directory. The
verified-download action stores immutable tool downloads below this directory
by platform, version, and SHA-256.

The action writes through a temporary file and renames only verified content.
Concurrent jobs can therefore share the local directory without trusting a
partial download.

## L1 S3-compatible shared object cache

`COIL_CI_S3_CACHE_BUCKET` enables the shared object cache. Set
`COIL_CI_S3_CACHE_ENDPOINT` for an S3-compatible service; leave the endpoint
unset when the standard AWS S3 endpoint should supply the cache.

The verified-download action uses this lookup order:

```text
L0 runner-local cache
  -> L1 S3-compatible shared cache
  -> GitHub Actions cache when runners have no private cache access
  -> HTTPS origin, optionally through Squid
```

Every cache hit receives the same SHA-256 verification as an origin download.
A digest mismatch in the shared cache fails the job instead of silently falling
back to the network.

Only merge-group jobs, trusted pushes to the default branch, and manual runs on
the default branch may populate the shared object cache. Pull requests and tags
do not upload objects. The object key includes platform, architecture, tool,
version, digest, and filename, so policy keys address shared tool objects by
content.

Configure lifecycle expiration in the object store rather than deleting cache
objects from CI jobs. Use a bounded retention window that matches runner reuse,
and expire incomplete multipart uploads separately.

## Squid egress proxy

Use Squid as the runner egress proxy and apply an LRU disk replacement policy
when the deployed Squid version supports that configuration. Do not enable TLS
interception only to improve CI cache hit rate. Normal HTTPS `CONNECT` traffic
remains end-to-end encrypted and does not expose response bodies to Squid.

The pipeline honors standard `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`
variables inherited from the runner service. Put the shared object store, OCI
registry, and Bazel cache in `NO_PROXY` when they live on the runner LAN.

## OCI registry or mirror

Provision the container runtime with the local OCI registry or pull-through
mirror before the runner service starts. The workflow does not mutate the host
daemon because that would require privileged job access.

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
may read cached results but may not upload them. Bazel download verification
remains enabled.

The repository lint workflow runs `bazel test //...` when a Bazel workspace
marker is present. Until Coil adopts Bazel, the job validates the cache-plane
integration and exits without building.

For `bazel-remote`, use bounded disk storage with its automatic LRU eviction
and zstd storage. Prefer NVMe storage close to the runners.

## Cache hierarchy and trust boundary

The effective hierarchy is:

```text
L0  persistent runner-local immutable tool cache
L1  S3-compatible shared cache for trusted self-hosted runners
H1  GitHub Actions cache for hosted runners without private cache access
S1  OCI registry / mirror for container layers and manifests
S2  Bazel remote cache for action outputs when Bazel is in use
E1  Squid for egress control and eligible HTTP caching
O1  upstream origin
```

The `H1`, `S1`, `S2`, and `E1` labels describe parallel services rather than a
single linear fallback chain.

Pull requests stay on GitHub-hosted runners and do not receive private cache
credentials. Release and tag tool downloads may read a configured shared object
cache but do not publish new objects. GitHub-hosted release and tag jobs still
go directly to the verified upstream origin because they do not restore or save
the GitHub Actions tool cache.

The action verifies every immutable tool artifact with SHA-256 after retrieval,
regardless of which cache or origin supplied it.
