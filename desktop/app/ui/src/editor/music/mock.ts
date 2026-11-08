// Browser stand-ins for the editor media commands (owner: ms-capture), so the
// camera and music UI open in Safari. lib/mock.ts imports this.
import { mock } from "../../lib/ipc";
import type { Song } from "./music";

const song = (id: string, title: string, artist: string, duration: number, genres: string[], bpm?: number): Song => ({
  id,
  title,
  artist,
  duration,
  genres,
  bpm,
  license: "cc0",
  audioURL: "",
  energy: bpm ? Math.min(0.95, (bpm - 60) / 80) : 0.2,
  peaks: Array.from({ length: 64 }, (_, i) => 0.3 + 0.6 * Math.abs(Math.sin((i + id.length * 3) / 5)) * (0.5 + 0.5 * Math.sin(i / 17))),
  grid: bpm ? { bar: 240 / bpm, firstDownbeat: 0.2, lifts: [16 * (240 / bpm)] } : null,
});

const songs: Song[] = [
  song("1", "Lost On The Freeway", "HoliznaCC0", 154, ["grooving", "lofi"], 108),
  song("2", "Night Driving", "HoliznaCC0", 132, ["mellow"], 92),
  song("3", "Disco In The Sky", "John Bartmann", 181, ["sunny", "disco"], 118),
  song("4", "Clair de Lune", "Debussy, played by a friend", 296, ["classical", "dreamy"]),
  song("5", "Day Trips", "HoliznaCC0", 140, ["dreamy"], 84),
];

mock("music_library", (a) => {
  const { query, mood } = a as { query: string; mood: string | null };
  const words = query.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return songs.filter((s) => {
    if (words.length) return words.every((w) => `${s.title} ${s.artist} ${s.genres.join(" ")}`.toLowerCase().includes(w));
    return mood ? s.genres.includes(mood) : true;
  });
});
mock("music_suggest", () => songs.slice(0, 4));
mock("music_voice", () => []);
mock("music_add", (a) => `music-${(a as { song: Song }).song.id}.m4a`);
mock("music_own_file", (a) => ({ ...song("own", String((a as { path: string }).path), "Your music", 120, []), license: "own" }));
mock("music_shape", () => ({
  wave: Array.from({ length: 240 }, (_, i) => 0.35 + 0.6 * Math.abs(Math.sin(i / 7)) * (0.6 + 0.4 * Math.sin(i / 31))),
  grid: { bar: 2.22, firstDownbeat: 0.4, lifts: [17.9, 53.4, 89] },
}));

mock("camera_open", () => true);
mock("camera_close", () => {});
mock("camera_devices", () => ({
  cameras: [{ id: "0", name: "FaceTime HD Camera" }],
  microphones: [{ id: "0", name: "MacBook Pro Microphone" }],
  camera: null,
  mic: null,
}));
mock("camera_use", () => {});
mock("camera_record", () => new Promise((r) => setTimeout(r, 300)));
mock("camera_stop", () => ({ file: `camera-${Math.floor(Date.now() / 1000)}.mp4`, duration: 4 }));
mock("camera_take", () => {});
