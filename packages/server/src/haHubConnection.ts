import { WebSocket } from "undici";
import { RECV_TIMEOUT, type HubConnection } from "./haHub.js";

// The real websocket behind HubConnection. Frames are queued as they arrive and handed out one by
// one with a timeout, which is exactly the "recv with idle timeout" the hub loop is written against.
export function connectHaWebSocket(url: string, connectTimeoutMs = 10_000): Promise<HubConnection> {
  return new Promise<HubConnection>((resolve, reject) => {
    const ws = new WebSocket(url);
    const queue: string[] = [];
    let waiter: { resolve: (value: string | typeof RECV_TIMEOUT) => void; reject: (error: Error) => void; timer: NodeJS.Timeout } | null = null;
    let broken: Error | null = null;
    let opened = false;

    const fail = (error: Error) => {
      if (broken) {
        return;
      }
      broken = error;
      if (!opened) {
        clearTimeout(connectTimer);
        reject(error);
      }
      if (waiter) {
        clearTimeout(waiter.timer);
        const pending = waiter;
        waiter = null;
        pending.reject(error);
      }
    };

    const connectTimer = setTimeout(() => {
      try {
        ws.close();
      } catch {
        // not open yet
      }
      fail(new Error("connecting to Home Assistant timed out"));
    }, connectTimeoutMs);

    const connection: HubConnection = {
      recv(timeoutMs) {
        const next = queue.shift();
        if (next !== undefined) {
          return Promise.resolve(next);
        }
        if (broken) {
          return Promise.reject(broken);
        }
        return new Promise((res, rej) => {
          const timer = setTimeout(() => {
            waiter = null;
            res(RECV_TIMEOUT);
          }, timeoutMs);
          waiter = { resolve: res, reject: rej, timer };
        });
      },
      send(data) {
        if (broken || ws.readyState !== WebSocket.OPEN) {
          throw broken ?? new Error("the websocket is not open");
        }
        ws.send(data);
      },
      close() {
        try {
          ws.close();
        } catch {
          // already closed
        }
      }
    };

    ws.addEventListener("open", () => {
      opened = true;
      clearTimeout(connectTimer);
      resolve(connection);
    });
    ws.addEventListener("message", (event) => {
      const data = (event as { data?: unknown }).data;
      if (typeof data !== "string") {
        return; // Home Assistant speaks text frames only
      }
      if (waiter) {
        clearTimeout(waiter.timer);
        const pending = waiter;
        waiter = null;
        pending.resolve(data);
      } else {
        queue.push(data);
      }
    });
    ws.addEventListener("error", (event) => {
      const message = (event as { message?: unknown }).message;
      fail(new Error(typeof message === "string" && message ? message : "websocket error"));
    });
    ws.addEventListener("close", () => {
      fail(new Error("the websocket was closed"));
    });
  });
}
