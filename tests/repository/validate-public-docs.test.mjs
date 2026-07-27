import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(
  new URL("../../scripts/validate-public-docs.mjs", import.meta.url),
);
const captureScript = fileURLToPath(
  new URL("../../scripts/demo/capture-ios-screenshots.sh", import.meta.url),
);

function git(directory, args) {
  return execFileSync("git", args, { cwd: directory, encoding: "utf8" }).trim();
}

function writeFile(directory, file, content) {
  const destination = join(directory, file);
  execFileSync("mkdir", ["-p", dirname(destination)]);
  writeFileSync(destination, content);
}

function png(index) {
  const data = Buffer.alloc(25);
  data.write("89504e470d0a1a0a", "hex");
  data.writeUInt32BE(1, 16);
  data.writeUInt32BE(2, 20);
  data[24] = index;
  return data;
}

function capture(index) {
  const isIPad = index >= 7 && index <= 11;
  const data = png(index);
  const file = `${String(index).padStart(2, "0")}-${isIPad ? "teacher" : "student"}.png`;
  return {
    capture: {
      index,
      file,
      persona: isIPad ? "teacher" : "student",
      device: isIPad ? "iPad portrait" : "iPhone portrait",
      os: isIPad ? "iPadOS 26.2" : "iOS 26.2",
      width: 1,
      height: 2,
      sha256: createHash("sha256").update(data).digest("hex"),
    },
    data,
  };
}

function createRepository({ manifest = true } = {}) {
  const directory = mkdtempSync(join(tmpdir(), "resonance-public-docs-"));
  writeFile(
    directory,
    "scripts/validate-public-docs.mjs",
    readFileSync(script),
  );
  writeFile(directory, "app/source.txt", "capture source\n");
  writeFile(directory, ".gitignore", "ignored.png\n");
  git(directory, ["init", "--quiet"]);
  git(directory, ["config", "user.email", "tests@example.invalid"]);
  git(directory, ["config", "user.name", "Release contract test"]);
  git(directory, ["add", "."]);
  git(directory, ["commit", "--quiet", "-m", "capture source"]);
  const sourceCommit = git(directory, ["rev-parse", "HEAD"]);

  if (!manifest) return { directory, sourceCommit };

  const captures = Array.from({ length: 12 }, (_, offset) =>
    capture(offset + 1),
  );
  const manifestDirectory = "docs/assets/screenshots/approved/v0.1.0-alpha.1";
  for (const { capture: entry, data } of captures) {
    writeFile(directory, join(manifestDirectory, entry.file), data);
  }
  writeFile(
    directory,
    "docs/release-notes/v0.1.0-alpha.1.md",
    `${captures
      .map(
        ({ capture: entry }) =>
          `![${entry.file}](../assets/screenshots/approved/v0.1.0-alpha.1/${entry.file})`,
      )
      .join("\n")}\n`,
  );
  writeFile(
    directory,
    join(manifestDirectory, "manifest.json"),
    `${JSON.stringify(
      {
        schemaVersion: 2,
        release: "v0.1.0-alpha.1",
        generatedAt: "2026-07-19T12:00:00.000Z",
        revalidatedAt: "2026-07-19",
        source: { commit: sourceCommit, dirty: false, status: "release-ready" },
        proofModel: { kind: "visual-ui-evidence" },
        verification: {
          screenshotCount: 12,
          humanVisualInspection: "passed",
          captureLogsPublished: false,
          releaseReady: true,
        },
        captures: captures.map(({ capture: entry }) => entry),
      },
      null,
      2,
    )}\n`,
  );
  git(directory, ["add", "."]);
  git(directory, ["commit", "--quiet", "-m", "publish reviewed screenshots"]);
  return { directory, sourceCommit, manifestDirectory };
}

function validate(directory, release = true, extraArgs = []) {
  try {
    return {
      status: 0,
      output: execFileSync(
        "node",
        [
          "scripts/validate-public-docs.mjs",
          ...(release ? ["--release"] : []),
          ...extraArgs,
        ],
        { cwd: directory, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      ),
    };
  } catch (error) {
    return {
      status: error.status,
      output: `${error.stdout ?? ""}${error.stderr ?? ""}`,
    };
  }
}

function withRepository(options, run) {
  const repository = createRepository(options);
  try {
    run(repository);
  } finally {
    rmSync(repository.directory, { recursive: true, force: true });
  }
}

test("release mode accepts a clean capture commit followed by approved publication changes", () => {
  withRepository({}, ({ directory }) => {
    const result = validate(directory);
    assert.equal(result.status, 0, result.output);
    assert.match(result.output, /12 published visual captures/);
  });
});

test("release mode rejects a nonancestor capture commit", () => {
  withRepository({}, ({ directory, manifestDirectory }) => {
    const unrelatedCommit = git(directory, [
      "commit-tree",
      "HEAD^{tree}",
      "-m",
      "unrelated",
    ]);
    const manifestPath = join(directory, manifestDirectory, "manifest.json");
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    manifest.source.commit = unrelatedCommit;
    writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    git(directory, ["add", "."]);
    git(directory, ["commit", "--quiet", "-m", "use invalid source"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /source\.commit is not an ancestor of publication HEAD/,
    );
  });
});

test("release mode rejects source changes after capture", () => {
  withRepository({}, ({ directory }) => {
    writeFile(
      directory,
      "app/disallowed.txt",
      "not screenshot publication work\n",
    );
    git(directory, ["add", "."]);
    git(directory, ["commit", "--quiet", "-m", "change source after capture"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /publication includes a disallowed change.*app\/disallowed\.txt/,
    );
  });
});

test("release mode rejects an additional captured-clean screenshot manifest", () => {
  withRepository({}, ({ directory, sourceCommit, manifestDirectory }) => {
    const releaseManifest = JSON.parse(
      readFileSync(join(directory, manifestDirectory, "manifest.json"), "utf8"),
    );
    const baselineDirectory =
      "docs/assets/screenshots/approved/visual-baseline";
    releaseManifest.source.status = "captured-clean-commit";
    releaseManifest.verification.releaseReady = false;
    for (const entry of releaseManifest.captures) {
      writeFile(
        directory,
        join(baselineDirectory, entry.file),
        readFileSync(join(directory, manifestDirectory, entry.file)),
      );
    }
    releaseManifest.source.commit = sourceCommit;
    writeFile(
      directory,
      join(baselineDirectory, "manifest.json"),
      `${JSON.stringify(releaseManifest, null, 2)}\n`,
    );
    git(directory, ["add", "."]);
    git(directory, ["commit", "--quiet", "-m", "add captured-clean baseline"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /release validation requires exactly one screenshot manifest; found 2/,
    );
  });
});

test("release mode requires public nonempty-alt references for every capture", () => {
  withRepository({}, ({ directory }) => {
    writeFile(directory, "docs/release-notes/v0.1.0-alpha.1.md", "# Release\n");
    git(directory, ["add", "."]);
    git(directory, ["commit", "--quiet", "-m", "remove screenshot references"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /release-ready capture is not referenced by public Markdown/,
    );
  });
});

test("local Markdown links cannot escape the repository or target ignored files", () => {
  withRepository({}, ({ directory }) => {
    writeFile(directory, "ignored.png", png(99));
    symlinkSync(
      "../../ignored.png",
      join(directory, "docs/release-notes/ignored-link.png"),
    );
    writeFile(
      directory,
      "docs/release-notes/v0.1.0-alpha.1.md",
      "![Outside](../../../outside.png)\n![Ignored](../../ignored.png)\n![Symlink](./ignored-link.png)\n",
    );
    git(directory, ["add", "docs/release-notes"]);
    git(directory, ["commit", "--quiet", "-m", "add invalid local references"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /local link escapes the repository/);
    assert.match(result.output, /does not resolve to a publication candidate/);
  });
});

test("release mode rejects a stray approved PNG outside every manifest", () => {
  withRepository({}, ({ directory }) => {
    writeFile(
      directory,
      "docs/assets/screenshots/approved/extra/stray.png",
      png(99),
    );
    git(directory, ["add", "."]);
    git(directory, ["commit", "--quiet", "-m", "add stray approved PNG"]);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /approved screenshot PNG is not declared by a manifest: docs\/assets\/screenshots\/approved\/extra\/stray\.png/,
    );
  });
});

test("release mode rejects an absent manifest", () => {
  withRepository({ manifest: false }, ({ directory }) => {
    const defaultResult = validate(directory, false);
    assert.equal(defaultResult.status, 0, defaultResult.output);

    const result = validate(directory);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /requires exactly one release-ready screenshot manifest; found 0/,
    );
  });
});

test("validator rejects unknown arguments", () => {
  withRepository({ manifest: false }, ({ directory }) => {
    const result = validate(directory, false, ["--unexpected"]);
    assert.notEqual(result.status, 0);
    assert.match(
      result.output,
      /unknown validator argument\(s\): --unexpected/,
    );
  });
});

test("capture script reuses named simulators only from the selected runtime", () => {
  const content = readFileSync(captureScript, "utf8");
  assert.match(
    content,
    /--arg runtime "\$RUNTIME_ID" '\[\.devices\[\$runtime\]\[\]\? \| select\(\.name == \$name\)\]/,
  );
  assert.doesNotMatch(
    content,
    /\.devices\[\]\[\]\s*\|\s*select\(\.name == \$name\)/,
  );
});
