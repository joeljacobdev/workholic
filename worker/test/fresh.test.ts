import assert from "node:assert/strict";
import test from "node:test";
import { ensureCurrent, restartIfOlder } from "../src/fresh.ts";

function fakeCtx() {
  const aborts: string[] = [];
  const ctx = {
    abort(reason?: string) {
      aborts.push(reason ?? "");
      throw new Error("aborted");
    },
  } as unknown as DurableObjectState;
  return { ctx, aborts };
}

const older = { id: "v1", tag: "", timestamp: "2026-10-12T05:00:00.000Z" };
const newer = { id: "v2", tag: "", timestamp: "2026-10-12T06:00:00.000Z" };

test("an object on the caller's version stays", () => {
  const { ctx, aborts } = fakeCtx();
  assert.equal(restartIfOlder(ctx, newer, newer), "current");
  assert.deepEqual(aborts, []);
});

test("an object on older code restarts", () => {
  const { ctx, aborts } = fakeCtx();
  assert.throws(() => restartIfOlder(ctx, older, newer), /aborted/);
  assert.deepEqual(aborts, ["newer code deployed"]);
});

test("an older Worker mid-rollout does not restart an object on newer code", () => {
  const { ctx, aborts } = fakeCtx();
  assert.equal(restartIfOlder(ctx, newer, older), "current");
  assert.deepEqual(aborts, []);
});

test("each object is checked once per isolate, and a restart does not fail the request", async () => {
  const env = { CF_VERSION_METADATA: newer } as unknown as Env;
  let calls = 0;
  const stub = {
    async restartIfOlder() {
      calls += 1;
      throw new Error("aborted");
    },
  };
  await ensureCurrent(env, "user-1", stub);
  await ensureCurrent(env, "user-1", stub);
  assert.equal(calls, 1);
  await ensureCurrent(env, "user-2", stub);
  assert.equal(calls, 2);
});
