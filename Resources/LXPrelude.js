// Independently implemented LX public protocol bridge. No Node or OS modules.
(() => {
  const native = globalThis.__lxNative;
  delete globalThis.__lxNative;
  const call = (op, value) => {
    const r = JSON.parse(native(op, JSON.stringify(value === undefined ? null : value)));
    if (r && r.__error) throw new Error(r.__error);
    return r;
  };
  let seq = 0, handler;
  const timers = new Map(), requests = new Map();
  globalThis.setTimeout = (fn, delay = 0, ...args) => {
    if (typeof fn !== 'function') throw new TypeError('Timer requires a function');
    const id = ++seq; timers.set(id, () => fn(...args));
    try { call('timer', {id, delay: Math.max(0, Number(delay) || 0)}); } catch(e) { timers.delete(id); throw e; }
    return id;
  };
  globalThis.clearTimeout = id => { timers.delete(id); call('clearTimer', id); };
  globalThis.__lxTimer = id => { const fn = timers.get(id); timers.delete(id); if (fn) fn(); };
  globalThis.__lxHTTP = (id, error, response, body) => {
    const fn = requests.get(id); requests.delete(id);
    if (response) response.raw = Uint8Array.from(response.raw || []);
    if (fn) fn(error ? new Error(error) : null, response, body);
  };
  globalThis.__lxClear = () => { timers.clear(); requests.clear(); };
  globalThis.__lxResolve = (id, event) => {
    Promise.resolve().then(() => {
      if (!handler) throw new Error('Missing request handler');
      return handler(event);
    }).then(value => call('resolved', {id, value}), error => call('rejected', {
      id, message: String(error && error.message || error || '音源解析失败').slice(0, 512)
    }));
  };
  const bytes = value => {
    if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
    if (ArrayBuffer.isView(value)) return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
    if (Array.isArray(value)) return value.map(v => Number(v) & 255);
    throw new TypeError('Expected byte buffer');
  };
  const from = (value, encoding = 'utf8') => {
    if (typeof value !== 'string') return Uint8Array.from(bytes(value));
    return Uint8Array.from(call('bufferFrom', {value, encoding}));
  };
  const text = (value, encoding = 'utf8') => call('bufferString', {value: bytes(value), encoding});
  const request = (url, options, callback) => {
    if (typeof options === 'function') { callback = options; options = {}; }
    if (typeof callback !== 'function') throw new TypeError('Missing HTTP callback');
    const id = ++seq;
    options = Object.assign({}, options || {});
    if (options.body instanceof ArrayBuffer || ArrayBuffer.isView(options.body)) options.body = {__bytes: bytes(options.body)};
    requests.set(id, callback);
    try { call('http', {id, url, options}); } catch(e) { requests.delete(id); throw e; }
    return () => { if (requests.delete(id)) { call('abort', id); callback(new Error('Request cancelled'), null, null); } };
  };
  globalThis.lx = {
    EVENT_NAMES: Object.freeze({inited:'inited', request:'request', updateAlert:'updateAlert'}),
    env: 'mobile', version: '1.2.0', currentScriptInfo: call('information'),
    on: (event, fn) => { if (event !== 'request' || typeof fn !== 'function') throw new Error('Unsupported event'); handler = fn; return Promise.resolve(); },
    send: (event, data) => Promise.resolve(call('send', {event, data})), request,
    utils: {
      buffer: {from, bufToString: text},
      crypto: {
        md5: value => call('md5', String(value)),
        randomBytes: size => Uint8Array.from(call('random', size)),
        aesEncrypt: (value, mode, key, iv) => Uint8Array.from(call('aes', {value:bytes(value),mode,key:bytes(key),iv:iv ? bytes(iv):[]})),
        rsaEncrypt: (value, key) => Uint8Array.from(call('rsa', {value:bytes(value),key:String(key)}))
      },
      zlib: {
        inflate: value => Promise.resolve().then(() => Uint8Array.from(call('inflate', bytes(value)))),
        deflate: value => Promise.resolve().then(() => Uint8Array.from(call('deflate', bytes(value))))
      }
    }
  };
  globalThis.console = Object.freeze({log(){},info(){},warn(){},error(){},debug(){}});
  globalThis.atob = value => text(from(value, 'base64'), 'latin1');
  globalThis.btoa = value => text(from(value, 'latin1'), 'base64');
})();
