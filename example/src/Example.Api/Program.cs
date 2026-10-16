using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);

// /healthz: what the container HEALTHCHECK, `ez app deploy` and the reverse proxy probe.
// Add checks for what the app cannot run without (database, Redis): AddDbContextCheck, ...
builder.Services.AddHealthChecks();

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
