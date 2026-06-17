# Grafana Dashboards

Place exported Grafana dashboard JSON files here.

This cluster used a dashboard named `grafana-alloy-logs-dashboard.json`
(built against the Loki + Alloy logging pipeline set up by
`scripts/07-install-loki-alloy.sh`) in an external Grafana instance. If
you're recreating this setup, export your own dashboard JSON from Grafana
(Dashboard settings → JSON Model, or the share/export feature) and drop it
here for version control.

To import a dashboard JSON file into Grafana:

1. Grafana UI → Dashboards → New → Import
2. Upload the `.json` file, or paste its contents
3. Select the Loki datasource pointing at your Loki instance
   (see `values/alloy-values.yaml` for the Loki endpoint this cluster uses)
