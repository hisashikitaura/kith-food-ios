import { test } from "node:test";
import assert from "node:assert/strict";
import { resolveUid, HttpError } from "../lambda/common";

const CLIENT = "client-abc";
const mapping: Record<string, string> = { "owner-sub": "FIREBASE_OWNER_UID" };
const lookup = async (sub: string) => mapping[sub];
const tok = (sub: string, extra: Record<string, unknown> = {}) =>
  ({ sub, token_use: "access", client_id: CLIENT, ...extra });

test("owner token resolves to mapped firebase uid", async () => {
  assert.equal(await resolveUid(tok("owner-sub"), CLIENT, lookup), "FIREBASE_OWNER_UID");
});

test("another user's valid token without mapping is rejected (403)", async () => {
  await assert.rejects(resolveUid(tok("attacker-sub"), CLIENT, lookup),
    (e: unknown) => e instanceof HttpError && e.status === 403);
});

test("claims that try to smuggle a uid are ignored", async () => {
  const uid = await resolveUid(tok("owner-sub", { uid: "VICTIM", firebaseUid: "VICTIM", "custom:uid": "VICTIM" }), CLIENT, lookup);
  assert.equal(uid, "FIREBASE_OWNER_UID");
  await assert.rejects(resolveUid(tok("attacker-sub", { firebaseUid: "FIREBASE_OWNER_UID" }), CLIENT, lookup),
    (e: unknown) => e instanceof HttpError && e.status === 403);
});

test("id token / other app client / missing claims are rejected (401)", async () => {
  for (const c of [undefined, {}, tok("owner-sub", { token_use: "id" }), tok("owner-sub", { client_id: "other" })]) {
    await assert.rejects(resolveUid(c as any, CLIENT, lookup),
      (e: unknown) => e instanceof HttpError && e.status === 401);
  }
});
