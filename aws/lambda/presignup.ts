import type { PreSignUpTriggerEvent } from "aws-lambda";

/** Single-user allow-list: only the owner's Google account may be created. */
export const handler = async (event: PreSignUpTriggerEvent) => {
  const email = String(event.request.userAttributes?.email ?? "").toLowerCase();
  if (event.triggerSource !== "PreSignUp_ExternalProvider" || email !== process.env.OWNER_EMAIL) {
    throw new Error("Sign-up is not allowed");
  }
  return event;
};
