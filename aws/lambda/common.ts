/** Shared helpers. The user key is derived ONLY from verified JWT claims + server-side mapping. */

export class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export interface JwtClaims {
  sub?: string;
  token_use?: string;
  client_id?: string;
  [k: string]: unknown;
}

export type MappingLookup = (cognitoSub: string) => Promise<string | undefined>;

/**
 * Resolve the Firebase uid for this request.
 * - claims come from the API Gateway JWT authorizer (signature/issuer/audience already verified)
 * - request path/query/body are intentionally NOT inputs here (prevents BOLA)
 */
export async function resolveUid(
  claims: JwtClaims | undefined,
  expectedClientId: string,
  lookup: MappingLookup,
): Promise<string> {
  if (!claims || typeof claims.sub !== "string" || claims.sub.length === 0) {
    throw new HttpError(401, "unauthenticated");
  }
  if (claims.token_use !== "access" || claims.client_id !== expectedClientId) {
    throw new HttpError(401, "invalid token");
  }
  const uid = await lookup(claims.sub);
  if (!uid) throw new HttpError(403, "no mapping for this user");
  return uid;
}

export const MEAL_ID = /^[A-Za-z0-9_-]{1,64}$/;

export function mealKey(uid: string, takenAtIso: string, id: string) {
  return { PK: `USER#${uid}`, SK: `MEAL#${takenAtIso}#${id}` };
}

export function photoKey(uid: string, id: string) {
  return `users/${uid}/meals/${id}.jpg`;
}

export const GENRES = ["ラーメン", "寿司", "焼肉", "カレー", "中華", "イタリアン",
  "和食", "洋食", "カフェ・スイーツ", "その他"];
