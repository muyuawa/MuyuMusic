/**
 * @name 暮雨自写协议测试源
 * @description 验证导入、现代语法和异步解析；播放前请替换示例 HTTPS 音频地址
 * @version 1.0.0
 * @author Muyu Music contributors
 */
// Original test fixture; no third-party music service or credentials.
// Copy into Documents to import. Replace this URL with an HTTPS audio file you control.
const audioURL = 'https://example.com/replace-with-your-audio.mp3';
const { EVENT_NAMES, on, send, utils } = globalThis.lx;
on(EVENT_NAMES.request, async ({ source, action, info }) => {
  if (source !== 'wy' || action !== 'musicUrl') throw new Error('Unsupported action');
  if (typeof info.musicInfo.songmid !== 'string') throw new Error('Expected string song ID');
  await new Promise(resolve => setTimeout(resolve, 25));
  return audioURL;
});
(async () => {
  const bytes = utils.buffer.from('Muyu runtime fixture', 'utf8');
  const restored = await utils.zlib.inflate(await utils.zlib.deflate(bytes));
  if (utils.buffer.bufToString(restored) !== 'Muyu runtime fixture') throw new Error('zlib failed');
  await send(EVENT_NAMES.inited, { sources: {
    wy: { name: '网易云目录协议测试', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
  } });
})();
