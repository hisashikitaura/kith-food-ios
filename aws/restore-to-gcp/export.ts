/**
 * restore-to-gcp (simple version): export changes made in AWS mode so they can be put back into Firestore.
 *
 *   AWS_PROFILE=kith npx tsx restore-to-gcp/export.ts <TableName> <FirebaseUid> [out.json]
 *
 * Output: meals with origin="aws" (created/edited/AI-analyzed in AWS mode) and AWS-side deletions (tombstones).
 * Photos for AWS-created meals are in S3 under users/<uid>/meals/<id>.jpg (download with `aws s3 cp`).
 *
 * TODO: import step (write to Firestore users/<uid>/meals/<id> + upload photos to Cloud Storage)
 *       using firebase-admin with a short-lived login. Not automated yet on purpose: in a BCP
 *       situation a human should review the export before writing back to the primary.
 */
import { writeFileSync } from "fs";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

async function main() {
  const [table, uid, out = "aws-only-changes.export.json"] = process.argv.slice(2);
  if (!table || !uid) throw new Error("usage: export.ts <TableName> <FirebaseUid> [out.json]");
  const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: process.env.AWS_REGION ?? "ap-northeast-1" }));
  const items: Record<string, any>[] = [];
  let start: any;
  do {
    const r = await ddb.send(new QueryCommand({
      TableName: table, KeyConditionExpression: "PK = :pk",
      ExpressionAttributeValues: { ":pk": `USER#${uid}` }, ExclusiveStartKey: start,
    }));
    items.push(...(r.Items ?? []));
    start = r.LastEvaluatedKey;
  } while (start);
  const changed = items.filter((i) => i.origin === "aws");
  const result = {
    exportedAt: new Date().toISOString(),
    uid,
    upserts: changed.filter((i) => String(i.SK).startsWith("MEAL#")),
    deletes: changed.filter((i) => String(i.SK).startsWith("TOMB#")).map((i) => i.id),
  };
  writeFileSync(out, JSON.stringify(result, null, 2));
  console.log(`upserts=${result.upserts.length} deletes=${result.deletes.length} -> ${out}`);
}
main().catch((e) => { console.error(e); process.exit(1); });
