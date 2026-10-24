// A deploy gives new requests new code, but a Durable Object that never goes idle keeps the code
// it started with: the Macs ask every minute, so an account object could run old code for days,
// and new methods fail with "The RPC receiver does not implement the method".
//
// So the first time a Worker isolate talks to an object, it hands over its own version. An object
// running older code restarts itself with ctx.abort(), and the next call starts it on the new code.
// Isolates are new after a deploy, so this costs one extra call per object per isolate.

export interface CodeVersion {
  id: string;
  timestamp: string;
}

/** Inside the object. Restarts it when the caller's code is newer. Restarting surfaces to the caller as an error. */
export function restartIfOlder(ctx: DurableObjectState, mine: WorkerVersionMetadata, caller: CodeVersion): "current" {
  if (mine.id === caller.id) return "current";
  // During a rollout an older Worker can reach an object already on newer code; that one stays.
  if (Date.parse(mine.timestamp) >= Date.parse(caller.timestamp)) return "current";
  ctx.abort("newer code deployed");
  return "current";
}

/** Objects this isolate has already checked, by name. */
const checked = new Set<string>();

/** In the Worker. Checks an object once per isolate; `key` names it, such as "directory" or a user id. */
export async function ensureCurrent(
  env: Env,
  key: string,
  stub: { restartIfOlder(caller: CodeVersion): Promise<unknown> },
): Promise<void> {
  if (checked.has(key)) return;
  checked.add(key);
  const { id, timestamp } = env.CF_VERSION_METADATA;
  try {
    await stub.restartIfOlder({ id, timestamp });
  } catch (error) {
    // Either the object restarted, or it predates this check and cannot restart itself (once, the first deploy).
    const message = error instanceof Error ? error.message : "";
    const kind = key === "directory" ? "directory" : "account";
    const outcome = message.includes("does not implement") ? "too old to restart itself" : "restarted for new code";
    console.log(JSON.stringify({ object: kind, outcome }));
  }
}
