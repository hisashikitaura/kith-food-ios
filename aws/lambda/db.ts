import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

export const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
  marshallOptions: { removeUndefinedValues: true },
});
export const TABLE = process.env.TABLE!;

/** All items for one meal id (normally 0 or 1; >1 only transiently if takenAt changed). */
export async function findMealItems(uid: string, id: string): Promise<Record<string, any>[]> {
  const out: Record<string, any>[] = [];
  let start: Record<string, any> | undefined;
  do {
    const r = await ddb.send(new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: "PK = :pk AND begins_with(SK, :sk)",
      FilterExpression: "id = :id",
      ExpressionAttributeValues: { ":pk": `USER#${uid}`, ":sk": "MEAL#", ":id": id },
      ExclusiveStartKey: start,
    }));
    out.push(...(r.Items ?? []));
    start = r.LastEvaluatedKey;
  } while (start);
  return out;
}
