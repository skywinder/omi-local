export function formatTime(value) {
  const seconds = Math.max(0, Math.floor(Number(value) || 0));
  return seconds >= 3600 ? `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds / 60) % 60).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}` : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}
export function segmentAt(segments, time) {
  return segments.findIndex(s => time >= s.start && time < s.end);
}

// Keep one location per turn even when a common word occurs hundreds of times.
export function findTurns(segments, query) {
  const literal = query.trim();
  if (!literal) return [];
  const pattern = new RegExp(literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'iu');
  const matches = [];
  for (const [index, segment] of segments.entries()) {
    const match = pattern.exec(segment.text);
    if (match) matches.push({index, start: match.index, end: match.index + match[0].length});
  }
  return matches;
}
export function speakerBadge(segment) {
  const number = /^SPEAKER_\d{1,4}$/.test(segment.speaker) ? Number(segment.speaker.slice(8)) : null;
  const label = segment.is_user ? 'Вы' : segment.speaker_name || (number === null ? '' : `Говорящий ${number + 1}`);
  return {label, tone: number === null ? 'neutral' : String(number % 4)};
}
export function seekTo(audio, time, duration) {
  audio.currentTime = Math.max(0, Math.min(time, duration));
}
export async function playFrom(audio, time, duration) {
  seekTo(audio, time, duration);
  await audio.play();
}
