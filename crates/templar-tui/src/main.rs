use std::error::Error;
use std::io::{self, Read};
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use serde_json::{json, Value};
use templarlib::TemplarLib;
use zeroize::Zeroize;

type AppResult<T> = Result<T, Box<dyn Error>>;

#[derive(Parser)]
#[command(
    name = "templar",
    version,
    about = "Templar Wallet terminal client",
    long_about = "Terminal client for templarlib. Run without a command to open the TUI.\n\
                  Use `templar methods` to list every engine method."
)]
struct Cli {
    /// Keep wallet data and configuration under this directory.
    #[arg(long, global = true, value_name = "PATH")]
    data_dir: Option<PathBuf>,

    /// Prompt securely for the vault password before running the command.
    #[arg(long, global = true)]
    unlock: bool,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Open the interactive terminal interface.
    Tui,
    /// Print engine, vault, network, and storage status as JSON.
    Status,
    /// Print registered wallets as JSON.
    Wallets,
    /// List every templarlib method accepted by `call`.
    Methods,
    /// Call any templarlib method using JSON parameters.
    Call {
        /// Method from `templar methods`.
        method: String,
        /// JSON object, or `-` to read JSON from standard input.
        #[arg(short, long, default_value = "{}", value_name = "JSON|-")]
        params: String,
    },
}

fn main() -> AppResult<()> {
    let Cli {
        data_dir,
        unlock,
        command,
    } = Cli::parse();
    if matches!(command, Some(Command::Methods)) {
        for method in TemplarLib::methods() {
            println!("{method}");
        }
        return Ok(());
    }

    let engine = match data_dir {
        Some(path) => TemplarLib::with_data_dir(path),
        None => TemplarLib::new(),
    };
    if unlock {
        unlock_engine(&engine)?;
    }

    match command.unwrap_or(Command::Tui) {
        Command::Tui => run_tui(&engine),
        Command::Status => {
            print_json(&status(&engine));
            Ok(())
        }
        Command::Wallets => {
            print_json(&engine.call("list_wallets", &json!({})));
            Ok(())
        }
        Command::Methods => unreachable!("handled before engine initialization"),
        Command::Call { method, params } => {
            let mut params = parse_params(params)?;
            let mut response = engine.call(&method, &params);
            let failed = response.get("err").is_some();
            print_json(&response);
            zeroize_json_strings(&mut params);
            zeroize_json_strings(&mut response);
            if failed {
                std::process::exit(1);
            }
            Ok(())
        }
    }
}

fn unlock_engine(engine: &TemplarLib) -> AppResult<()> {
    let mut passphrase = rpassword::prompt_password("Vault passphrase: ")?;
    let mut params = json!({ "passphrase": passphrase });
    passphrase.zeroize();
    let mut response = engine.call("unlock_vault", &params);
    zeroize_json_strings(&mut params);
    let error = response
        .get("err")
        .and_then(Value::as_str)
        .map(str::to_string);
    zeroize_json_strings(&mut response);
    match error {
        Some(error) => Err(io::Error::other(error).into()),
        None => Ok(()),
    }
}

fn parse_params(argument: String) -> AppResult<Value> {
    let mut raw = if argument == "-" {
        let mut input = String::new();
        io::stdin().read_to_string(&mut input)?;
        input
    } else {
        argument
    };
    let parsed = serde_json::from_str(&raw);
    raw.zeroize();
    Ok(parsed?)
}

fn print_json(value: &Value) {
    let mut output = serde_json::to_string_pretty(value).unwrap_or_else(|_| value.to_string());
    println!("{output}");
    output.zeroize();
}

fn zeroize_json_strings(value: &mut Value) {
    match value {
        Value::String(value) => value.zeroize(),
        Value::Array(values) => values.iter_mut().for_each(zeroize_json_strings),
        Value::Object(values) => values.values_mut().for_each(zeroize_json_strings),
        _ => {}
    }
}

fn status(engine: &TemplarLib) -> Value {
    json!({
        "version": engine.call("version", &json!({})),
        "data_dir": engine.call("get_data_dir", &json!({})),
        "vault": engine.call("vault_status", &json!({})),
        "liquid_network": engine.call("get_liquid_network", &json!({})),
        "wallets": engine.call("list_wallets", &json!({})),
    })
}

#[derive(Default)]
struct Snapshot {
    version: String,
    data_dir: String,
    vault: String,
    liquid_network: String,
    wallets: Vec<String>,
    error: Option<String>,
}

impl Snapshot {
    fn load(engine: &TemplarLib) -> Self {
        let version_response = engine.call("version", &json!({}));
        let data_dir_response = engine.call("get_data_dir", &json!({}));
        let version = ok_value(&version_response)
            .and_then(Value::as_str)
            .unwrap_or("unknown")
            .to_string();
        let data_dir = ok_value(&data_dir_response)
            .and_then(Value::as_str)
            .unwrap_or("unavailable")
            .to_string();
        let vault_response = engine.call("vault_status", &json!({}));
        let network_response = engine.call("get_liquid_network", &json!({}));
        let wallets_response = engine.call("list_wallets", &json!({}));

        let error = [&vault_response, &network_response, &wallets_response]
            .iter()
            .find_map(|response| response.get("err").and_then(Value::as_str))
            .map(str::to_string);
        let vault = ok_value(&vault_response)
            .map(compact_json)
            .unwrap_or_else(|| "unavailable".to_string());
        let liquid_network = ok_value(&network_response)
            .map(compact_json)
            .unwrap_or_else(|| "unavailable".to_string());
        let wallets = ok_value(&wallets_response)
            .and_then(Value::as_array)
            .map(|items| items.iter().map(wallet_label).collect())
            .unwrap_or_default();

        Self {
            version,
            data_dir,
            vault,
            liquid_network,
            wallets,
            error,
        }
    }
}

fn ok_value(response: &Value) -> Option<&Value> {
    response.get("ok")
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(&value).unwrap_or_else(|_| "unavailable".to_string())
}

fn wallet_label(wallet: &Value) -> String {
    let name = wallet
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("Unnamed wallet");
    let kind = wallet
        .get("type_label")
        .or_else(|| wallet.get("wallet_type"))
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let balance = wallet
        .get("balance_sats")
        .and_then(Value::as_i64)
        .unwrap_or_default();
    format!("{name}  {kind}  {balance} sats")
}

struct TuiApp {
    snapshot: Snapshot,
    selected: usize,
    show_help: bool,
}

impl TuiApp {
    fn new(engine: &TemplarLib) -> Self {
        Self {
            snapshot: Snapshot::load(engine),
            selected: 0,
            show_help: false,
        }
    }

    fn refresh(&mut self, engine: &TemplarLib) {
        self.snapshot = Snapshot::load(engine);
        self.selected = self
            .selected
            .min(self.snapshot.wallets.len().saturating_sub(1));
    }
}

fn run_tui(engine: &TemplarLib) -> AppResult<()> {
    enable_raw_mode()?;
    let terminal_mode = TerminalModeGuard;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let mut app = TuiApp::new(engine);

    let result = tui_loop(&mut terminal, &mut app, engine);

    terminal.show_cursor()?;
    drop(terminal);
    drop(terminal_mode);
    result
}

struct TerminalModeGuard;

impl Drop for TerminalModeGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(io::stdout(), LeaveAlternateScreen);
    }
}

fn tui_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    app: &mut TuiApp,
    engine: &TemplarLib,
) -> AppResult<()> {
    loop {
        terminal.draw(|frame| draw(frame, app))?;
        if !event::poll(Duration::from_millis(250))? {
            continue;
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        match key.code {
            KeyCode::Char('q') => return Ok(()),
            KeyCode::Char('r') => app.refresh(engine),
            KeyCode::Char('?') => app.show_help = !app.show_help,
            KeyCode::Esc if app.show_help => app.show_help = false,
            KeyCode::Up | KeyCode::Char('k') => {
                app.selected = app.selected.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') if app.selected + 1 < app.snapshot.wallets.len() => {
                app.selected += 1;
            }
            _ => {}
        }
    }
}

fn draw(frame: &mut Frame, app: &TuiApp) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(8),
            Constraint::Min(5),
            Constraint::Length(2),
        ])
        .split(frame.area());

    let title = Paragraph::new(Line::from(vec![
        Span::styled(
            " TEMPLAR ",
            Style::default()
                .fg(Color::White)
                .bg(Color::Rgb(193, 18, 31))
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(format!("  Wallet terminal  v{}", app.snapshot.version)),
    ]))
    .block(Block::default().borders(Borders::ALL));
    frame.render_widget(title, rows[0]);

    let status_lines = vec![
        Line::from(format!("Data: {}", app.snapshot.data_dir)),
        Line::from(format!("Vault: {}", app.snapshot.vault)),
        Line::from(format!("Liquid: {}", app.snapshot.liquid_network)),
        Line::from(match &app.snapshot.error {
            Some(error) => format!("Error: {error}"),
            None => "Engine: ready".to_string(),
        }),
    ];
    let status = Paragraph::new(status_lines)
        .block(Block::default().title(" Status ").borders(Borders::ALL))
        .wrap(Wrap { trim: true });
    frame.render_widget(status, rows[1]);

    let wallet_items: Vec<ListItem> = if app.snapshot.wallets.is_empty() {
        vec![ListItem::new(
            "No visible wallets. Unlock the vault if configured.",
        )]
    } else {
        app.snapshot
            .wallets
            .iter()
            .enumerate()
            .map(|(index, wallet)| {
                let style = if index == app.selected {
                    Style::default()
                        .fg(Color::White)
                        .bg(Color::Rgb(88, 12, 20))
                        .add_modifier(Modifier::BOLD)
                } else {
                    Style::default()
                };
                ListItem::new(wallet.as_str()).style(style)
            })
            .collect()
    };
    frame.render_widget(
        List::new(wallet_items).block(Block::default().title(" Wallets ").borders(Borders::ALL)),
        rows[2],
    );

    frame.render_widget(
        Paragraph::new("q quit   r refresh   ? help   ↑/↓ select").alignment(Alignment::Center),
        rows[3],
    );

    if app.show_help {
        let area = centered_rect(66, 60, frame.area());
        frame.render_widget(Clear, area);
        let help = Paragraph::new(vec![
            Line::from("Interactive commands"),
            Line::from(""),
            Line::from("q        Quit"),
            Line::from("r        Reload engine status and wallet list"),
            Line::from("?        Toggle this help"),
            Line::from("Esc      Close this help"),
            Line::from("↑/k ↓/j  Select a wallet"),
            Line::from(""),
            Line::from("Shell commands"),
            Line::from("templar --help"),
            Line::from("templar --unlock"),
            Line::from("templar methods"),
            Line::from("templar call <METHOD> --params <JSON|->"),
        ])
        .block(Block::default().title(" Help ").borders(Borders::ALL))
        .wrap(Wrap { trim: true });
        frame.render_widget(help, area);
    }
}

fn centered_rect(width_percent: u16, height_percent: u16, area: Rect) -> Rect {
    let vertical = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - height_percent) / 2),
            Constraint::Percentage(height_percent),
            Constraint::Percentage((100 - height_percent) / 2),
        ])
        .split(area);
    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - width_percent) / 2),
            Constraint::Percentage(width_percent),
            Constraint::Percentage((100 - width_percent) / 2),
        ])
        .split(vertical[1])[1]
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;

    use super::*;

    #[test]
    fn command_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn unlock_is_a_global_option() {
        let before = Cli::try_parse_from(["templar", "--unlock", "status"]).unwrap();
        let after = Cli::try_parse_from(["templar", "status", "--unlock"]).unwrap();
        assert!(before.unlock && after.unlock);
    }

    #[test]
    fn call_parameters_accept_objects() {
        assert_eq!(
            parse_params(r#"{"wallet_id":"abc"}"#.to_string()).unwrap()["wallet_id"],
            "abc"
        );
    }

    #[test]
    fn wallet_labels_keep_operator_fields() {
        let label = wallet_label(&json!({
            "name": "Treasury",
            "type_label": "2-of-3 multisig",
            "balance_sats": 42,
        }));
        assert_eq!(label, "Treasury  2-of-3 multisig  42 sats");
    }
}
