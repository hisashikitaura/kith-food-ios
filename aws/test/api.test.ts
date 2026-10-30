import { test, mock } from "node:test";
import assert from "node:assert/strict";

process.env.TABLE = "t"; process.env.BUCKET = "b"; process.env.CLIENT_ID = "client-abc"; process.env.MODEL_ID = "m";

// Fake DynamoDB: records every key condition the handler uses.
const queried: string[] = [];
const items: Record<string, any>[] = [
  { PK: "USER#OWNER", SK: "MEAL#2026-01-01T00:00:00.000Z#m1", id: "m1", photoPath: "users/OWNER/meals/m1.jpg" },
  { PK: "USER#VICTIM", SK: "MEAL#2026-01-01T00:00:00.000Z#v1", id: "v1", photoPath: "users/VICTIM/meals/v1.jpg" },
  { PK: "IDMAP#owner-sub", SK: "IDMAP", firebaseUid: "OWNER" },
];

test("handler only ever reads PK of the uid mapped from the token (BOLA)", async () => {
  const db = await import("../lambda/db");
  mock.method(db.ddb, "send", async (cmd: any) => {
    const i = cmd.input;
    if (i.Key) return { Item: items.find((x) => x.PK === i.Key.PK && x.SK === i.Key.SK) };
    const pk = i.ExpressionAttributeValues[":pk"]; queried.push(pk);
    return { Items: items.filter((x) => x.PK === pk && (!i.ExpressionAttributeValues[":id"] || x.id === i.ExpressionAttributeValues[":id"])) };
  });
  const { handler } = await import("../lambda/api");
  const ev = (path: string, id?: string, sub = "owner-sub", qs?: Record<string, string>) => ({
    rawPath: path, pathParameters: id ? { id } : undefined, queryStringParameters: qs,
    requestContext: { http: { method: "GET" }, authorizer: { jwt: { claims: { sub, token_use: "access", client_id: "client-abc" } } } },
  }) as any;

  const list: any = await handler(ev("/meals", undefined, "owner-sub", { uid: "VICTIM" }));
  assert.equal(list.statusCode, 200);
  assert.deepEqual(JSON.parse(list.body).meals.map((m: any) => m.id), ["m1"]);

  // Victim's meal id with owner's token -> 404 (looked up under USER#OWNER only)
  const other: any = await handler(ev("/meals/v1/photo", "v1"));
  assert.equal(other.statusCode, 404);

  // Unknown cognito user -> 403
  const stranger: any = await handler(ev("/meals", undefined, "attacker-sub"));
  assert.equal(stranger.statusCode, 403);

  assert.ok(queried.every((pk) => pk === "USER#OWNER"), `queried: ${queried}`);
});
