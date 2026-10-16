using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);

// /healthz: what the container HEALTHCHECK and `ez dotnet deploy` probe. Add checks for what the
// app cannot run without (database, Redis): AddDbContextCheck, ...
// Example__FailHealthCheck=true makes it unhealthy, to try ez's rollback.
builder.Services.AddHealthChecks()
    .AddCheck("example", () => builder.Configuration.GetValue<bool>("Example:FailHealthCheck")
        ? Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckResult.Unhealthy("Example:FailHealthCheck is set")
        : Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckResult.Healthy());

// Behind Nginx Proxy Manager: trust its X-Forwarded-For/-Proto, so Request.Scheme is https
// and the client IP is the visitor's. The proxy is on the shared Docker network.
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear();
});

var app = builder.Build();

app.UseForwardedHeaders();
app.MapHealthChecks("/healthz");
app.MapGet("/", (IHostEnvironment env) => new { app = "Example.Api", environment = env.EnvironmentName });

app.Run();

// Lets the tests host the app in-process.
public partial class Program;
