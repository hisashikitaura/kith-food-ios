import type { APIGatewayProxyEventV2WithJWTAuthorizer, APIGatewayProxyResultV2 } from "aws-lambda";
import { randomBytes } from "crypto";
import { DeleteCommand, GetCommand, PutCommand, QueryCommand, UpdateCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, GetObjectCommand, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { BedrockRuntimeClient, ConverseCommand } from "@aws-sdk/client-bedrock-runtime";
import { ddb, TABLE, findMealItems } from "./db";
import { GENRES, HttpError, MEAL_ID, mealKey, photoKey, resolveUid, type JwtClaims } from "./common";

const s3 = new S3Client({});
const bedrock = new BedrockRuntimeClient({});
const BUCKET = process.env.BUCKET!;
const CLIENT_ID = process.env.CLIENT_ID!;
const MODEL_ID = process.env.MODEL_ID!;

const mapCache = new Map<string, string>();
async function lookupMapping(sub: string): Promise<string | undefined> {
  if (mapCache.has(sub)) return mapCache.get(sub);
  const r = await ddb.send(new GetCommand({ TableName: TABLE, Key: { PK: `IDMAP#${sub}`, SK: "IDMAP" } }));
  const uid = r.Item?.firebaseUid as string | undefined;
  if (uid) mapCache.set(sub, uid);
  return uid;
}

const json = (status: number, body: unknown): APIGatewayProxyResultV2 => ({
  statusCode: status,
  headers: { "content-type": "application/json", "cache-control": "no-store" },
  body: JSON.stringify(body),
});

const PUBLIC_FIELDS = ["id", "photoPath", "takenAt", "lat", "lng", "geohash", "placeName", "dish", "genre",
  "memo", "aiStatus", "aiConfidence", "aiComment", "aiAt", "createdAt", "origin", "syncVersion"];
function toPublic(it: Record<string, any>) {
  const o: Record<string, unknown> = {};
  for (const f of PUBLIC_FIELDS) if (it[f] !== undefined) o[f] = it[f];
  return o;
}

async function getMeal(uid: string, id: string) {
  if (!MEAL_ID.test(id)) throw new HttpError(400, "invalid id");
  const items = await findMealItems(uid, id);
  if (items.length === 0) throw new HttpError(404, "not found");
  return items.sort((a, b) => (b.syncVersion ?? 0) - (a.syncVersion ?? 0))[0];
}

const nowVersion = () => Date.now() * 1000;
const str = (v: unknown, max: number) => (typeof v === "string" ? v.slice(0, max) : undefined);
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

export async function route(uid: string, method: string, path: string, id: string | undefined, body: any) {
  // ---- list ----
  if (method === "GET" && path === "/meals") {
    const out: any[] = [];
    let start: any;
    do {
      const r = await ddb.send(new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
        ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":sk": "MEAL#" },
        ScanIndexForward: false,
        ExclusiveStartKey: start,
      }));
      out.push(...(r.Items ?? []).map(toPublic));
      start = r.LastEvaluatedKey;
    } while (start);
    return json(200, { meals: out });
  }
  // ---- create ----
  if (method === "POST" && path === "/meals") {
    const newId = randomBytes(15).toString("base64url");
    const takenAt = str(body?.takenAt, 40) && !Number.isNaN(Date.parse(body.takenAt))
      ? new Date(body.takenAt).toISOString() : new Date().toISOString();
    const lat = num(body?.lat), lng = num(body?.lng);
    const item = {
      ...mealKey(uid, takenAt, newId),
      id: newId, uid, photoPath: photoKey(uid, newId), takenAt,
      ...(lat !== undefined && lng !== undefined ? { lat, lng, geohash: str(body?.geohash, 16) } : {}),
      placeName: str(body?.placeName, 120) ?? "", dish: "", genre: "", memo: "",
      aiStatus: "pending", createdAt: new Date().toISOString(),
      origin: "aws", syncVersion: nowVersion(), awsUpdatedAt: new Date().toISOString(),
    };
    await ddb.send(new PutCommand({ TableName: TABLE, Item: item }));
    const uploadUrl = await getSignedUrl(s3, new PutObjectCommand({
      Bucket: BUCKET, Key: item.photoPath, ContentType: "image/jpeg",
    }), { expiresIn: 300 });
    return json(201, { meal: toPublic(item), uploadUrl });
  }
  if (!id) throw new HttpError(404, "not found");
  const meal = await getMeal(uid, id); // always scoped to PK=USER#<uid from token>

  if (method === "PATCH" && path === `/meals/${id}`) {
    const sets: string[] = [], vals: Record<string, unknown> = {};
    for (const [f, max] of [["dish", 80], ["placeName", 120], ["memo", 2000]] as const) {
      const v = str(body?.[f], max);
      if (v !== undefined) { sets.push(`${f} = :${f}`); vals[`:${f}`] = v; }
    }
    if (typeof body?.genre === "string" && (body.genre === "" || GENRES.includes(body.genre))) {
      sets.push("genre = :genre"); vals[":genre"] = body.genre;
    }
    sets.push("origin = :o", "syncVersion = :v", "awsUpdatedAt = :t");
    Object.assign(vals, { ":o": "aws", ":v": nowVersion(), ":t": new Date().toISOString() });
    const r = await ddb.send(new UpdateCommand({
      TableName: TABLE, Key: { PK: meal.PK, SK: meal.SK },
      UpdateExpression: "SET " + sets.join(", "), ExpressionAttributeValues: vals, ReturnValues: "ALL_NEW",
    }));
    return json(200, { meal: toPublic(r.Attributes ?? {}) });
  }
  if (method === "DELETE" && path === `/meals/${id}`) {
    await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: photoKey(uid, id) }));
    await ddb.send(new DeleteCommand({ TableName: TABLE, Key: { PK: meal.PK, SK: meal.SK } }));
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { PK: meal.PK, SK: `TOMB#${id}`, id, syncVersion: nowVersion(), origin: "aws",
        ttl: Math.floor(Date.now() / 1000) + 30 * 86400 },
    }));
    return json(204, {});
  }
  if (method === "GET" && path === `/meals/${id}/photo`) {
    const url = await getSignedUrl(s3, new GetObjectCommand({ Bucket: BUCKET, Key: photoKey(uid, id) }), { expiresIn: 600 });
    return json(200, { url });
  }
  if (method === "POST" && path === `/meals/${id}/upload-url`) {
    const url = await getSignedUrl(s3, new PutObjectCommand({
      Bucket: BUCKET, Key: photoKey(uid, id), ContentType: "image/jpeg",
    }), { expiresIn: 300 });
    return json(200, { url });
  }
  if (method === "POST" && path === `/meals/${id}/analyze`) {
    return analyze(uid, meal);
  }
  throw new HttpError(404, "not found");
}

async function analyze(uid: string, meal: Record<string, any>) {
  const setStatus = (extra: Record<string, unknown>) => {
    const keys = Object.keys(extra);
    return ddb.send(new UpdateCommand({
      TableName: TABLE, Key: { PK: meal.PK, SK: meal.SK },
      UpdateExpression: "SET " + keys.map((k) => `${k} = :${k}`).join(", ") + ", origin = :o, syncVersion = :v, awsUpdatedAt = :t",
      ExpressionAttributeValues: {
        ...Object.fromEntries(keys.map((k) => [`:${k}`, extra[k]])),
        ":o": "aws", ":v": nowVersion(), ":t": new Date().toISOString(),
      },
      ReturnValues: "ALL_NEW",
    }));
  };
  try {
    const obj = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: photoKey(uid, meal.id) }));
    const bytes = await obj.Body!.transformToByteArray();
    const res = await bedrock.send(new ConverseCommand({
      modelId: MODEL_ID,
      messages: [{
        role: "user",
        content: [
          { image: { format: "jpeg", source: { bytes } } },
          { text: `この料理の写真を見て、次のJSONだけを返してください。
{"dish":"料理名（短く）","genre":"${GENRES.join("|")} のどれか1つ","comment":"見た目の一言（40文字以内）","confidence":0〜1}
料理が写っていなければ dish は「不明」、genre は「その他」。` },
        ],
      }],
      inferenceConfig: { maxTokens: 300, temperature: 0.3 },
    }));
    const text = res.output?.message?.content?.map((c) => c.text ?? "").join("") ?? "";
    const m = text.match(/\{[\s\S]*\}/);
    const r = m ? JSON.parse(m[0]) : {};
    const genre = GENRES.includes(r.genre) ? r.genre : "その他";
    const out = await setStatus({
      dish: String(r.dish ?? "").slice(0, 80), genre,
      aiComment: String(r.comment ?? "").slice(0, 200),
      aiConfidence: Math.max(0, Math.min(1, Number(r.confidence) || 0)),
      aiStatus: "done", aiAt: new Date().toISOString(),
    });
    return json(200, { meal: toPublic(out.Attributes ?? {}) });
  } catch (e: any) {
    console.error("analyze failed", e?.name, e?.message);
    await setStatus({ aiStatus: "error" });
    // Graceful degradation: e.g. Bedrock model access not enabled for this account
    return json(503, { error: "ai_unavailable", message: "AWSモードのAI判定は現在利用できません（Bedrockのモデルアクセス未設定の可能性）" });
  }
}

export const handler = async (event: APIGatewayProxyEventV2WithJWTAuthorizer): Promise<APIGatewayProxyResultV2> => {
  try {
    const claims = event.requestContext.authorizer?.jwt?.claims as JwtClaims | undefined;
    const uid = await resolveUid(claims, CLIENT_ID, lookupMapping);
    const method = event.requestContext.http.method;
    const path = event.rawPath;
    const id = event.pathParameters?.id;
    let body: any = undefined;
    if (event.body) {
      const raw = event.isBase64Encoded ? Buffer.from(event.body, "base64").toString("utf8") : event.body;
      if (raw.length > 20000) throw new HttpError(413, "too large");
      body = JSON.parse(raw);
    }
    return await route(uid, method, path, id, body);
  } catch (e: any) {
    if (e instanceof HttpError) return json(e.status, { error: e.message });
    if (e instanceof SyntaxError) return json(400, { error: "bad json" });
    console.error(e);
    return json(500, { error: "internal" });
  }
};
