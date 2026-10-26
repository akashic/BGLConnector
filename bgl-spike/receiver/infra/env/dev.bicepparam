using '../main.bicep'

// Spike settings for BGL staging. Nothing organisation-specific belongs here: this repo is public.
param environmentName = 'dev'
param location = 'australiaeast'

// Lets Send-BglTestWebhook.ps1 print why a message was rejected (T17). Turn off before real traffic matters.
param exposeRejectionReason = true

// Set after T12 shows the client code BGL sends. Empty = not checked.
param expectedClientCode = ''

// BGL's source IP ranges, once BGL provides them (open question 6). Empty = no IP restriction.
param allowedIpRanges = []
