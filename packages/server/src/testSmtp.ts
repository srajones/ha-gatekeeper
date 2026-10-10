import net from "node:net";

// A minimal SMTP receiver for tests (plain text, no TLS): records the messages it is given. Used only by tests.
export type ReceivedMail = { from: string; to: string[]; data: string; user?: string; password?: string };

export class FakeSmtpServer {
  readonly mails: ReceivedMail[] = [];
  requireAuth = false;
  rejectAll = false;
  private readonly server: net.Server;

  constructor() {
    this.server = net.createServer((socket) => this.handle(socket));
  }

  async listen(): Promise<number> {
    await new Promise<void>((resolve) => this.server.listen(0, "127.0.0.1", resolve));
    return (this.server.address() as net.AddressInfo).port;
  }

  async close(): Promise<void> {
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  private handle(socket: net.Socket): void {
    const mail: ReceivedMail = { from: "", to: [], data: "" };
    let inData = false;
    let authStep: "none" | "user" | "pass" = "none";
    let buffer = "";
    const send = (line: string) => socket.write(line + "\r\n");
    send("220 fake.smtp ESMTP ready");
    socket.on("error", () => undefined);
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let index: number;
      while ((index = buffer.indexOf("\r\n")) >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 2);
        if (inData) {
          if (line === ".") {
            inData = false;
            if (this.rejectAll) {
              send("554 mailbox refused");
            } else {
              this.mails.push({ ...mail, to: [...mail.to] });
              send("250 queued");
            }
          } else {
            mail.data += (line.startsWith("..") ? line.slice(1) : line) + "\n";
          }
          continue;
        }
        if (authStep === "user") {
          mail.user = Buffer.from(line, "base64").toString();
          authStep = "pass";
          send("334 UGFzc3dvcmQ6");
          continue;
        }
        if (authStep === "pass") {
          mail.password = Buffer.from(line, "base64").toString();
          authStep = "none";
          send("235 authenticated");
          continue;
        }
        const upper = line.toUpperCase();
        if (upper.startsWith("EHLO") || upper.startsWith("HELO")) {
          socket.write("250-fake.smtp\r\n250-AUTH LOGIN PLAIN\r\n250 8BITMIME\r\n");
        } else if (upper.startsWith("AUTH LOGIN")) {
          authStep = "user";
          send("334 VXNlcm5hbWU6");
        } else if (upper.startsWith("AUTH PLAIN")) {
          const decoded = Buffer.from(line.split(" ")[2] ?? "", "base64").toString().split("\0");
          mail.user = decoded[1];
          mail.password = decoded[2];
          send("235 authenticated");
        } else if (upper.startsWith("MAIL FROM:")) {
          if (this.requireAuth && mail.user === undefined) {
            send("530 authentication required");
          } else {
            mail.from = /<([^>]*)>/.exec(line)?.[1] ?? "";
            send("250 ok");
          }
        } else if (upper.startsWith("RCPT TO:")) {
          mail.to.push(/<([^>]*)>/.exec(line)?.[1] ?? "");
          send("250 ok");
        } else if (upper === "DATA") {
          inData = true;
          send("354 go ahead");
        } else if (upper === "QUIT") {
          send("221 bye");
          socket.end();
        } else if (upper === "RSET") {
          mail.to = [];
          send("250 ok");
        } else {
          send("250 ok");
        }
      }
    });
  }
}
