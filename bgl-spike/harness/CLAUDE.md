# Harness scripts that call live BGL

These need a BGL app client ID/secret plus an interactive browser consent. Don't run them unless the user asks (see the root `CLAUDE.md` for the safety rules around writes).

- `Get-BglToken.ps1 -ClientId <id> [-TestAllStyles] [-ManualCode]` (T02/T03/T05): Authorization Code flow on `127.0.0.1:8765`, then tries four token-request styles (`BglDocumented`, `FormBody`, `FormBodyWithScope`, `FormBodyBasicAuth`).
- `Invoke-BglProbe.ps1 [-WriteTestContactId <id>] [-FinancialYear <yyyy>]` (T06/T13–T15): uses the saved token (refuses to run once it has expired) and makes about 15 calls. The write test asks for confirmation (`-Confirm:$false` skips it). It builds its PUT body from the fields BGL's PUT table allows for the contact's `contactType` (`ConvertTo-BglContactUpdate`), sends it as UTF-8 bytes, then compares the *whole* record before and after, ignoring `entityRelationships` order (`Compare-BglRecord`).
- `Send-BglTestWebhook.ps1 -Url <url> -Secret spike-test-secret -ClientCode spike [-Tamper All]`: webhook simulator.
