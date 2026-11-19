// Keeps every media tab's latest state and passes it to Visor through
// visor-bridge (native messaging); passes Visor's commands to the tab.
const api = globalThis.browser ?? chrome;
const tabs = new Map();  // tab id -> { state, at }
let port = null;

function connect() {
  if (port) return port;
  try {
    port = api.runtime.connectNative('visor.media');
  } catch (e) {
    port = null;
    return null;
  }
  port.onMessage.addListener(message => {
    if (message.type === 'command') {
      api.tabs.sendMessage(Number(message.tab), { type: 'command', command: message.command }).catch(() => {});
    }
  });
  // Visor quit, or isn't installed: try again on the next report.
  port.onDisconnect.addListener(() => { port = null; });
  return port;
}

function send() {
  const p = connect();
  if (!p) return;
  const list = [...tabs].map(([id, entry]) => ({ id: String(id), at: entry.at, ...entry.state }));
  try { p.postMessage({ type: 'tabs', tabs: list }); } catch (e) { port = null; }
}

api.runtime.onMessage.addListener((message, sender) => {
  if (message.type !== 'media' || !sender.tab) return;
  if (message.state) tabs.set(sender.tab.id, { state: message.state, at: Date.now() });
  else tabs.delete(sender.tab.id);
  send();
});

api.tabs.onRemoved.addListener(id => {
  if (tabs.delete(id)) send();
});

// After a restart of this script the list is empty: ask open tabs to report again.
api.tabs.query({}).then(all => {
  for (const tab of all) api.tabs.sendMessage(tab.id, { type: 'report' }).catch(() => {});
}).catch(() => {});
connect();
