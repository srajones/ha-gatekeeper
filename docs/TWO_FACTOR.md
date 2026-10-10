# Two-factor login (optional)

The dashboard login can ask for a second factor: a 6-digit code from an authenticator app on your phone, on top of
the admin password. A stolen, leaked or guessed password is then not enough to open the dashboard.

It is **off until you turn it on**, and it protects the **dashboard only**. API keys are separate: they are
long random secrets that never go through the login.

Not used in the Home Assistant add-on: there, sign-in is handled by Home Assistant. Turn on multi-factor
authentication in your Home Assistant profile instead.

## Turning it on

1. Open the dashboard, tab **Security**, press **Set up two-factor login**.
2. Confirm your admin password.
3. In your authenticator app (Google Authenticator, Aegis, 1Password, Bitwarden, Authy, ...) add an account and
   enter the **setup key** shown (or open the link on your phone). Type: time-based, 6 digits, 30 seconds.
4. Type the code the app shows. If it is right, two-factor login is on and **10 recovery codes** are shown.
5. **Save the recovery codes** (password manager or print them). They are shown once, and each works one time.

## Signing in

Password first, then the code. A recovery code can be typed in the same box instead of the 6-digit code (letters
only, dashes optional, `0` and `1` are read as the letters `O` and `I`).

## Managing it

On the Security tab, with your password and a current code (or a recovery code):

- **Make new recovery codes**: the old ones stop working immediately.
- **Turn off two-factor login**.

## Lost your phone and your recovery codes

Someone with command-line access to the server can switch it off (the password still applies):

```bash
sudo gatekeeper 2fa-reset
```

That is the whole recovery path, on purpose: whoever can run it already controls the server and can read `.env`.
Then sign in with the password and set it up again.

## How it is protected

| Concern | What happens |
| --- | --- |
| Stored secret | Encrypted in the database (AES-256-GCM) with a key derived from `ADMIN_SESSION_SECRET`. A copy of the database alone does not give an attacker the secret. |
| Recovery codes | Only keyed hashes (HMAC-SHA-256) are stored; a code works once. |
| Replay | A code that was used (or an older one) is refused, so a sniffed code is useless. One 30-second step either side is accepted for clock drift. |
| Guessing | 5 wrong codes throw the half-finished login away (password needed again); 10 wrong codes from anywhere pause every attempt for up to 15 minutes; the login routes are also rate limited per address. |
| Half-finished login | After the password the session is **not** an admin session. Every admin route stays closed until the code is accepted, and the password step expires after 5 minutes. |
| Changing the settings | Turning it off, making new recovery codes and starting a setup all need the password again (and, for off / new codes, a current code), so a stolen session cannot weaken it. |
| Audit | Password step, code step, enable, disable, new recovery codes and recovery-code use are written to the Activity log. Codes and secrets never are. |
| Fails closed | If the saved secret cannot be read (for example `ADMIN_SESSION_SECRET` was changed, or the row is damaged), the login stays closed and says so. Run `sudo gatekeeper 2fa-reset`. Do not rotate `ADMIN_SESSION_SECRET` casually while two-factor is on. |
| Backups | The two-factor state lives in the database, so it is in backups and comes back on restore; it is encrypted with the same secret as above. |

## For the curious: the API

`POST /admin/login` answers `{"ok":true,"needs2fa":true}` when the password was right but a code is still owed;
then `POST /admin/login/2fa {"code":"123456"}`. `GET /admin/me` reports `twoFactorPending`.
Management: `GET /admin/2fa`, `POST /admin/2fa/setup`, `/enable`, `/disable`, `/recovery-codes`.
