//! The window: a steering wheel that turns with the controller, live graphs of the tilt, the steering and the raw
//! sensors, and the settings.

use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use eframe::egui::{
    self, Align, Align2, Color32, FontId, Layout, Pos2, Rect, RichText, Sense, Shape, Stroke, StrokeKind, Vec2,
    ViewportCommand, WindowLevel, pos2, vec2,
};
use egui_plot::{GridMark, HLine, Line, Plot, PlotPoint, PlotPoints, PlotUi, Polygon, Text, VLine};
use serde::{Deserialize, Serialize};

use crate::pad::{PadInfo, button_label, button_order};
use crate::steer::{Action, Command, CoreHandle, CoreState, Sample, Tuning, WINDOW_SECONDS, now};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// What's saved between runs.
#[derive(Serialize, Deserialize, Default)]
#[serde(default)]
struct Saved {
    tuning: Tuning,
    bindings: BTreeMap<Action, BTreeSet<String>>,
    keep_on_top: bool,
    raw_accel: bool,
}

/// Set from the command line.
#[derive(Default)]
pub struct Options {
    pub simulate: bool,
    pub theme: Option<egui::Theme>,
    /// Saves the window to this PNG a few seconds after it opens, then quits. For checking the layout.
    pub snapshot: Option<PathBuf>,
}

pub struct GyroApp {
    core: CoreHandle,
    state: CoreState,
    tuning: Tuning,
    sent_tuning: Tuning,
    keep_on_top: bool,
    applied_keep_on_top: Option<bool>,
    raw_accel: bool,
    paused: bool,
    frozen: Vec<Sample>,
    frozen_now: f64,
    hover_ago: Option<f64>,
    refresh_times: VecDeque<f64>,
    now: f64,
    snapshot: Option<PathBuf>,
    snapshot_requested: bool,
    quit: Arc<AtomicBool>,
}

impl GyroApp {
    pub fn new(cc: &eframe::CreationContext<'_>, options: Options) -> GyroApp {
        let saved: Saved = cc.storage.and_then(|s| eframe::get_value(s, "settings")).unwrap_or_default();
        // Follow the system unless the command line says otherwise; set every time, as egui saves the choice.
        cc.egui_ctx.set_theme(options.theme.map_or(egui::ThemePreference::System, Into::into));
        let mut bindings = Action::default_bindings();
        for (action, buttons) in saved.bindings {
            bindings.insert(action, buttons);
        }
        let core = CoreHandle::start(saved.tuning.clone(), bindings);
        if options.simulate {
            core.send(Command::Simulate(true));
        }
        GyroApp {
            core,
            state: CoreState::default(),
            tuning: saved.tuning.clone(),
            sent_tuning: saved.tuning,
            keep_on_top: saved.keep_on_top,
            applied_keep_on_top: None,
            raw_accel: saved.raw_accel,
            paused: false,
            frozen: Vec::new(),
            frozen_now: 0.0,
            hover_ago: None,
            refresh_times: VecDeque::new(),
            now: now(),
            snapshot: options.snapshot,
            snapshot_requested: false,
            quit: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl eframe::App for GyroApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.now = now();
        self.refresh_times.push_back(self.now);
        while self.refresh_times.front().is_some_and(|t| *t < self.now - 1.0) {
            self.refresh_times.pop_front();
        }
        if let Some(s) = self.core.snapshot_if_newer(self.state.version) {
            self.state = s;
        }
        if self.tuning != self.sent_tuning {
            self.sent_tuning = self.tuning.clone();
            self.core.send(Command::Tuning(self.tuning.clone()));
        }
        if self.applied_keep_on_top != Some(self.keep_on_top) {
            self.applied_keep_on_top = Some(self.keep_on_top);
            let level = if self.keep_on_top { WindowLevel::AlwaysOnTop } else { WindowLevel::Normal };
            ctx.send_viewport_cmd(ViewportCommand::WindowLevel(level));
        }
        ctx.request_repaint_after(Duration::from_millis(33));

        let colors = Colors::new(ui.visuals());
        egui::Panel::top("status")
            .frame(egui::Frame::side_top_panel(ui.style()).inner_margin(egui::Margin::symmetric(16, 10)))
            .show(ui, |ui| self.status_bar(ui, &colors));
        egui::Panel::left("side")
            .exact_size(340.0)
            .resizable(false)
            .frame(egui::Frame::side_top_panel(ui.style()).inner_margin(egui::Margin::same(0)))
            .show(ui, |ui| {
                egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                    egui::Frame::new().inner_margin(egui::Margin::same(16)).show(ui, |ui| self.side_panel(ui, &colors));
                });
            });
        egui::CentralPanel::default()
            .frame(egui::Frame::central_panel(ui.style()).inner_margin(egui::Margin::same(16)))
            .show(ui, |ui| self.charts(ui, &colors));

        self.take_snapshot(&ctx);
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        let saved = Saved {
            tuning: self.tuning.clone(),
            bindings: self.state.bindings.clone(),
            keep_on_top: self.keep_on_top,
            raw_accel: self.raw_accel,
        };
        eframe::set_value(storage, "settings", &saved);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.core.shutdown();
    }
}

// MARK: - Colours

struct Colors {
    series1: Color32,
    series2: Color32,
    series3: Color32,
    good: Color32,
    warning: Color32,
    critical: Color32,
    /// Secondary text and marks.
    weak: Color32,
    /// Primary ink.
    strong: Color32,
    background: Color32,
}

const fn hex(v: u32) -> Color32 {
    Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

impl Colors {
    fn new(v: &egui::Visuals) -> Colors {
        // Categorical slots 1-3 (blue, orange, aqua), each with its light and dark step.
        let pick = |light: u32, dark: u32| if v.dark_mode { hex(dark) } else { hex(light) };
        Colors {
            series1: pick(0x2a78d6, 0x3987e5),
            series2: pick(0xeb6834, 0xd95926),
            series3: pick(0x1baf7a, 0x199e70),
            good: hex(0x0ca30c),
            warning: hex(0xfab219),
            critical: hex(0xd03b3b),
            weak: v.weak_text_color(),
            strong: v.strong_text_color(),
            background: v.panel_fill,
        }
    }
}

fn faded(c: Color32, alpha: f32) -> Color32 {
    c.gamma_multiply(alpha)
}

/// `c` at `amount` over `background`, but opaque, so overlapping shapes don't show darker where they meet.
fn solid(c: Color32, amount: f32, background: Color32) -> Color32 {
    let mix = |a: u8, b: u8| (f32::from(a) + (f32::from(b) - f32::from(a)) * amount).round() as u8;
    Color32::from_rgb(mix(background.r(), c.r()), mix(background.g(), c.g()), mix(background.b(), c.b()))
}

// MARK: - Status

#[derive(Clone, Copy)]
enum Chip {
    Good,
    Warning,
    Critical,
    Idle,
}

fn chip(ui: &mut egui::Ui, colors: &Colors, state: Chip, text: &str) {
    let color = match state {
        Chip::Good => colors.good,
        Chip::Warning => colors.warning,
        Chip::Critical => colors.critical,
        Chip::Idle => colors.weak,
    };
    let (rect, _) = ui.allocate_exact_size(vec2(12.0, 12.0), Sense::hover());
    ui.painter().circle_filled(rect.center(), 5.5, color);
    ui.label(text);
}

impl GyroApp {
    fn status_bar(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        let s = &self.state;
        let rate = s.motion_rate(self.now);
        let (cs, ct) = if s.simulate {
            (Chip::Warning, format!("Simulated controller · {rate} updates/s"))
        } else {
            match &s.controller {
                None => (Chip::Critical, "No controller: connect one with a gyro".to_string()),
                Some(c) if rate == 0 => (Chip::Warning, format!("{} · no motion data", c.name)),
                Some(c) => (Chip::Good, format!("{} · {rate} updates/s", c.name)),
            }
        };
        let g = &s.game;
        let (gs, gt) = if !g.answering(self.now) {
            (Chip::Critical, "BeamNG isn't answering: is it running with the mod?".to_string())
        } else if g.mod_version.as_deref() != Some(VERSION) {
            let theirs = g.mod_version.as_deref().map_or("an older version".to_string(), |v| format!("version {v}"));
            (Chip::Warning, format!("The BeamNG mod is {theirs}: install the one from GyroSteer {VERSION}"))
        } else if !g.has_car {
            (Chip::Warning, "BeamNG: no car to steer".to_string())
        } else if g.steering {
            (Chip::Good, "BeamNG is steering the car".to_string())
        } else {
            (Chip::Idle, "BeamNG connected · gyro steering off".to_string())
        };
        let notice = s.notice.as_ref().filter(|(_, t)| self.now - t < 6.0).map(|(n, _)| n.clone());
        ui.horizontal(|ui| {
            chip(ui, colors, cs, &ct);
            ui.add_space(22.0);
            chip(ui, colors, gs, &gt);
            if let Some(notice) = notice {
                ui.add_space(12.0);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    ui.add(egui::Label::new(RichText::new(notice).color(colors.weak)).truncate());
                });
            }
        });
    }

    // MARK: - Side panel

    fn side_panel(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        let latest = self.state.history.back().copied();
        let threshold = (self.tuning.keep_turning && self.tuning.threshold < self.tuning.range).then_some(self.tuning.threshold);
        wheel_view(
            ui,
            colors,
            latest.map_or(0.0, |s| s.wheel),
            latest.and_then(|s| s.sent).unwrap_or(0.0),
            self.state.gyro_enabled,
        );
        ui.add_space(12.0);
        tilt_meter(ui, colors, latest.map_or(0.0, |s| s.tilt), threshold);
        ui.add_space(14.0);

        ui.columns(3, |cols| {
            stat(&mut cols[0], colors, "Steering sent", latest.and_then(|s| s.sent).map_or("off".into(), steering_text), Align::Min);
            stat(&mut cols[1], colors, "Wheel", latest.map_or("–".into(), |s| format!("{:+.0}°", s.wheel)), Align::Center);
            stat(&mut cols[2], colors, "Tilt", latest.map_or("–".into(), |s| format!("{:+.0}°", s.tilt)), Align::Max);
        });
        ui.add_space(10.0);

        let gyro_on = self.state.gyro_enabled;
        let core = &self.core;
        egui::Sides::new().show(
            ui,
            |ui| {
                let mut on = gyro_on;
                if toggle(ui, &mut on).changed() {
                    core.send(Command::Gyro(on));
                }
                ui.label("Gyro steering");
            },
            |ui| {
                if ui.button("Set straight").on_hover_text("Makes the controller's current tilt count as straight").clicked() {
                    core.send(Command::Recenter);
                }
            },
        );

        section(ui);
        self.pedals_section(ui, colors);
        section(ui);
        self.buttons_section(ui, colors);
        section(ui);
        self.tuning_section(ui, colors);
        section(ui);

        ui.label(RichText::new("Window").strong());
        ui.add_space(4.0);
        if ui.checkbox(&mut self.paused, "Pause graphs").changed() {
            self.frozen = if self.paused { self.state.history.iter().copied().collect() } else { Vec::new() };
            self.frozen_now = self.now;
        }
        ui.checkbox(&mut self.keep_on_top, "Keep this window on top");
        let mut simulate = self.state.simulate;
        if ui
            .checkbox(&mut simulate, "Simulate a controller")
            .on_hover_text("Makes up a controller turning left and right, to test the graphs and the mod")
            .changed()
        {
            self.core.send(Command::Simulate(simulate));
        }
    }

    fn pedals_section(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        let pedals = &mut self.tuning.pedals;
        egui::Sides::new().show(
            ui,
            |ui| ui.label(RichText::new("Gas and brake").strong()),
            |ui| toggle(ui, pedals).on_hover_text("Right stick is the throttle, left stick the brake"),
        );
        ui.add_space(4.0);
        let (throttle, brake) = (self.state.throttle, self.state.brake);
        let tuning = &mut self.tuning;
        ui.add_enabled_ui(tuning.pedals, |ui| {
            caption(ui, colors, "Right stick is the throttle, left stick the brake. The further from the middle, in any direction, the harder.");
            ui.add_space(6.0);
            pedal_bar(ui, colors, "Throttle · right stick", throttle, colors.series3);
            ui.add_space(6.0);
            pedal_bar(ui, colors, "Brake · left stick", brake, colors.series2);
            ui.add_space(8.0);
            slider_row(ui, colors, "Stick dead zone", &mut tuning.pedal_deadzone, 0.0..=30.0, 1.0,
                       |v| format!("{v:.0}% of travel"), "Stick movement ignored around the middle");
        });
    }

    fn buttons_section(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        ui.label(RichText::new("Controller buttons").strong());
        caption(ui, colors, "Press these together on the controller.");
        let pad = self.state.controller.clone().unwrap_or_default();
        for action in Action::ALL {
            ui.add_space(6.0);
            let learning = self.state.learning == Some(action);
            let binding = self.state.bindings.get(&action).cloned().unwrap_or_default();
            let core = &self.core;
            egui::Sides::new().show(
                ui,
                |ui| ui.label(action.title()),
                |ui| {
                    if learning {
                        if ui.button("Cancel").clicked() {
                            core.send(Command::Learn(None));
                        }
                    } else {
                        if ui.add_enabled(binding != action.default_buttons(), egui::Button::new("Default")).clicked() {
                            core.send(Command::ResetButtons(action));
                        }
                        if ui.button("Change").clicked() {
                            core.send(Command::Learn(Some(action)));
                        }
                    }
                },
            );
            if learning {
                let prompt = if self.state.controller.is_none() {
                    "Connect the controller first".to_string()
                } else if self.state.learned.is_empty() {
                    "Press the button or buttons now, then let go".to_string()
                } else {
                    format!("{}: let go to save", button_names(&self.state.learned, &pad))
                };
                ui.label(RichText::new(format!("🎮 {prompt}")).color(colors.series1));
            } else {
                ui.label(RichText::new(button_names(&binding, &pad)).monospace().color(colors.weak));
            }
        }
    }

    fn tuning_section(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        ui.label(RichText::new("Tuning").strong());
        ui.add_space(6.0);
        let t = &mut self.tuning;
        slider_row(ui, colors, "Full lock", &mut t.range, 15.0..=540.0, 5.0, |v| format!("{v:.0}° of wheel"),
                   "How far the wheel turns each way for full lock. Less is quicker steering; real cars are around 450°.");
        ui.checkbox(&mut t.keep_turning, "Keep turning past a tilt");
        ui.add_space(6.0);
        let keep = t.keep_turning;
        ui.add_enabled_ui(keep, |ui| {
            slider_row(ui, colors, "Keep turning past", &mut t.threshold, 30.0..=85.0, 1.0, |v| format!("{v:.0}° tilt"),
                       "Up to this tilt the wheel follows the controller exactly. Tilt further and it keeps turning; tilt back to unwind.");
            slider_row(ui, colors, "Turning speed", &mut t.speed, 30.0..=720.0, 10.0, |v| format!("{v:.0}°/s"),
                       "How fast it keeps turning with the controller tilted all the way (90°); slower just past the threshold");
        });
        let hint = if t.keep_turning && t.range <= t.threshold {
            Some(format!(
                "Full lock comes before {0:.0}° of tilt, so the wheel never needs to keep turning. Set Full lock above {0:.0}° to use it.",
                t.threshold
            ))
        } else if !t.keep_turning && t.range > 90.0 {
            Some("Full lock is more than you can tilt (90°). Turn on Keep turning to reach it.".to_string())
        } else {
            None
        };
        if let Some(hint) = hint {
            caption(ui, colors, &format!("ⓘ {hint}"));
            ui.add_space(6.0);
        }
        slider_row(ui, colors, "Dead zone", &mut t.deadzone, 0.0..=10.0, 0.5, |v| format!("{v:.1}°"), "Tilt ignored around straight");
        slider_row(ui, colors, "Curve", &mut t.curve, 0.5..=3.0, 0.1, |v| format!("{v:.1}"),
                   "Above 1 makes small tilts gentler, for finer control at speed");
        ui.checkbox(&mut t.invert, "Steer the other way");
        ui.checkbox(&mut t.direct, "Send as a wheel, not a gamepad")
            .on_hover_text("Skips BeamNG's gamepad smoothing and its speed-based steering limit");
    }

    // MARK: - Graphs

    fn charts(&mut self, ui: &mut egui::Ui, colors: &Colors) {
        let (all, now): (Vec<Sample>, f64) = if self.paused {
            (self.frozen.clone(), self.frozen_now)
        } else {
            (self.state.history.iter().copied().collect(), self.now)
        };
        let shown = self
            .hover_ago
            .and_then(|ago| all.iter().min_by(|a, b| (a.t - now - ago).abs().total_cmp(&(b.t - now - ago).abs())))
            .or(all.last())
            .copied();
        // At most about 200 points a line: plenty for the eye, and keeps the drawing quick.
        let step = (all.len() / 200).max(1);
        let data: Vec<Sample> = all
            .iter()
            .enumerate()
            .filter(|(i, _)| i % step == 0 || *i == all.len() - 1)
            .map(|(_, s)| *s)
            .collect();

        let gap = 18.0;
        let header = 46.0;
        let plot_height = ((ui.available_height() - 2.0 * gap) / 3.0 - header).max(90.0);
        let probe = self.hover_ago;
        let t = &self.tuning;
        let threshold = (t.keep_turning && t.threshold < t.range).then_some(t.threshold);

        let mut hover = None;
        hover = hover.or(tilt_chart(ui, colors, &data, now, t.range, t.deadzone, threshold, shown, probe, plot_height));
        ui.add_space(gap);
        hover = hover.or(steering_chart(ui, colors, &data, now, shown, probe, plot_height));
        ui.add_space(gap);
        hover = hover.or(raw_chart(ui, colors, &data, now, &mut self.raw_accel, shown, probe, plot_height));
        self.hover_ago = hover;
    }

    fn take_snapshot(&mut self, ctx: &egui::Context) {
        if self.quit.load(Ordering::Relaxed) {
            ctx.send_viewport_cmd(ViewportCommand::Close);
            return;
        }
        let Some(path) = self.snapshot.clone() else { return };
        if self.snapshot_requested || self.now < 7.0 {
            return;
        }
        self.snapshot_requested = true;
        println!(
            "window refreshes/s: {}, motion updates/s: {}",
            self.refresh_times.len(),
            self.state.motion_rate(self.now)
        );
        let quit = self.quit.clone();
        let repaint = ctx.clone();
        ctx.request_screenshot(move |image| {
            if let Err(e) = save_png(&path, &image) {
                eprintln!("GyroSteer: can't save {}: {e}", path.display());
            }
            quit.store(true, Ordering::Relaxed);
            repaint.request_repaint();
        });
    }
}

fn save_png(path: &Path, image: &egui::ColorImage) -> Result<(), Box<dyn std::error::Error>> {
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut encoder = png::Encoder::new(file, image.size[0] as u32, image.size[1] as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let bytes: Vec<u8> = image.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
    encoder.write_header()?.write_image_data(&bytes)?;
    Ok(())
}

// MARK: - Small widgets

fn section(ui: &mut egui::Ui) {
    ui.add_space(10.0);
    ui.separator();
    ui.add_space(10.0);
}

fn caption(ui: &mut egui::Ui, colors: &Colors, text: &str) {
    ui.label(RichText::new(text).small().color(colors.weak));
}

/// An on/off switch.
fn toggle(ui: &mut egui::Ui, on: &mut bool) -> egui::Response {
    let size = ui.spacing().interact_size.y * vec2(1.8, 0.9);
    let (rect, mut response) = ui.allocate_exact_size(size, Sense::click());
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }
    if ui.is_rect_visible(rect) {
        let how_on = ui.ctx().animate_bool_responsive(response.id, *on);
        let visuals = ui.style().interact_selectable(&response, *on);
        let rect = rect.expand(visuals.expansion);
        let radius = 0.5 * rect.height();
        ui.painter().rect(rect, radius, visuals.bg_fill, visuals.bg_stroke, StrokeKind::Inside);
        let x = egui::lerp((rect.left() + radius)..=(rect.right() - radius), how_on);
        ui.painter().circle(pos2(x, rect.center().y), 0.75 * radius, visuals.bg_fill, visuals.fg_stroke);
    }
    response
}

fn stat(ui: &mut egui::Ui, colors: &Colors, title: &str, value: String, align: Align) {
    ui.with_layout(Layout::top_down(align), |ui| {
        ui.label(RichText::new(title).small().color(colors.weak));
        ui.add(egui::Label::new(RichText::new(value).size(20.0).strong()).wrap_mode(egui::TextWrapMode::Extend));
    });
}

fn steering_text(v: f64) -> String {
    let side = if v.abs() < 0.005 { "" } else if v < 0.0 { " left" } else { " right" };
    format!("{:.2}{side}", v.abs())
}

fn slider_row(
    ui: &mut egui::Ui,
    colors: &Colors,
    title: &str,
    value: &mut f64,
    range: std::ops::RangeInclusive<f64>,
    step: f64,
    format: impl Fn(f64) -> String,
    help: &str,
) {
    let shown = format(*value);
    egui::Sides::new().show(ui, |ui| ui.label(title), |ui| ui.label(RichText::new(shown).color(colors.weak)));
    ui.scope(|ui| {
        ui.spacing_mut().slider_width = ui.available_width();
        ui.add(egui::Slider::new(value, range).step_by(step).show_value(false));
    });
    caption(ui, colors, help);
    ui.add_space(8.0);
}

/// A pedal from 0 (empty) to 1 (full), with its percentage.
fn pedal_bar(ui: &mut egui::Ui, colors: &Colors, title: &str, value: f64, color: Color32) {
    egui::Sides::new().show(
        ui,
        |ui| ui.label(title),
        |ui| ui.label(RichText::new(format!("{:.0}%", value * 100.0)).monospace().color(colors.weak)),
    );
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 8.0), Sense::hover());
    let painter = ui.painter();
    painter.rect_filled(rect, 4.0, faded(colors.weak, 0.2));
    let fill = rect.width() * value.clamp(0.0, 1.0) as f32;
    if fill > 0.5 {
        painter.rect_filled(Rect::from_min_size(rect.min, vec2(fill.max(8.0), rect.height())), 4.0, color);
    }
}

/// The controller's tilt on a 90° left ... 90° right scale. Past the threshold (the darker ends), the wheel keeps
/// turning.
fn tilt_meter(ui: &mut egui::Ui, colors: &Colors, tilt: f64, threshold: Option<f64>) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 18.0), Sense::hover());
    let w = rect.width();
    let x = |deg: f64| rect.left() + w / 2.0 + (deg.clamp(-90.0, 90.0) / 90.0) as f32 * (w / 2.0);
    let bar = Rect::from_center_size(rect.center(), vec2(w, 8.0));
    let painter = ui.painter();
    painter.rect_filled(bar, 4.0, faded(colors.weak, 0.2));
    if let Some(th) = threshold {
        let clipped = painter.with_clip_rect(bar);
        let dark = faded(colors.weak, 0.6);
        clipped.rect_filled(Rect::from_min_max(bar.min, pos2(x(-th), bar.max.y)), 4.0, dark);
        clipped.rect_filled(Rect::from_min_max(pos2(x(th), bar.min.y), bar.max), 4.0, dark);
    }
    let c = rect.center();
    painter.line_segment([pos2(c.x, c.y - 7.0), pos2(c.x, c.y + 7.0)], Stroke::new(1.0, colors.weak));
    painter.rect_filled(Rect::from_center_size(pos2(x(tilt), c.y), vec2(4.0, 18.0)), 2.0, colors.strong);

    let (left, right) = if threshold.is_some() { ("« keeps turning", "keeps turning »") } else { ("90° left", "90° right") };
    ui.columns(3, |cols| {
        for (col, text, align) in [(0, left, Align::Min), (1, "controller tilt", Align::Center), (2, right, Align::Max)] {
            cols[col].with_layout(Layout::top_down(align), |ui| ui.label(RichText::new(text).small().color(colors.weak)));
        }
    });
}

// MARK: - Wheel

/// How far round the arc reaches at full lock, degrees from the top.
const ARC_REACH: f64 = 125.0;

/// A point `r` from `c`, `deg` degrees clockwise from 12 o'clock.
fn around(c: Pos2, r: f32, deg: f64) -> Pos2 {
    let a = (deg - 90.0).to_radians() as f32;
    pos2(c.x + r * a.cos(), c.y + r * a.sin())
}

fn arc(painter: &egui::Painter, c: Pos2, r: f32, from: f64, to: f64, width: f32, color: Color32) {
    let (a, b) = (from.min(to), from.max(to));
    if b - a <= 0.2 {
        return;
    }
    let steps = ((b - a) / 2.0).ceil().max(2.0) as usize;
    let points: Vec<Pos2> = (0..=steps).map(|i| around(c, r, a + (b - a) * i as f64 / steps as f64)).collect();
    // Round caps.
    painter.circle_filled(points[0], width / 2.0, color);
    painter.circle_filled(points[steps], width / 2.0, color);
    painter.add(Shape::line(points, Stroke::new(width, color)));
}

/// The wheel turns to the wheel angle; the arc around it fills with the steering sent to the game.
fn wheel_view(ui: &mut egui::Ui, colors: &Colors, angle: f64, steer: f64, on: bool) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 250.0), Sense::hover());
    let size = rect.width().min(rect.height());
    let c = rect.center();
    let painter = ui.painter();
    let ring = size / 2.0 - 4.0;
    arc(painter, c, ring, -ARC_REACH, ARC_REACH, 7.0, solid(colors.weak, 0.25, colors.background));
    if on {
        arc(painter, c, ring, 0.0, steer * ARC_REACH, 7.0, colors.series1);
    }
    for (text, deg) in [("L", -ARC_REACH - 12.0), ("R", ARC_REACH + 12.0)] {
        painter.text(around(c, size / 2.0 - 3.0, deg), Align2::CENTER_CENTER, text, FontId::proportional(11.0), colors.weak);
    }

    // The wheel itself, inside the arc.
    let s = size * (1.0 - 2.0 * 0.085);
    let rim = s * 0.08;
    let r = s / 2.0 - rim / 2.0;
    let ink = solid(colors.strong, if on { 0.8 } else { 0.3 }, colors.background);
    let turn = angle.to_radians() as f32;
    let rot = |dx: f32, dy: f32| pos2(c.x + dx * turn.cos() - dy * turn.sin(), c.y + dx * turn.sin() + dy * turn.cos());
    painter.circle_stroke(c, r, Stroke::new(rim, ink));
    let spoke = s * 0.065;
    let joints = [rot(-r, s * 0.03), rot(0.0, 0.0), rot(r, s * 0.03)];
    painter.add(Shape::line(joints.to_vec(), Stroke::new(spoke, ink)));
    painter.line_segment([rot(0.0, 0.0), rot(0.0, r)], Stroke::new(spoke, ink));
    for p in joints {
        painter.circle_filled(p, spoke / 2.0, ink);
    }
    painter.circle_filled(c, s * 0.14, ink);
    // The notch at the top shows which way is straight.
    painter.line_segment([rot(0.0, -r - rim / 2.0 - 1.0), rot(0.0, -r + rim / 2.0 + 1.0)], Stroke::new(s * 0.04, colors.background));
}

// MARK: - Charts

struct Legend {
    color: Color32,
    name: String,
    value: String,
    thin: bool,
}

fn legend(color: Color32, name: &str, value: Option<String>) -> Legend {
    Legend { color, name: name.to_string(), value: value.unwrap_or_else(|| "–".into()), thin: false }
}

/// The graph's title and legend. `raw_accel`, for the raw sensors, adds the switch between gyro and accelerometer.
fn chart_header(
    ui: &mut egui::Ui,
    colors: &Colors,
    title: &str,
    detail: &str,
    entries: &[Legend],
    probe: Option<f64>,
    raw_accel: Option<&mut bool>,
) {
    egui::Sides::new().show(
        ui,
        |ui| {
            ui.label(RichText::new(title).strong());
            ui.label(RichText::new(detail).small().color(colors.weak));
        },
        |ui| {
            let when = probe.map_or("now".to_string(), |ago| format!("{:.1} s ago", -ago));
            ui.label(RichText::new(when).small().monospace().color(colors.weak));
            if let Some(raw_accel) = raw_accel {
                ui.add_space(8.0);
                ui.selectable_value(raw_accel, true, "Accelerometer");
                ui.selectable_value(raw_accel, false, "Gyro");
            }
        },
    );
    ui.horizontal(|ui| {
        for e in entries {
            let (rect, _) = ui.allocate_exact_size(vec2(16.0, 10.0), Sense::hover());
            let h = if e.thin { 1.5 } else { 3.0 };
            ui.painter().rect_filled(Rect::from_center_size(rect.center(), vec2(16.0, h)), h / 2.0, e.color);
            ui.label(RichText::new(&e.name).small().color(colors.weak));
            ui.label(RichText::new(&e.value).small().monospace());
            ui.add_space(10.0);
        }
    });
    ui.add_space(4.0);
}

/// The line through `value`, split wherever it is missing, so gaps stay gaps.
fn segments(data: &[Sample], now: f64, value: impl Fn(&Sample) -> Option<f64>) -> Vec<Vec<[f64; 2]>> {
    let mut out: Vec<Vec<[f64; 2]>> = vec![Vec::new()];
    for s in data {
        match value(s) {
            Some(y) => out.last_mut().unwrap().push([s.t - now, y]),
            None if !out.last().unwrap().is_empty() => out.push(Vec::new()),
            None => {}
        }
    }
    out.retain(|seg| !seg.is_empty());
    out
}

fn draw_line(pui: &mut PlotUi<'_>, points: Vec<[f64; 2]>, color: Color32, width: f32) {
    pui.line(Line::new("", PlotPoints::from(points)).color(color).width(width).allow_hover(false));
}

/// A graph of the last 10 seconds, with `y` from -limit to limit. Returns where the pointer is, in seconds before
/// now.
fn time_plot(
    ui: &mut egui::Ui,
    id: &str,
    height: f32,
    limit: f64,
    y_marks: Vec<f64>,
    y_text: impl Fn(f64) -> String + 'static,
    colors: &Colors,
    probe: Option<f64>,
    build: impl FnOnce(&mut PlotUi<'_>),
) -> Option<f64> {
    let probe_color = colors.weak;
    let grid_color = faded(colors.weak, 0.3);
    let grid_y = y_marks.clone();
    let step = if y_marks.len() > 1 { y_marks[1] - y_marks[0] } else { limit };
    let response = Plot::new(id)
        .height(height)
        .allow_drag(false)
        .allow_zoom(false)
        .allow_scroll(false)
        .allow_boxed_zoom(false)
        .allow_double_click_reset(false)
        .allow_axis_zoom_drag(false)
        .show_x(false)
        .show_y(false)
        .set_margin_fraction(Vec2::ZERO)
        .show_grid(false)
        .x_grid_spacer(|_| (0..=5).map(|i| GridMark { value: -10.0 + 2.0 * i as f64, step_size: 2.0 }).collect())
        // The left edge is 10 s ago; its label would run into the bottom of the y axis, so it's left off.
        .x_axis_formatter(|m, _| match m.value {
            v if v.abs() < 1e-9 => "now".into(),
            v if v <= -WINDOW_SECONDS + 1e-9 => String::new(),
            v => format!("{v:.0} s"),
        })
        .y_grid_spacer(move |_| y_marks.iter().map(|v| GridMark { value: *v, step_size: step }).collect())
        .y_axis_formatter(move |m, _| y_text(m.value))
        .show(ui, |pui| {
            pui.set_plot_bounds_x(-WINDOW_SECONDS..=0.0);
            pui.set_plot_bounds_y(-limit..=limit);
            // Gridlines: thin, so they stay behind the data.
            for i in 1..5 {
                pui.vline(VLine::new("", -WINDOW_SECONDS + 2.0 * i as f64).color(grid_color).width(0.5).allow_hover(false));
            }
            for y in grid_y {
                if y.abs() < limit - 1e-9 {
                    pui.hline(HLine::new("", y).color(grid_color).width(0.5).allow_hover(false));
                }
            }
            build(pui);
            if let Some(ago) = probe {
                pui.vline(VLine::new("", ago).color(probe_color).width(1.0));
            }
            if pui.response().hovered() { pui.pointer_coordinate().map(|p| p.x) } else { None }
        });
    response.inner.filter(|x| (-WINDOW_SECONDS..=0.0).contains(x))
}

#[allow(clippy::too_many_arguments)]
fn tilt_chart(
    ui: &mut egui::Ui,
    colors: &Colors,
    data: &[Sample],
    now: f64,
    range: f64,
    deadzone: f64,
    threshold: Option<f64>,
    shown: Option<Sample>,
    probe: Option<f64>,
    height: f32,
) -> Option<f64> {
    // Mark where the tilt stops mapping 1:1: the keep-turning threshold, or full lock.
    let mark = threshold.unwrap_or(range.min(90.0));
    let (above, below) = if threshold.is_none() {
        ("full lock right", "full lock left")
    } else {
        ("keeps turning right past here", "keeps turning left past here")
    };
    let limit = if threshold.is_none() { (mark + 15.0).max(30.0).min(90.0) } else { 90.0 };
    let deg = |v: f64| format!("{v:+.1}°");
    let mut accel_entry = legend(colors.weak, "Accelerometer alone", shown.map(|s| deg(s.accel_tilt)));
    accel_entry.thin = true;
    chart_header(ui, colors, "Tilt", "degrees from straight; the shaded band is the dead zone", &[
        legend(colors.series1, "Gyro + accelerometer (steers)", shown.map(|s| deg(s.tilt))),
        accel_entry,
    ], probe, None);
    let marks: Vec<f64> = (-3..=3).map(|i| i as f64 * 30.0).filter(|v| v.abs() <= limit).collect();
    let fused = segments(data, now, |s| Some(s.tilt));
    let accel = segments(data, now, |s| Some(s.accel_tilt));
    let (weak, series1) = (colors.weak, colors.series1);
    time_plot(ui, "tilt", height, limit, marks, |v| format!("{v:.0}°"), colors, probe, move |pui| {
        pui.polygon(
            Polygon::new("", PlotPoints::from(vec![[-WINDOW_SECONDS, -deadzone], [0.0, -deadzone], [0.0, deadzone], [-WINDOW_SECONDS, deadzone]]))
                .fill_color(faded(weak, 0.16))
                .stroke(Stroke::NONE)
                .allow_hover(false),
        );
        for (y, text, anchor) in [(mark, above, Align2::LEFT_BOTTOM), (-mark, below, Align2::LEFT_TOP)] {
            pui.hline(HLine::new("", y).color(faded(weak, 0.7)).width(1.0));
            pui.text(
                Text::new("", PlotPoint::new(-WINDOW_SECONDS + 0.1, y), RichText::new(text).small().color(weak))
                    .anchor(anchor)
                    .allow_hover(false),
            );
        }
        for seg in accel {
            draw_line(pui, seg, faded(weak, 0.75), 1.0);
        }
        for seg in fused {
            draw_line(pui, seg, series1, 2.0);
        }
    })
}

fn signed(v: f64) -> String {
    format!("{v:+.2}")
}

fn steering_chart(
    ui: &mut egui::Ui,
    colors: &Colors,
    data: &[Sample],
    now: f64,
    shown: Option<Sample>,
    probe: Option<f64>,
    height: f32,
) -> Option<f64> {
    chart_header(ui, colors, "Steering", "−1 full left … +1 full right", &[
        legend(colors.series1, "Sent to BeamNG", shown.map(|s| s.sent.map_or("off".into(), signed))),
        legend(colors.series2, "Applied in the car (after the game's smoothing)", shown.and_then(|s| s.applied).map(signed)),
    ], probe, None);
    let sent = segments(data, now, |s| s.sent);
    let applied = segments(data, now, |s| s.applied);
    let (weak, series1, series2) = (colors.weak, colors.series1, colors.series2);
    let marks = vec![-1.0, -0.5, 0.0, 0.5, 1.0];
    let text = |v: f64| if v.abs() < 1e-9 { "0".into() } else { format!("{v:+.1}") };
    time_plot(ui, "steering", height, 1.08, marks, text, colors, probe, move |pui| {
        pui.hline(HLine::new("", 0.0).color(faded(weak, 0.5)).width(1.0));
        for seg in applied {
            draw_line(pui, seg, series2, 2.0);
        }
        for seg in sent {
            draw_line(pui, seg, series1, 2.0);
        }
    })
}

#[allow(clippy::too_many_arguments)]
fn raw_chart(
    ui: &mut egui::Ui,
    colors: &Colors,
    data: &[Sample],
    now: f64,
    raw_accel: &mut bool,
    shown: Option<Sample>,
    probe: Option<f64>,
    height: f32,
) -> Option<f64> {
    let gyro = !*raw_accel;
    let pick = |s: &Sample| if gyro { s.gyro } else { s.accel };
    let peak = data.iter().map(|s| {
        let v = pick(s);
        v.x.abs().max(v.y.abs()).max(v.z.abs())
    }).fold(0.0, f64::max);
    let limit = if gyro { (peak / 30.0).ceil().max(1.0) * 30.0 } else { ((peak / 0.5).ceil() * 0.5).max(1.25) };
    let unit = if gyro { "°/s" } else { "g" };
    let names: [&str; 3] = if gyro {
        // Which way of turning each axis picks up, holding the controller flat.
        ["x (tip forward/back)", "y (tilt like a wheel)", "z (twist flat)"]
    } else {
        ["x (right)", "y (forward)", "z (out of the face)"]
    };
    let axis_colors = [colors.series1, colors.series2, colors.series3];
    let get = |v: crate::tilt::V3, i: usize| [v.x, v.y, v.z][i];
    let entries: Vec<Legend> = (0..3)
        .map(|i| {
            let value = shown.map(|s| {
                let v = get(pick(&s), i);
                if gyro { format!("{v:+.0} {unit}") } else { format!("{v:+.2} {unit}") }
            });
            legend(axis_colors[i], names[i], value)
        })
        .collect();
    let detail = if gyro {
        "turning speed around the controller's axes"
    } else {
        "acceleration; held still, it's just gravity (1 g down)"
    };
    chart_header(ui, colors, "Raw sensors", detail, &entries, probe, Some(raw_accel));
    let lines: Vec<Vec<[f64; 2]>> = (0..3).map(|i| data.iter().map(|s| [s.t - now, get(pick(s), i)]).collect()).collect();
    let marks: Vec<f64> = if gyro {
        // The smallest round step that needs no more than three marks each side.
        let step = [10.0, 15.0, 30.0, 60.0, 120.0, 180.0, 240.0, 360.0, 480.0, 720.0, 1440.0]
            .into_iter()
            .find(|step| limit / step <= 3.0)
            .unwrap_or(limit);
        let n = (limit / step).floor() as i32;
        (-n..=n).map(|i| i as f64 * step).collect()
    } else {
        let step = if limit > 2.0 { 1.0 } else { 0.5 };
        let n = (limit / step).floor() as i32;
        (-n..=n).map(|i| i as f64 * step).collect()
    };
    let text = move |v: f64| if gyro { format!("{v:.0}") } else { format!("{v:.1}") };
    let weak = colors.weak;
    time_plot(ui, "raw", height, limit, marks, text, colors, probe, move |pui| {
        pui.hline(HLine::new("", 0.0).color(faded(weak, 0.5)).width(1.0));
        for (i, line) in lines.into_iter().enumerate() {
            draw_line(pui, line, axis_colors[i], 2.0);
        }
    })
}

/// Button names as printed on the controller, in a steady order, joined with " + ".
fn button_names(names: &BTreeSet<String>, pad: &PadInfo) -> String {
    let mut ordered: Vec<&String> = names.iter().collect();
    ordered.sort_by_key(|n| (button_order(n), n.to_string()));
    if ordered.is_empty() {
        return "none".into();
    }
    ordered.iter().map(|n| button_label(n, pad)).collect::<Vec<_>>().join(" + ")
}
