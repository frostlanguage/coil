-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Verify the npm graph using Node's native JSON reader before installation.
local platform = dofile("scripts/libs/platform.lua")
local adapter = [==[
// SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
// SPDX-License-Identifier: GPL-3.0-only

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const tools = JSON.parse(process.env.TOOLCHAIN_TOOLS);
const manifest = JSON.parse(
   readFileSync("tools/lint/code/md/package.json"),
);
const lock = JSON.parse(
   readFileSync("tools/lint/code/md/package-lock.json"),
);
const identities = {
   "markdownlint-cli2": "markdownlint",
   "markdown-it": "markdown_it",
   mermaid: "mermaid",
   jsdom: "jsdom",
};
assert.equal(lock.lockfileVersion, 3);
assert.deepEqual(
   Object.keys(manifest.dependencies).sort(),
   Object.keys(identities).sort(),
);
for (const [dependency, identity] of Object.entries(
   identities,
)) {
   assert.equal(
      manifest.dependencies[dependency],
      tools[identity].version,
      dependency,
   );
   assert.equal(
      lock.packages[""]?.dependencies[dependency],
      tools[identity].version,
      dependency,
   );
   assert.equal(
      lock.packages["node_modules/" + dependency]?.version,
      tools[identity].version,
      dependency,
   );
}
// CWE-1395: upstream exact pins need these audited transitive fixes.
const overrides = {
   "lodash-es": "lodash_es",
   "smol-toml": "smol_toml",
};
assert.deepEqual(
   Object.keys(manifest.overrides).sort(),
   Object.keys(overrides).sort(),
);
for (const [dependency, identity] of Object.entries(overrides)) {
   const version = tools[identity].version;
   assert.equal(manifest.overrides[dependency], version, dependency);
   const copies = Object.entries(lock.packages).filter(([path]) =>
      path.endsWith("node_modules/" + dependency),
   );
   assert.ok(copies.length > 0, dependency);
   for (const [path, item] of copies) {
      assert.equal(item.version, version, path);
   }
}
// CWE-494 / CAPEC-184: require HTTPS and integrity for every package.
for (const [path, item] of Object.entries(lock.packages)) {
   if (!path) continue;
   assert.match(
      item.resolved,
      /^https:\/\/registry\.npmjs\.org\//,
      path,
   );
   assert.match(
      item.integrity,
      /^sha512-[A-Za-z0-9+/]+={0,2}$/,
      path,
   );
   assert.equal(item.link, undefined, path);
}
console.log(
   "Document dependencies match the toolchain and integrity policy.",
);
]==]
platform.run({ "node", "--input-type=module", "--eval", adapter })
-- EOF
