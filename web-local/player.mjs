export function formatTime(value) {
  const seconds = Math.max(0, Math.floor(Number(value) || 0));
  return seconds >= 3600 ? `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}` : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
export function segmentAt(segments, time) {
  return segments.findIndex(s => time >= s.start && time < s.end);
}
export function seekTo(audio, time, duration) {
  audio.currentTime = Math.max(0, Math.min(time, duration));
}
export async function playFrom(audio, time, duration) {
  seekTo(audio, time, duration);
  await audio.play();
}
