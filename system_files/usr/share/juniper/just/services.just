# Run Prometheus node_exporter as a quadlet (reachable over Tailscale on :9100)
enable-metrics:
    #!/usr/bin/bash
    set -euo pipefail
    sudo tee /etc/containers/systemd/node-exporter.container >/dev/null <<'EOF'
    [Unit]
    Description=Prometheus node exporter
    [Container]
    # v1.12.1, pinned: no auto-updates of unsigned code with host access (just bump-tools)
    Image=quay.io/prometheus/node-exporter@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0
    Network=host
    PodmanArgs=--pid=host
    Volume=/:/host:ro,rslave
    Exec=--path.rootfs=/host
    User=65534
    Group=65534
    DropCapability=ALL
    NoNewPrivileges=true
    ReadOnly=true
    [Install]
    WantedBy=multi-user.target
    EOF
    sudo systemctl daemon-reload
    sudo systemctl start node-exporter.service
    echo "Metrics: http://$(tailscale ip -4 | head -1):9100/metrics"
