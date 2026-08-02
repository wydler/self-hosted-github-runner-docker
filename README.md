# self-hosted-github-runner-docker

![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-Self--Hosted-blue)
![Docker](https://img.shields.io/badge/Docker-Supported-blue)
![Docker Swarm](https://img.shields.io/badge/Docker%20Swarm-Supported-blue)
![License](https://img.shields.io/badge/License-Apache%202.0-green)

Docker-based self-hosted GitHub Actions Runner with automatic installation, registration and lifecycle management.

This project provides a lightweight solution to run GitHub Actions self-hosted runners inside Docker containers.

It supports:

- Organization runners
- Repository runners
- Docker Swarm deployments
- Ephemeral runners
- Secure token handling using Docker secrets


# Overview

The goal of this project is to provide disposable GitHub Actions runners.

Each container:

1. Creates a dedicated runner user
2. Installs the GitHub Actions runner
3. Requests a registration token from GitHub
4. Registers itself
5. Starts the runner process
6. Executes workflows
7. Is replaced automatically by Docker Swarm


# Docker Image
This project does not build the Docker image itself. The required runner image is provided by: https://github.com/wydler/runner-images-hetzner-cloud. The image contains the runtime environment and required tooling.

This repository provides the runner bootstrap and deployment configuration:
- GitHub Actions runner installation
- registration token handling
- organization/repository registration
- runner configuration
- Docker Compose / Swarm deployment


Architecture:

```
runner-images-hetzner-cloud
            |
            v
self-hosted-github-runner-docker
            |
            v
GitHub Actions Runner
```


# Features

- Automatic GitHub Actions Runner installation
- Supports x64 and ARM64
- Organization and Repository runners
- Ephemeral runners (`--ephemeral`)
- Automatic registration token creation
- Automatic cleanup
- Custom runner names & labels
- Runner groups
- Docker secrets support
- Docker Swarm rolling updates


# Requirements

- Docker Engine
- Docker Compose
- Docker Swarm
- GitHub Fine-grained Personal Access Token


# GitHub Token

The runner requires a GitHub Fine-grained Personal Access Token.

The required permissions depend on the runner type.


## Organization Runner

For organization-level runners the token requires:

```
Organization permissions:

Self-hosted runners:
Read and write
```


The token must be allowed to manage self-hosted runners inside the organization.


## Repository Runner

For repository-level runners the token requires:

```
Repository permissions:

Administration:
Read and write
```

The token must be allowed to manage self-hosted runners for the repository.


Create token file:

```bash
echo "YOUR_TOKEN" > github_token.txt

chmod 600 github_token.txt
```
Do not commit this file.


# Installation

Clone repository:

```bash
git clone https://github.com/wydler/self-hosted-github-runner-docker.git /opt/containers/self-hosted-github-runner-docker
git -C /opt/containers/self-hosted-github-runner-docker checkout $(git -C /opt/containers/self-hosted-github-runner-docker tag | tail -1)


cd /opt/containers/self-hosted-github-runner-docker
```


# Docker Swarm

Initialize Swarm:

```bash
docker swarm init
```

Create the external Swarm overlay network used by the GitHub Actions runner stack.
This step is required before running docker stack deploy.

```bash
docker network create -d overlay ci_github_network
```

Deploy:

```bash
docker stack deploy -c docker-stack.yml ci -d
```


Check services:

```bash
docker service ls
docker service ps ci_github-runner
```


Logs:

```bash
docker service logs -f ci_github-runner
```

To remove the GitHub Actions runner stack and stop all running services, execute:

```bash
docker stack rm ci
```

# Updating

Change image version:

```yaml
image:
  wydler/runner-images-hetzner-cloud:20260626.0006.1
```


Deploy again:

```bash
docker stack deploy -c docker-stack.yml ci -d
```


Docker Swarm performs a rolling update.

Example:

```yaml
update_config:
  parallelism: 1
  delay: 60s
  order: start-first
  monitor: 60s
  failure_action: pause
```


# Runner Lifecycle

Startup process:

```
Container start
        |
        v
Create runner user
        |
        v
Install GitHub Actions Runner
        |
        v
Create registration token
        |
        v
Register runner
        |
        v
Start runner
        |
        v
Execute workflow
        |
        v
Runner removed
```


# Environment Variables

| Variable | Description |
|---|---|
| GITHUB_SCOPE | `org` or `repo` |
| GITHUB_ORGANIZATION | GitHub organization |
| GITHUB_REPOSITORY | Repository name |
| RUNNER_GROUP | Runner group |
| RUNNER_LABELS | Runner labels |


# Security Notes

- Use Docker secrets for tokens.
- Do not store tokens in environment variables.
- Use Fine-grained tokens.
- Grant only required permissions.
- Do not commit secret files.
- Prefer ephemeral runners for CI workloads.


# Troubleshooting

View Docker Swarm logs:

```bash
docker service logs -f ci_github-runner
```


Check runners:
VV
```
GitHub
 → Settings
 → Actions
 → Runners
```

To display all services currently running in the Docker Swarm, execute:

```bash
docker service ls
```

To display all nodes currently part of the Docker Swarm cluster, execute:

```bash
docker node ls
```


# License

This project is licensed under the Apache License 2.0.