export const PBKDF2_ITERATIONS = 100_000;

export function bytesToBase64(bytes: Uint8Array): string {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text);
}

export function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

export function base64url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function timingSafeEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let diff = 0;
  for (let index = 0; index < left.length; index += 1) diff |= left[index] ^ right[index];
  return diff === 0;
}

export async function sameSecret(left: string, right: string): Promise<boolean> {
  const [a, b] = await Promise.all([sha256Hex(left), sha256Hex(right)]);
  return timingSafeEqual(new TextEncoder().encode(a), new TextEncoder().encode(b));
}

export async function hashPassword(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

const DUMMY_SALT = new Uint8Array(16).fill(7);

/** Spend a hash even when the username is missing, so the two answers take similar time. */
export async function dummyHash(password: string): Promise<void> {
  await hashPassword(password, DUMMY_SALT, PBKDF2_ITERATIONS);
}
