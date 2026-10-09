# Run Prometheus node_exporter as a quadlet (reachable over Tailscale on :9100)
enable-metrics:
    #!/usr/bin/bash
    set -euo pipefail
    sudo tee /etc/containers/systemd/node-exporter.container >/dev/null <<'EOF'
    [Unit]
    Description=Prometheus node exporter
    [Container]
    Image=quay.io/prometheus/node-exporter:latest
    Network=host
    PodmanArgs=--pid=host
    Volume=/:/host:ro,rslave
    Exec=--path.rootfs=/host
    AutoUpdate=registry
    [Install]
    WantedBy=multi-user.target
    EOF
    sudo systemctl daemon-reload
    sudo systemctl start node-exporter.service
    echo "Metrics: http://$(tailscale ip -4 | head -1):9100/metrics"
