# Contributing

Thanks for contributing to Resonance.

## Getting Started

- Follow the setup in `README.md` and `docs/RUNBOOK.md`.
- Run the local CI loop before opening a PR:

```bash
./scripts/ci-local.sh --with-docker
```

## Pull Requests

- Keep changes small and focused.
- Add or update tests for behavior changes.
- Update documentation when behavior changes.

## Coding Standards

- TypeScript: run `npm run lint` and `npm run format:check` in `server/`.
- Swift: use Xcode defaults (avoid mass reformatting).

## Security

- Do not commit secrets or PII.
- For security issues, follow `SECURITY.md`.
