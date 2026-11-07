import { createClient } from 'npm:@supabase/supabase-js@2.119.0';

/** Private worker-to-worker audio bus. The SDK and server key never reach an
 * APK. Browser/phone clients only use their authenticated game WebSocket. */
export class SupabaseVoice {
  constructor({ url, secretKey }) {
    this.client = createClient(url, secretKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      realtime: { params: { eventsPerSecond: 100 } }
    });
  }
  subscribe(topic, receive, status) {
    let ready = false, closed = false;
    const channel = this.client.channel(`rami-voice:${topic}`, { config: { private: true, broadcast: { self: true, ack: false } } });
    channel.on('broadcast', { event: 'audio' }, message => { if (!closed) receive(message.payload); });
    channel.subscribe(state => {
      ready = state === 'SUBSCRIBED';
      if (!closed) status(ready);
    });
    return {
      send: payload => {
        if (!ready || closed) return;
        // Never fall back to REST (which would amplify requests and latency).
        channel.send({ type: 'broadcast', event: 'audio', payload }).catch(() => { ready = false; status(false); });
      },
      close: () => { closed = true; ready = false; this.client.removeChannel(channel).catch(() => {}); }
    };
  }
  async close() { await this.client.removeAllChannels(); }
}
