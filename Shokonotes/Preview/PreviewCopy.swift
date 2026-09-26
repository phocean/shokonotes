import AppKit
import WebKit

/// Live-preview copy: the DOM selection script for ⌘C, and the fenced-block
/// button injected only by `PreviewHostView`. Print and PDF share the
/// highlighter, not this.
enum PreviewCopy {
    static let buttonClass = "code-copy"
    /// What `PreviewHostView.copy(_:)` evaluates. Named so a test can pin it
    /// without the host inlining a magic string.
    static let selectionScript = "window.getSelection().toString()"
    static let copyBlockFunction = "shokonotesCopyCodeBlock"

    static func write(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func liveUserScript() -> WKUserScript {
        WKUserScript(
            source: userScript(
                copy: NSLocalizedString("Copy", comment: ""),
                copied: NSLocalizedString("Copied", comment: "")
            ),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// ES5. Injects its own `<style>` so print/PDF, which never load this
    /// script, stay unmarked.
    static func userScript(copy: String, copied: String) -> String {
        let css = [
            "pre{position:relative}",
            "pre>.\(buttonClass){",
            "position:absolute;top:.4em;right:.55em;",
            "margin:0;padding:0;border:0;background:transparent;",
            "color:var(--muted);font:small-caption;line-height:1;cursor:pointer;",
            "opacity:.18;-webkit-appearance:none;appearance:none;",
            "user-select:none;-webkit-user-select:none",
            "}",
            "pre:hover>.\(buttonClass){opacity:.8}",
            "pre>.\(buttonClass):hover{opacity:1}",
            "@media (hover:none){pre>.\(buttonClass){opacity:.45}}",
            "@media print{pre>.\(buttonClass){display:none!important}}"
        ].joined()
        return """
        (function(){
        var COPY=\(jsString(copy));
        var COPIED=\(jsString(copied));
        var CLASS=\(jsString(buttonClass));
        var css=\(jsString(css));
        var style=document.createElement("style");
        style.appendChild(document.createTextNode(css));
        (document.head||document.documentElement).appendChild(style);
        function copyPre(pre,btn){
        var code=pre.querySelector("code");
        if(!code)return "";
        var text=code.innerText;
        var ta=document.createElement("textarea");
        ta.value=text;
        ta.setAttribute("readonly","");
        ta.style.position="fixed";
        ta.style.left="-9999px";
        document.body.appendChild(ta);
        ta.select();
        try{document.execCommand("copy");}catch(e){}
        document.body.removeChild(ta);
        if(btn){
        btn.textContent=COPIED;
        setTimeout(function(){btn.textContent=COPY;},1200);
        }
        return text;
        }
        window.\(copyBlockFunction)=function(pre){return copyPre(pre,null);};
        var blocks=document.querySelectorAll("pre");
        for(var i=0;i<blocks.length;i++){
        var pre=blocks[i];
        if(pre.querySelector("."+CLASS))continue;
        if(!pre.querySelector("code"))continue;
        var btn=document.createElement("button");
        btn.type="button";
        btn.className=CLASS;
        btn.textContent=COPY;
        btn.addEventListener("click",function(ev){
        ev.preventDefault();
        ev.stopPropagation();
        copyPre(this.parentNode,this);
        });
        pre.appendChild(btn);
        }
        })();
        """
    }

    private static func jsString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count + 8)
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\u{2028}": escaped += "\\u2028"
            case "\u{2029}": escaped += "\\u2029"
            case "<": escaped += "\\u003C"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
