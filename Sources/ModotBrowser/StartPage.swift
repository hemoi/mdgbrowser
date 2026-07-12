import Foundation

enum StartPage {
    static let url = URL(string: "https://start.modot.local")!

    static let html = #"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>Modot Browser</title>
        <style>
          :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
          * { box-sizing: border-box; }
          body { margin: 0; min-height: 100vh; color: #111; background: #fff; }
          main { width: min(88vw, 700px); margin: 0 auto; padding: max(12vh, 72px) 0 64px; }
          .eyebrow { color: #737373; font-size: 12px; font-weight: 700; letter-spacing: .14em; text-transform: uppercase; }
          h1 { margin: 18px 0 14px; max-width: 620px; font-size: clamp(40px, 8vw, 76px); letter-spacing: -.055em; line-height: .98; }
          .intro { margin: 0; max-width: 520px; color: #666; font-size: 17px; line-height: 1.55; }
          ol { margin: 48px 0 0; padding: 0; list-style: none; border-top: 1px solid #e5e5e5; }
          li { display: grid; grid-template-columns: 34px 1fr; gap: 12px; padding: 17px 0; border-bottom: 1px solid #e5e5e5; }
          .index { color: #0f7a55; font-size: 12px; font-weight: 750; }
          strong { display: block; margin-bottom: 4px; font-size: 14px; }
          li span:last-child { color: #737373; font-size: 13px; line-height: 1.45; }
          @media (prefers-color-scheme: dark) {
            body { color: #fafafa; background: #0a0a0a; }
            .intro, li span:last-child, .eyebrow { color: #a3a3a3; }
            ol, li { border-color: #292929; }
          }
        </style>
      </head>
      <body>
        <main>
          <div class="eyebrow">Modot Browser</div>
          <h1>Your services. One quiet workspace.</h1>
          <p class="intro">Keep Codex, OpenCode, and Tailnet tools close without turning the browser into another dashboard.</p>
          <ol>
            <li><span class="index">01</span><span><strong>Add a Tailnet bookmark</strong>Use the star or the sidebar. No example service is added until you provide a real address.</span></li>
            <li><span class="index">02</span><span><strong>Pin only what stays important</strong>Pinned services remain in the single command row; everything else stays grouped in the sidebar.</span></li>
            <li><span class="index">03</span><span><strong>Split when two tools need attention</strong>Open the left and right panes, then drag the divider to resize them.</span></li>
          </ol>
        </main>
      </body>
    </html>
    """#
}
