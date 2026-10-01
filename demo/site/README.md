# Static walkthrough

`demo/site/` is a dependency-free, presentation-only walkthrough of Resonance.
It uses synthetic in-memory data and never connects to an account, API,
database, microphone, camera, or storage service. It is not the iOS app and does
not demonstrate server or offline-sync behavior.

The page also hosts the screenshot tour in `screenshots/`. Those images come from
the real iOS app running in a simulator against the deterministic demo fixture,
not from generated mockups.

Open `index.html` directly in a browser for local viewing. From the repository
root, validate the publication boundary with:

```bash
node scripts/demo/validate-static-site.mjs
```

The validator requires the walkthrough to stay self-contained, keeps simulated
controls visible, rejects operational data fields and unsafe markup sinks, and
confirms that the root README links to the public site.

`.github/workflows/pages.yml` publishes only this directory to GitHub Pages
after the validator passes on changes to `main`. The workflow is the only
deployment definition for this component.
