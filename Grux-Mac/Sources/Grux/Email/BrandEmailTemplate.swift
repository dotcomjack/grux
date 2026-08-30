import Foundation

// BrandEmailTemplate: wraps a support reply in an HTML email shell, so an
// outbound reply looks like a real branded email (header, type, dark-mode,
// footer) instead of a plain-text blurb.
//
// Every brand voice renders through one neutral shell. There is deliberately
// no bespoke per-brand artwork compiled in here: a shell carries a specific
// company's fonts, palette, tagline and postal line, and none of that belongs
// in a general-purpose tool. The header reads the brand voice the account is
// configured with, and the footer link is omitted when no site is known.
//
// Pure string building, unit tested. The reply text is HTML-escaped and split
// into paragraphs; the plain text is still sent alongside as the fallback.
enum BrandEmailTemplate {

    static func html(voice: String, replyText: String) -> String {
        generic(brand: brandName(voice), site: brandSite(voice),
                body: paragraphs(replyText, ink: "#1a1a1a"))
    }

    // Reply text -> escaped HTML paragraphs. A blank line starts a new <p>; a
    // single newline becomes <br>.
    nonisolated static func paragraphs(_ text: String, ink: String) -> String {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let safe = blocks.isEmpty ? [""] : blocks
        return safe.map { b in
            let inner = escape(b).replacingOccurrences(of: "\n", with: "<br>")
            return "<p style=\"margin:0 0 16px;font-size:16px;line-height:1.6;color:\(ink)\">\(inner)</p>"
        }.joined()
    }

    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Shell

    nonisolated private static func generic(brand: String, site: String, body: String) -> String {
        let sans = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
        let footerSite = site.isEmpty ? "" : "<p style=\"margin:8px 0 0;font-size:13px;color:#777;text-align:center\"><a href=\"https://\(site)\" style=\"color:#777;text-decoration:underline\">\(escape(site))</a></p>"
        return """
        <!doctype html><html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><title>\(escape(brand))</title></head>
        <body style="margin:0;padding:0;width:100%;background:#f4f4f5;font-family:\(sans);color:#1a1a1a">
        <table width="100%" cellpadding="0" cellspacing="0" role="presentation" style="width:100%;background:#f4f4f5"><tr><td align="center" style="padding:40px 20px">
        <table cellpadding="0" cellspacing="0" role="presentation" style="width:100%;max-width:600px;background:#ffffff;border:1px solid #e4e4e7;border-radius:8px">
        <tr><td style="padding:32px 36px 8px;text-align:center"><p style="margin:0;font-size:13px;letter-spacing:0.2em;text-transform:uppercase;color:#3f3f46;font-weight:700">\(escape(brand))</p></td></tr>
        <tr><td style="padding:24px 36px 32px">\(body)</td></tr>
        <tr><td style="padding:0 36px 28px"><div style="height:1px;background:#e4e4e7;margin:0 0 16px"></div>\(footerSite)</td></tr>
        </table>
        </td></tr></table></body></html>
        """
    }

    // Header label. The brand voice token IS the label: there is no built-in
    // roster of company names to look it up in.
    nonisolated private static func brandName(_ voice: String) -> String {
        voice.uppercased()
    }

    // Footer link. Empty until a site is configured, which the shell renders
    // as no footer link at all rather than a broken one.
    nonisolated private static func brandSite(_ voice: String) -> String {
        ""
    }
}
