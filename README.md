# EuroTransit Configuration

Status: GitOps bootstrap in progress.

This repository is the source of truth for the desired Kubernetes state of EuroTransit:

- application Helm chart under `deploy/charts/eurotransit`
- platform configuration under `platform`
- operational documentation under `docs`

## GitOps Prerequisites

GitOps needs two sides before Argo CD can compare and reconcile anything:

- **Git desired state**: the reviewed configuration committed to the deploy branch
- **Kubernetes live state**: an AKS cluster with Argo CD and the required platform CRDs installed

Argo CD is the controller that compares those two sides and reconciles drift.

## Kubernetes Bootstrap

First connect the local machine to the AKS cluster and allow the cluster to pull images from ACR:

```bash
az aks update \
  --resource-group G_06 \
  --name Lab02cluster \
  --attach-acr Lab02clusterregistry

az aks get-credentials \
  --resource-group G_06 \
  --name Lab02cluster \
  --overwrite-existing

kubectl config current-context
```

Then install the shared platform components required by the manifests in this repository.

Minimum platform layer before syncing the EuroTransit application:

- Traefik CRDs and controller
- cert-manager CRDs and controller
- kube-prometheus-stack CRDs, including `ServiceMonitor` and `PrometheusRule`
- CloudNativePG CRDs and operator
- Strimzi CRDs and operator
- Argo CD
- Chaos Mesh before running chaos experiments

The application chart should be synced only after the CRDs it references exist in the cluster.

## GitOps Workflow

EuroTransit uses the two-repository delivery model required by the capstone:

- the application repository builds and tests the services
- the application repository pushes immutable container images to ACR
- the application repository updates image tags in this configuration repository
- Argo CD runs inside the AKS cluster and reconciles this repository into Kubernetes

CI must not hold cluster credentials or run `kubectl apply`. Argo CD is the only actor that applies application desired state to the cluster.

## Branch Policy

The `main` branch is the GitOps deploy branch watched by Argo CD.

Normal change flow:

1. Create a branch using `feat/`, `impr/`, or `bug/`.
2. Open a pull request to `dev`.
3. Review and validate the change.
4. Promote reviewed changes from `dev` to `main`.
5. Argo CD detects `main` changes and syncs the cluster.

This keeps review between AI-generated changes and the branch that Argo CD deploys.

## Argo CD Application Bootstrap

Install Argo CD with the repository values:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values platform/argocd/values.yaml
```

Then apply the EuroTransit Argo CD `Application`:

```bash
kubectl apply -f platform/argocd/eurotransit-application.yaml
```

The application watches:

- repository: `https://github.com/CPO-G02/eurotransit-configuration-g02`
- branch: `main`
- path: `deploy/charts/eurotransit`
- destination namespace: `eurotransit`

The application uses automated sync with pruning and self-healing enabled.
