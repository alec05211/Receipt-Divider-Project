import { createRemoteJWKSet, jwtVerify } from "jose";
import type { JWTVerifyGetKey } from "jose";
import type { Authenticator } from "./app.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function createSupabaseAuthenticator(projectUrl: string, suppliedKeys?: JWTVerifyGetKey): Authenticator {
  const baseUrl = new URL(projectUrl);
  if (baseUrl.protocol !== "https:") throw new Error("SUPABASE_URL must use HTTPS");
  const issuer = new URL("/auth/v1", baseUrl).toString().replace(/\/$/, "");
  const keys = suppliedKeys ?? createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));

  return async (context) => {
    const authorization = context.req.header("authorization") ?? "";
    const match = authorization.match(/^Bearer\s+(.+)$/i);
    if (!match) return null;

    try {
      const { payload } = await jwtVerify(match[1]!, keys, {
        issuer,
        audience: "authenticated",
        algorithms: ["ES256", "RS256"],
      });
      if (payload.role !== "authenticated" || typeof payload.sub !== "string" || !uuidPattern.test(payload.sub)) return null;
      return payload.sub;
    } catch {
      return null;
    }
  };
}
