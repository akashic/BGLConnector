// Supporting classes for compiling custom connector code locally, as published in Microsoft Learn
// "Use custom code in a custom connector" (learn.microsoft.com/connectors/custom-connectors/write-code).
// CreateNotificationUri and OriginalRequestUri are undocumented. They are used only by
// script-with-proxy.csx, and their signatures are inferred from the certified DocuSign connector.
using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;

public abstract class ScriptBase
{
    public IScriptContext Context { get; }

    public CancellationToken CancellationToken { get; }

    public static StringContent CreateJsonContent(string serializedJson) => new StringContent(serializedJson);

    public abstract Task<HttpResponseMessage> ExecuteAsync();
}

public interface IScriptContext
{
    string CorrelationId { get; }

    string OperationId { get; }

    HttpRequestMessage Request { get; }

    ILogger Logger { get; }

    Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken);

    // Undocumented
    Uri CreateNotificationUri(string relativePath);

    // Undocumented
    Uri OriginalRequestUri { get; }
}
