using Azure;
using Azure.Core;
using Azure.Data.Tables;
using Microsoft.Extensions.Configuration;

namespace BglWebhookReceiver;

public sealed class TableEventStore(TableClient table) : IEventStore
{
    public async Task<bool> TryAddAsync(EventKey key, BglEvent evt, CancellationToken cancellationToken)
    {
        var entity = new TableEntity(key.PartitionKey, key.RowKey)
        {
            ["EventId"] = evt.EventId,
            ["EventType"] = evt.EventType,
            ["FirmId"] = evt.FirmId,
            ["EntityId"] = evt.EntityId,
            ["ReceivedUtc"] = DateTimeOffset.UtcNow,
        };
        try
        {
            await table.AddEntityAsync(entity, cancellationToken);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == 409)
        {
            return false;
        }
    }

    public async Task RemoveAsync(EventKey key, CancellationToken cancellationToken)
    {
        try { await table.DeleteEntityAsync(key.PartitionKey, key.RowKey, ETag.All, cancellationToken); }
        catch (RequestFailedException ex) when (ex.Status == 404) { }
    }

    /// <summary>
    /// Uses the host's storage account: the managed identity and AzureWebJobsStorage__tableServiceUri in Azure (the
    /// table is created by the Bicep template), or the AzureWebJobsStorage connection string locally (e.g. Azurite).
    /// </summary>
    public static TableClient CreateClient(IConfiguration configuration, TokenCredential credential, string tableName)
    {
        // The processor doesn't cancel store calls (see WebhookProcessor.ProcessAsync), so bound them here instead of
        // relying on the SDK's default 100-second network timeout.
        var options = new TableClientOptions();
        options.Retry.MaxRetries = 2;
        options.Retry.NetworkTimeout = TimeSpan.FromSeconds(5);

        var serviceUri = configuration["AzureWebJobsStorage:tableServiceUri"];
        if (!string.IsNullOrEmpty(serviceUri)) return new TableClient(new Uri(serviceUri), tableName, credential, options);

        var connectionString = configuration["AzureWebJobsStorage"]
            ?? throw new InvalidOperationException("Set AzureWebJobsStorage__tableServiceUri (Azure) or AzureWebJobsStorage (local).");
        var client = new TableClient(connectionString, tableName, options);
        client.CreateIfNotExists();
        return client;
    }
}
