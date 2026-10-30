import type { SQSEvent, SQSBatchResponse } from "aws-lambda";
import { DeleteCommand, GetCommand, PutCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, TABLE, findMealItems } from "./db";
import { MEAL_ID, mealKey } from "./common";

/** Message sent by the GCP Cloud Function. version = Firestore updateTime in microseconds. */
export interface SyncMessage {
  op: "upsert" | "delete";
  uid: string;
  mealId: string;
  version: number;
  data?: Record<string, unknown>;
}

const MEAL_FIELDS = ["photoPath", "takenAt", "lat", "lng", "geohash", "placeName", "dish", "genre",
  "memo", "aiStatus", "aiConfidence", "aiComment", "aiAt", "createdAt"];

export async function apply(m: SyncMessage): Promise<string> {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(m.uid) || !MEAL_ID.test(m.mealId) || !Number.isFinite(m.version)) {
    return "invalid";
  }
  const pk = `USER#${m.uid}`;
  const tombKey = { PK: pk, SK: `TOMB#${m.mealId}` };
  const existing = await findMealItems(m.uid, m.mealId);
  const maxVer = Math.max(0, ...existing.map((e) => Number(e.syncVersion) || 0));
  if (m.version <= maxVer) return "stale";

  if (m.op === "delete") {
    for (const e of existing) {
      await ddb.send(new DeleteCommand({
        TableName: TABLE, Key: { PK: e.PK, SK: e.SK },
        ConditionExpression: "attribute_not_exists(PK) OR syncVersion < :v",
        ExpressionAttributeValues: { ":v": m.version },
      })).catch(ignoreConditional);
    }
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { ...tombKey, id: m.mealId, syncVersion: m.version, ttl: Math.floor(Date.now() / 1000) + 30 * 86400 },
    }));
    return "deleted";
  }

  const tomb = await ddb.send(new GetCommand({ TableName: TABLE, Key: tombKey }));
  if (tomb.Item && Number(tomb.Item.syncVersion) >= m.version) return "stale-after-delete";

  const d = m.data ?? {};
  const item: Record<string, unknown> = {};
  for (const f of MEAL_FIELDS) if (d[f] !== undefined && d[f] !== null) item[f] = d[f];
  const takenAt = typeof d.takenAt === "string" ? d.takenAt : new Date(0).toISOString();
  const key = mealKey(m.uid, takenAt, m.mealId);
  await ddb.send(new PutCommand({
    TableName: TABLE,
    Item: { ...key, ...item, id: m.mealId, uid: m.uid, syncVersion: m.version, origin: "gcp", syncedAt: new Date().toISOString() },
    ConditionExpression: "attribute_not_exists(PK) OR syncVersion < :v",
    ExpressionAttributeValues: { ":v": m.version },
  })).catch(ignoreConditional);
  // takenAt changed -> remove the item stored under the old sort key
  for (const e of existing) {
    if (e.SK !== key.SK) await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { PK: e.PK, SK: e.SK } }));
  }
  return "upserted";
}

function ignoreConditional(e: any) {
  if (e?.name !== "ConditionalCheckFailedException") throw e;
}

export const handler = async (event: SQSEvent): Promise<SQSBatchResponse> => {
  const failures: { itemIdentifier: string }[] = [];
  for (const r of event.Records) {
    try {
      const m = JSON.parse(r.body) as SyncMessage;
      const res = await apply(m);
      console.log(JSON.stringify({ op: m.op, mealId: m.mealId, version: m.version, res,
        lagMs: Date.now() - Number(r.attributes.SentTimestamp) }));
    } catch (e) {
      console.error("sync failed", r.messageId, e);
      failures.push({ itemIdentifier: r.messageId });
      // FIFO: stop processing the rest of the batch to keep ordering
      const idx = event.Records.indexOf(r);
      for (const rest of event.Records.slice(idx + 1)) failures.push({ itemIdentifier: rest.messageId });
      break;
    }
  }
  return { batchItemFailures: failures };
};
