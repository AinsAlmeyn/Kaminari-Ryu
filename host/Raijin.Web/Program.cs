using Raijin.Web.Components;
using Raijin.Web.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Doom's packed hex weighs in at ~37 MB. Blazor Server streams InputFile
// uploads over the SignalR circuit, which defaults to a 32 KB receive cap
// AND also enforces a MaximumIncomingBytes on Hub options. Raise both so
// the upload chunks land without rejection.
builder.Services.Configure<Microsoft.AspNetCore.SignalR.HubOptions>(opts =>
{
    opts.MaximumReceiveMessageSize = 64L * 1024 * 1024;   // 64 MB
});

// HTTP request body cap (in case we ever switch to non-SignalR uploads).
builder.WebHost.ConfigureKestrel(k =>
{
    k.Limits.MaxRequestBodySize = 64L * 1024 * 1024;
});

// MVP single-user: one simulator shared across the (single) browser tab.
// Multi-session deployment will switch this to scoped + a session registry.
builder.Services.AddSingleton<SimulationRunner>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();
