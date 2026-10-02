using Discord;
using Discord.WebSocket;
using Microsoft.Extensions.Options;

namespace Contoso.Web.Discord;

public sealed class DiscordBotService : BackgroundService
{
    private readonly DiscordSocketClient _client;
    private readonly IServiceProvider _services;
    private readonly ILogger<DiscordBotService> _logger;
    private readonly DiscordOptions _options;

    public DiscordBotService(IServiceProvider services, ILogger<DiscordBotService> logger, IOptions<DiscordOptions> options)
    {
        _services = services;
        _logger = logger;
        _options = options.Value;
        _client = new DiscordSocketClient(new DiscordSocketConfig { GatewayIntents = GatewayIntents.All });
    }

    public override async Task StartAsync(CancellationToken cancellationToken)
    {
        _client.Log += m => { _logger.LogTrace("{@Message}", m); return Task.CompletedTask; };
        _client.Ready += async () =>
        {
            var weather = new SlashCommandBuilder().WithName("weather").WithDescription("Current weather")
                .AddOption("city", ApplicationCommandOptionType.String, "City", isRequired: true).Build();
            var report = new SlashCommandBuilder().WithName("report").WithDescription("Weekly sales report").Build();
            await _client.BulkOverwriteGlobalApplicationCommandsAsync([weather, report]);

            _client.SlashCommandExecuted += async command =>
            {
                try
                {
                    using var scope = _services.CreateScope();
                    switch (command.Data.Name)
                    {
                        case "weather":
                            var http = scope.ServiceProvider.GetRequiredService<IHttpClientFactory>().CreateClient("weather");
                            var city = (string)command.Data.Options.First().Value;
                            var json = await http.GetStringAsync($"/current?city={city}");
                            await command.RespondAsync(embed: new EmbedBuilder().WithTitle($"Weather in {city}").WithDescription(json).Build());
                            break;
                        case "report":
                            var reports = scope.ServiceProvider.GetRequiredService<ISalesReports>();
                            var rows = await reports.GetWeeklyAsync(); // ~5-10 s query
                            var embed = new EmbedBuilder().WithTitle("Weekly sales");
                            foreach (var row in rows) embed.AddField(row.Region, row.Total.ToString("C"));
                            await command.RespondAsync(embed: embed.Build());
                            break;
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Command failed");
                }
            };
        };

        while (true)
        {
            try
            {
                await _client.LoginAsync(TokenType.Bot, _options.Token);
                await _client.StartAsync();
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Discord login failed, retrying");
                await Task.Delay(5000, cancellationToken);
            }
        }
    }

    protected override Task ExecuteAsync(CancellationToken stoppingToken) => Task.Delay(Timeout.Infinite, stoppingToken);

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await _client.StopAsync();
        await _client.DisposeAsync();
    }
}
