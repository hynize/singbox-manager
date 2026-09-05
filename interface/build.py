#!/usr/bin/env python3
"""把 index.html 内嵌进 worker.js。修改界面后运行：python build.py"""
import json
import io
import os

HEADER = '''/**
 * singbox-manager interface
 * Singbox-Manager 一键SSH命令生成器 - Cloudflare Workers 单文件版
 * 项目地址: https://github.com/hynize/singbox-manager
 *
 * 部署方式一(控制台): CF Dashboard -> Workers & Pages -> Create Worker -> 粘贴本文件全部内容 -> Deploy
 * 部署方式二(Wrangler): 本目录下执行 `wrangler deploy` (配置见 wrangler.toml)
 * 部署方式三(GitHub): 推送到 GitHub 后手动运行 "Deploy to Cloudflare Workers" 工作流
 *                     （需配置 CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID 两个 Secrets）
 *
 * 本文件由 build.py 从 index.html 自动生成，请勿直接修改；改界面请编辑 index.html 后重新运行 build.py。
 */

const HTML = %s;

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== '/') {
      return new Response('Not Found', { status: 404 });
    }
    return new Response(HTML, {
      headers: {
        'content-type': 'text/html;charset=UTF-8',
        'cache-control': 'no-store',
      },
    });
  },
};
'''


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    with io.open(os.path.join(here, 'index.html'), encoding='utf-8') as f:
        html = f.read()

    out = HEADER % json.dumps(html, ensure_ascii=False)
    with io.open(os.path.join(here, 'worker.js'), 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)

    print('worker.js generated:', len(out), 'chars')


if __name__ == '__main__':
    main()
