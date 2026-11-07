import { Buffer } from 'node:buffer';

// Independently decodable mono IMA ADPCM: 80 ms at 16 kHz. The server only
// validates/relays bounded frames; no audio or transcripts enter room storage.
export function validVoiceFrame(data) {
  if (typeof data !== 'string' || data.length !== 860 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) return false;
  const frame = Buffer.from(data, 'base64');
  return frame.length === 645 && frame[2] <= 88 && frame.readUInt16LE(3) === 1280 && frame.toString('base64') === data;
}
