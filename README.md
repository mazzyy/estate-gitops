# estate-gitops

The estate [Warden](https://github.com/mazzyy/warden) watches, and the only
surface anything in that system can write to.

This repository is deliberately separate from the agent code. Warden's
Remediator holds a GitHub token scoped to **this repo and nothing else**, with
permission to open pull requests and none to merge them. That separation is what
makes the claim provable rather than asserted:

> **No agent holds production write credentials. Their only write primitive is
> opening a pull request.**

## Layout

```
namespace.yaml               the blast radius — every agent is pinned to `demo`
apps/checkout-svc/
  deployment.yaml            what the Remediator patches
  service.yaml
  kustomization.yaml
rbac/warden-reader.yaml      the read-only ServiceAccount Warden authenticates as
app/                         checkout-svc itself — a service built to fail properly
scripts/inject.sh            break it, restore it
.github/workflows/sync.yml   merged PR -> cluster. The only credential that can change anything.
```

## checkout-svc

A small FastAPI service with two real failure modes. Both are genuine — the
process exits, the kubelet restarts it, and `kubectl describe` reports
CrashLoopBackOff and OOMKilled for real reasons. Nothing is simulated, because
the hackathon requires unedited live execution and a demo that fakes its own
failure proves nothing.

| Injection | Cause | What the cluster reports |
|---|---|---|
| `bad-config` | `PAYMENT_ENDPOINT` scheme `htps` — one missing character | `CrashLoopBackOff`, exit 1 |
| `oom` | `WARMUP_MB=128` against a `64Mi` limit | `OOMKilled`, exit 137 |

The log line the bad config produces —
`FATAL: unsupported URL scheme "htps" in PAYMENT_ENDPOINT` — is byte-identical
to what Warden's offline fake estate emits, so the Diagnostician behaves the
same whether it is reasoning about a real cluster or a fixture.

## Running the demo

```bash
# once. -f on the app dir, NOT on kustomization.yaml (that needs -k).
kubectl apply -f namespace.yaml
kubectl apply -f rbac/warden-reader.yaml
kubectl apply -f apps/checkout-svc/deployment.yaml -f apps/checkout-svc/service.yaml

# prove the reader token cannot mutate anything — keep this output for the video
./scripts/verify-rbac.sh

# break it
./scripts/inject.sh bad-config
kubectl get pods -n demo -w

# ...Warden triages, diagnoses, and opens a pull request. You review and merge.
# sync.yml applies it. The service recovers.

# reset between takes
./scripts/inject.sh restore
```

`inject.sh` commits and pushes the bad change before applying it, rather than
poking the cluster behind git's back. That asymmetry is the story — humans break
things directly, the agent fixes them through review — and it gives the
Diagnostician a real ReplicaSet history with a real change-cause to correlate
against, which is what turns *"the service is down"* into *"revision r42, four
minutes ago, did this."*

**Rehearse the full sequence three times before recording.** The rules forbid
editing around a failure, and `restore` before every take is not optional.

## Proving the read-only claim

`./scripts/verify-rbac.sh` is the only correct way to test it, and the reason is
worth knowing.

The obvious test is wrong:

```bash
kubectl --token=$TOKEN --server=$APISERVER -n demo delete deploy checkout-svc
```

That *appears* to work — and it deletes the deployment. Not because RBAC failed,
but because an AKS admin kubeconfig authenticates with **client certificates**,
and Kubernetes accepts a valid client cert regardless of any bearer token you
also pass. `--token` is silently ignored and the command runs as cluster-admin.

So the "proof" proves nothing. Recording it would mean demonstrating a
governance guarantee that was never actually tested. The script passes
`--kubeconfig=/dev/null`, which removes the context and its certs and leaves the
token as the only credential.

## Building the image

```bash
cd app
docker build -t ghcr.io/mazzyy/checkout-svc:1.4.2 .
docker push ghcr.io/mazzyy/checkout-svc:1.4.2
```

## Branch protection

Protect `main`: require a pull request before merging. That is what makes *"no
agent can merge its own PR"* true in the platform rather than only in the prompt.
