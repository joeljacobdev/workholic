#!/usr/bin/env node
// Operator commands: create a Workholic user and change that user's limit, timezone, or password.
// There is no signup. This command is the only way to add a user.

import { existsSync } from "node:fs";

const PRODUCTION_URL = "https://workaholic.joeljacob.tech";
const ENV_FILE = new URL("../.env", import.meta.url);
if (existsSync(ENV_FILE)) process.loadEnvFile(ENV_FILE);

const args = process.argv.slice(2);
const command = args[0];

function flag(name) {
  const index = args.indexOf(name);
  if (index === -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}

function help() {
  console.log(`Usage:
  npm run user -- create-user  --username NAME --timezone Asia/Kolkata
  npm run user -- set-limit    --username NAME --hours 8   (or --minutes 90)
  npm run user -- set-timezone --username NAME --timezone Asia/Kolkata
  npm run user -- set-password --username NAME

Passwords for create-user and set-password come from WORKHOLIC_PASSWORD, never a flag,
so they stay out of shell history. set-password signs out every web and app session.

The bootstrap token comes from WORKHOLIC_BOOTSTRAP_TOKEN, read from the git-ignored .env
at the repo root. Only these operator commands use it; the apps never send it.

WORKHOLIC_URL defaults to ${PRODUCTION_URL}. For a local worker use
WORKHOLIC_URL=http://127.0.0.1:8787 with the token from worker/.dev.vars.`);
}

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing ${name}`);
    process.exit(1);
  }
  return value;
}

async function post(path, body) {
  const url = process.env.WORKHOLIC_URL ?? PRODUCTION_URL;
  console.error(`→ ${url}${path}`);
  const response = await fetch(`${url}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-bootstrap-token": requiredEnv("WORKHOLIC_BOOTSTRAP_TOKEN"),
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  if (!response.ok) {
    console.error(`${response.status} ${text}`);
    process.exit(1);
  }
  console.log(JSON.stringify(parsed, null, 2));
}

function requireFlags(...names) {
  const values = names.map(flag);
  if (values.some((value) => !value)) {
    help();
    process.exit(1);
  }
  return values;
}

if (command === "create-user") {
  const [username, timezone] = requireFlags("--username", "--timezone");
  await post("/v1/admin/users", { username, password: requiredEnv("WORKHOLIC_PASSWORD"), timezone });
} else if (command === "set-limit") {
  const username = flag("--username");
  const hours = flag("--hours");
  const minutes = flag("--minutes");
  if (!username || (!hours && !minutes)) {
    help();
    process.exit(1);
  }
  const limitMs = hours ? Number(hours) * 60 * 60 * 1000 : Number(minutes) * 60 * 1000;
  if (!Number.isInteger(limitMs) || limitMs < 0) {
    console.error("Limit must be a whole number of hours or minutes");
    process.exit(1);
  }
  await post("/v1/admin/limits", { username, limit_ms: limitMs });
} else if (command === "set-timezone") {
  const [username, timezone] = requireFlags("--username", "--timezone");
  await post("/v1/admin/timezone", { username, timezone });
} else if (command === "set-password") {
  const [username] = requireFlags("--username");
  await post("/v1/admin/password", { username, password: requiredEnv("WORKHOLIC_PASSWORD") });
} else {
  help();
  process.exit(command ? 1 : 0);
}
