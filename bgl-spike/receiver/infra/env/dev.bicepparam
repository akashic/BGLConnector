using '../main.bicep'

// Spike settings for BGL staging. Nothing organisation-specific belongs here: this repo is public.
param environmentName = 'dev'
param location = 'australiaeast'

// Off, because BGL is registered against this environment. T17 turns it on (with expectedClientCode = 'spike') by an
// inline override: D2's $t17 on a laptop, or the workflow's "t17" input. Never set it to true here.
param exposeRejectionReason = false

// Set after T12 shows the client code BGL sends. Empty = not checked.
param expectedClientCode = ''

// BGL's source IP ranges, once BGL provides them (open question 6). Empty = no IP restriction.
param allowedIpRanges = []
