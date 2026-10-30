import type { PostConfirmationTriggerEvent } from "aws-lambda";
import { PutCommand } from "@aws-sdk/lib-dynamodb";
import { ddb, TABLE } from "./db";

/**
 * Writes the Cognito sub -> Firebase uid mapping for the owner.
 * The Firebase uid comes from deploy-time config, never from the client.
 */
export const handler = async (event: PostConfirmationTriggerEvent) => {
  const email = String(event.request.userAttributes?.email ?? "").toLowerCase();
  const sub = event.request.userAttributes?.sub;
  if (email === process.env.OWNER_EMAIL && sub) {
    await ddb.send(new PutCommand({
      TableName: TABLE,
      Item: { PK: `IDMAP#${sub}`, SK: "IDMAP", firebaseUid: process.env.OWNER_FIREBASE_UID, email, at: new Date().toISOString() },
    }));
  }
  return event;
};
