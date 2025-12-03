# Syncthing4Swarm

**Automatic file synchronization for Docker Swarm**

Syncthing4Swarm deploys [Syncthing](https://syncthing.net/) across a Docker Swarm cluster with automatic peer discovery and zero-touch configuration.

## Features

- **Global deployment**: one Syncthing instance on every Swarm node
- **Automatic discovery**: scans the overlay network to find other instances
- **Auto-configuration**: mutual device pairing and folder sharing without manual intervention
- **Private mode**: disables relays and global discovery (internal traffic only)

## Quick Start

```bash
# Clone the repository
git clone https://github.com/your-username/syncthing4swarm.git
cd syncthing4swarm

# Deploy to Swarm
docker stack deploy -c docker-compose.yml syncthing4swarm
```

## Configuration

Available environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `STGUIAPIKEY` | *required* | API key for Syncthing interface |
| `SYNCTHING_PORT` | `8384` | REST API port |
| `SYNCTHING_SYNC_PORT` | `22000` | Synchronization port |
| `SYNCTHING_FOLDER_ID` | `shared` | Shared folder identifier |
| `SYNCTHING_FOLDER_PATH` | `/var/syncthing/data` | Synchronized folder path |
| `SYNCTHING_FOLDER_LABEL` | `Shared` | Display name for the folder |
| `SYNCTHING_DISABLE_GLOBAL` | `true` | Disables relays and global discovery |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Docker Swarm                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │   Node 1    │  │   Node 2    │  │   Node 3    │     │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │     │
│  │ │Syncthing│◄┼──┼►│Syncthing│◄┼──┼►│Syncthing│ │     │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │     │
│  │     │       │  │     │       │  │     │       │     │
│  │ /var/sync/  │  │ /var/sync/  │  │ /var/sync/  │     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
│                                                         │
│               Overlay network (internal)                │
└─────────────────────────────────────────────────────────┘
```

## How It Works

On each container startup:

1. Waits for Syncthing to become operational
2. Disables global features (relays, NAT, external discovery)
3. Creates the shared folder if it doesn't exist
4. Scans the overlay subnet (`/24`)
5. Mutually adds all discovered devices with their static IP addresses
6. Syncs the device list across the shared folder

## Requirements

- Initialized Docker Swarm (`docker swarm init`)
- Configured overlay network
- Same `STGUIAPIKEY` on all nodes

## Exposed Ports

| Port | Protocol | Usage |
|------|----------|-------|
| 8384 | TCP | Web interface and REST API |
| 22000 | TCP/UDP | File synchronization |
| 21027 | UDP | Local discovery |

## Acknowledgments

This project is built on top of [Syncthing](https://github.com/syncthing/syncthing), an amazing open-source continuous file synchronization program. Huge thanks to the Syncthing contributors for their incredible work.

This project was inspired by [docker-swarm-syncthing](https://github.com/bluepuma77/docker-swarm-syncthing) by bluepuma77.


