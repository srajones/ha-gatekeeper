// What "healthy" means for this server, and when it should give up and let Docker restart it.
//
// It must NOT depend on Home Assistant (an outage there is no reason to restart anything). It does depend on its
// own database, so two probes run against it:
//   read   a query that really reads the database file (not just SELECT 1, which never touches it)
//   write  a tiny upsert (catches a full disk, a read-only file system, a locked or damaged file)
// /healthz answers from a cheap read plus the result of the last write probe. The periodic self-check runs both;
// after `maxFailures` bad rounds in a row the process exits, and Docker (restart policy) starts a fresh one.

export type HealthDeps = {
  read: () => Promise<unknown>;
  write: () => Promise<unknown>;
  timeoutMs?: number;
};

function withTimeout<T>(job: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${ms} ms`)), ms);
  });
  return Promise.race([job, timeout]).finally(() => clearTimeout(timer));
}

export class DatabaseHealth {
  private writeOk = true;
  private writeError = "";
  consecutiveFailures = 0;

  constructor(private readonly deps: HealthDeps) {}

  private get timeoutMs(): number {
    return this.deps.timeoutMs ?? 3000;
  }

  // For /healthz: a fresh read, plus whether the last write probe worked.
  async quick(): Promise<{ ok: boolean; error?: string }> {
    try {
      await withTimeout(Promise.resolve().then(this.deps.read), this.timeoutMs, "database read");
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
    return this.writeOk ? { ok: true } : { ok: false, error: this.writeError };
  }

  // For the periodic self-check: read and write. Counts consecutive failures.
  async full(): Promise<{ ok: boolean; error?: string }> {
    let result: { ok: boolean; error?: string } = { ok: true };
    try {
      await withTimeout(Promise.resolve().then(this.deps.read), this.timeoutMs, "database read");
      await withTimeout(Promise.resolve().then(this.deps.write), this.timeoutMs, "database write");
      this.writeOk = true;
      this.writeError = "";
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.writeOk = false;
      this.writeError = message;
      result = { ok: false, error: message };
    }
    this.consecutiveFailures = result.ok ? 0 : this.consecutiveFailures + 1;
    return result;
  }
}
