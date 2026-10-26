using Azure.Core;
using Azure.Identity;
using BglWebhookReceiver;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services.AddOptions<ReceiverOptions>().Bind(builder.Configuration.GetSection(ReceiverOptions.SectionName));
builder.Services.AddSingleton(TimeProvider.System);

// In Azure, use the app's system-assigned managed identity explicitly (no credential probing). Locally,
// DefaultAzureCredential, though local runs normally use the Azurite connection string instead.
TokenCredential credential = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WEBSITE_SITE_NAME"))
    ? new DefaultAzureCredential()
    : new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned);

builder.Services.AddSingleton(credential);

builder.Services.AddSingleton<IEventStore>(sp => new TableEventStore(TableEventStore.CreateClient(
    builder.Configuration, credential, sp.GetRequiredService<IOptions<ReceiverOptions>>().Value.EventTableName)));

// Flows without a Response action reply 202 straight away, so these timeouts are generous. Together they stay well
// inside any reasonable webhook delivery timeout (BGL's isn't documented: open question 6). The timeouts include
// getting the flow token (FlowAuthHandler).
builder.Services.AddTransient<FlowAuthHandler>();
builder.Services.AddHttpClient(HttpEventForwarder.ClientName, c => c.Timeout = TimeSpan.FromSeconds(20))
    .AddHttpMessageHandler<FlowAuthHandler>();
builder.Services.AddHttpClient(HttpErrorReporter.ClientName, c => c.Timeout = TimeSpan.FromSeconds(5))
    .AddHttpMessageHandler<FlowAuthHandler>();
builder.Services.AddSingleton<IEventForwarder, HttpEventForwarder>();
builder.Services.AddSingleton<IErrorReporter, HttpErrorReporter>();
builder.Services.AddSingleton<WebhookProcessor>();

builder.Build().Run();
