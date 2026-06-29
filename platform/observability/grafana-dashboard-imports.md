# Imported Grafana dashboards

## Kubernetes / Views / Pods

- **Grafana ID:** 15760
- **Source:** https://grafana.com/grafana/dashboards/15760-kubernetes-views-pods/
- **Datasource:** Prometheus (kube-prometheus-stack)
- **Reason for import:** This dashboard helps inspect Pod-level CPU, memory, restarts, and runtime behavior during k6 experiments. It provides infrastructure-level context (USE signals) to complement the application RED signals dashboard.

## How to import

1. Open Grafana via port-forward: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80`
2. Navigate to **Dashboards → New → Import**
3. Enter the dashboard ID (e.g., `15760`) and click **Load**
4. Select the **Prometheus** datasource
5. Click **Import**
