// The camera's UI state that isn't the edit's: devices for the CameraBar menu.
// (The phase and "Just me" live on the EditorStore.)
export interface Device {
  id: string;
  name: string;
}

export const cameraUi = $state({
  cameras: [] as Device[],
  microphones: [] as Device[],
  /** The remembered choice; null = the system default. */
  camera: null as string | null,
  mic: null as string | null,
});
