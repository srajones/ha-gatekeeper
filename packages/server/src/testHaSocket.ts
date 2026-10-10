import crypto from "node:crypto";
import http from "node:http";
import type { Duplex } from "node:stream";

// A tiny Home Assistant look-alike for tests: the websocket handshake of /api/websocket
// (auth_required -> auth -> auth_ok), subscribe_entities with an initial full "a" event, change
// events on demand, ping/pong, and switches to go silent or drop connections. HTTP requests that are
// not upgrades are handed to `onRequest`. Not shipped logic: used only by tests.

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export type FakeState = { s: string; a?: Record<string, unknown>; lc?: number; lu?: number };

type Client = { socket: Duplex; subscribed: boolean; ids: string[]; id: number };

function frame(text: string): Buffer {
  const payload = Buffer.from(text);
  const length = payload.length;
  if (length < 126) {
    return Buffer.concat([Buffer.from([0x81, length]), payload]);
  }
  const header = Buffer.alloc(4);
  header[0] = 0x81;
  header[1] = 126;
  header.writeUInt16BE(length, 2);
  return Buffer.concat([header, payload]);
}

function* readFrames(buffer: Buffer): Generator<{ opcode: number; payload: Buffer; consumed: number }> {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const opcode = buffer[offset]! & 0x0f;
    const masked = (buffer[offset + 1]! & 0x80) !== 0;
    let length = buffer[offset + 1]! & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (buffer.length - cursor < 2) return;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    }
    const maskLength = masked ? 4 : 0;
    if (buffer.length - cursor < maskLength + length) return;
    const mask = masked ? buffer.subarray(cursor, cursor + 4) : null;
    cursor += maskLength;
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] = payload[i]! ^ mask[i % 4]!;
    }
    offset = cursor + length;
    yield { opcode, payload, consumed: offset };
  }
}

export class FakeHaServer {
  readonly server: http.Server;
  readonly states = new Map<string, FakeState>();
  readonly clients = new Set<Client>();
  connections = 0;
  subscriptions: string[][] = [];
  silent = false; // ignore everything the client sends: no pong, no events
  rejectAuth = false;
  private nextClientId = 1;

  constructor(private readonly token: string, onRequest?: http.RequestListener) {
    this.server = http.createServer(onRequest ?? ((_req, res) => { res.writeHead(404); res.end(); }));
    this.server.on("upgrade", (req, socket) => this.upgrade(req, socket));
  }

  async listen(): Promise<number> {
    await new Promise<void>((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    return (this.server.address() as { port: number }).port;
  }

  async close(): Promise<void> {
    this.dropConnections();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  dropConnections(): void {
    for (const client of this.clients) client.socket.destroy();
    this.clients.clear();
  }

  // Sends a "c" (changed) event for one entity to everybody subscribed to it.
  pushChange(entityId: string, plus: Record<string, unknown>, minus?: { a: string[] }): void {
    if (this.silent) return;
    const current = this.states.get(entityId);
    if (current) {
      if (typeof plus.s === "string") current.s = plus.s;
      if (plus.a && typeof plus.a === "object") current.a = { ...(current.a ?? {}), ...(plus.a as object) };
    }
    const delta: Record<string, unknown> = { "+": plus };
    if (minus) delta["-"] = minus;
    this.broadcast(entityId, { c: { [entityId]: delta } });
  }

  pushRemoved(entityId: string): void {
    this.broadcast(entityId, { r: [entityId] });
  }

  private broadcast(entityId: string, event: unknown): void {
    for (const client of this.clients) {
      if (client.subscribed && client.ids.includes(entityId)) {
        client.socket.write(frame(JSON.stringify({ id: 1, type: "event", event })));
      }
    }
  }

  private upgrade(req: http.IncomingMessage, socket: Duplex): void {
    const key = req.headers["sec-websocket-key"];
    if (req.url !== "/api/websocket" || typeof key !== "string") {
      socket.destroy();
      return;
    }
    const accept = crypto.createHash("sha1").update(key + GUID).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const client: Client = { socket, subscribed: false, ids: [], id: this.nextClientId++ };
    this.clients.add(client);
    this.connections += 1;
    socket.on("close", () => this.clients.delete(client));
    socket.on("error", () => this.clients.delete(client));
    socket.write(frame(JSON.stringify({ type: "auth_required", ha_version: "2026.9.0" })));

    let pending = Buffer.alloc(0);
    socket.on("data", (chunk: Buffer) => {
      pending = Buffer.concat([pending, chunk]);
      let consumed = 0;
      for (const f of readFrames(pending)) {
        consumed = f.consumed;
        if (f.opcode === 0x8) {
          socket.end();
          return;
        }
        if (f.opcode !== 0x1 || this.silent) continue;
        this.onMessage(client, f.payload.toString("utf8"));
      }
      pending = pending.subarray(consumed);
    });
  }

  private onMessage(client: Client, text: string): void {
    let message: { type?: string; id?: number; access_token?: string; entity_ids?: string[] };
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    const send = (value: unknown) => client.socket.write(frame(JSON.stringify(value)));
    if (message.type === "auth") {
      send({ type: !this.rejectAuth && message.access_token === this.token ? "auth_ok" : "auth_invalid", ha_version: "2026.9.0" });
    } else if (message.type === "subscribe_entities") {
      client.subscribed = true;
      client.ids = message.entity_ids ?? [];
      this.subscriptions.push(client.ids);
      send({ id: message.id, type: "result", success: true, result: null });
      const added: Record<string, FakeState> = {};
      for (const id of client.ids) {
        const state = this.states.get(id);
        if (state) added[id] = state;
      }
      send({ id: message.id, type: "event", event: { a: added } });
    } else if (message.type === "ping") {
      send({ id: message.id, type: "pong" });
    }
  }
}
