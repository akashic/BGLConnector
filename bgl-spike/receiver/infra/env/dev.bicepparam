using '../main.bicep'

// Spike settings for BGL staging. Nothing organisation-specific belongs here: this repo is public.
param environmentName = 'dev'
param location = 'australiaeast'

// Off, because BGL is registered against this environment. T17 turns it on (with expectedClientCode = 'spike') by an
// inline override: D2's $t17 on a laptop, or the workflow's "t17" input. Never set it to true here.
param exposeRejectionReason = false

// Stays empty here: BGL's real client code may identify your firm, and this repo is public. T12 passes it at deploy
// time instead ($clientCode in D2, or the BGL_EXPECTED_CLIENT_CODE environment secret in the workflow).
param expectedClientCode = ''

// Entra: Flows D and E accept only the Function's managed identity. 'Sas' only if your region doesn't offer the
// trigger's "Specific users in my tenant" option yet (runbook Part D).
param flowAuthentication = 'Entra'

// BGL's source IP ranges, once BGL provides them (open question 6). Empty = no IP restriction.
param allowedIpRanges = []
