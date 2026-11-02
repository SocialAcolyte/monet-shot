fn main() {
    // Resources/Music (the bundled songs) is part of the Mac's music work
    // and may not be in this checkout yet. Tauri refuses a missing resource
    // folder, so an absent one is bundled empty: the library still works
    // from the network and from the user's own files.
    let music = std::path::Path::new("../../../Resources/Music");
    if !music.exists() {
        let _ = std::fs::create_dir_all(music);
    }
    tauri_build::build()
}
