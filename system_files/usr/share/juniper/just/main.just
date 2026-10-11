set shell := ["bash", "-c"]

import "update.just"
import "network.just"
import "services.just"
import "pi.just"
# Developer recipes exist only in the full juniper image.
import? "dev.just"
# Desktop recipes exist only in juniper-desktop.
import? "desktop.just"

[private]
default:
    @echo "Juniper commands (ujust <command>):"
    @just --justfile {{ justfile() }} --list --list-heading ''
