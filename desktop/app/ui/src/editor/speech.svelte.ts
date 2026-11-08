// Your voice in the editor (EditorCaptions on the Mac): which takes have
// one, transcribing them on this computer (the app's `transcribe` command:
// whisper, its model fetched on first use), the transcript panel's fixes,
// the Captions switch and "Copy transcript".

import { call, on } from "../lib/ipc";
import type { CaptionWord, Transcript } from "./core";
import type { EditorStore } from "./store.svelte";

export interface SpeechSettings {
  mic: string | null;
  language: string;
  autoTranscribe: boolean;
  writeSubtitles: boolean;
}

export interface Busy {
  take: number;
  stage: "download" | "listen";
  progress: number;
}

/** Languages offered (whisper hears ~100; these cover most people). */
export const LANGUAGES: { value: string; label: string }[] = [
  { value: "auto", label: "Automatic" },
  { value: "en", label: "English" },
  { value: "es", label: "Spanish" },
  { value: "fr", label: "French" },
  { value: "de", label: "German" },
  { value: "it", label: "Italian" },
  { value: "pt", label: "Portuguese" },
  { value: "nl", label: "Dutch" },
  { value: "sv", label: "Swedish" },
  { value: "pl", label: "Polish" },
  { value: "tr", label: "Turkish" },
  { value: "ru", label: "Russian" },
  { value: "uk", label: "Ukrainian" },
  { value: "ar", label: "Arabic" },
  { value: "hi", label: "Hindi" },
  { value: "ja", label: "Japanese" },
  { value: "ko", label: "Korean" },
  { value: "zh", label: "Chinese" },
];

export class Speech {
  settings = $state<SpeechSettings>({ mic: null, language: "auto", autoTranscribe: true, writeSubtitles: true });
  busy = $state<Busy | null>(null);
  error = $state<string | null>(null);
  /** The word being fixed in the transcript panel. */
  editing = $state<CaptionWord | null>(null);
  copied = $state(false);
  private stop = false;

  constructor(private store: EditorStore) {
    on<{ folder: string; take: number; stage: "download" | "listen"; progress: number }>("transcribe-progress", (p) => {
      if (this.busy && p.take === this.busy.take) this.busy = { take: p.take, stage: p.stage, progress: p.progress };
    });
    call<SpeechSettings>("speech_settings").then(
      (s) => {
        this.settings = s;
        void this.autoStart();
      },
      () => {},
    );
  }

  /** Takes with a voice to hear. */
  get voiced(): number[] {
    return this.store.takes.flatMap((t, i) => (t.voice ? [i] : []));
  }
  get hasVoice(): boolean {
    return this.voiced.length > 0;
  }
  get transcribed(): boolean {
    return this.store.takes.some((t) => t.transcript && t.transcript.words.length > 0);
  }
  /** The words the edit shows, in play order (re-read after every edit). */
  get words(): CaptionWord[] {
    void this.store.version;
    return this.store.editor.captionWords();
  }

  get on(): boolean {
    return this.store.edit.captions === true;
  }
  setOn(v: boolean) {
    this.store.update((e) => {
      if (v) e.captions = true;
      else delete e.captions;
    });
  }

  async setSettings(change: Partial<SpeechSettings>) {
    this.settings = { ...this.settings, ...change };
    try {
      await call("speech_set", { settings: this.settings });
    } catch (e) {
      console.error("speech_set", e);
    }
  }

  /** After opening (or a new take): hear every voice not yet heard. */
  async autoStart() {
    if (!this.settings.autoTranscribe || this.busy) return;
    const todo = this.voiced.filter((i) => !this.store.takes[i].transcript);
    if (todo.length) await this.transcribe(todo);
  }

  /** Transcribes these takes (all with a voice by default), one by one. */
  async transcribe(takes = this.voiced) {
    if (this.busy) return;
    this.stop = false;
    this.error = null;
    for (const take of takes) {
      if (this.stop) break;
      this.busy = { take, stage: "listen", progress: 0 };
      try {
        const lang = this.settings.language === "auto" ? null : this.settings.language;
        const t = await call<Transcript>("transcribe", { folder: this.store.folder, take, language: lang });
        this.store.setTranscript(take, t);
        // Heard for the first time: show it.
        if (t.words.length && this.store.edit.captions == null) this.setOn(true);
      } catch (e) {
        const m = String(e);
        if (m !== "cancelled") this.error = m;
        break;
      }
    }
    this.busy = null;
  }

  cancel() {
    this.stop = true;
    void call("transcribe_cancel", { folder: this.store.folder });
  }

  /** Word `w` spelled `text` (empty drops it); saved at once. */
  async fix(w: CaptionWord, text: string) {
    // Enter, then the field's blur as it goes: only the first counts.
    const e = this.editing;
    if (!e || e.take !== w.take || e.index !== w.index) return;
    this.editing = null;
    const t = this.store.takes[w.take]?.transcript;
    if (!t || t.words[w.index]?.text === text.trim()) return;
    const next = this.store.c.transcriptEdit(t, w.index, text);
    this.store.setTranscript(w.take, next);
    try {
      await call("transcript_save", { folder: this.store.folder, take: w.take, transcript: next });
    } catch (e) {
      this.error = String(e);
    }
  }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.store.editor.transcriptText());
      this.copied = true;
      setTimeout(() => (this.copied = false), 1600);
    } catch (e) {
      this.error = `Couldn't copy: ${e}`;
    }
  }
}
