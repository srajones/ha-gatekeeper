// Protects Home Assistant from the number of API keys in front of it.
//
// However many tokens exist and however often agents poll, Home Assistant sees:
//   - at most one state read per entity per cache window (reads of the same entity that arrive
//     together share one request),
//   - at most `maxConcurrent` requests in flight at any moment, with a bounded queue behind
//     them; when that queue is full or a request waits too long the caller gets "ha_busy"
//     (HTTP 503 + Retry-After) instead of piling more work onto Home Assistant.

export class HaBusyError extends Error {
  constructor() {
    super("ha_busy");
    this.name = "HaBusyError";
  }
}

type Waiter = { resolve: () => void; reject: (error: Error) => void; timer: NodeJS.Timeout };

export class ConcurrencyLimiter {
  private active = 0;
  private readonly queue: Waiter[] = [];

  constructor(
    private maxConcurrent: number,
    private maxQueue: number,
    private readonly maxWaitMs: number
  ) {}

  // Changes the limit while running (settings page). Waiters are let in if the limit went up.
  setLimits(maxConcurrent: number, maxQueue: number): void {
    this.maxConcurrent = maxConcurrent;
    this.maxQueue = maxQueue;
    while (this.queue.length > 0 && this.active < this.maxConcurrent) {
      const next = this.queue.shift();
      if (next) {
        clearTimeout(next.timer);
        this.active += 1;
        next.resolve();
      }
    }
  }

  async run<T>(fn: () => Promise<T>): Promise<T> {
    await this.acquire();
    try {
      return await fn();
    } finally {
      this.release();
    }
  }

  get inFlight(): number {
    return this.active;
  }

  get waiting(): number {
    return this.queue.length;
  }

  private acquire(): Promise<void> {
    if (this.active < this.maxConcurrent) {
      this.active += 1;
      return Promise.resolve();
    }
    if (this.queue.length >= this.maxQueue) {
      return Promise.reject(new HaBusyError());
    }
    return new Promise<void>((resolve, reject) => {
      const waiter: Waiter = {
        resolve,
        reject,
        timer: setTimeout(() => {
          const index = this.queue.indexOf(waiter);
          if (index >= 0) {
            this.queue.splice(index, 1);
          }
          reject(new HaBusyError());
        }, this.maxWaitMs)
      };
      this.queue.push(waiter);
    });
  }

  private release(): void {
    const next = this.queue.shift();
    if (next) {
      clearTimeout(next.timer);
      next.resolve(); // the slot passes straight to the next waiter
    } else {
      this.active -= 1;
    }
  }
}

type CacheEntry<T> = { value: T; expiresAt: number };

// Short-lived read cache with request coalescing. A `ttlMs` of 0 turns caching off (reads are
// still never duplicated while one is in flight).
export class CoalescingCache<T> {
  private readonly entries = new Map<string, CacheEntry<T>>();
  private readonly inflight = new Map<string, Promise<T>>();
  private generation = 0;

  constructor(
    private ttlMs: number,
    private readonly now: () => number = Date.now,
    private readonly maxEntries = 5000
  ) {}

  async get(key: string, load: () => Promise<T>, cacheable: (value: T) => boolean): Promise<T> {
    const hit = this.entries.get(key);
    if (hit && hit.expiresAt > this.now()) {
      return hit.value;
    }
    if (hit) {
      this.entries.delete(key);
    }

    const running = this.inflight.get(key);
    if (running) {
      return running;
    }

    const generation = this.generation;
    const promise: Promise<T> = load()
      .then((value) => {
        // A write that happened while this read was in flight makes its result stale: serve it
        // to the callers that were already waiting, but do not keep it.
        if (this.ttlMs > 0 && generation === this.generation && cacheable(value)) {
          this.store(key, value);
        }
        return value;
      })
      .finally(() => {
        if (this.inflight.get(key) === promise) {
          this.inflight.delete(key);
        }
      });
    this.inflight.set(key, promise);
    return promise;
  }

  setTtl(ttlMs: number): void {
    this.ttlMs = ttlMs;
    if (ttlMs <= 0) {
      this.entries.clear();
    }
  }

  // Forget everything (called after a service call: the next read must see its effect).
  invalidate(): void {
    this.generation += 1;
    this.entries.clear();
    this.inflight.clear();
  }

  get size(): number {
    return this.entries.size;
  }

  private store(key: string, value: T): void {
    if (this.entries.size >= this.maxEntries) {
      const oldest = this.entries.keys().next().value;
      if (oldest !== undefined) {
        this.entries.delete(oldest);
      }
    }
    this.entries.set(key, { value, expiresAt: this.now() + this.ttlMs });
  }
}
