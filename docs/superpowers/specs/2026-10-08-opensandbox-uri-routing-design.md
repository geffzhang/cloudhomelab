# OpenSandbox URI Routing Design

## Goal

Configure OpenSandbox sandbox URL routing to use URI-based routes while
continuing to use the gateway ingress mode and the configured gateway hostname.

## Scope

- Set `gateway.route.mode` to `"uri"` in the rendered OpenSandbox server
  configuration.
- Keep `ingress.mode = "gateway"` and the existing `gateway.address` hostname.
- Update the OpenSandbox operations guide to explain that these settings work
  together and that the hostname should match the ingress domain.
- Do not change gateway deployment resources, routing permissions, or other
  runtime settings.

## Validation

- Confirm the rendered `server.yaml` remains valid YAML and its embedded
  `config.toml` uses URI route mode, gateway ingress mode, and the configured
  hostname.
- Confirm the operations guide describes the same configuration.
