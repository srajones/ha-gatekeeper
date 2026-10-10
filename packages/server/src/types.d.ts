import "@fastify/secure-session";

declare module "@fastify/secure-session" {
  interface SessionData {
    admin?: boolean;
    pending2fa?: number;
    fails2fa?: number;
    totpSetup?: { secretEnc: string; at: number };
  }
}
