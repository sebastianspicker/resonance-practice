# Contributing

Thanks for contributing to Resonance.

## Getting Started

- Follow the setup in `README.md` and `docs/RUNBOOK.md`.
- Run the fast loop before opening a PR:

```bash
./scripts/secret-scan.sh
cd server
npm run lint
npm run format
npm run build
npm test
```

## Pull Requests

- Keep changes small and focused.
- Add or update tests for behavior changes.
- Update documentation when behavior changes.

## Coding Standards

- TypeScript: run `npm run lint` and `npm run format` in `server/`.
- Swift: use Xcode defaults (avoid mass reformatting).

## Security

- Do not commit secrets or PII.
- For security issues, follow `SECURITY.md`.
