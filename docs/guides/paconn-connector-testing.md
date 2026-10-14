# Testing a custom connector with paconn

A reusable guide to checking a Power Platform custom connector definition (`apiDefinition.swagger.json` + `apiProperties.json`) with `paconn`, the Power Platform Connectors CLI. It's written for any connector project, not one API.

**What was verified, and how.** Everything marked *verified* was run on 14 Oct 2026, with paconn 0.0.21 on Python 3.14 (macOS), against a real 133-operation connector definition. Everything marked *from the docs* comes from `paconn --help` or Microsoft Learn and wasn't exercised. Re-check both with your paconn version.

## Contents

1. [What paconn is for](#1-what-paconn-is-for)
2. [Install](#2-install)
3. [Sign in](#3-sign-in)
4. [Validate a definition](#4-validate-a-definition)
5. [Read the results](#5-read-the-results)
6. [Check what the validator misses](#6-check-what-the-validator-misses)
7. [Create, update and download connectors](#7-create-update-and-download-connectors)
8. [Test the deployed connector](#8-test-the-deployed-connector)
9. [Security](#9-security)
10. [Troubleshooting](#10-troubleshooting)
11. [Checklist](#11-checklist)
12. [Where this guidance comes from](#12-where-this-guidance-comes-from)

---

## 1. What paconn is for

| Command | What it does |
|---|---|
| `paconn login` / `logout` | Device-code sign-in to Power Platform; logout deletes the saved token |
| `paconn validate` | Sends the definition to Power Platform's `validateApiSwagger` endpoint, **always with certification rules on** (see §4) |
| `paconn create` / `update` | Creates or updates a custom connector from local files; accepts `--secret` for an OAuth client secret |
| `paconn download` | Downloads an existing custom connector's files |

`pac` (the Power Platform CLI) can also create and update connectors (`pac connector create/update`), and works with solutions (`--solution-unique-name`). It has **no validate command** and **no `--secret` option** (*from the docs*: Microsoft Learn "pac connector"). Use paconn for validation, and either tool to deploy.

**Status.** paconn 0.0.21 depends on `adal`, Microsoft's retired sign-in library. It still signed in and validated successfully (*verified*), but expect it to break eventually. If it does, the fallback for checking a definition is importing it in the maker portal (Custom connectors → Import an OpenAPI file).

## 2. Install

Use an isolated virtual environment; paconn pulls in old versions of several packages.

```bash
python3 -m venv .paconn-venv
.paconn-venv/bin/pip install paconn
.paconn-venv/bin/paconn --help
```

- A pip warning that `pylint` has "an invalid Requires-Python" is harmless (*verified*).
- Keep the virtual environment out of git (e.g. add `.paconn-venv/` to `.gitignore`).

## 3. Sign in

```bash
paconn login            # device code: open https://login.microsoft.com/device and enter the code shown
paconn logout           # deletes the saved token
```

Options (*from `paconn login --help`*): `--tenant/-t`, `--clid/-i` (client ID), `--authority_url/-a`, `--resource/-r`, `--force/-f` (sign in again even if a token exists), `--settings/-s`.

**Running it outside a real terminal** (an agent's shell tool, a `!` command in Claude Code, CI, or a pipe) needs care. Python buffers paconn's "enter the code" line until the process exits, which is after the code has expired. The symptom is a long silence followed by `AdalError: Unexpected polling state code_expired` (*verified*). Use unbuffered output:

```bash
PYTHONUNBUFFERED=1 paconn login > paconn-login.log 2>&1 &
# then read the code from paconn-login.log straight away; it's only valid for a limited time
```

**Token lifetime** (*verified from paconn 0.0.21 source and the saved token*):
- The token is saved in `~/.paconn/accessTokens.json`, readable only by your user account (mode 0600). It holds an access token **and a refresh token**.
- The access token lasted about 65 minutes (`expires_in` 3913). paconn treats it as expired 10 minutes early and **never uses the refresh token**.
- After about 55 minutes every command fails with `Access token invalid. Please login again.`; run `paconn login` again.

## 4. Validate a definition

### 4.1 `paconn validate`: certification mode only

```bash
paconn validate --api-def apiDefinition.swagger.json
```

- paconn 0.0.21 always sends `enableConnectorCertificationRules=true` (*verified in its source*, `paconn/operations/validate.py`). So this checks the rules for connectors Microsoft certifies and publishes.
- Those rules demand things a private custom connector doesn't need, such as a `description` on every operation and parameter, and `info.contact`. A perfectly usable private connector can fail it with many errors (*verified*: 100 errors on a definition that's fine to import privately).
- It exits 1 and prints a JSON error body when validation fails (*verified*).
- Some certification errors have **no location**, for example `Error : The 'x-ms-connector-metadata' property is required.` An earlier version of `validate_connector.py` (§4.2) only parsed `Error : <location> : <text>`. It skipped those errors and reported "0 errors" next to an HTTP 400 (*verified* 14 Oct 2026, paconn 0.0.21, on a 13-operation definition). The version below counts them. If any tool reports HTTP 400 with no errors, read the raw message.

### 4.2 Validate with certification rules off

The `validateApiSwagger` endpoint accepts the flag either way; paconn just doesn't expose it. This script makes the same call with paconn's sign-in, so you can choose. Save it as `validate_connector.py` and run it with paconn's Python (*verified* both ways).

```python
"""Validate a custom connector definition with Power Platform's validator.

`paconn validate` always applies the connector *certification* rules. This script calls the same
validateApiSwagger endpoint and lets you choose: the default checks what a private custom connector
needs; --certification adds the certification rules (what `paconn validate` reports).

Usage:  python validate_connector.py apiDefinition.swagger.json [--certification]
Needs:  pip install paconn, and a current `paconn login` (this reuses its token).
Exit:   0 when there are no errors (warnings are printed but allowed), 1 otherwise.
"""
import argparse, json, re, sys

import requests
from paconn import _VALIDATE
from paconn.settings.settingsbuilder import SettingsBuilder
from paconn.settings.util import load_powerapps_and_flow_rp


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('api_def', help='path to apiDefinition.swagger.json')
    ap.add_argument('--certification', action='store_true', help='also apply the certification rules')
    a = ap.parse_args()

    with open(a.api_def, encoding='utf-8-sig') as f:
        definition = json.load(f)
    settings = SettingsBuilder.get_settings(
        environment=None, settings_file=None, api_properties=None, api_definition=a.api_def, icon=None,
        script=None, connector_id=None, powerapps_url=None, powerapps_version=None)
    rp, _ = load_powerapps_and_flow_rp(settings=settings, command_context=_VALIDATE)   # raises if not logged in

    api = rp.api_manager
    url = api.construct_url(path=api.add_object_id('validateApiSwagger'),
                            query={'enableConnectorCertificationRules': 'true'} if a.certification else None)
    headers = {'Authorization': f"{api.credentials['token_type']} {api.credentials['access_token']}",
               **(rp.rp_headers or {})}
    response = requests.post(url, json=definition, headers=headers, timeout=120)

    try:
        body = response.json()
    except ValueError:
        body = response.text
    message = body.get('error', {}).get('message', '') if isinstance(body, dict) else str(body or '')
    # Most findings are "Error : <location> : <text>", but some have no location, e.g.
    # "Error : The 'x-ms-connector-metadata' property is required." The location group is optional so
    # those are counted too.
    findings = re.findall(r'(Error|Warning) : (?:(\S+) : )?(.+?)(?=\r?\n(?:Error|Warning) : |\Z)', message, re.S)

    mode = 'with certification rules' if a.certification else 'custom connector rules only'
    errors = [f for f in findings if f[0] == 'Error']
    for kind, location, text in findings:
        print(f'{kind.upper():7} {location or "(definition)"}\n        {text.strip()}')
    if response.status_code >= 400 and not findings:
        print(f'HTTP {response.status_code}: {message or response.text}')
    print(f'\n{a.api_def} ({mode}): {len(errors)} errors, {len(findings) - len(errors)} warnings, '
          f'HTTP {response.status_code}')
    return 1 if errors or response.status_code >= 400 else 0


if __name__ == '__main__':
    sys.exit(main())
```

```bash
.paconn-venv/bin/python validate_connector.py apiDefinition.swagger.json                  # private connector
.paconn-venv/bin/python validate_connector.py apiDefinition.swagger.json --certification  # same as paconn validate
```

- **Fragile by design:** the script relies on paconn's internals (`_VALIDATE`, `load_powerapps_and_flow_rp`, `api_manager`), so it may need adjusting for other paconn versions.
- **What the certification-off result does and doesn't mean:** it shows Power Platform accepts the definition, not that it follows Microsoft's rules. It's **lenient**: in a test it passed a schema on a `default` response and a form-data parameter on a `GET`, both of which Microsoft's rules page lists as errors (*verified*). Whether importing in the maker portal applies more checks wasn't tested.

### 4.3 Get past the first stage before trusting the results

The validator reports **in stages** (*verified*). While required properties are missing, it lists only those (plus format errors such as `'Multi' is not supported`) and says "Please validate again after fixing following errors". Rules from later stages don't appear until then. In testing:
- a planted DefaultResponseHasSchema error, and an OperationHasManyResponsesWithSchema warning, only appeared in the second stage;
- PartialDuplicateOperationPath warnings went from 9 to 25.

To see the later stages without writing real descriptions first, validate a throwaway **probe copy** (*verified*):

```python
"""Make a throwaway copy of a connector definition that gets past the validator's first stage.

Fills placeholder descriptions, x-ms-summary, info.contact and x-ms-connector-metadata, and replaces
collectionFormat 'multi',
so a certification-mode validation reports the rules it checks in later stages. Never deploy the copy.

Usage:  python probe_copy.py apiDefinition.swagger.json probe.swagger.json
"""
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8-sig') as f:
    spec = json.load(f)
spec['info'].setdefault('contact', {'name': 'Probe', 'url': 'https://example.com', 'email': 'probe@example.com'})
spec.setdefault('x-ms-connector-metadata', [
    {'propertyName': 'Website', 'propertyValue': 'https://example.com'},
    {'propertyName': 'Privacy policy', 'propertyValue': 'https://example.com/privacy'},
    {'propertyName': 'Categories', 'propertyValue': 'Productivity'}])
for ops in spec['paths'].values():
    for op in ops.values():
        if not isinstance(op, dict) or 'responses' not in op: continue   # skip path-level parameters
        op.setdefault('description', 'Probe description.')
        for p in op.get('parameters', []):
            p.setdefault('description', 'Probe parameter description.')
            p.setdefault('x-ms-summary', p.get('name', 'Probe'))
            if p.get('collectionFormat') == 'multi':
                p['collectionFormat'] = 'csv'
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(spec, f, indent=2)
print(f'wrote {dst} (probe copy: do not deploy)')
```

```bash
python probe_copy.py apiDefinition.swagger.json probe.swagger.json
.paconn-venv/bin/python validate_connector.py probe.swagger.json --certification
```

Errors left in the probe run are real rule problems. Fix them in the real definition (or its generator), never by deploying the probe.

### 4.4 Recommended sequence

1. A local generic check (e.g. `openapi-spec-validator`) for Swagger 2.0 structure. It doesn't know Power Platform's rules.
2. `validate_connector.py` without `--certification`: does Power Platform accept it?
3. A probe copy with `--certification`: does it follow Power Platform's rules beyond stage one?
4. `paconn validate`, only if the connector is going to Microsoft for certification.
5. Deploy to a test environment and exercise it (§8). None of the above checks runtime behaviour.

## 5. Read the results

Each finding has a level (`Error`/`Warning`), a JSON-pointer location and a message. In locations, `~1` means `/` (`paths/~1core~1v1~1clients/get` is `GET /core/v1/clients`).

Findings seen in testing (*verified*):

| Message | Mode | Stage | Meaning / fix |
|---|---|---|---|
| `The 'description' property is required.` | certification | 1 | Add operation and parameter descriptions (not needed for a private connector) |
| `The 'contact' property is required.` | certification | 1 | Add `info.contact` (name, url, email) |
| `The 'x-ms-summary' property is required.` | certification | 1 | Give every parameter a display label |
| `The 'collectionFormat' keyword value 'Multi' is not supported.` | certification | 1 | Use `csv`, omit `collectionFormat`, or a single value; all three passed. `multi` passed without certification. |
| `The 'default' response should not have schema definition.` | certification | 2 | Remove the schema from `default` |
| `…has more than one response with specified schema…` (warning) | certification | 2 | Keep one success-response schema |
| `…path template … is similar to other operation path templates…` (warning) | certification | 1–2 | e.g. `/items/{id}` next to `/items/detailed`; usually the API's design, safe to accept |
| `The 'x-ms-connector-metadata' property is required.` (no location) | certification | 2 | Add top-level `x-ms-connector-metadata`: `propertyName`/`propertyValue` pairs for `Website`, `Privacy policy` and `Categories` (format as in Microsoft's certified connectors). Certification only. |
| `Encoding for path parameter '<name>' is missing, which might lead to invalid requests. Use "x-ms-url-encoding": "single"…` (warning) | certification | 1 | Add `"x-ms-url-encoding": "single"` to every `in: path` parameter. Not reported with certification rules off. |

- **Accepted in both modes:** `format: uuid`.
- **Not flagged in any mode tested:** form data on a `GET`, even though Microsoft lists it as BodyOrFormDataParameterInFetchOperationNotAllowed.

The full rule list is Microsoft Learn's [Fix Swagger Validator errors](https://learn.microsoft.com/connectors/custom-connectors/certification-swagger-validator-rules). It documents the rules but not which mode or stage enforces each.

## 6. Check what the validator misses

A clean validation doesn't mean a good connector. In testing:
- openapi-spec-validator passed definitions that break Power Platform's rules;
- Power Platform's own validator passed some of them too, either in certification-off mode or at every stage tested.

Build these checks into whatever produces the definition (a generator with tests, or a review checklist for hand-written files). Each item below says how far the service enforced it (*verified* 14 Oct 2026 unless marked).

### 6.1 Validate the real thing

- **Check against the real API description and the real generated definition, not samples.** Running a generator on the vendor's actual collection surfaced every deployment-blocking defect that reading the code had missed: invalid Swagger, silently dropped operations, unresolved `{{variables}}`, and types inferred as strings. It also disproved review claims made from the code alone.
- **Turn each real-data defect into a small automated test,** so it stays fixed without needing the vendor's file.
- **Re-measure counts and sizes from the output.** For example, the warning count changed from 9 to 25 once past stage one; don't carry numbers over from an earlier run.

### 6.2 Responses

- **Only one response should carry a schema:** the success response. No schema on `default` (DefaultResponseHasSchema), and not several responses with schemas (OperationHasManyResponsesWithSchema). openapi-spec-validator accepts both. Power Platform reported them only in certification mode, at stage 2. The designer uses one schema anyway.
- **Error bodies stay untyped as a result.** In flows, read them from the failed action's outputs, e.g. `outputs('Get_item')?['body/detail']`.
- **Flag operations with no usable success example.** They'd produce untyped output with nothing in dynamic content. Write a schema from the API's documentation or observed responses, never invent fields.

### 6.3 Parameters and bodies

- **Bodies only on POST, PUT, PATCH (and DELETE).** Microsoft's BodyOrFormDataParameterInFetchOperationNotAllowed rule forbids bodies on fetch operations (GET). In testing, **neither validator mode flagged form data on a GET**, so check it yourself. Don't widen the rule: Microsoft's docs say nothing against DELETE bodies.
- **`connectionId` is a reserved parameter name** (ConnectionIdParameterNotAllowed). openapi-spec-validator accepts it. Drop the parameter, or skip the request if it's in the path.
- **Mark required parameters as required.** Some vendors record requiredness only in description text, e.g. a "(Required)" prefix in Postman collections, which have no required flag for query parameters. Otherwise flow makers find out from a 400 at runtime.
- **List-valued query filters** (`?Id=a&Id=b`) need one array parameter. Repeating the parameter makes the Swagger invalid.
  - `collectionFormat: multi` passed Power Platform's validator with certification rules off, but fails certification ("'Multi' is not supported"); `csv`, no format, or a single value pass.
  - Whether Power Platform sends `multi` as repeated keys at runtime is **untested**; check it in §8.
- **Types:** `format: uuid` is accepted. If examples are typed placeholders such as `"<boolean>"` or `<uuid>`, map them to real types; read literally, every field becomes a string.
- **Keep parameter `name`s exactly as the API spells them.** Only change display labels (`x-ms-summary`). Watch for vendors whose areas differ in casing (`PageSize` in one API, `pageSize` in another): match names case-insensitively when applying rules, and copy names from the action in flows.
- **Never let environment or test values reach paths.** Resolving every `{{variable}}` in a Postman URL hard-wires an action to the tester's record and copies that ID into a shareable definition. Resolve only the leading `{{base_url}}`.

### 6.4 Paths, hosts and size

- **One host per connector.** Requests to a second host would be silently sent to the first one; skip them or build a separate connector.
- **Paths that differ only in letter case** are rejected (PathRedefined; *from the docs*, not tested against the service).
- **`/items/{id}` next to `/items/detailed`** gives PartialDuplicateOperationPath warnings. These are usually the API's design and safe to accept.
- **Size and count limits** (*from the docs*): the definition must be under 1 MB (indentation alone can push it over, so write compact JSON if needed), and Logic Apps allows at most 256 operations.

### 6.5 Text that users see

- **Action `summary`:** sentence case, no `/`, at most 80 characters, and no trailing punctuation (*from Microsoft's string guidance*; whether the validator enforces this wasn't tested). Postman request names like "Create a Client Entity." or "List documents (minimal)" need cleaning. Don't just strip punctuation, or "(minimal)" becomes "(minimal".
- **Display labels (`x-ms-summary`):** Title Case, with spaces between words and acronyms kept (`clientID` → "Client ID"). Certification requires one on every parameter.
- **Connector title:** at most 30 characters. Connector metadata URLs (website, privacy policy) must be absolute (UrlNotValid; openapi-spec-validator doesn't check them).

### 6.6 Security definition and connection

- **OAuth 2.0 connectors need `"redirectMode": "GlobalPerConnector"`.** Register the Redirect URL shown on the connector's Security tab (`https://global.consent.azure-apim.net/redirect/<connector-id>`). The shared `…/redirect` URL stopped working for new connections (*from the docs*: Microsoft Learn custom connectors overview).
- **Require `https` for authorization and token URLs,** and request the scope that grants refresh tokens (often `offline_access`), or connections will expire.
- **Check the identity provider's flow before building.** Custom connectors use the authorization code flow, and Microsoft's docs say the client credentials grant isn't supported. PKCE isn't documented for Generic OAuth 2, so if the vendor requires PKCE or client credentials, confirm with them early that a client-secret integration is possible.
- **`pac connector create` has no `--secret`.** Enter the secret on the Security tab, or use `paconn create --secret` (see §9 on shell history).

### 6.7 Keep claims to what the docs say

When turning a Microsoft rule or limit into a check, a warning or documentation:
- scope it to exactly what the cited page says, and quote the rule name;
- mark anything wider as unverified.

Twice in the source project a rule was stated more broadly than Microsoft documents it, and both times it had to be corrected:
- "only POST/PUT/PATCH may have bodies" (the rule only covers GET);
- "Apply to each exceeds the concurrency limit by default" (its default is 1).

Record the date and tool versions alongside validation results, as this guide does.

## 7. Create, update and download connectors

*From `paconn --help` and Microsoft Learn's [paconn CLI article](https://learn.microsoft.com/connectors/custom-connectors/paconn-cli); not exercised in this project.*

```bash
paconn create --api-def apiDefinition.swagger.json --api-prop apiProperties.json \
              --env <environment-guid> [--icon icon.png] [--script script.csx] [--secret <oauth-client-secret>]
paconn update --api-def apiDefinition.swagger.json --api-prop apiProperties.json \
              --env <environment-guid> --cid <connector-id> [--secret <oauth-client-secret>]
paconn download --env <environment-guid> --cid <connector-id> [--dest <folder>]
```

- **Always pass `--env`** (and `--cid` for update and download). Otherwise paconn prompts interactively for them (*verified in its source*), which hangs in scripts and CI.
- **`create` prints the new connector ID.** Per Microsoft's docs, `download` writes the connector files plus a `settings.json` into a subfolder named after the connector ID, and `--settings settings.json` can replace the individual arguments for later commands.
- **Test environment first:** create the connector in a test environment, check it, then repeat in production.
- **OAuth connectors:** after `create`, copy the connector's per-connector Redirect URL from its Security tab and register it with the identity provider.
- **Solutions:** to put the connector in a solution for moving between environments, use `pac connector create --solution-unique-name …` instead. pac has no `--secret`, so enter the secret on the Security tab.

## 8. Test the deployed connector

Validation doesn't call your API. After deploying to a test environment (*from the docs*, "Create a custom connector from an OpenAPI definition" → Test the connector):

1. Open the connector in Power Automate or Power Apps → **Test** → **New connection**. Sign in through the connector's own OAuth flow, which checks the redirect URL registration.
2. Run a few operations from the Test page: a list call, a call with a required parameter left blank, and one that returns an error. Check the responses match the schemas.
3. Exercise behaviour validation can't see:
   - **List-valued filters:** call one with two values and confirm the API applied both. That's the only way to learn how Power Platform sent the array (§6.3).
   - **Token refresh:** reuse the connection after the access token's lifetime. If calls start failing, the connector probably isn't getting a refresh token (check the scopes, e.g. `offline_access`).
   - **Error bodies:** trigger an error and read it from the failed action's outputs (`outputs('<action>')?['body']`), since error responses aren't typed (§6.2).
4. Use the connector in a simple flow and check its outputs appear as expected in dynamic content.
5. **Paging:** Power Automate's built-in pagination (`x-ms-pageable`) only understands a `nextLink` or `@odata.nextLink` field (*from the docs*: InvalidNextLinkNameValue). APIs that page by number (`Page`, `PageSize`) need an explicit loop in the flow. Respect any documented maximum page size.
6. **Rate limits and concurrency** (*from the docs*):
   - "Apply to each" runs one item at a time by default; its concurrency can be raised to 50.
   - Flow runs are unlimited when trigger concurrency control is off, which is the default.

     (Both from Microsoft Learn "Limits of automated, scheduled, and instant flows".)
   - A custom connector connection allows 10,000 requests per minute in Power Automate (Microsoft Learn custom connector FAQ), so the API's own limits are usually the binding ones.

   Check whether the vendor's limits are per app or shared across the customer's tenant. A tenant-wide limit, such as 10 concurrent requests, is shared with every other integration. Keep *total* parallelism (loops, parallel branches, simultaneous runs) under it, and make sure flows cope with 429 responses (check the vendor's docs for a `Retry-After` header, and test how your flow's retry policy behaves).

## 9. Security

- **Token file:** `~/.paconn/accessTokens.json` holds a refresh token. Never copy or commit it, and run `paconn logout` when done.
- **`--secret` on the command line** puts the OAuth client secret in your shell history and the process list. Prefer entering it on the connector's Security tab, or clear your history afterwards.
- **Validation sends the whole definition** to Microsoft's service. Don't validate files containing secrets or real record IDs; keep environment test values out of connector paths.
- **Test environments:** create connectors in a test environment first, and don't share connections made with privileged accounts.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Access token invalid. Please login again.` | Not signed in, or the token is within 10 minutes of expiry (~55 min after sign-in) | `paconn login` |
| Long silence, then `AdalError: Unexpected polling state code_expired` | The device code was buffered (non-TTY output) and expired before being shown | `PYTHONUNBUFFERED=1 paconn login`, or run it in a real terminal |
| `400 … SwaggerCertificationFailedWithErrors` from `paconn validate` | Certification rules failed. This is normal for private connectors. | Read §5; use `validate_connector.py` without `--certification` |
| A definition "passes" but you expected rule errors | Certification-off is lenient, or results are still at stage 1 | Run a probe copy with `--certification` (§4.3) |
| HTTP 400 but "0 errors" reported | An error with no location (e.g. `x-ms-connector-metadata` required) that a parser expecting `Error : <location> : <text>` skipped | Read the raw message; the current `validate_connector.py` counts these |
| `create`/`update` waits for input in a script | Environment or connector ID not given | Pass `--env` (and `--cid`) |

## 11. Checklist

- [ ] paconn installed in its own virtual environment, which is git-ignored
- [ ] `paconn login` (unbuffered if not in a terminal); remember the ~55-minute session
- [ ] Generic Swagger check passes locally
- [ ] §6 checks done on the **real** definition:
  - one success schema per action and none on `default`;
  - no GET/HEAD bodies; no `connectionId`; required parameters marked;
  - one host; no environment values in paths; `"x-ms-url-encoding": "single"` on path parameters;
  - summaries, labels and title follow the string guidance;
  - OAuth uses `GlobalPerConnector`, `https` URLs and a refresh scope;
  - under 1 MB
- [ ] `validate_connector.py` (certification off): 0 errors
- [ ] Probe copy with `--certification`: no errors left beyond what you accept; warnings reviewed
- [ ] Deployed to a **test** environment; redirect URL registered; Test tab and a sample flow work
- [ ] Runtime behaviour checked: a list filter with two values, a token refresh, paging, an error body, and concurrency within the vendor's limits
- [ ] `paconn logout`; no secrets in shell history or committed files

## 12. Where this guidance comes from

The guidance was worked out on a real connector project: a Postman-generated custom connector with 133 operations, on 14 Oct 2026. Each claim is marked as one of:
- *verified*: run with paconn 0.0.21 on Python 3.14 (macOS);
- *from the docs*: taken from `paconn --help` or Microsoft Learn, and not exercised.

Microsoft's rules and paconn both change, so re-check both kinds of claim with your paconn version before relying on them.

Related lessons in this repo:
- [stackOwner blocks connector updates](../lessons/2026-10-14-1645-stackowner-blocks-connector-updates.md): why `apiProperties.json` here has no `stackOwner`, so paconn can update the connector (§7).
- [A connector operation missing from scriptOperations is sent to the real API host](../lessons/2026-10-14-1645-connector-op-missing-from-scriptoperations-goes-to-backend.md): a runtime routing problem that no validator in §4 catches (§6).
