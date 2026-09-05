---
status: accepted
---

# Xiaomi Cloud login: username/password, not QR

The original Xiaomi Cloud onboarding used `QrCodeXiaomiCloudConnector`'s QR flow specifically so the app would never see the account password — auth happened entirely on Xiaomi's side, and the app only long-polled for the result. We replaced it with `PasswordXiaomiCloudConnector`'s username/password flow (with captcha and emailed-2FA support), ported from the same reference tool.

This is a conscious trade-off, not an oversight: the QR flow depended on a second device (or an in-app `SFSafariViewController` kept alive for a fragile long-poll) and left the user waiting on Xiaomi's confirmation with no direct control. Password login is more direct and self-contained, at the cost of the password passing through the app's process memory during the login call (never persisted, never logged — used once to compute the request's MD5 hash and build the login POST). We chose directness over that previously-load-bearing privacy property.
