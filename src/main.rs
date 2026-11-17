// GyroSteer: steer BeamNG.drive by tilting a controller like a wheel. See README.md.
//
//   gyrosteer                  the window
//   gyrosteer --simulate       starts with a made-up controller turning left and right
//   gyrosteer --light|--dark   forces the window's theme
//   gyrosteer --snapshot x.png saves the window a few seconds after it opens, then quits

// No console window on Windows.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod link;
mod pad;
mod steer;
mod tilt;
mod ui;

use eframe::egui;

fn icon() -> Option<egui::IconData> {
    let decoder = png::Decoder::new(std::io::Cursor::new(include_bytes!("../assets/icon-256.png")));
    let mut reader = decoder.read_info().ok()?;
    let mut rgba = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut rgba).ok()?;
    rgba.truncate(info.buffer_size());
    (info.color_type == png::ColorType::Rgba).then_some(egui::IconData { rgba, width: info.width, height: info.height })
}

fn main() -> eframe::Result {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("GyroSteer {}", ui::VERSION);
        return Ok(());
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("GyroSteer {}: steer BeamNG.drive by tilting a controller like a wheel.", ui::VERSION);
        println!("Options: --simulate  --light  --dark  --snapshot <file.png>  --version");
        return Ok(());
    }
    let options = ui::Options {
        simulate: args.iter().any(|a| a == "--simulate"),
        theme: if args.iter().any(|a| a == "--dark") {
            Some(egui::Theme::Dark)
        } else if args.iter().any(|a| a == "--light") {
            Some(egui::Theme::Light)
        } else {
            None
        },
        snapshot: args.iter().position(|a| a == "--snapshot").and_then(|i| args.get(i + 1)).map(Into::into),
    };

    let mut viewport = egui::ViewportBuilder::default()
        .with_title(format!("GyroSteer {}", ui::VERSION))
        .with_app_id("gyrosteer")
        .with_inner_size([1120.0, 780.0])
        .with_min_inner_size([980.0, 700.0]);
    if let Some(icon) = icon() {
        viewport = viewport.with_icon(icon);
    }
    let native = eframe::NativeOptions { viewport, ..Default::default() };
    eframe::run_native("GyroSteer", native, Box::new(move |cc| Ok(Box::new(ui::GyroApp::new(cc, options)))))
}
