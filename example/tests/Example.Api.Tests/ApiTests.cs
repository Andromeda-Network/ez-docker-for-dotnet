using System.Net;
using Microsoft.AspNetCore.Mvc.Testing;

namespace Example.Api.Tests;

public class ApiTests(WebApplicationFactory<Program> factory) : IClassFixture<WebApplicationFactory<Program>>
{
    [Fact]
    public async Task HealthCheck_IsHealthy()
    {
        var response = await factory.CreateClient().GetAsync("/healthz");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task HealthCheck_CanBeMadeToFail()
    {
        var failing = factory.WithWebHostBuilder(b => b.UseSetting("Example:FailHealthCheck", "true"));

        var response = await failing.CreateClient().GetAsync("/healthz");

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
    }

    [Fact]
    public async Task Root_ReportsTheEnvironment()
    {
        var body = await factory.CreateClient().GetStringAsync("/");

        Assert.Contains("Example.Api", body);
    }
}
